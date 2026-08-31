-- src/export/json.lua — JSON export with correct type mapping
-- NULL as JSON null, boolean as JSON boolean, numeric as JSON number
-- when type info reliable, string as JSON string, binary as encoded string.

local M = {}

-- Encode a single value to JSON.
local function json_value(val)
    if val == nil then return "null" end
    if type(val) == "table" and val.is_null then return "null" end
    if type(val) == "boolean" then return val and "true" or "false" end
    if type(val) == "number" then
        -- JSON doesn't support NaN or Infinity
        if val ~= val then return "null" end  -- NaN
        if val == math.huge or val == -math.huge then return "null" end
        return tostring(val)
    end
    if type(val) == "string" then
        -- Escape special characters
        local s = val
            :gsub('\\', '\\\\')
            :gsub('"', '\\"')
            :gsub('\n', '\\n')
            :gsub('\r', '\\r')
            :gsub('\t', '\\t')
            :gsub('[%z\x01-\x1f]', function(c)
                return string.format('\\u%04x', c:byte())
            end)
        return '"' .. s .. '"'
    end
    -- Binary or other table types
    if type(val) == "table" then
        return '"[binary]"'
    end
    return '"' .. tostring(val) .. '"'
end

-- Export rows to JSON string.
-- columns: array of column name strings
-- rows: array of row tables (positional keys)
-- Returns JSON string (array of objects).
M._value = json_value

function M.to_string(columns, rows)
    local parts = {}
    for _, row in ipairs(rows) do
        local obj_parts = {}
        for i, name in ipairs(columns) do
            table.insert(obj_parts, '"' .. name:gsub('"', '\\"') .. '":' .. json_value(row[i]))
        end
        table.insert(parts, "{" .. table.concat(obj_parts, ",") .. "}")
    end
    return "[" .. table.concat(parts, ",") .. "]"
end

-- Export rows to JSON file.
-- path: output file path
-- columns: array of column name strings
-- rows: array of row tables (positional keys)
-- Returns true on success, nil+error on failure.
function M.to_file(path, columns, rows)
    local content = M.to_string(columns, rows)
    local f, err = io.open(path, "w")
    if not f then return nil, err end
    f:write(content)
    f:close()
    return true
end

return M
