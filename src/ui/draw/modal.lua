-- src/ui/draw/modal.lua — modal overlay renderer

local M = {}

function M.render(term, title, lines, region, theme, terminal)
    local max_width = #title + 4
    for _, line in ipairs(lines) do
        if #line + 4 > max_width then max_width = #line + 4 end
    end
    max_width = math.min(max_width, region.width - 4)
    local modal_h = #lines + 2
    local modal_w = max_width
    local modal_x = region.x + math.floor((region.width - modal_w) / 2)
    local modal_y = region.y + math.floor((region.height - modal_h) / 2)

    -- Draw border
    local border_color = theme.border
    for x = modal_x, modal_x + modal_w - 1 do
        term.cell(x, modal_y, string.byte("-"), border_color, theme.bg)
        term.cell(x, modal_y + modal_h - 1, string.byte("-"), border_color, theme.bg)
    end
    for y = modal_y + 1, modal_y + modal_h - 2 do
        term.cell(modal_x, y, string.byte("|"), border_color, theme.bg)
        term.cell(modal_x + modal_w - 1, y, string.byte("|"), border_color, theme.bg)
    end
    term.cell(modal_x, modal_y, string.byte("+"), border_color, theme.bg)
    term.cell(modal_x + modal_w - 1, modal_y, string.byte("+"), border_color, theme.bg)
    term.cell(modal_x, modal_y + modal_h - 1, string.byte("+"), border_color, theme.bg)
    term.cell(modal_x + modal_w - 1, modal_y + modal_h - 1, string.byte("+"), border_color, theme.bg)

    -- Title
    term.text(modal_x + 2, modal_y, " " .. title .. " ", theme.keyword, theme.bg)

    -- Content lines
    for i, line in ipairs(lines) do
        local y = modal_y + i
        if y >= modal_y + modal_h - 1 then break end
        term.text(modal_x + 2, y, line:sub(1, modal_w - 4), theme.fg, theme.bg)
    end
end

return M
