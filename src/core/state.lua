-- src/core/state.lua — application state management

local M = {}

-- Create a new application state.
function M.new()
    local self = {
        -- Connection state
        current_connection = nil,  -- the live adapter
        connection_name = nil,     -- name from config
        connection_status = "disconnected", -- "disconnected" | "connecting" | "connected" | "error"

        -- UI state
        focus = "editor", -- "sidebar" | "editor" | "grid"
        sidebar_width = 30,

        -- Editor state
        buffer = "",
        cursor_x = 0,
        cursor_y = 0,

        -- Grid state
        grid_page = 1,
        grid_page_size = 100,
        grid_scroll_x = 0,
        grid_sort_column = nil,
        grid_sort_ascending = true,
        grid_filter = nil,

        -- History state
        history_index = 0,
        history_entries = {},

        -- Execution state
        execution = nil,

        -- Status
        status_message = "",
        elapsed_ms = 0,
        row_count = 0,

        -- Running flag
        running = true,
    }

    return self
end

return M
