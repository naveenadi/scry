-- src/db/row_builder.lua – shared Result set row normalization
-- LuaSQL omits NULL-valued named fields; keep named and positional access aligned.

local adapter = require("src.db.adapter")

local M = {}

-- Mutate and return the driver row with positional fields and NULL sentinels.
function M.normalize_row(row, columns)
    if not row or not columns then return row end

    for i, name in ipairs(columns) do
        if row[name] == nil then
            row[name] = adapter.NULL
        end
        row[i] = row[name]
    end

    return row
end

return M
