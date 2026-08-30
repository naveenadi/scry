-- src/history/store.lua — query history persisted to history.jsonl
-- Plain data, one JSON object per line. Never executed as code.
-- One entry per Execution (full buffer/selection text, even multi-statement).
-- Appended on every Execution regardless of outcome.
-- Oldest entries pruned when count exceeds history_limit.
-- Entries over history_max_entry_bytes truncated/flagged, not silently dropped.

local M = {}

-- Minimal JSON encoder (no external dependency).
-- Handles: string, number, boolean, nil, table (array or object).
local function json_encode(val)
    local t = type(val)
    if val == nil then return "null" end
    if t == "boolean" then return val and "true" or "false" end
    if t == "number" then return tostring(val) end
    if t == "string" then
        -- Escape special characters
        local s = val:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
        return '"' .. s .. '"'
    end
    if t == "table" then
        -- Check if array (sequential integer keys)
        local is_array = true
        local max_i = 0
        for k, _ in pairs(val) do
            if type(k) ~= "number" or k ~= math.floor(k) or k < 1 then
                is_array = false
                break
            end
            if k > max_i then max_i = k end
        end
        if is_array and max_i == #val then
            local parts = {}
            for i = 1, #val do
                parts[i] = json_encode(val[i])
            end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            local parts = {}
            for k, v in pairs(val) do
                if type(k) == "string" then
                    table.insert(parts, json_encode(k) .. ":" .. json_encode(v))
                end
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    end
    return "null"
end

-- Minimal JSON decoder (handles the subset we write).
local function json_decode(str)
    if not str or str == "" then return nil end
    local ok, result = pcall(function()
        -- Transform JSON to Lua table literal:
        --   {"key":value} → {["key"]=value}
        --   null → nil, true/false/numbers/strings as-is
        local lua_str = str
            :gsub("null", "nil")
            :gsub('"([^"]+)":', '["%1"]=')  -- quote keys
        local fn = load("return " .. lua_str)
        if fn then return fn() end
        return nil
    end)
    if ok then return result end
    return nil
end

-- Create a new history store.
-- platform: platform module (must have history_path())
-- opts: { history_limit = N, history_max_entry_bytes = N }
function M.new(platform, opts)
    opts = opts or {}
    local self = {
        _path = platform.history_path(),
        _limit = opts.history_limit or 1000,
        _max_entry_bytes = opts.history_max_entry_bytes or 100000,
        _entries = {},  -- newest first
    }

    -- Ensure the state directory exists.
    local function ensure_dir()
        local dir = self._path:match("(.+)/[^/]+$") or self._path:match("(.+)\\[^\\]+$")
        if dir then
            os.execute('mkdir -p "' .. dir .. '" 2>/dev/null')
        end
    end

    -- Load history from disk. Called once on startup.
    function self:load()
        self._entries = {}
        local f = io.open(self._path, "r")
        if not f then return end
        for line in f:lines() do
            if line ~= "" then
                local entry = json_decode(line)
                if entry and entry.sql then
                    table.insert(self._entries, entry)
                end
            end
        end
        f:close()
        -- Newest first
        -- File is append-only (oldest first on disk), so reverse
        local reversed = {}
        for i = #self._entries, 1, -1 do
            table.insert(reversed, self._entries[i])
        end
        self._entries = reversed
        self:_prune()
    end

    -- Append an entry for an Execution.
    -- sql: the buffer/selection text that was executed
    -- outcome: "success" | "error" | "cancelled"
    function self:append(sql, outcome)
        if not sql or sql == "" then return end

        local truncated = false
        if #sql > self._max_entry_bytes then
            sql = sql:sub(1, self._max_entry_bytes)
            truncated = true
        end

        local entry = {
            sql = sql,
            outcome = outcome or "success",
            timestamp = os.time(),
            truncated = truncated,
        }

        -- Insert at front (newest first)
        table.insert(self._entries, 1, entry)
        self:_prune()

        -- Persist to disk
        self:_flush()
    end

    -- Get entries (newest first). Returns a copy.
    function self:entries()
        local copy = {}
        for i, e in ipairs(self._entries) do
            copy[i] = e
        end
        return copy
    end

    -- Get SQL strings only (newest first). For Ctrl+p/Ctrl+n navigation.
    function self:sql_list()
        local list = {}
        for i, e in ipairs(self._entries) do
            list[i] = e.sql
        end
        return list
    end

    -- Search by substring (case-insensitive). Returns matching entries.
    function self:search(query)
        if not query or query == "" then return self:entries() end
        local lower = query:lower()
        local results = {}
        for _, e in ipairs(self._entries) do
            if e.sql:lower():find(lower, 1, true) then
                table.insert(results, e)
            end
        end
        return results
    end

    -- Number of entries.
    function self:count()
        return #self._entries
    end

    -- Prune to limit (remove oldest).
    function self:_prune()
        while #self._entries > self._limit do
            table.remove(self._entries)
        end
    end

    -- Flush all entries to disk (rewrite file).
    -- File format: oldest first (reverse of in-memory order).
    function self:_flush()
        ensure_dir()
        local f = io.open(self._path, "w")
        if not f then return end
        -- Write oldest first (reverse of in-memory newest-first order)
        for i = #self._entries, 1, -1 do
            f:write(json_encode(self._entries[i]) .. "\n")
        end
        f:close()
    end

    return self
end

return M
