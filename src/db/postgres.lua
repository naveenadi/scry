-- src/db/postgres.lua — PostgreSQL adapter
-- Implements the adapter contract for PostgreSQL via luasql's async API.
-- Async: send_query / poll / get_result / getfd (libpq PQsendQuery / PQconsumeInput / PQisBusy / PQgetResult).
-- close_result() drains remaining results — luasql's cursor close does NOT do this.

local adapter = require("src.db.adapter")
local row_builder = require("src.db.row_builder")

local M = {}

-- Escape a PostgreSQL identifier (table/column name) for use in catalog queries.
-- Doubles embedded quotes; wraps in double quotes.
local function escape_identifier(name)
    return '"' .. tostring(name):gsub('"', '""') .. '"'
end

function M.new()
    local self = {
        _state = adapter.DISCONNECTED,
        _env = nil,
        _conn = nil,
        _cursor = nil,
        _columns = nil,
        _error = nil,
        _host = nil,
        _port = nil,
        _database = nil,
        _username = nil,
        _password = nil,
    }

    -- Connect to a PostgreSQL database.
    function self:connect(config)
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
    function self:send_query(sql)
        if self._state ~= adapter.READY then
            return false, "adapter not ready"
        end

        self._state = adapter.QUERYING
        self._error = nil
        self._columns = nil

        local ok, flush_res = self._conn:send_query(sql)
        if not ok then
            self._state = adapter.ERROR
            self._error = tostring(flush_res)
            return false, self._error
        end

        -- flush_res: 0 = fully sent, 1 = still flushing
        -- Either way, the query is in flight — poll() will drive it.
        return true
    end

    -- Poll for query completion (non-blocking via libpq PQconsumeInput + PQisBusy).
    -- Returns true if still in flight, false if result is ready.
    function self:poll()
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
            return true -- still in flight
        end

        -- Result is ready — execution engine checks adapter:state() for RESULT_READY
        self._state = adapter.RESULT_READY
        return false
    end

    -- Get the result (calls luasql get_result internally).
    -- Called by execution engine after poll() reports RESULT_READY.
    -- Returns: true for SELECT (cursor ready), number for non-SELECT (rows affected), nil+err on error.
    -- After this, columns() and next_row() are valid.
    function self:get_result()
        if self._state ~= adapter.RESULT_READY then
            return nil, "not in RESULT_READY state"
        end

        local result, err = self._conn:get_result()

        if err then
            -- Error from PQgetResult (PGRES_FATAL_ERROR etc.)
            self._state = adapter.ERROR
            self._error = tostring(err)
            return nil, self._error
        end

        if result == nil then
            -- No more results (shouldn't happen for single-statement, but handle it)
            self._state = adapter.READY
            return nil
        end

        if type(result) == "number" then
            -- Non-SELECT: rows affected
            self._state = adapter.FETCHING
            self._cursor = nil
            return result
        end

        -- SELECT: result is a cursor
        self._cursor = result
        self._columns = nil
        self._state = adapter.FETCHING
        return true
    end

    -- Get column names. Valid after get_result() returns a cursor.
    -- Returns flat array of name strings (matches SQLite adapter pattern).
    function self:columns()
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

    -- Get the next row. Returns a table of values, or nil at end of results.
    -- Named fields + positional fields for the grid (matches SQLite adapter pattern).
    -- NULL values are replaced with adapter.NULL sentinel.
    function self:next_row()
        if not self._cursor then
            return nil
        end

        local row, err = self._cursor:fetch({}, "a")
        if not row then
            return nil
        end

        return row_builder.normalize_row(row, self._columns)
    end

    -- Close the current result set and drain remaining results.
    -- CRITICAL: luasql's cursor close does NOT drain PQgetResult chain.
    -- We must drain manually or the connection is left dirty.
    function self:close_result()
        if self._cursor then
            pcall(function() self._cursor:close() end)
            self._cursor = nil
        end
        self._columns = nil

        -- Drain any remaining results from the connection.
        -- For single-statement queries there's typically one result,
        -- but multi-statement or stored procedures may have more.
        if self._conn and self._state ~= adapter.ERROR then
            local function drain()
                while true do
                    local res, err = self._conn:get_result()
                    if res == nil then break end
                    -- Discard each remaining result
                    if type(res) ~= "number" and res.close then
                        pcall(function() res:close() end)
                    end
                end
            end
            pcall(drain)
        end

        self._state = adapter.READY
    end

    -- Cancel the current query (close-and-reconnect per ADR-0004).
    function self:cancel()
        if self._state == adapter.QUERYING then
            -- Close connection, need reconnect
            self:close()
            self._state = adapter.CANCELED
        elseif self._state == adapter.FETCHING then
            -- Stop consumption, return to READY
            self:close_result()
        end
    end

    -- List tables via information_schema.
    function self:list_tables()
        if self._state ~= adapter.READY then
            return {}
        end

        local tables = {}
        local cursor, err = self._conn:execute(
            "SELECT table_name FROM information_schema.tables "
            .. "WHERE table_schema = 'public' ORDER BY table_name"
        )
        if cursor then
            local row = cursor:fetch({}, "a")
            while row do
                table.insert(tables, row.table_name or row[1])
                row = cursor:fetch({}, "a")
            end
            cursor:close()
        end
        return tables
    end

    -- Get columns for a table via information_schema.
    function self:get_columns(table_name)
        if self._state ~= adapter.READY then
            return {}
        end

        local escaped = escape_identifier(table_name)
        local columns = {}
        local cursor, err = self._conn:execute(
            "SELECT column_name, data_type, is_nullable, column_default "
            .. "FROM information_schema.columns "
            .. "WHERE table_schema = 'public' AND table_name = '" .. table_name:gsub("'", "''") .. "' "
            .. "ORDER BY ordinal_position"
        )
        if cursor then
            local row = cursor:fetch({}, "a")
            while row do
                table.insert(columns, {
                    name = row.column_name,
                    type = row.data_type,
                    notnull = row.is_nullable == "NO",
                    pk = false, -- information_schema doesn't directly expose PK; good enough for sidebar
                })
                row = cursor:fetch({}, "a")
            end
            cursor:close()
        end
        return columns
    end

    -- Health check.
    function self:ping()
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

    -- Close the connection.
    function self:close()
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

    -- Current state.
    function self:state()
        return self._state
    end

    -- Current error message.
    function self:error()
        return self._error
    end

    -- Driver capabilities.
    function self:capabilities()
        return {
            query_async = true,
            result_streaming = true,
            result_fetch_async = true,
            early_close_requires_drain = true,
        }
    end

    return self
end

return M
