-- src/platform/init.lua — platform detection and module loading

local M = {}

-- Detect platform
local jit = require("jit")
if jit.os == "Windows" then
    M.platform = require("src.platform.windows")
else
    M.platform = require("src.platform.unix")
end

-- Convenience: expose platform methods at top level
for k, v in pairs(M.platform) do
    if type(v) == "function" then
        M[k] = v
    end
end

M.os_name = jit.os

return M
