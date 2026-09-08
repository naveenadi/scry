-- src/utils/json.lua — small data-only JSON codec
-- Supports the JSON values used by History without executing input.

local M = {}

local function encode_value(val)
    local t = type(val)
    if val == nil then return "null" end
    if t == "boolean" then return val and "true" or "false" end
    if t == "number" then return tostring(val) end
    if t == "string" then
        local s = val:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
        return '"' .. s .. '"'
    end
    if t == "table" then
        local is_array = true
        local max_i = 0
        for k, _ in pairs(val) do
            if type(k) ~= "number" or k ~= math.floor(k) or k < 1 then
                is_array = false
                break
            end
            if k > max_i then max_i = k end
        end
        if is_array and max_i == #val then
            local parts = {}
            for i = 1, #val do
                parts[i] = encode_value(val[i])
            end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local parts = {}
        for k, v in pairs(val) do
            if type(k) == "string" then
                table.insert(parts, encode_value(k) .. ":" .. encode_value(v))
            end
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "null"
end

function M.encode(val)
    return encode_value(val)
end

function M.decode(text)
    if type(text) ~= "string" then return nil, "expected string" end

    local pos = 1
    local len = #text

    local function skip_space()
        while pos <= len and text:sub(pos, pos):match("%s") do pos = pos + 1 end
    end

    local parse_value
    local function parse_string()
        pos = pos + 1
        local parts = {}
        while pos <= len do
            local ch = text:sub(pos, pos)
            if ch == '"' then
                pos = pos + 1
                return table.concat(parts)
            elseif ch == "\\" then
                pos = pos + 1
                local escaped = text:sub(pos, pos)
                local replacements = {
                    ['"'] = '"', ['\\'] = "\\", ['/'] = "/",
                    ["b"] = "\b", ["f"] = "\f", ["n"] = "\n",
                    ["r"] = "\r", ["t"] = "\t",
                }
                if replacements[escaped] then
                    table.insert(parts, replacements[escaped])
                    pos = pos + 1
                elseif escaped == "u" then
                    local hex = text:sub(pos + 1, pos + 4)
                    if not hex:match("^%x%x%x%x$") then return nil, "invalid unicode escape" end
                    table.insert(parts, utf8.char(tonumber(hex, 16)))
                    pos = pos + 5
                else
                    return nil, "invalid escape"
                end
            else
                if ch:byte() < 0x20 then return nil, "control character in string" end
                table.insert(parts, ch)
                pos = pos + 1
            end
        end
        return nil, "unterminated string"
    end

    local function parse_number()
        local fragment = text:sub(pos)
        local number = fragment:match("^-?%d+%.?%d*[eE][+-]?%d+")
            or fragment:match("^-?%d+%.%d+")
            or fragment:match("^-?%d+")
        if not number then return nil, "invalid number" end
        pos = pos + #number
        return tonumber(number)
    end

    local function parse_array()
        pos = pos + 1
        local result = {}
        skip_space()
        if text:sub(pos, pos) == "]" then pos = pos + 1; return result end
        while true do
            local value, err = parse_value()
            if err then return nil, err end
            table.insert(result, value)
            skip_space()
            local ch = text:sub(pos, pos)
            if ch == "]" then pos = pos + 1; return result end
            if ch ~= "," then return nil, "expected comma or closing bracket" end
            pos = pos + 1
            skip_space()
        end
    end

    local function parse_object()
        pos = pos + 1
        local result = {}
        skip_space()
        if text:sub(pos, pos) == "}" then pos = pos + 1; return result end
        while true do
            if text:sub(pos, pos) ~= '"' then return nil, "expected object key" end
            local key, err = parse_string()
            if err then return nil, err end
            skip_space()
            if text:sub(pos, pos) ~= ":" then return nil, "expected colon" end
            pos = pos + 1
            local value
            value, err = parse_value()
            if err then return nil, err end
            result[key] = value
            skip_space()
            local ch = text:sub(pos, pos)
            if ch == "}" then pos = pos + 1; return result end
            if ch ~= "," then return nil, "expected comma or closing brace" end
            pos = pos + 1
            skip_space()
        end
    end

    parse_value = function()
        skip_space()
        local ch = text:sub(pos, pos)
        if ch == '"' then return parse_string()
        elseif ch == "{" then return parse_object()
        elseif ch == "[" then return parse_array()
        elseif text:sub(pos, pos + 3) == "true" then pos = pos + 4; return true
        elseif text:sub(pos, pos + 4) == "false" then pos = pos + 5; return false
        elseif text:sub(pos, pos + 3) == "null" then pos = pos + 4; return nil
        else return parse_number() end
    end

    local value, err = parse_value()
    if err then return nil, err end
    skip_space()
    if pos <= len then return nil, "trailing data" end
    return value
end

return M
