-- src/export/csv.lua — RFC 4180 compliant CSV export
-- Values double-quoted when containing comma, newline, or double-quote.
-- Embedded quotes escaped by doubling. NULL as empty string. UTF-8 output.

local M = {}

-- RFC 4180 quoting: wrap in double quotes if value contains comma, newline,
-- or double-quote. Embedded double-quotes are doubled.
local function csv_escape(value)
    if value == nil then return "" end
    if type(value) == "table" and value.is_null then return "" end
    local s = tostring(value)
    if s:find('[,"\n\r]') then
        return '"' .. s:gsub('"', '""') .. '"'
    end
    return s
end

-- Export rows to CSV string.
-- columns: array of column name strings
-- rows: array of row tables (positional keys)
-- Returns CSV string.
function M.to_string(columns, rows)
    local parts = {}

    -- Header row
    local header = {}
    for i, name in ipairs(columns) do
        header[i] = csv_escape(name)
    end
    table.insert(parts, table.concat(header, ","))

    -- Data rows
    for _, row in ipairs(rows) do
        local line = {}
        for i = 1, #columns do
            line[i] = csv_escape(row[i])
        end
        table.insert(parts, table.concat(line, ","))
    end

    return table.concat(parts, "\n") .. "\n"
end

-- Export rows to CSV file.
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
