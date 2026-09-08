-- tests/core/statement_cycle_test.lua — one-statement adapter choreography

package.path = "./?.lua;./src/?.lua;./tests/?.lua;" .. package.path

local h = require("test_helper")
local cycle_mod = require("core.statement_cycle")

local function mock_adapter(opts)
    opts = opts or {}
    local self = {
        _state = "READY",
        _columns = opts.columns or { "id" },
        _rows = opts.rows or { { 1 } },
        _row_index = 0,
        _error = nil,
        _drain = opts.drain or false,
    }

    function self:send_query(sql)
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
        return self._rows[self._row_index]
    end
    function self:close_result()
        if self._drain then
            self._state = "DRAINING"
        else
            self._state = "READY"
        end
    end
    function self:cancel() self._state = "CANCELED" end
    function self:capabilities()
        return {
            result_fetch_async = false,
            early_close_requires_drain = self._drain,
        }
    end

    return self
end

h.test("statement_cycle: completes one SELECT", function()
    local adapter = mock_adapter()
    local cycle = cycle_mod.new(adapter, { row_budget = 100 })
    local outcome = cycle:begin("SELECT 1")
    h.assert_eq(outcome.status, "yield", "after begin")

    adapter:poll()
    outcome = cycle:advance()
    while outcome.status == "yield" do
        if cycle:needs_poll() then adapter:poll() end
        outcome = cycle:advance()
    end

    h.assert_eq(outcome.status, "ok", "final status")
    h.assert_eq(outcome.row_count, 1, "row_count")
end)

h.test("statement_cycle: cancel during QUERYING", function()
    local adapter = mock_adapter()
    local cycle = cycle_mod.new(adapter)
    cycle:begin("SELECT 1")
    local outcome = cycle:advance(true)
    h.assert_eq(outcome.status, "cancelled", "status")
    h.assert_true(outcome.reconnect, "reconnect")
end)

h.summary()
