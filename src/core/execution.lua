-- src/core/execution.lua — execution engine
-- Drives multi-statement Executions through the adapter contract.
-- Owns Execution state; adapters own Connection/driver state.

local parse = require("src.sql.parse")
local statement_cycle = require("src.core.statement_cycle")
local adapter_contract = require("src.db.adapter")

local M = {}

-- Execution states
M.IDLE               = "IDLE"
M.SPLITTING          = "SPLITTING"
M.CLASSIFYING        = "CLASSIFYING"
M.STATEMENT_RUNNING  = "STATEMENT_RUNNING"
M.COMPLETE           = "COMPLETE"
M.BLOCKED            = "BLOCKED"
M.RECONNECT_CONFIRM  = "RECONNECT_CONFIRM"
M.EXECUTION_FAILED   = "EXECUTION_FAILED"

-- Kept for callers/tests that referenced per-adapter states
M.QUERYING           = M.STATEMENT_RUNNING
M.FETCHING           = M.STATEMENT_RUNNING

local DEFAULT_ROW_BUDGET = 1000

function M.new(adapter, config, read_only)
    local valid, validation_error = adapter_contract.validate(adapter)
    if not valid then error(validation_error, 2) end

    local self = {
        adapter = adapter,
        config = config,
        read_only = read_only == true,
        state = M.IDLE,

        buffer_text = nil,
        statements = {},
        current_statement_index = 0,
        statement_results = {},
        execution_status = "success",
        failure = nil,

        cycle = nil,
        current_rows = {},
        max_result_rows = config and config.general and config.general.max_result_rows or 100000,
        row_budget = DEFAULT_ROW_BUDGET,

        result_columns = nil,
        result_rows = {},
        result_row_count = 0,
        result_truncated = false,
        result_error = nil,
        result_elapsed_ms = 0,

        cancel_requested = false,
        needs_reconnect = false,

        on_history_entry = nil,
    }

    function self:_new_cycle()
        return statement_cycle.new(self.adapter, {
            row_budget = self.row_budget,
            max_result_rows = self.max_result_rows,
        })
    end

    function self:_handle_cycle_outcome(outcome)
        if outcome.status == "yield" then
            self.current_rows = self.cycle.rows
            return
        end

        self.cycle = nil

        if outcome.status == "error" then
            self.result_error = outcome.error
            self.execution_status = "error"
            self:_record_statement_result(self.current_statement_index, "error", nil, outcome.error)
            self.state = M.EXECUTION_FAILED
            return
        end

        if outcome.status == "cancelled" then
            self.execution_status = "cancelled"
            if outcome.reconnect then
                self.needs_reconnect = true
                self.state = M.RECONNECT_CONFIRM
            else
                self.state = M.EXECUTION_FAILED
            end
            return
        end

        if outcome.status == "ok" then
            self:_record_statement_result(
                self.current_statement_index,
                "success",
                outcome.columns,
                nil,
                outcome.row_count
            )
            self.result_columns = outcome.columns
            self.result_rows = outcome.rows
            self.result_row_count = outcome.row_count
            self.result_truncated = outcome.truncated == true
            self.current_rows = outcome.rows

            if self.current_statement_index >= #self.statements then
                self.state = M.COMPLETE
                return
            end
            self.state = M.CLASSIFYING
            return self:_advance()
        end
    end

    function self:execute(buffer_text)
        if self.state ~= M.IDLE and self.state ~= M.COMPLETE and self.state ~= M.EXECUTION_FAILED then
            return false, "execution already in progress"
        end

        self.buffer_text = buffer_text
        self.statements = {}
        self.current_statement_index = 0
        self.statement_results = {}
        self.execution_status = "success"
        self.failure = nil
        self.cycle = nil
        self.current_rows = {}
        self.result_columns = nil
        self.result_rows = {}
        self.result_row_count = 0
        self.result_truncated = false
        self.result_error = nil
        self.result_elapsed_ms = 0
        self.cancel_requested = false
        self.needs_reconnect = false

        self.state = M.SPLITTING
        return self:_advance()
    end

    function self:_advance()
        if self.state == M.SPLITTING then
            self.statements = parse.split_statements(self.buffer_text)
            if #self.statements == 0 then
                self.state = M.COMPLETE
                return
            end
            self.current_statement_index = 0
            self.state = M.CLASSIFYING
            return self:_advance()

        elseif self.state == M.CLASSIFYING then
            self.current_statement_index = self.current_statement_index + 1
            if self.current_statement_index > #self.statements then
                self.state = M.COMPLETE
                return
            end

            local stmt = self.statements[self.current_statement_index]
            local classification = parse.classify_statement(stmt.text)

            if self.read_only and classification.blocked_keyword then
                self.result_error = string.format(
                    "READ ONLY: statement %d blocked — %s keyword found: %s",
                    self.current_statement_index,
                    classification.blocked_keyword,
                    stmt.text:sub(1, 80)
                )
                self.execution_status = "error"
                self:_record_statement_result(self.current_statement_index, "error", nil, self.result_error)
                self.state = M.EXECUTION_FAILED
                return
            end

            self.cycle = self:_new_cycle()
            self.state = M.STATEMENT_RUNNING
            return self:_handle_cycle_outcome(self.cycle:begin(stmt.text))

        elseif self.state == M.STATEMENT_RUNNING then
            local cancel = self.cancel_requested
            if cancel then
                self.cancel_requested = false
            end
            return self:_handle_cycle_outcome(self.cycle:advance(cancel))

        elseif self.state == M.COMPLETE or self.state == M.EXECUTION_FAILED then
            if self.on_history_entry then
                self.on_history_entry(self.buffer_text, self.execution_status)
            end
            return

        elseif self.state == M.BLOCKED then
            return

        else
            self.state = M.IDLE
            return
        end
    end

    function self:poll()
        if self.state == M.STATEMENT_RUNNING then
            if self.cycle:needs_poll() then
                self.adapter:poll()
            end
            self:_advance()
            return true
        end
        return false
    end

    function self:cancel()
        if self.state == M.STATEMENT_RUNNING and self.cycle:is_running() then
            self.cancel_requested = true
        end
    end

    function self:confirm_reconnect()
        if self.state == M.RECONNECT_CONFIRM then
            self.state = M.IDLE
            return true
        end
        return false
    end

    function self:get_result()
        return {
            columns = self.result_columns,
            rows = self.result_rows,
            row_count = self.result_row_count,
            truncated = self.result_truncated,
            error = self.result_error,
        }
    end

    function self:get_metadata()
        return {
            sql = self.buffer_text,
            statements = self.statement_results,
            failed_statement = self.failure,
            status = self.execution_status,
        }
    end

    function self:_record_statement_result(index, status, columns, error, row_count)
        self.statement_results[index] = {
            sql = self.statements[index] and self.statements[index].text or "",
            status = status,
            columns = columns,
            error = error,
            row_count = row_count,
        }
        if status == "error" then
            self.failure = index
        end
    end

    function self:is_idle()
        return self.state == M.IDLE or self.state == M.COMPLETE or self.state == M.EXECUTION_FAILED
    end

    function self:is_running()
        return self.state == M.STATEMENT_RUNNING and self.cycle and self.cycle:is_running()
    end

    function self:is_read_only()
        return self.read_only
    end

    return self
end

return M
