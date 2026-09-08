-- src/ui/draw/status.lua — status bar renderer

local M = {}

function M.render(term, app_state, region, theme, exec, command_mode, focus)
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

return M
