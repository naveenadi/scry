-- src/ui/draw.lua — render the application's views

local syntax = require("src.utils.syntax")

local M = {}

function M.editor(term, editor, region, theme)
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

function M.grid(term, result, region, theme, page, page_size)
    if not result or not result.columns then
        term.text(region.x + 1, region.y,
            result and result.error and "Error: " .. result.error or "No results",
            result and result.error and theme.error_fg or theme.comment, theme.bg)
        return
    end

    local columns, rows = result.columns, result.rows or {}
    local widths = {}
    local function cell_text(value)
        if value == nil or (type(value) == "table" and value.is_null) then return "NULL" end
        if type(value) == "table" then return "[binary]" end
        local text = tostring(value)
        return #text > 30 and text:sub(1, 27) .. "..." or text
    end
    for i, name in ipairs(columns) do widths[i] = #tostring(name) end
    for _, row in ipairs(rows) do
        for i = 1, #columns do widths[i] = math.max(widths[i], #cell_text(row[i])) end
    end
    local function draw_row(row, y, color)
        local x = region.x + 1
        for i = 1, #columns do
            local text = row and cell_text(row[i]) or tostring(columns[i])
            term.text(x, y, text .. string.rep(" ", widths[i] - #text), color, theme.bg)
            x = x + widths[i]
            if i < #columns then term.text(x, y, " | ", theme.border, theme.bg); x = x + 3 end
        end
    end
    draw_row(nil, region.y, theme.keyword)
    local separator = {}
    for i = 1, #columns do separator[i] = string.rep("-", widths[i]) end
    term.text(region.x + 1, region.y + 1, table.concat(separator, "-+-"), theme.border, theme.bg)
    local start_row = (page - 1) * page_size + 1
    local end_row = math.min(start_row + page_size - 1, #rows)
    for i = start_row, end_row do
        local y = region.y + 2 + i - start_row
        if y >= region.y + region.height then break end
        draw_row(rows[i], y, theme.fg)
    end
    if result.row_count and result.row_count > 0 then
        term.text(region.x + 1, region.y + region.height - 1,
            string.format("%d rows", result.row_count), theme.comment, theme.bg)
    end
end

function M.status(term, app_state, region, theme, exec, command_mode, focus)
    for x = region.x, region.x + region.width - 1 do
        term.cell(x, region.y, string.byte(" "), theme.status_fg, theme.status_bg)
    end
    local mode = command_mode and "[COMMAND]"
        or focus == "sidebar" and "[SIDEBAR]"
        or "[INSERT]"
    local parts = { mode }
    if app_state.connection_name then table.insert(parts, app_state.connection_name) end
    if exec and exec:is_read_only() then table.insert(parts, "READ ONLY") end
    if app_state.page_info then table.insert(parts, app_state.page_info) end
    if app_state.row_count > 0 then table.insert(parts, string.format("%d rows", app_state.row_count)) end
    if app_state.elapsed_ms > 0 then table.insert(parts, string.format("%d ms", app_state.elapsed_ms)) end
    if app_state.status_message ~= "" then table.insert(parts, app_state.status_message) end
    term.text(region.x, region.y, " " .. table.concat(parts, " | "), theme.status_fg, theme.status_bg)
end

function M.sidebar(term, app_state, region, theme, terminal, sidebar_state)
    term.text(region.x + 1, region.y, "Connections", theme.keyword, theme.bg)
    local color = app_state.connection_status == "connected" and terminal.GREEN
        or app_state.connection_status == "connecting" and terminal.YELLOW or terminal.RED
    term.text(region.x + 1, region.y + 1, "* " .. (app_state.connection_name or "none"), color, theme.bg)
    if app_state.connection_status == "connected" then
        term.text(region.x + 1, region.y + 3, "Tables", theme.keyword, theme.bg)
        local sel = sidebar_state and sidebar_state.selected or 0
        local scroll = sidebar_state and sidebar_state.scroll or 0
        local visible = region.height - 4
        -- Adjust scroll to keep selection visible
        if sel - scroll >= visible then scroll = sel - visible + 1 end
        if sel < scroll then scroll = sel end
        for i, name in ipairs(app_state.tables or {}) do
            local row = i - scroll
            if row < 0 then -- skip
            elseif row >= visible then break
            else
                local y = region.y + 4 + row
                local fg = (i == sel) and theme.sidebar_selected or theme.sidebar_fg
                local prefix = (i == sel) and "> " or "  "
                term.text(region.x + 1, y, prefix .. name, fg, theme.bg)
            end
        end
        if sidebar_state then
            sidebar_state.scroll = scroll
        end
    end
end

function M.modal(term, title, lines, region, theme, terminal)
    -- Draw a centered modal box
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

function M.too_small(term, terminal)
    term.clear()
    local message = "Terminal too small. Please resize to at least 80x24."
    term.text(math.floor((term.width() - #message) / 2), math.floor(term.height() / 2), message, terminal.RED, terminal.DEFAULT)
    term.present()
end

return M
