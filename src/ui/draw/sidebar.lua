-- src/ui/draw/sidebar.lua — sidebar renderer

local M = {}

function M.render(term, app_state, region, theme, terminal, sidebar_state)
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

return M
