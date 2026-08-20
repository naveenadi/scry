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

-- Check if a value is the NULL sentinel.
function M.is_null(val)
    return type(val) == "table" and val.is_null == true
end

return M
