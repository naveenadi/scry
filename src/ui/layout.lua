-- src/ui/layout.lua — UI layout management

local M = {}

-- Layout regions
function M.calculate(terminal, config)
    local w = terminal.width()
    local h = terminal.height()

    -- Minimum terminal size
    if w < 80 or h < 24 then
        return nil -- too small
    end

    local sidebar_width = config and config.general and config.general.sidebar_width or 30
    local status_height = 1
    local editor_ratio = 0.4
    local grid_ratio = 0.6

    local main_width = w - sidebar_width
    local main_height = h - status_height

    local editor_height = math.floor(main_height * editor_ratio)
    local grid_height = main_height - editor_height

    return {
        width = w,
        height = h,
        sidebar = {
            x = 0,
            y = 0,
            width = sidebar_width,
            height = main_height,
        },
        editor = {
            x = sidebar_width,
            y = 0,
            width = main_width,
            height = editor_height,
        },
        grid = {
            x = sidebar_width,
            y = editor_height,
            width = main_width,
            height = grid_height,
        },
        status = {
            x = 0,
            y = h - status_height,
            width = w,
            height = status_height,
        },
    }
end

return M
