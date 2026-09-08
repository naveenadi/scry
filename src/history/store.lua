-- src/history/store.lua — query history persisted to history.jsonl
-- Plain data, one JSON object per line. Never executed as code.
-- One entry per Execution (full buffer/selection text, even multi-statement).
-- Appended on every Execution regardless of outcome.
-- Oldest entries pruned when count exceeds history_limit.
-- Entries over history_max_entry_bytes truncated/flagged, not silently dropped.

local json = require("src.utils.json")

local M = {}

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
                local entry = json.decode(line)
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
            f:write(json.encode(self._entries[i]) .. "\n")
        end
        f:close()
    end

    return self
end

return M
