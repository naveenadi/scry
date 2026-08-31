-- src/export/executor.lua – bounded Result set export
-- Re-executes one Statement and streams rows to an atomically completed file.

local M = {}

M.IDLE = "IDLE"
M.PREPARE = "PREPARE"
M.QUERYING = "QUERYING"
M.MATERIALIZING = "MATERIALIZING"
M.FETCHING = "FETCHING"
M.WRITING = "WRITING"
M.COMPLETE = "COMPLETE"
M.FAILED = "FAILED"
M.CANCELED = "CANCELED"

local DEFAULT_ROW_BUDGET = 1000

function M.new(adapter)
    local self = {
        adapter = adapter,
        state = M.IDLE,
        statement_sql = nil,
        output_path = nil,
        temp_path = nil,
        format = nil,
        output_file = nil,
        columns = nil,
        row_count = 0,
        row_budget = DEFAULT_ROW_BUDGET,
        error_message = nil,
        cancel_requested = false,
        header_written = false,
    }

    local function fail(message)
        if self.output_file then
            self.output_file:close()
            self.output_file = nil
        end
        if self.temp_path then os.remove(self.temp_path) end
        pcall(function() self.adapter:close_result() end)
        self.error_message = message
        self.state = M.FAILED
    end

    local function cleanup_cancel()
        if self.output_file then
            self.output_file:close()
            self.output_file = nil
        end
        if self.temp_path then os.remove(self.temp_path) end
        pcall(function() self.adapter:cancel() end)
        self.error_message = "Export cancelled"
        self.state = M.CANCELED
    end

    function self:execute(statement_sql, output_path, format)
        if not self:is_idle() then return false, "export already in progress" end
        if format ~= "csv" and format ~= "json" then return false, "unsupported export format" end
        if not statement_sql or statement_sql == "" then return false, "No statement to export" end
        if not output_path or output_path == "" then return false, "No output path" end

        self.statement_sql = statement_sql
        self.output_path = output_path
        self.temp_path = output_path .. ".tmp"
        self.format = format
        self.columns = nil
        self.row_count = 0
        self.error_message = nil
        self.cancel_requested = false
        self.header_written = false
        self.output_file = nil
        self.state = M.PREPARE
        return self:_advance()
    end

    function self:_write_header()
        if self.header_written then return end
        self.columns = self.adapter:columns() or {}
        if self.format == "csv" then
            local csv = require("src.export.csv")
            local header = {}
            for i, name in ipairs(self.columns) do header[i] = csv._escape(name) end
            self.output_file:write(table.concat(header, ",") .. "\n")
        else
            self.output_file:write("[")
        end
        self.header_written = true
    end

    function self:_write_row(row)
        if self.format == "csv" then
            local csv = require("src.export.csv")
            local values = {}
            for i = 1, #self.columns do values[i] = csv._escape(row[i]) end
            self.output_file:write(table.concat(values, ",") .. "\n")
            return
        end

        local json = require("src.export.json")
        local values = {}
        for i, name in ipairs(self.columns) do
            local key = tostring(name):gsub('\\', '\\\\'):gsub('"', '\\"')
            values[i] = '"' .. key .. '":' .. json._value(row[i])
        end
        if self.row_count > 0 then self.output_file:write(",") end
        self.output_file:write("{" .. table.concat(values, ",") .. "}")
    end

    function self:_advance()
        if self.state == M.PREPARE then
            local file, err = io.open(self.temp_path, "w")
            if not file then
                self.state = M.FAILED
                self.error_message = "Failed to open temp file: " .. tostring(err)
                return false, self.error_message
            end
            self.output_file = file
            self.state = M.QUERYING
            return self:_advance()
        elseif self.state == M.QUERYING then
            if self.cancel_requested then return cleanup_cancel() end
            local ok, err = self.adapter:send_query(self.statement_sql)
            if not ok then fail(err or "send_query failed"); return false, self.error_message end
            -- The first adapter poll happens on the next event-loop tick.
            return true
        elseif self.state == M.MATERIALIZING then
            if self.cancel_requested then return cleanup_cancel() end
            local ok, err = self.adapter:get_result()
            if not ok then fail(err or "get_result failed"); return false, self.error_message end
            self.state = M.FETCHING
            return self:_advance()
        elseif self.state == M.FETCHING then
            if self.cancel_requested then return cleanup_cancel() end
            self:_write_header()
            local consumed = 0
            while consumed < self.row_budget do
                if self.cancel_requested then return cleanup_cancel() end
                local row = self.adapter:next_row()
                if not row then
                    if self.format == "json" then self.output_file:write("]\n") end
                    self.state = M.WRITING
                    return self:_advance()
                end
                self:_write_row(row)
                self.row_count = self.row_count + 1
                consumed = consumed + 1
            end
            return true
        elseif self.state == M.WRITING then
            self.adapter:close_result()
            self.output_file:close()
            self.output_file = nil
            local ok, err = os.rename(self.temp_path, self.output_path)
            if not ok then
                os.remove(self.temp_path)
                self.state = M.FAILED
                self.error_message = "Failed to rename temp file: " .. tostring(err)
                return false, self.error_message
            end
            self.state = M.COMPLETE
            return true
        end
        return false
    end

    function self:poll()
        if self.state == M.QUERYING then
            if self.cancel_requested then return cleanup_cancel() end
            self.adapter:poll()
            if self.adapter:state() == "RESULT_READY" then
                self.state = M.MATERIALIZING
            elseif self.adapter:state() == "ERROR" then
                fail(self.adapter:error() or "query failed")
                return false
            else
                return true
            end
        end
        if self.state == M.MATERIALIZING or self.state == M.FETCHING then
            return self:_advance()
        end
        return false
    end

    function self:cancel()
        self.cancel_requested = true
    end

    function self:is_running()
        return self.state == M.QUERYING or self.state == M.MATERIALIZING or self.state == M.FETCHING
    end

    function self:is_idle()
        return self.state == M.IDLE or self.state == M.COMPLETE or
            self.state == M.FAILED or self.state == M.CANCELED
    end

    function self:get_status()
        return { state = self.state, row_count = self.row_count,
            error = self.error_message, output_path = self.output_path }
    end

    return self
end

return M
