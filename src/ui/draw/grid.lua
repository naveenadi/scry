-- src/ui/draw/grid.lua — result grid renderer

local grid_mod = require("src.ui.grid")

local M = {}

local function cell_text(value)
    local text = grid_mod.format_cell(value)
    if #text > 30 then
        return text:sub(1, 27) .. "..."
    end
    return text
end

function M.render(term, prepared, view, region, theme, focused)
    if not prepared or not prepared.columns then
        local message = prepared and prepared.error and ("Error: " .. prepared.error) or "No results"
        term.text(region.x + 1, region.y, message,
            prepared and prepared.error and theme.error_fg or theme.comment, theme.bg)
        return
    end

    local columns = prepared.columns
    local col_offset = math.max(0, view.col_offset)
    local visible = {}
    for i = col_offset + 1, #columns do
        visible[#visible + 1] = { index = i, name = columns[i] }
    end
    if #visible == 0 then return end

    local widths = {}
    for _, col in ipairs(visible) do
        local name = col.name
        local suffix = ""
        if view.sort_col == col.index then
            suffix = view.sort_asc and " ^" or " v"
        end
        widths[#widths + 1] = math.max(#name + #suffix, 3)
    end
    for _, row in ipairs(prepared.rows) do
        for i, col in ipairs(visible) do
            widths[i] = math.max(widths[i], #cell_text(row[col.index]))
        end
    end

    local function draw_header()
        local y = region.y
        local x = region.x + 1
        for i, col in ipairs(visible) do
            local text = col.name
            if view.sort_col == col.index then
                text = text .. (view.sort_asc and " ^" or " v")
            end
            local highlight = focused and view.select_row == 0 and view.select_col == col.index
            local fg = highlight and theme.cursor or theme.keyword
            term.text(x, y, text .. string.rep(" ", widths[i] - #text), fg, theme.bg)
            x = x + widths[i]
            if i < #visible then
                term.text(x, y, " | ", theme.border, theme.bg)
                x = x + 3
            end
        end
    end

    draw_header()

    local separator = {}
    for i = 1, #visible do separator[i] = string.rep("-", widths[i]) end
    term.text(region.x + 1, region.y + 1, table.concat(separator, "-+-"), theme.border, theme.bg)

    for i, row in ipairs(prepared.rows) do
        local y = region.y + 1 + i
        if y >= region.y + region.height then break end
        local abs_row = prepared.page_start + i - 1
        local row_color = theme.fg
        local x = region.x + 1
        for j, col in ipairs(visible) do
            local text = cell_text(row[col.index])
            local highlight = focused
                and view.select_row == abs_row
                and view.select_col == col.index
            local fg = highlight and theme.cursor or row_color
            term.text(x, y, text .. string.rep(" ", widths[j] - #text), fg, theme.bg)
            x = x + widths[j]
            if j < #visible then
                term.text(x, y, " | ", theme.border, theme.bg)
                x = x + 3
            end
        end
    end

    local footer_y = region.y + region.height - 1
    if footer_y > region.y + 2 then
        local parts = {}
        if prepared.row_count and prepared.row_count > 0 then
            parts[#parts + 1] = string.format("%d rows", prepared.row_count)
        end
        if prepared.truncated then
            parts[#parts + 1] = "(truncated at max_result_rows)"
        end
        if view.filter ~= "" then
            parts[#parts + 1] = string.format("filter: %s", view.filter)
        end
        if #parts > 0 then
            term.text(region.x + 1, footer_y, table.concat(parts, " · "), theme.comment, theme.bg)
        end
    end
end

return M
