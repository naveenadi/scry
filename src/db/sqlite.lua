-- src/db/sqlite.lua — SQLite adapter
-- Implements the adapter contract for SQLite databases.

local adapter = require("src.db.adapter")

local M = {}

-- Create a new SQLite adapter.
function M.new()
    local self = {
        _state = adapter.DISCONNECTED,
        _env = nil,
        _conn = nil,
        _cursor = nil,
        _columns = nil,
        _error = nil,
        _read_only = false,
        _database = nil,
    }

    -- Connect to a SQLite database.
    function self:connect(config)
        self._database = config.database or ":memory:"
        self._read_only = config.read_only or false
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

    -- Send a query (non-blocking for SQLite — prepare only).
    function self:send_query(sql)
        if self._state ~= adapter.READY then
            return false, "adapter not ready"
        end

        self._state = adapter.QUERYING
        self._error = nil
        self._columns = nil

        -- SQLite: prepare the statement (non-blocking)
        -- The actual execution happens in get_result()
        -- For simplicity in Phase 1, we execute directly
        local ok, err = pcall(function()
            self._cursor = self._conn:execute(sql)
        end)

        if not ok then
            self._state = adapter.ERROR
            self._error = tostring(err)
            return false, self._error
        end

        -- If cursor is nil, it's a non-SELECT statement (INSERT/UPDATE/DELETE/etc.)
        -- that returns affected rows count
        if self._cursor == nil then
            -- Non-SELECT: get affected rows
            self._state = adapter.RESULT_READY
            return true
        end

        -- SELECT: cursor is ready
        self._state = adapter.RESULT_READY
        return true
    end

    -- Poll (stub for SQLite — always returns false).
    function self:poll()
        -- SQLite is local-file fast, no async polling needed
        return false
    end

    -- Get result (transitions to FETCHING).
    function self:get_result()
        if self._state ~= adapter.RESULT_READY then
            return false, "not in RESULT_READY state"
        end

        if self._cursor == nil then
            -- Non-SELECT statement, no rows to fetch
            self._state = adapter.FETCHING
            return true
        end

        -- Get column names from the cursor
        self._columns = {}
        -- LuaSQL cursor:getcolnames() returns column names
        local ok, names = pcall(function()
            return self._cursor:getcolnames()
        end)
        if ok and names then
            self._columns = names
        end

        self._state = adapter.FETCHING
        return true
    end

    -- Get current state.
    function self:state()
        return self._state
    end

    -- Get last error.
    function self:error()
        return self._error
    end

    -- Get column metadata.
    function self:columns()
        return self._columns or {}
    end

    -- Get next row. Returns nil at end of results.
    function self:next_row()
        if self._state ~= adapter.FETCHING then
            return nil
        end

        if self._cursor == nil then
            return nil
        end

        -- LuaSQL cursor:fetch returns a table or nil
        local row = self._cursor:fetch({}, "a")
        if row == nil then
            return nil
        end

        -- Convert NULL values to sentinel
        for k, v in pairs(row) do
            if v == nil then
                row[k] = adapter.NULL
            end
        end

        return row
    end

    -- Close the current result.
    function self:close_result()
        if self._cursor then
            pcall(function() self._cursor:close() end)
            self._cursor = nil
        end
        self._columns = nil
        self._state = adapter.READY
    end

    -- Cancel (close-and-reconnect for QUERYING, close_result for FETCHING).
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

    -- List tables via sqlite_master.
    function self:list_tables()
        if self._state ~= adapter.READY then
            return {}
        end

        local tables = {}
        local cursor, err = self._conn:execute(
            "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
        )
        if cursor then
            local row = cursor:fetch({}, "a")
            while row do
                table.insert(tables, row.name or row[1])
                row = cursor:fetch({}, "a")
            end
            cursor:close()
        end
        return tables
    end

    -- Get columns for a table via PRAGMA table_info.
    function self:get_columns(table_name)
        if self._state ~= adapter.READY then
            return {}
        end

        -- Escape table name to prevent injection
        local escaped = table_name:gsub("'", "''")
        local columns = {}
        local cursor, err = self._conn:execute(
            "PRAGMA table_info('" .. escaped .. "')"
        )
        if cursor then
            local row = cursor:fetch({}, "a")
            while row do
                table.insert(columns, {
                    name = row.name,
                    type = row.type,
                    notnull = row.notnull == 1,
                    pk = row.pk == 1,
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
        local cursor, err = self._conn:execute("SELECT sqlite_version()")
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

    -- Driver capabilities.
    function self:capabilities()
        return {
            query_async = false,
            result_streaming = true,
            result_fetch_async = false,
            early_close_requires_drain = false,
        }
    end

    return self
end

return M
