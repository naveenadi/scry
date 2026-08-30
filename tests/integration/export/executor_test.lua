-- tests/integration/export/executor_test.lua – async export tests

package.path = "src/?.lua;" .. package.path

local h = require("tests.test_helper")
local adapter = require("src.db.adapter")
local executor = require("src.export.executor")

local function mock_adapter(rows)
    local self = {
        _state = adapter.READY,
        _rows = rows,
        _index = 0,
        _columns = { "id", "value" },
        close_result_called = false,
    }

    function self:connect() self._state = adapter.READY; return true end
    function self:send_query()
        self._state = adapter.QUERYING
        self._index = 0
        return true
    end
    function self:poll()
        if self._state == adapter.QUERYING then self._state = adapter.RESULT_READY end
    end
    function self:get_result()
        if self._state ~= adapter.RESULT_READY then return false, "not ready" end
        self._state = adapter.FETCHING
        return true
    end
    function self:state() return self._state end
    function self:error() return nil end
    function self:columns() return self._columns end
    function self:next_row()
        if self._state ~= adapter.FETCHING then return nil end
        self._index = self._index + 1
        return self._rows[self._index]
    end
    function self:close_result()
        self.close_result_called = true
        self._state = adapter.READY
    end
    function self:cancel() self:close_result() end
    function self:list_tables() return {} end
    function self:get_columns() return {} end
    function self:ping() return true end
    function self:close() self._state = adapter.DISCONNECTED end
    function self:capabilities()
        return { query_async = false, result_streaming = true,
            result_fetch_async = false, early_close_requires_drain = false }
    end

    return self
end

local function temp_path(extension)
    return os.tmpname() .. extension
end

local function read_file(path)
    local file = assert(io.open(path, "r"))
    local content = file:read("*a")
    file:close()
    return content
end

local function run_to_completion(export)
    while export:is_running() do export:poll() end
end

h.test("export: streams CSV and atomically completes", function()
    local path = temp_path(".csv")
    local db = mock_adapter({ { 1, "a,b" }, { 2, adapter.NULL } })
    local export = executor.new(db)
    export.row_budget = 1

    local ok, err = export:execute("SELECT 1", path, "csv")
    h.assert_true(ok, err or "start failed")
    run_to_completion(export)

    h.assert_eq(export.state, executor.COMPLETE, "state")
    h.assert_eq(read_file(path), "id,value\n1,\"a,b\"\n2,\n", "CSV output")
    h.assert_true(db.close_result_called, "result closed")
    h.assert_nil(io.open(path .. ".tmp", "r"), "temporary file removed")
    os.remove(path)
end)

h.test("export: streams JSON with NULL values", function()
    local path = temp_path(".json")
    local db = mock_adapter({ { 1, adapter.NULL }, { 2, true } })
    local export = executor.new(db)

    local ok, err = export:execute("SELECT 1", path, "json")
    h.assert_true(ok, err or "start failed")
    run_to_completion(export)

    h.assert_eq(export.state, executor.COMPLETE, "state")
    h.assert_eq(read_file(path), "[{\"id\":1,\"value\":null},{\"id\":2,\"value\":true}]\n", "JSON output")
    os.remove(path)
end)

h.test("export: cancellation removes temporary output", function()
    local path = temp_path(".csv")
    local db = mock_adapter({ { 1, "first" }, { 2, "second" } })
    local export = executor.new(db)
    export.row_budget = 1

    local ok, err = export:execute("SELECT 1", path, "csv")
    h.assert_true(ok, err or "start failed")
    export:poll()
    h.assert_eq(export.state, executor.FETCHING, "fetching before cancel")
    export:cancel()
    export:poll()

    h.assert_eq(export.state, executor.CANCELED, "state")
    h.assert_nil(io.open(path, "r"), "final output absent")
    h.assert_nil(io.open(path .. ".tmp", "r"), "temporary output absent")
    h.assert_true(db.close_result_called, "result closed")
end)

h.test("export: cleans temporary file after send failure", function()
    local path = temp_path(".csv")
    local db = mock_adapter({})
    function db:send_query()
        self._state = adapter.ERROR
        return false, "send failed"
    end
    local export = executor.new(db)
    local ok, err = export:execute("SELECT 1", path, "csv")
    h.assert_true(not ok)
    h.assert_true(err:find("send failed") ~= nil)
    h.assert_eq(export.state, executor.FAILED, "state")
    h.assert_nil(io.open(path .. ".tmp", "r"), "temporary output absent")
    h.assert_nil(io.open(path, "r"), "final output absent")
end)

h.test("export: rejects invalid format and empty statement", function()
    local export = executor.new(mock_adapter({}))
    local ok, err = export:execute("SELECT 1", temp_path(".txt"), "xml")
    h.assert_true(not ok)
    h.assert_true(err:find("unsupported") ~= nil)
    ok, err = export:execute("", temp_path(".csv"), "csv")
    h.assert_true(not ok)
    h.assert_true(err:find("No statement") ~= nil)
end)

h.summary()
