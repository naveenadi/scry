-- src/core/statement_cycle.lua — one Statement through the adapter contract
-- send_query → poll → get_result → bounded next_row → close_result (+ drain)

local M = {}

M.SEND_QUERY     = "SEND_QUERY"
M.QUERYING       = "QUERYING"
M.GETTING_RESULT = "GETTING_RESULT"
M.MATERIALIZING  = "MATERIALIZING"
M.FETCHING       = "FETCHING"
M.CLOSING_RESULT = "CLOSING_RESULT"
M.DRAINING       = "DRAINING"

function M.new(adapter, opts)
    opts = opts or {}
    local self = {
        adapter = adapter,
        state = nil,
        row_budget = opts.row_budget or 1000,
        max_result_rows = opts.max_result_rows or 100000,
        rows = {},
        rows_consumed = 0,
        _pending_columns = nil,
        _truncated = false,
    }

    function self:begin(sql)
        self.rows = {}
        self.rows_consumed = 0
        self._pending_columns = nil
        self._truncated = false
        self.state = M.SEND_QUERY

        local ok, err = self.adapter:send_query(sql)
        if not ok then
            self.state = nil
            return { status = "error", error = err or "send_query failed" }
        end
        self.state = M.QUERYING
        return { status = "yield" }
    end

    function self:needs_poll()
        return self.state == M.QUERYING or self.state == M.DRAINING
    end

    function self:is_running()
        return self.state == M.QUERYING or self.state == M.FETCHING
            or self.state == M.MATERIALIZING or self.state == M.DRAINING
    end

    local function finish_ok()
        local columns = self._pending_columns or self.adapter:columns()
        local row_count = #self.rows
        local truncated = self._truncated
        self.state = nil
        self._truncated = false
        return {
            status = "ok",
            columns = columns,
            rows = self.rows,
            row_count = row_count,
            truncated = truncated,
        }
    end

    -- Returns { status = "yield" | "ok" | "error" | "cancelled", ... }
    function self:advance(cancel_requested)
        if not self.state then
            return { status = "error", error = "statement cycle not started" }
        end

        if self.state == M.QUERYING then
            if cancel_requested then
                self.adapter:cancel()
                self.state = nil
                return { status = "cancelled", reconnect = true }
            end

            local adapter_state = self.adapter:state()
            if adapter_state == "RESULT_READY" then
                self.state = M.GETTING_RESULT
                return self:advance(cancel_requested)
            elseif adapter_state == "ERROR" then
                self.state = nil
                return { status = "error", error = self.adapter:error() or "query failed" }
            elseif adapter_state == "CANCELED" then
                self.state = nil
                return { status = "cancelled", reconnect = false }
            end
            return { status = "yield" }
        end

        if self.state == M.GETTING_RESULT then
            local caps = self.adapter:capabilities()
            self.state = caps.result_fetch_async == false and M.MATERIALIZING or M.FETCHING
            return self:advance(cancel_requested)
        end

        if self.state == M.MATERIALIZING then
            local ok, err = self.adapter:get_result()
            if not ok then
                self.state = nil
                return { status = "error", error = err or "get_result failed" }
            end
            self.state = M.FETCHING
            return self:advance(cancel_requested)
        end

        if self.state == M.FETCHING then
            -- Consume rows until budget, max_result_rows, or cancel
            local stopped_by_cap = false
            local rows_this_call = 0
            while rows_this_call < self.row_budget do
                if cancel_requested then
                    break
                end
                if self.rows_consumed >= self.max_result_rows then
                    stopped_by_cap = true
                    break
                end
                local row = self.adapter:next_row()
                if row == nil then
                    break
                end
                table.insert(self.rows, row)
                self.rows_consumed = self.rows_consumed + 1
                rows_this_call = rows_this_call + 1
            end

            if self.rows_consumed >= self.max_result_rows then
                self._truncated = true
            end

            if rows_this_call < self.row_budget then
                self._pending_columns = self.adapter:columns()
                self.state = M.CLOSING_RESULT
                return self:advance(cancel_requested)
            end
            return { status = "yield" }
        end

        if self.state == M.CLOSING_RESULT then
            self.adapter:close_result()
            self.rows_consumed = 0

            local caps = self.adapter:capabilities()
            if caps.early_close_requires_drain then
                self.state = M.DRAINING
                return self:advance(cancel_requested)
            end
            return finish_ok()
        end

        if self.state == M.DRAINING then
            if self.adapter:state() == "READY" then
                return finish_ok()
            end
            return { status = "yield" }
        end

        self.state = nil
        return { status = "error", error = "unknown statement cycle state" }
    end

    return self
end

return M
