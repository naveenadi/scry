-- src/db/factory.lua — adapter factory with registration table
-- Centralizes adapter creation. Adding a new adapter type is one register() call.

local M = {}

-- Registry: type name → module path
local registry = {}

-- Register an adapter type.
-- name: string key (e.g., "sqlite", "postgres", "mysql")
-- module_path: require path (e.g., "src.db.sqlite")
function M.register(name, module_path)
    registry[name] = module_path
end

-- Create an adapter instance for the given type.
-- Returns the adapter, or nil + error if type is unknown.
function M.create(adapter_type)
    local path = registry[adapter_type]
    if not path then
        return nil, "unsupported database type: " .. tostring(adapter_type)
    end
    local mod = require(path)
    return mod.new()
end

-- List registered adapter types.
function M.types()
    local t = {}
    for name in pairs(registry) do
        table.insert(t, name)
    end
    table.sort(t)
    return t
end

-- Built-in registrations
M.register("sqlite",   "src.db.sqlite")
M.register("postgres", "src.db.postgres")
M.register("mysql",    "src.db.mysql")

return M
