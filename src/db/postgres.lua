-- src/db/postgres.lua — PostgreSQL adapter
-- Inherits shared logic from base adapter.
-- Overrides: connect, send_query, poll, get_result, close_result,
--            list_tables, get_columns, capabilities.
-- Async: send_query / poll / get_result / getfd (libpq PQsendQuery / PQconsumeInput / PQisBusy / PQgetResult).
-- close_result() drains remaining results — luasql's cursor close does NOT do this.

local adapter = require("src.db.adapter")
local base = require("src.db.base")

local M = {}
M.__index = M
setmetatable(M, { __index = base })

function M.new()
    return setmetatable(base.new(), M)
end

-- Connect to a PostgreSQL database.
function M:connect(config)
    self._host = config.host or "localhost"
    self._port = config.port or 5432
    self._database = config.database or "postgres"
    self._username = config.username or ""
    self._password = config.password or ""
    self._state = adapter.CONNECTING

    local luasql = require("luasql.postgres")
    local env = luasql.postgres()
    if not env then
        self._state = adapter.ERROR
        self._error = "failed to create PostgreSQL environment"
        return false, self._error
    end

    local conn, err = env:connect(self._database, self._username, self._password, self._host, self._port)
    if not conn then
        self._state = adapter.ERROR
        self._error = err or "failed to connect to PostgreSQL"
        env:close()
        return false, self._error
    end

    self._env = env
    self._conn = conn
    self._state = adapter.READY
    return true
end

-- Send a query (non-blocking via libpq PQsendQuery).
function M:send_query(sql)
    if self._state ~= adapter.READY then
        return false, "adapter not ready"
    end

    self._state = adapter.QUERYING
    self._error = nil
    self:_invalidate_columns()

    local ok, flush_res = self._conn:send_query(sql)
    if not ok then
        self._state = adapter.ERROR
        self._error = tostring(flush_res)
        return false, self._error
    end

    return true
end

-- Poll for query completion (non-blocking via libpq PQconsumeInput + PQisBusy).
function M:poll()
    if self._state ~= adapter.QUERYING then
        return false
    end

    local busy, err = self._conn:poll()
    if err then
        self._state = adapter.ERROR
        self._error = tostring(err)
        return false
    end

    if busy then
        return true
    end

    self._state = adapter.RESULT_READY
    return false
end

-- Get the result (calls luasql get_result internally).
function M:get_result()
    if self._state ~= adapter.RESULT_READY then
        return nil, "not in RESULT_READY state"
    end

    local result, err = self._conn:get_result()

    if err then
        self._state = adapter.ERROR
        self._error = tostring(err)
        return nil, self._error
    end

    if result == nil then
        self._state = adapter.READY
        return nil
    end

    if type(result) == "number" then
        self._state = adapter.FETCHING
        self._cursor = nil
        return result
    end

    self._cursor = result
    self:_invalidate_columns()
    self._state = adapter.FETCHING
    return true
end

-- Close the current result set and drain remaining results.
-- CRITICAL: luasql's cursor close does NOT drain PQgetResult chain.
function M:close_result()
    if self._cursor then
        pcall(function() self._cursor:close() end)
        self._cursor = nil
    end
    self:_invalidate_columns()

    -- Drain any remaining results from the connection.
    if self._conn and self._state ~= adapter.ERROR then
        local function drain()
            while true do
                local res, err = self._conn:get_result()
                if res == nil then break end
                if type(res) ~= "number" and res.close then
                    pcall(function() res:close() end)
                end
            end
        end
        pcall(drain)
    end

    self._state = adapter.READY
end

-- List tables via information_schema.
function M:list_tables()
    return self:_fetch_all(
        "SELECT table_name FROM information_schema.tables "
            .. "WHERE table_schema = 'public' ORDER BY table_name",
        function(row) return row.table_name or row[1] end
    )
end

-- Get columns for a table via information_schema.
function M:get_columns(table_name)
    return self:_fetch_all(
        "SELECT column_name, data_type, is_nullable, column_default "
            .. "FROM information_schema.columns "
            .. "WHERE table_schema = 'public' AND table_name = '"
            .. table_name:gsub("'", "''") .. "' "
            .. "ORDER BY ordinal_position",
        function(row)
            return {
                name = row.column_name,
                type = row.data_type,
                notnull = row.is_nullable == "NO",
                pk = false,
            }
        end
    )
end

-- Driver capabilities.
function M:capabilities()
    return {
        query_async = true,
        result_streaming = true,
        result_fetch_async = true,
        early_close_requires_drain = true,
    }
end

return M
