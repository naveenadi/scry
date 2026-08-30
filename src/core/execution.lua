-- src/core/execution.lua — execution engine
-- Drives multi-statement Executions through the adapter contract.
-- Owns Execution state; adapters own Connection/driver state.

local parse = require("src.sql.parse")
local adapter_contract = require("src.db.adapter")

local M = {}

-- Execution states
M.IDLE              = "IDLE"
M.SPLITTING         = "SPLITTING"
M.CLASSIFYING       = "CLASSIFYING"
M.SEND_QUERY        = "SEND_QUERY"
M.QUERYING          = "QUERYING"
M.GETTING_RESULT    = "GETTING_RESULT"
M.MATERIALIZING     = "MATERIALIZING"
M.FETCHING          = "FETCHING"
M.CLOSING_RESULT    = "CLOSING_RESULT"
M.DRAINING          = "DRAINING"
M.STATEMENT_COMPLETE = "STATEMENT_COMPLETE"
M.COMPLETE          = "COMPLETE"
M.BLOCKED           = "BLOCKED"
M.CANCELING         = "CANCELING"
M.RECONNECT_CONFIRM = "RECONNECT_CONFIRM"
M.EXECUTION_FAILED  = "EXECUTION_FAILED"

-- Row consumption budget per UI tick
local DEFAULT_ROW_BUDGET = 1000

-- Create a new execution engine.
-- adapter: the database adapter (implements the adapter contract)
-- config: the merged configuration
-- read_only: execution policy, independent of the adapter implementation
function M.new(adapter, config, read_only)
    local valid, validation_error = adapter_contract.validate(adapter)
    if not valid then error(validation_error, 2) end

    local self = {
        adapter = adapter,
        config = config,
        read_only = read_only == true,
        state = M.IDLE,

        -- Execution state
        buffer_text = nil,
        statements = {},
        current_statement_index = 0,
        statement_results = {},
        execution_status = "success", -- "success" | "error" | "cancelled"
        failure = nil,

        -- Current result state
        current_columns = nil,
        current_rows = {},
        rows_consumed = 0,
        max_result_rows = config and config.general and config.general.max_result_rows or 100000,
        row_budget = DEFAULT_ROW_BUDGET,

        -- Result metadata for the UI
        result_columns = nil,
        result_rows = {},
        result_row_count = 0,
        result_error = nil,
        result_elapsed_ms = 0,

        -- Cancellation
        cancel_requested = false,
        needs_reconnect = false,

        -- History callback
        on_history_entry = nil,
    }

    -- Start an Execution from a Buffer (or Selection).
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
        self.current_columns = nil
        self.current_rows = {}
        self.rows_consumed = 0
        self.result_columns = nil
        self.result_rows = {}
        self.result_row_count = 0
        self.result_error = nil
        self.result_elapsed_ms = 0
        self.cancel_requested = false
        self.needs_reconnect = false

        self.state = M.SPLITTING
        return self:_advance()
    end

    -- Advance the state machine by one step. Called once per event-loop tick
    -- (via poll()) or recursively for immediate transitions that don't need
    -- to yield (SPLITTING→CLASSIFYING, CLASSIFYING→SEND_QUERY, etc.).
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

                -- Check read-only mode
                if self.read_only and classification.blocked_keyword then
                    self.state = M.BLOCKED
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

                self.state = M.SEND_QUERY
                return self:_advance()

            elseif self.state == M.SEND_QUERY then
                local stmt = self.statements[self.current_statement_index]
                local ok, err = self.adapter:send_query(stmt.text)
                if not ok then
                    self.result_error = err or "send_query failed"
                    self.execution_status = "error"
                    self:_record_statement_result(self.current_statement_index, "error", nil, self.result_error)
                    self.state = M.EXECUTION_FAILED
                    return
                end
                self.state = M.QUERYING
                -- Yield to event loop; poll() will drive QUERYING→RESULT_READY

            elseif self.state == M.QUERYING then
                if self.cancel_requested then
                    self.state = M.CANCELING
                    return self:_advance()
                end

                local adapter_state = self.adapter:state()
                if adapter_state == "RESULT_READY" then
                    self.state = M.GETTING_RESULT
                    return self:_advance()
                elseif adapter_state == "ERROR" then
                    self.result_error = self.adapter:error() or "query failed"
                    self.execution_status = "error"
                    self:_record_statement_result(self.current_statement_index, "error", nil, self.result_error)
                    self.state = M.EXECUTION_FAILED
                    return
                elseif adapter_state == "CANCELED" then
                    self.execution_status = "cancelled"
                    self.state = M.EXECUTION_FAILED
                    return
                end
                -- else: still querying, yield to event loop

            elseif self.state == M.GETTING_RESULT then
                local caps = self.adapter:capabilities()
                if caps.result_fetch_async == false then
                    -- May block (MySQL)
                    self.state = M.MATERIALIZING
                else
                    self.state = M.FETCHING
                end
                return self:_advance()

            elseif self.state == M.MATERIALIZING then
                -- get_result() may block for MySQL
                local ok, err = self.adapter:get_result()
                if not ok then
                    self.result_error = err or "get_result failed"
                    self.execution_status = "error"
                    self:_record_statement_result(self.current_statement_index, "error", nil, self.result_error)
                    self.state = M.EXECUTION_FAILED
                    return
                end
                self.state = M.FETCHING
                return self:_advance()

            elseif self.state == M.FETCHING then
                -- Consume rows up to the budget
                local budget = self.row_budget
                local consumed = 0

                while consumed < budget do
                    if self.cancel_requested then
                        -- FETCHING cancellation: stop consumption, no reconnect
                        self.cancel_requested = false
                        self.state = M.CLOSING_RESULT
                        return self:_advance()
                    end

                    -- Check max_result_rows cap
                    if self.rows_consumed >= self.max_result_rows then
                        self.state = M.CLOSING_RESULT
                        return self:_advance()
                    end

                    local row = self.adapter:next_row()
                    if row == nil then
                        -- End of results
                        self.state = M.CLOSING_RESULT
                        return self:_advance()
                    end

                    -- Store row
                    table.insert(self.current_rows, row)
                    self.rows_consumed = self.rows_consumed + 1
                    consumed = consumed + 1
                end

                -- Budget exhausted, yield to event loop
                return

            elseif self.state == M.CLOSING_RESULT then
                -- Record the statement result
                local row_count = #self.current_rows
                self:_record_statement_result(
                    self.current_statement_index,
                    "success",
                    self.adapter:columns(),
                    nil,
                    row_count
                )

                -- Store result for display (Phase 1: last result only)
                self.result_columns = self.adapter:columns()
                self.result_rows = self.current_rows
                self.result_row_count = row_count

                -- Close the result
                self.adapter:close_result()
                self.current_rows = {}
                self.rows_consumed = 0

                -- Check if adapter needs draining
                local caps = self.adapter:capabilities()
                if caps.early_close_requires_drain then
                    self.state = M.DRAINING
                else
                    self.state = M.STATEMENT_COMPLETE
                end
                return self:_advance()

            elseif self.state == M.DRAINING then
                -- Wait for adapter to finish draining
                local adapter_state = self.adapter:state()
                if adapter_state == "READY" then
                    self.state = M.STATEMENT_COMPLETE
                    return self:_advance()
                end
                -- Yield to event loop, poll will advance drain

            elseif self.state == M.STATEMENT_COMPLETE then
                if self.current_statement_index >= #self.statements then
                    self.state = M.COMPLETE
                    return
                end
                -- More statements to execute
                self.state = M.CLASSIFYING
                return self:_advance()

            elseif self.state == M.CANCELING then
                -- QUERYING cancellation: abandon and close connection
                self.adapter:cancel()
                self.execution_status = "cancelled"
                self.needs_reconnect = true
                self.state = M.RECONNECT_CONFIRM
                return

            elseif self.state == M.COMPLETE then
                -- Record history on completion
                if self.on_history_entry then
                    self.on_history_entry(self.buffer_text, self.execution_status)
                end
                return

            elseif self.state == M.EXECUTION_FAILED then
                -- Record history on failure
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

    -- Poll the execution (called once per UI tick).
    -- Returns true if the execution has new state to report.
    function self:poll()
        if self.state == M.QUERYING or self.state == M.DRAINING then
            -- Poll the adapter while the Statement is in flight or draining,
            -- then advance even if polling made progress this tick.
            self.adapter:poll()
            self:_advance()
            return true
        end

        if self.state == M.MATERIALIZING or self.state == M.FETCHING then
            -- Advance every other runnable state once per event-loop tick.
            self:_advance()
            return true
        end
        return false
    end

    -- Request cancellation (Ctrl+C).
    function self:cancel()
        if self.state == M.QUERYING then
            self.cancel_requested = true
        elseif self.state == M.FETCHING then
            self.cancel_requested = true
        end
    end

    -- Confirm reconnect after cancellation.
    function self:confirm_reconnect()
        if self.state == M.RECONNECT_CONFIRM then
            self.state = M.IDLE
            return true
        end
        return false
    end

    -- Get the current result for display.
    -- Returns { columns = {...}, rows = {...}, row_count = N, error = "..." or nil }
    function self:get_result()
        return {
            columns = self.result_columns,
            rows = self.result_rows,
            row_count = self.result_row_count,
            error = self.result_error,
        }
    end

    -- Get execution metadata.
    function self:get_metadata()
        return {
            sql = self.buffer_text,
            statements = self.statement_results,
            failed_statement = self.failure,
            status = self.execution_status,
        }
    end

    -- Record a statement result.
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

    -- Check if the execution is idle.
    function self:is_idle()
        return self.state == M.IDLE or self.state == M.COMPLETE or self.state == M.EXECUTION_FAILED
    end

    -- Check if a query is running.
    function self:is_running()
        return self.state == M.QUERYING or self.state == M.FETCHING or
               self.state == M.MATERIALIZING or self.state == M.DRAINING
    end

    -- Check if this execution enforces read-only mode.
    function self:is_read_only()
        return self.read_only
    end

    return self
end

return M
