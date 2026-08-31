-- tests/adapters/contract_test.lua – shared adapter contract checks

package.path = "src/?.lua;" .. package.path

local h = require("tests.test_helper")
local adapter_contract = require("src.db.adapter")
local sqlite = require("src.db.sqlite")

local function mock_adapter()
    local self = {
        _state = adapter_contract.READY,
        _columns = { "id", "name" },
        _rows = { { id = 1, name = "x" }, { id = 2, name = nil } },
        _row_index = 0,
    }

    function self:connect() self._state = adapter_contract.READY; return true end
    function self:send_query()
        self._state = adapter_contract.QUERYING
        self._row_index = 0
        return true
    end
    function self:poll()
        if self._state == adapter_contract.QUERYING then
            self._state = adapter_contract.RESULT_READY
        end
        return false
    end
    function self:get_result()
        self._state = adapter_contract.FETCHING
        return true
    end
    function self:state() return self._state end
    function self:error() return nil end
    function self:columns() return self._columns end
    function self:next_row()
        if self._state ~= adapter_contract.FETCHING then return nil end
        self._row_index = self._row_index + 1
        local row = self._rows[self._row_index]
        if not row then return nil end
        for i, name in ipairs(self._columns) do
            if row[name] == nil then row[name] = adapter_contract.NULL end
            row[i] = row[name]
        end
        return row
    end
    function self:close_result() self._state = adapter_contract.READY end
    function self:cancel() self._state = adapter_contract.CANCELED end
    function self:list_tables() return {} end
    function self:get_columns() return {} end
    function self:ping() return true end
    function self:close() self._state = adapter_contract.DISCONNECTED end
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

local function open_result(factory, config)
    local db = factory()
    local ok, err = db:connect(config or { database = ":memory:" })
    h.assert_true(ok, "connect: " .. (err or ""))
    ok, err = db:send_query("SELECT 1 AS id, 'x' AS name")
    h.assert_true(ok, "send_query: " .. (err or ""))
    db:poll()
    h.assert_eq(db:state(), adapter_contract.RESULT_READY, "RESULT_READY after poll")
    ok, err = db:get_result()
    h.assert_true(ok, "get_result: " .. (err or ""))
    h.assert_eq(db:state(), adapter_contract.FETCHING, "FETCHING after get_result")
    return db
end

local function run_contract_tests(name, factory, config, expected_columns)
    h.test("adapter contract: " .. name, function()
        local valid, err = adapter_contract.validate(factory())
        h.assert_true(valid, err or "adapter is invalid")
    end)

    h.test("adapter rows: " .. name, function()
        local db = open_result(factory, config)
        local row = db:next_row()
        h.assert_true(row ~= nil, "first row exists")
        h.assert_eq(row[1], 1, "positional first value")
        h.assert_eq(row[2], "x", "positional second value")
        h.assert_eq(row[1], row[expected_columns and expected_columns[1] or "id"], "named first value")
        db:close_result()
        h.assert_nil(db:next_row(), "row after close_result")
        db:close()
    end)

    h.test("adapter state and columns: " .. name, function()
        local db = open_result(factory, config)
        local columns = db:columns()
        h.assert_eq(#columns, 2, "column count")
        h.assert_eq(columns[1], expected_columns and expected_columns[1] or "id", "first column")
        h.assert_eq(columns[2], expected_columns and expected_columns[2] or "name", "second column")
        db:next_row()
        db:close_result()
        h.assert_eq(db:state(), adapter_contract.READY, "READY after close_result")
        db:close()
    end)
end

run_contract_tests("mock", mock_adapter, nil, nil)
run_contract_tests("sqlite", sqlite.new, { database = ":memory:" }, { "id", "name" })

h.test("adapter rows: sqlite preserves NULL sentinel", function()
    local db = open_result(sqlite.new, { database = ":memory:" })
    db:close_result()

    db:send_query("SELECT NULL AS n, 'x' AS s")
    db:get_result()
    local row = db:next_row()
    h.assert_true(adapter_contract.is_null(row[1]), "NULL positional sentinel")
    h.assert_true(adapter_contract.is_null(row.n), "NULL named sentinel")
    h.assert_eq(row[2], "x", "non-NULL positional value")
    db:close_result()
    db:close()
end)

h.summary()
