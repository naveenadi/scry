-- src/config/merge.lua — deep-merge logic for configuration

local M = {}

-- Deep-merge two tables.
-- general, query_editor, keybindings: merged key-by-key, recursively.
-- connections: merged by name at top level only — project replaces global entry wholesale.
function M.merge_config(base, override)
    if not override then return base end
    if not base then return override end

    local result = {}

    -- Copy all base keys
    for k, v in pairs(base) do
        result[k] = v
    end

    -- Merge override keys
    for k, v in pairs(override) do
        if k == "connections" then
            -- Connections: merge by name at top level only.
            -- A name present in both layers is replaced wholesale by the override.
            result[k] = M.merge_connections(base[k] or {}, v)
        elseif type(v) == "table" and type(result[k]) == "table" then
            -- general, query_editor, keybindings: recursive merge
            result[k] = M.merge_config(result[k], v)
        else
            -- Scalar or override is not a table: override wins
            result[k] = v
        end
    end

    return result
end

-- Merge connection maps. Project entries replace global entries wholesale.
function M.merge_connections(base, override)
    local result = {}

    -- Copy all base connections
    for name, conn in pairs(base) do
        result[name] = conn
    end

    -- Override connections replace base connections by name
    for name, conn in pairs(override) do
        result[name] = conn
    end

    return result
end

return M
