-- src/db/mysql.lua — MySQL/MariaDB adapter
-- Inherits shared logic from base adapter.
-- Overrides: connect, send_query, poll, get_result, list_tables, get_columns, capabilities.
-- Async: send_query uses mysql_real_query_start (MariaDB nonblocking).
-- poll() uses mysql_real_query_cont with internally stored status.
-- get_result() BLOCKS via mysql_store_result() — documented limitation.

local adapter = require("src.db.adapter")
local base = require("src.db.base")

local M = {}
M.__index = M
setmetatable(M, { __index = base })

-- Escape a MySQL identifier for use in catalog queries.
local function escape_identifier(name)
    return '`' .. tostring(name):gsub('`', '``') .. '`'
end

function M.new()
    local self = base.new()
    self._poll_status = 0
    return setmetatable(self, M)
end

-- Connect to a MySQL/MariaDB database.
function M:connect(config)
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
function M:send_query(sql)
    if self._state ~= adapter.READY then
        return false, "adapter not ready"
    end

    self._state = adapter.QUERYING
    self._error = nil
    self:_invalidate_columns()
    self._poll_status = 0

    local status, ret = self._conn:send_query(sql)
    self._poll_status = status

    if status == 0 then
        if ret ~= 0 then
            self._state = adapter.ERROR
            self._error = "query failed: " .. tostring(ret)
            return false, self._error
        end
        self._state = adapter.RESULT_READY
        return true
    end

    return true
end

-- Poll for query completion. Uses stored status from send_query/previous poll.
function M:poll()
    if self._state ~= adapter.QUERYING then
        return false
    end

    local busy, new_status = self._conn:poll(self._poll_status)
    self._poll_status = new_status

    if busy then
        return true
    end

    self._state = adapter.RESULT_READY
    return false
end

-- Get the result (BLOCKING via mysql_store_result).
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

-- List tables via SHOW TABLES.
function M:list_tables()
    return self:_fetch_all(
        "SHOW TABLES",
        function(row) return row[1] or "" end
    )
end

-- Get columns for a table via SHOW COLUMNS FROM.
function M:get_columns(table_name)
    local escaped = escape_identifier(table_name)
    return self:_fetch_all(
        "SHOW COLUMNS FROM " .. escaped,
        function(row)
            return {
                name = row.Field or row[1],
                type = row.Type or row[2],
                notnull = (row.Null or row[3]) == "NO",
                pk = (row.Key or row[4]) == "PRI",
            }
        end
    )
end

-- Driver capabilities.
function M:capabilities()
    return {
        query_async = true,
        result_streaming = true,
        result_fetch_async = false,  -- mysql_store_result() blocks
        early_close_requires_drain = false,
    }
end

return M
