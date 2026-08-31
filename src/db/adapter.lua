-- src/db/adapter.lua — adapter contract definition
-- Every Phase 1 adapter implements this interface.

local M = {}

-- Adapter states
M.DISCONNECTED    = "DISCONNECTED"
M.CONNECTING      = "CONNECTING"
M.READY           = "READY"
M.QUERYING        = "QUERYING"
M.RESULT_READY    = "RESULT_READY"
M.MATERIALIZING   = "MATERIALIZING"
M.FETCHING        = "FETCHING"
M.ERROR           = "ERROR"
M.CANCELED        = "CANCELED"
M.CONNECTION_LOST = "CONNECTION_LOST"

-- NULL sentinel — never bare Lua nil in row arrays
M.NULL = { is_null = true }

-- Adapters normalize rows with both named fields and positional fields in
-- column order; SQL NULL is represented by M.NULL in either form.

-- Check if a value is the NULL sentinel.
function M.is_null(val)
    return type(val) == "table" and val.is_null == true
end

-- Validate the adapter seam once, before an Execution can call it.
function M.validate(value)
    if type(value) ~= "table" then
        return false, "adapter must be a table"
    end

    local required = {
        "connect", "send_query", "poll", "get_result", "state", "error",
        "columns", "next_row", "close_result", "cancel", "list_tables",
        "get_columns", "ping", "close", "capabilities",
    }
    for _, name in ipairs(required) do
        if type(value[name]) ~= "function" then
            return false, "adapter is missing method: " .. name
        end
    end
    return true
end

return M
