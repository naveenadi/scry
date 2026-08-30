-- src/ui/keys.lua — keyboard dispatch for the TUI

local commands = require("src.ui.commands")

local M = {}

-- Help keybinding table
M.HELP_LINES = {
    "Keybindings:",
    "",
    "  Ctrl+r    Execute query",
    "  Ctrl+c    Cancel query",
    "  Ctrl+p    Previous history",
    "  Ctrl+n    Next history",
    "  Tab       Cycle focus (editor/grid/sidebar)",
    "  Esc       Focus sidebar (from editor)",
    "  ?         Toggle this help overlay",
    "",
    "  Editor:",
    "  Arrow keys  Move cursor",
    "  Home/End    Start/end of line",
    "  Ctrl+a/e    Start/end of line",
    "  Ctrl+k      Kill to end of line",
    "  Ctrl+u      Kill to start of line",
    "  Ctrl+l      Clear line",
    "",
    "  Grid:",
    "  Ctrl+f/b    Next/previous page",
    "",
    "  Sidebar:",
    "  j/k         Navigate tables",
    "  Enter        Select table (insert name)",
    "",
    "  Commands:",
    "  :q / :quit   Quit",
    "  :connect NAME Switch connection",
    "  :help        Show commands",
    "  :history     Show query history",
    "  :reconnect   Reconnect after cancel",
    "  :dismiss     Dismiss reconnect prompt",
}

function M.new(ctx)
    local terminal = ctx.terminal
    local ui = ctx.ui

    local function pressed(event, expected)
        return event.key == expected or event.ch == expected
    end

    local function finish_command()
        ui.command_mode = false
        ui.command_buffer = ""
    end

    local function run_command(text)
        local command, argument = commands.parse(text)
        if command == "quit" then
            ctx.loop:stop()
        elseif command == "connect" then
            if argument and argument ~= "" then
                local conn_config = ctx.config.connections[argument]
                if conn_config then
                    ctx.adapter:close()
                    local new_adapter
                    if conn_config.type == "sqlite" then
                        new_adapter = require("src.db.sqlite").new()
                    elseif conn_config.type == "postgres" then
                        new_adapter = require("src.db.postgres").new()
                    elseif conn_config.type == "mysql" then
                        new_adapter = require("src.db.mysql").new()
                    else
                        ctx.state.status_message = "Unsupported type: " .. (conn_config.type or "nil")
                        finish_command()
                        return
                    end
                    local ok, err = new_adapter:connect(conn_config)
                    if ok then
                        ctx.adapter = new_adapter
                        ctx.connection_config = conn_config
                        ctx.state.connection_name = argument
                        ctx.state.connection_status = "connected"
                        ctx.state.tables = new_adapter:list_tables()
                        ctx.state.status_message = "Connected to " .. argument
                        -- Rebuild execution with new adapter
                        ctx.execution = require("src.core.execution").new(
                            new_adapter, ctx.config, ctx.read_only)
                        ctx.state.status_message = "Connected to " .. argument
                    else
                        ctx.state.status_message = "Connect failed: " .. (err or "?")
                    end
                else
                    ctx.state.status_message = "Unknown connection: " .. argument
                end
            else
                ctx.state.status_message = "Usage: :connect NAME"
            end
        elseif command == "reconnect" then
            if ctx.execution.state == ctx.execution.RECONNECT_CONFIRM
                and ctx.execution:confirm_reconnect() then
                local ok, err = ctx.adapter:connect(ctx.connection_config)
                if ok then
                    ctx.state.connection_status = "connected"
                    ctx.state.status_message = "Reconnected"
                else
                    ctx.state.status_message = "Reconnect failed: " .. (err or "?")
                end
            else
                ctx.state.status_message = "Nothing to reconnect"
            end
        elseif command == "dismiss" then
            if ctx.execution.state == ctx.execution.RECONNECT_CONFIRM then
                ctx.execution:confirm_reconnect()
                ctx.state.status_message = "Continuing on abandoned connection"
            else
                ctx.state.status_message = "Nothing to dismiss"
            end
        elseif command == "help" then
            ui.show_help = true
        elseif command == "history" then
            local sql_list = ctx.history:sql_list()
            if #sql_list == 0 then
                ctx.state.status_message = "No history"
            else
                local lines = {}
                for i = 1, math.min(20, #sql_list) do
                    lines[i] = sql_list[i]
                end
                ui.help_lines = lines
                ui.help_title = "History (last " .. #lines .. ")"
                ui.show_help = true
            end
        else
            ctx.state.status_message = "Unknown command: :" .. (argument or "")
        end
        finish_command()
    end

    return function(event)
        local key, ch = event.key, event.char
        local enter = pressed(event, terminal.KEY_ENTER)
        local escape = pressed(event, terminal.KEY_ESC)
        local backspace = pressed(event, terminal.KEY_BACKSPACE)
            or key == terminal.KEY_BACKSPACE2 or event.ch == 0x7f

        if ui.command_mode then
            if escape then
                finish_command()
                ctx.state.status_message = ""
            elseif enter then
                run_command(ui.command_buffer)
            elseif backspace then
                ui.command_buffer = ui.command_buffer:sub(1, -2)
            elseif event.type == "char" and ch then
                if not (ui.command_buffer == "" and ch == ":") then
                    ui.command_buffer = ui.command_buffer .. ch
                end
            end
            return
        end

        -- Help overlay: any key dismisses it
        if ui.show_help then
            ui.show_help = false
            return
        end

        if ctx.state.focus == "editor"
            and ((event.type == "char" and ch == ":") or escape) then
            ui.command_mode = true
            ui.command_buffer = ""
            ctx.state.status_message = ""
            return
        end

        if pressed(event, terminal.KEY_CTRL_R) then
            local text = ctx.editor:get_text()
            if text and text:match("%S") then
                ui.exec_start_ms = ctx.platform.monotonic_ms()
                ui.result_consumed = false
                ctx.execution:execute(text)
                ctx.state.status_message = "Running..."
                ui.grid_page = 1
            end
            return
        end

        if pressed(event, terminal.KEY_CTRL_C) then
            if ctx.execution:is_running() then
                ctx.execution:cancel()
                ctx.state.status_message = "Cancelled"
            elseif ctx.execution.state == ctx.execution.RECONNECT_CONFIRM then
                ctx.state.status_message = "Connection abandoned — :reconnect or :dismiss"
            end
            return
        end

        if pressed(event, terminal.KEY_CTRL_P) then
            local sql_list = ctx.history:sql_list()
            if ui.history_index < #sql_list then
                ui.history_index = ui.history_index + 1
                ctx.editor:set_text(sql_list[ui.history_index])
            end
            return
        end

        if pressed(event, terminal.KEY_CTRL_N) then
            local sql_list = ctx.history:sql_list()
            if ui.history_index > 1 then
                ui.history_index = ui.history_index - 1
                ctx.editor:set_text(sql_list[ui.history_index])
            else
                ui.history_index = 0
                ctx.editor:set_text("")
            end
            return
        end

        if pressed(event, terminal.KEY_TAB) then
            ctx.state.focus = ctx.state.focus == "editor" and "grid"
                or ctx.state.focus == "grid" and "sidebar" or "editor"
            return
        end

        -- Help overlay toggle
        if event.ch == string.byte("?") then
            ui.show_help = not ui.show_help
            return
        end

        if escape then
            if ui.show_help then
                ui.show_help = false
                return
            end
            ctx.state.focus = "sidebar"
            return
        end

        -- Sidebar navigation
        if ctx.state.focus == "sidebar" then
            local sidebar = ui.sidebar_state
            local tables = ctx.state.tables or {}
            if pressed(event, terminal.KEY_ARROW_UP) or event.ch == string.byte("k") then
                if sidebar.selected > 1 then sidebar.selected = sidebar.selected - 1 end
            elseif pressed(event, terminal.KEY_ARROW_DOWN) or event.ch == string.byte("j") then
                if sidebar.selected < #tables then sidebar.selected = sidebar.selected + 1 end
            elseif enter then
                if #tables > 0 and sidebar.selected >= 1 and sidebar.selected <= #tables then
                    local name = tables[sidebar.selected]
                    ctx.editor:insert_text(name .. " ")
                    ctx.state.focus = "editor"
                    ctx.state.status_message = "Inserted: " .. name
                end
            elseif event.ch == string.byte("c") then
                -- 'c' in sidebar to switch connection
                ctx.state.status_message = "Use :connect NAME to switch"
            end
            return
        end

        if ctx.state.focus == "editor" then
            local editor = ctx.editor
            if pressed(event, terminal.KEY_ARROW_UP) then editor:move_up()
            elseif pressed(event, terminal.KEY_ARROW_DOWN) then editor:move_down()
            elseif pressed(event, terminal.KEY_ARROW_LEFT) then editor:move_left()
            elseif pressed(event, terminal.KEY_ARROW_RIGHT) then editor:move_right()
            elseif pressed(event, terminal.KEY_HOME) then editor:move_home()
            elseif pressed(event, terminal.KEY_END) then editor:move_end()
            elseif enter then editor:insert_newline()
            elseif backspace then editor:backspace()
            elseif pressed(event, terminal.KEY_DELETE) then editor:delete()
            elseif pressed(event, terminal.KEY_CTRL_A) then editor:move_home()
            elseif pressed(event, terminal.KEY_CTRL_E) then editor:move_end()
            elseif pressed(event, terminal.KEY_CTRL_K) then editor:kill_line()
            elseif pressed(event, terminal.KEY_CTRL_U) then editor:kill_line_start()
            elseif pressed(event, terminal.KEY_CTRL_L) then editor:clear_line()
            elseif event.type == "char" and ch then editor:insert_char(ch) end
            return
        end

        if ctx.state.focus == "grid" then
            if pressed(event, terminal.KEY_CTRL_F) then
                local rows = ui.last_result and #ui.last_result.rows or 0
                local pages = math.ceil(rows / ui.grid_page_size)
                if ui.grid_page < pages then ui.grid_page = ui.grid_page + 1 end
            elseif pressed(event, terminal.KEY_CTRL_B) and ui.grid_page > 1 then
                ui.grid_page = ui.grid_page - 1
            end
        end
    end
end

return M
