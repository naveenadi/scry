-- src/db/base.lua — base adapter with shared logic
-- Concrete adapters inherit via __index and override driver-specific methods.
-- Shared: next_row(), columns(), cancel(), ping(), close(), state(), error()
-- Driver-specific (must override): connect(), send_query(), poll(), get_result()
-- Driver-specific (override for custom SQL): list_tables(), get_columns()
-- Driver-specific (override for custom behavior): close_result(), capabilities()

local adapter = require("src.db.adapter")

local M = {}
M.__index = M

-- Create a new base adapter instance.
-- Concrete adapters call this and setmetatable to their own table.
function M.new()
    local self = {
        _state = adapter.DISCONNECTED,
        _env = nil,
        _conn = nil,
        _cursor = nil,
        _columns = nil,
        _error = nil,
    }
    return setmetatable(self, M)
end

-- Get current state.
function M:state()
    return self._state
end

-- Get last error message.
function M:error()
    return self._error
end

-- Get column names. Valid after get_result() returns a cursor.
-- Returns flat array of name strings.
-- Caches result — call _invalidate_columns() when cursor changes.
function M:columns()
    if not self._cursor then
        return {}
    end
    if self._columns then
        return self._columns
    end
    local ok, names = pcall(function() return self._cursor:getcolnames() end)
    if ok and names then
        self._columns = names
    else
        self._columns = {}
    end
    return self._columns
end

-- Get next row. Returns a table of values, or nil at end of results.
-- Named fields + positional fields for the grid.
-- NULL values replaced with adapter.NULL sentinel.
function M:next_row()
    if not self._cursor then
        return nil
    end

    local row = self._cursor:fetch({}, "a")
    if not row then
        return nil
    end

    -- Keep named fields for callers and add positional fields for the grid.
    -- LuaSQL omits NULL-valued named fields, so use column metadata to
    -- preserve their position with the adapter NULL sentinel.
    for i, name in ipairs(self._columns or {}) do
        if row[name] == nil then
            row[name] = adapter.NULL
        end
        row[i] = row[name]
    end

    return row
end

-- Close the current result set.
-- Override for driver-specific cleanup (e.g., Postgres drain).
function M:close_result()
    if self._cursor then
        pcall(function() self._cursor:close() end)
        self._cursor = nil
    end
    self._columns = nil
    self._state = adapter.READY
end

-- Cancel the current operation.
-- QUERYING: close connection (needs reconnect per ADR-0004).
-- FETCHING: stop consumption, return to READY.
function M:cancel()
    if self._state == adapter.QUERYING then
        self:close()
        self._state = adapter.CANCELED
    elseif self._state == adapter.FETCHING then
        self:close_result()
    end
end

-- Health check.
function M:ping()
    if self._state ~= adapter.READY then
        return false
    end
    local cursor, err = self._conn:execute("SELECT 1")
    if cursor then
        cursor:close()
        return true
    end
    return false
end

-- Close the connection and release all resources.
function M:close()
    if self._cursor then
        pcall(function() self._cursor:close() end)
        self._cursor = nil
    end
    if self._conn then
        pcall(function() self._conn:close() end)
        self._conn = nil
    end
    if self._env then
        pcall(function() self._env:close() end)
        self._env = nil
    end
    self._state = adapter.DISCONNECTED
end

-- Invalidate cached column metadata. Call when cursor changes.
function M:_invalidate_columns()
    self._columns = nil
end

-- Blocking catalog query helper. Requires READY state and _conn.
function M:_fetch_all(sql, map_row)
    if self._state ~= adapter.READY or not self._conn then
        return {}
    end

    local out = {}
    local cursor = self._conn:execute(sql)
    if not cursor then
        return out
    end

    local row = cursor:fetch({}, "a")
    while row do
        table.insert(out, map_row(row))
        row = cursor:fetch({}, "a")
    end
    cursor:close()
    return out
end

-- List tables. Override with driver-specific SQL.
-- Default: empty list.
function M:list_tables()
    return {}
end

-- Get columns for a table. Override with driver-specific SQL.
-- Default: empty list.
function M:get_columns(table_name)
    return {}
end

-- Driver capabilities. Override for driver-specific behavior.
function M:capabilities()
    return {
        query_async = false,
        result_streaming = true,
        result_fetch_async = false,
        early_close_requires_drain = false,
    }
end

-- Driver-specific methods that concrete adapters MUST override.
-- These are stubs that error if called directly.

function M:connect(config)
    error("connect() not implemented — override in concrete adapter", 2)
end

function M:send_query(sql)
    error("send_query() not implemented — override in concrete adapter", 2)
end

function M:poll()
    error("poll() not implemented — override in concrete adapter", 2)
end

function M:get_result()
    error("get_result() not implemented — override in concrete adapter", 2)
end

return M
