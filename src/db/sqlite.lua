-- src/db/sqlite.lua — SQLite adapter
-- Inherits shared logic from base adapter.
-- Overrides: connect, send_query, get_result, list_tables, get_columns, capabilities.

local adapter = require("src.db.adapter")
local base = require("src.db.base")

local M = {}
M.__index = M
setmetatable(M, { __index = base })

function M.new()
    return setmetatable(base.new(), M)
end

-- Connect to a SQLite database.
function M:connect(config)
    self._database = config.database or ":memory:"
    self._state = adapter.CONNECTING

    local luasql = require("luasql.sqlite3")
    local env = luasql.sqlite3()
    if not env then
        self._state = adapter.ERROR
        self._error = "failed to create SQLite environment"
        return false, self._error
    end

    local conn, err = env:connect(self._database)
    if not conn then
        self._state = adapter.ERROR
        self._error = err or "failed to connect to SQLite database"
        env:close()
        return false, self._error
    end

    self._env = env
    self._conn = conn
    self._state = adapter.READY
    return true
end

-- Send a query (blocking for SQLite — execute immediately).
function M:send_query(sql)
    if self._state ~= adapter.READY then
        return false, "adapter not ready"
    end

    self._state = adapter.QUERYING
    self._error = nil
    self:_invalidate_columns()

    local cursor, exec_err = self._conn:execute(sql)
    self._cursor = cursor

    if exec_err then
        self._state = adapter.READY
        self._error = tostring(exec_err)
        return false, self._error
    end

    -- Non-SELECT: cursor is nil, no rows to fetch
    -- SELECT: cursor is ready
    self._state = adapter.RESULT_READY
    return true
end

-- Poll (stub for SQLite — always returns false).
function M:poll()
    return false
end

-- Get result (transitions to FETCHING).
-- SQLite: cursor already set by send_query; just get column names.
function M:get_result()
    if self._state ~= adapter.RESULT_READY then
        return false, "not in RESULT_READY state"
    end

    -- Cache column names from cursor when a result set exists.
    if self._cursor then self:columns() end
    self._state = adapter.FETCHING
    return true
end

-- List tables via sqlite_master.
function M:list_tables()
    return self:_fetch_all(
        "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name",
        function(row) return row.name or row[1] end
    )
end

-- Get columns for a table via PRAGMA table_info.
function M:get_columns(table_name)
    local escaped = table_name:gsub("'", "''")
    return self:_fetch_all(
        "PRAGMA table_info('" .. escaped .. "')",
        function(row)
            return {
                name = row.name,
                type = row.type,
                notnull = row.notnull == 1,
                pk = row.pk == 1,
            }
        end
    )
end

-- Driver capabilities.
function M:capabilities()
    return {
        query_async = false,
        result_streaming = true,
        result_fetch_async = false,
        early_close_requires_drain = false,
    }
end

return M
