-- tests/integration/execution_test.lua — tests for the execution engine

package.path = "src/?.lua;" .. package.path

local h = require("tests.test_helper")
local execution = require("src.core.execution")


-- Mock adapter for testing
local function mock_adapter(opts)
    opts = opts or {}
    local self = {
        _state = "READY",
        _read_only = opts.read_only or false,
        _columns = opts.columns or { "id", "name" },
        _rows = opts.rows or { {1, "alice"}, {2, "bob"} },
        _row_index = 0,
        _error = nil,
        _send_query_called = false,
        _cancel_called = false,
        _close_result_called = false,
    }

    function self:connect(config) self._state = "READY"; return true end
    function self:send_query(sql)
        self._send_query_called = true
        self._state = "QUERYING"
        self._row_index = 0
        return true
    end
    function self:poll()
        if self._state == "QUERYING" then
            self._state = "RESULT_READY"
        elseif self._state == "DRAINING" then
            self._state = "READY"
        end
    end
    function self:get_result()
        self._state = "FETCHING"
        return true
    end
    function self:state() return self._state end
    function self:error() return self._error end
    function self:columns() return self._columns end
    function self:next_row()
        self._row_index = self._row_index + 1
        if self._row_index <= #self._rows then
            return self._rows[self._row_index]
        end
        return nil
    end
    function self:close_result()
        self._close_result_called = true
        self._state = "READY"
    end
    function self:cancel()
        self._cancel_called = true
        self._state = "CANCELED"
    end
    function self:list_tables() return {} end
    function self:get_columns(t) return {} end
    function self:ping() return true end
    function self:close() self._state = "DISCONNECTED" end
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

local config = {
    general = {
        max_result_rows = 100000,
        default_page_size = 100,
    },
}

-- === Tests ===

h.test("execution: starts in IDLE state", function()
    local adapter = mock_adapter()
    local exec = execution.new(adapter, config)
    h.assert_eq(exec.state, execution.IDLE, "state")
end)

h.test("execution: empty buffer completes immediately", function()
    local adapter = mock_adapter()
    local exec = execution.new(adapter, config)
    exec:execute("")
    h.assert_eq(exec.state, execution.COMPLETE, "state")
end)

h.test("execution: single SELECT statement", function()
    local adapter = mock_adapter()
    local exec = execution.new(adapter, config)
    exec:execute("SELECT 1")

    -- The state machine runs synchronously through SPLITTING -> CLASSIFYING -> SEND_QUERY -> QUERYING
    -- At QUERYING, _advance() yields because the adapter is still in QUERYING state
    h.assert_eq(exec.state, execution.QUERYING, "state after execute")

    -- Poll: adapter transitions QUERYING -> RESULT_READY, then _advance() runs through
    -- GETTING_RESULT -> MATERIALIZING -> FETCHING -> CLOSING_RESULT -> STATEMENT_COMPLETE -> COMPLETE
    exec:poll()

    h.assert_eq(exec.state, execution.COMPLETE, "state after poll")
    local result = exec:get_result()
    h.assert_eq(result.row_count, 2, "row_count")
end)

h.test("execution: multi-statement halt-on-first-failure", function()
    local adapter = mock_adapter()
    local exec = execution.new(adapter, config)

    -- First statement succeeds, second will fail
    local call_count = 0
    local orig_send = adapter.send_query
    adapter.send_query = function(self, sql)
        call_count = call_count + 1
        if call_count == 2 then
            self._error = "syntax error"
            self._state = "ERROR"
            return false
        end
        return orig_send(self, sql)
    end

    exec:execute("SELECT 1; INVALID SQL")

    -- First statement should complete
    adapter:poll()
    exec:poll()
    while exec.state == execution.FETCHING do
        exec:poll()
    end

    -- Should be in EXECUTION_FAILED after second statement fails
    h.assert_eq(exec.state, execution.EXECUTION_FAILED, "state")
    h.assert_eq(exec.execution_status, "error", "status")

    local meta = exec:get_metadata()
    h.assert_eq(meta.failed_statement, 2, "failed_statement")
end)

h.test("execution: read-only blocks write statements", function()
    local adapter = mock_adapter({ read_only = true })
    local exec = execution.new(adapter, config)
    exec:execute("INSERT INTO t VALUES (1)")

    -- The state machine runs synchronously: SPLITTING -> CLASSIFYING -> BLOCKED
    h.assert_eq(exec.state, execution.EXECUTION_FAILED, "state")
    h.assert_true(exec.result_error:find("READ ONLY") ~= nil, "error mentions READ ONLY")
end)

h.test("execution: read-only allows SELECT", function()
    local adapter = mock_adapter({ read_only = true })
    local exec = execution.new(adapter, config)
    exec:execute("SELECT 1")

    h.assert_eq(exec.state, execution.QUERYING, "state")
end)

h.test("execution: cancel during QUERYING", function()
    local adapter = mock_adapter()
    local exec = execution.new(adapter, config)
    exec:execute("SELECT 1")

    h.assert_eq(exec.state, execution.QUERYING, "state")
    exec:cancel()
    exec:poll() -- advance cancel

    h.assert_eq(exec.state, execution.RECONNECT_CONFIRM, "state after cancel")
    h.assert_true(exec.needs_reconnect, "needs_reconnect")
    h.assert_true(adapter._cancel_called, "adapter.cancel called")
end)

h.test("execution: is_idle returns true when complete", function()
    local adapter = mock_adapter()
    local exec = execution.new(adapter, config)
    exec:execute("")
    h.assert_true(exec:is_idle(), "is_idle")
end)

h.test("execution: is_running returns true during query", function()
    local adapter = mock_adapter()
    local exec = execution.new(adapter, config)
    exec:execute("SELECT 1")
    h.assert_true(exec:is_running(), "is_running")
end)

h.summary()
