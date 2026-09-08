-- tests/export/stream_test.lua — streaming export via adapter

package.path = "./?.lua;./src/?.lua;./tests/?.lua;" .. package.path

local h = require("test_helper")
local stream = require("export.stream")
local parse = require("sql.parse")

local function mock_adapter(rows)
    local self = {
        _state = "READY",
        _columns = { "id" },
        _rows = rows,
        _row_index = 0,
    }

    function self:send_query(sql)
        self._last_sql = sql
        self._state = "QUERYING"
        self._row_index = 0
        return true
    end
    function self:poll()
        if self._state == "QUERYING" then
            self._state = "RESULT_READY"
        end
    end
    function self:get_result()
        self._state = "FETCHING"
        return true
    end
    function self:state() return self._state end
    function self:error() return nil end
    function self:columns() return self._columns end
    function self:next_row()
        self._row_index = self._row_index + 1
        return self._rows[self._row_index]
    end
    function self:close_result() self._state = "READY" end
    function self:capabilities()
        return { result_fetch_async = false }
    end

    return self
end

h.test("eligible_sql: single SELECT", function()
    local sql, err = stream.eligible_sql({
        status = "success",
        statements = {
            { sql = "SELECT 1", status = "success", columns = { "id" }, row_count = 1 },
        },
    })
    h.assert_eq(sql, "SELECT 1", "sql")
    h.assert_eq(err, nil, "err")
end)

h.test("eligible_sql: rejects multi-statement", function()
    local sql, err = stream.eligible_sql({
        status = "success",
        statements = {
            { sql = "SELECT 1", status = "success", columns = { "id" } },
            { sql = "SELECT 2", status = "success", columns = { "id" } },
        },
    })
    h.assert_eq(sql, nil, "sql")
    h.assert_true(err:find("single") ~= nil, "err mentions single")
end)

h.test("eligible_sql: rejects INSERT", function()
    local sql, err = stream.eligible_sql({
        status = "success",
        statements = {
            { sql = "INSERT INTO t VALUES (1)", status = "success", columns = {} },
        },
    })
    h.assert_eq(sql, nil, "sql")
    h.assert_true(err:find("SELECT") ~= nil, "err mentions SELECT")
end)

h.test("to_file: streams all rows not grid cap", function()
    local rows = {}
    for i = 1, 5 do rows[i] = { i } end
    local adapter = mock_adapter(rows)
    local path = os.tmpname() .. ".csv"

    local ok, count = stream.to_file(adapter, "SELECT id FROM t", "csv", path)
    h.assert_true(ok, "export ok")
    h.assert_eq(count, 5, "row count")

    local f = io.open(path, "r")
    local content = f:read("*a")
    f:close()
    os.remove(path)

    h.assert_true(content:find("1\n") ~= nil, "has row 1")
    h.assert_true(content:find("5\n") ~= nil, "has row 5")
end)

h.summary()
