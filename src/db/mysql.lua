-- src/db/mysql.lua — MySQL/MariaDB adapter
-- Implements the adapter contract for MySQL/MariaDB via luasql's async API.
-- Async: send_query uses mysql_real_query_start (MariaDB nonblocking).
-- poll() uses mysql_real_query_cont with internally stored status.
-- get_result() BLOCKS via mysql_store_result() — documented limitation.
-- close_result() is safe — mysql_store_result already pulled all data.

local adapter = require("src.db.adapter")

local M = {}

-- Escape a MySQL identifier for use in catalog queries.
-- Backtick-wraps and doubles embedded backticks.
local function escape_identifier(name)
    return '`' .. tostring(name):gsub('`', '``') .. '`'
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
        _poll_status = 0,  -- MariaDB continuation status from send_query/poll
    }

    -- Connect to a MySQL/MariaDB database.
    function self:connect(config)
        self._host = config.host or "localhost"
        self._port = config.port or 3306
        self._database = config.database or ""
        self._username = config.username or ""
        self._password = config.password or ""
        self._state = adapter.CONNECTING

        local luasql = require("luasql.mysql")
        local env = luasql.mysql()
        if not env then
            self._state = adapter.ERROR
            self._error = "failed to create MySQL environment"
            return false, self._error
        end

        local conn, err = env:connect(self._database, self._username, self._password, self._host, self._port)
        if not conn then
            self._state = adapter.ERROR
            self._error = err or "failed to connect to MySQL"
            env:close()
            return false, self._error
        end

        self._env = env
        self._conn = conn
        self._state = adapter.READY
        return true
    end

    -- Send a query. With MYSQL_OPT_NONBLOCK (MariaDB), uses mysql_real_query_start.
    -- Without it, blocks via mysql_real_query (documented limitation).
    -- Returns: status, ret. status != 0 means still running (need to poll).
    function self:send_query(sql)
        if self._state ~= adapter.READY then
            return false, "adapter not ready"
        end

        self._state = adapter.QUERYING
        self._error = nil
        self._columns = nil
        self._poll_status = 0

        local status, ret = self._conn:send_query(sql)
        self._poll_status = status

        if status == 0 then
            -- Query completed immediately (blocking path or instant query)
            if ret ~= 0 then
                -- Error
                self._state = adapter.ERROR
                self._error = "query failed: " .. tostring(ret)
                return false, self._error
            end
            -- Success — result is ready
            self._state = adapter.RESULT_READY
            return true
        end

        -- Still running (nonblocking path) — need to poll
        return true
    end

    -- Poll for query completion. Uses stored status from send_query/previous poll.
    -- Returns true if still in flight, false if result is ready.
    function self:poll()
        if self._state ~= adapter.QUERYING then
            return false
        end

        local busy, new_status = self._conn:poll(self._poll_status)
        self._poll_status = new_status

        if busy then
            return true -- still in flight
        end

        -- Query completed
        self._state = adapter.RESULT_READY
        return false
    end

    -- Get the result (BLOCKING via mysql_store_result).
    -- Called by execution engine during MATERIALIZING state (result_fetch_async=false).
    -- Returns: true for SELECT (cursor ready), number for non-SELECT (rows affected), nil+err on error.
    function self:get_result()
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

    -- Close the current result set. Safe for MySQL — mysql_store_result already
    -- pulled all data, so mysql_free_result is clean.
    function self:close_result()
        if self._cursor then
            pcall(function() self._cursor:close() end)
            self._cursor = nil
        end
        self._columns = nil
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

    -- List tables via SHOW TABLES.
    function self:list_tables()
        if self._state ~= adapter.READY then
            return {}
        end

        local tables = {}
        local cursor, err = self._conn:execute("SHOW TABLES")
        if cursor then
            local row = cursor:fetch({}, "a")
            while row do
                -- SHOW TABLES returns a single column with the table name
                table.insert(tables, row[1] or row[table_name] or "")
                row = cursor:fetch({}, "a")
            end
            cursor:close()
        end
        return tables
    end

    -- Get columns for a table via SHOW COLUMNS FROM.
    function self:get_columns(table_name)
        if self._state ~= adapter.READY then
            return {}
        end

        local escaped = escape_identifier(table_name)
        local columns = {}
        local cursor, err = self._conn:execute("SHOW COLUMNS FROM " .. escaped)
        if cursor then
            local row = cursor:fetch({}, "a")
            while row do
                table.insert(columns, {
                    name = row.Field or row[1],
                    type = row.Type or row[2],
                    notnull = (row.Null or row[3]) == "NO",
                    pk = (row.Key or row[4]) == "PRI",
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
            result_fetch_async = false,  -- mysql_store_result() blocks
            early_close_requires_drain = false,  -- mysql_store_result already pulled data
        }
    end

    return self
end

return M
