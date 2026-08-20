-- src/core/errors.lua — error handling utilities

local M = {}

-- Create an error object.
function M.new(code, message, details)
    return {
        code = code,
        message = message,
        details = details,
    }
end

-- Error codes
M.CONNECT_FAILED    = "CONNECT_FAILED"
M.QUERY_FAILED      = "QUERY_FAILED"
M.READ_ONLY_BLOCKED = "READ_ONLY_BLOCKED"
M.CANCELLED         = "CANCELLED"
M.CONNECTION_LOST   = "CONNECTION_LOST"
M.TIMEOUT           = "TIMEOUT"
M.INVALID_STATE     = "INVALID_STATE"

return M
