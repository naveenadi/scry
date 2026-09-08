-- src/ui/draw/editor.lua — editor region renderer

local syntax = require("src.utils.syntax")

local M = {}

function M.render(term, editor, region, theme)
    local visible_lines = region.height - 1
    if editor.cursor_y < editor.scroll_y then editor.scroll_y = editor.cursor_y end
    if editor.cursor_y >= editor.scroll_y + visible_lines then
        editor.scroll_y = editor.cursor_y - visible_lines + 1
    end

    for row = 0, visible_lines - 1 do
        local line_idx = editor.scroll_y + row + 1
        local line = editor.lines[line_idx] or ""
        term.text(region.x, region.y + row, string.format("%3d ", line_idx), theme.comment, theme.bg)
        local col = region.x + 4
        for _, tok in ipairs(syntax.tokenize_line(line)) do
            local color = theme.fg
            if tok.type == syntax.TOKEN_KEYWORD then color = theme.keyword
            elseif tok.type == syntax.TOKEN_STRING then color = theme.string_color
            elseif tok.type == syntax.TOKEN_COMMENT then color = theme.comment
            elseif tok.type == syntax.TOKEN_NUMBER then color = theme.number end
            col = term.text(col, region.y + row, tok.text, color, theme.bg)
            if col >= region.x + region.width then break end
        end
    end

    local y = region.y + editor.cursor_y - editor.scroll_y
    local x = region.x + 4 + editor.cursor_x
    if y >= region.y and y < region.y + visible_lines then term.set_cursor(x, y) end
end

return M
