-- src/ui/keys.lua — keyboard dispatch for the TUI

local commands = require("src.ui.commands")

local M = {}

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
            ctx.state.status_message = ":q  :reconnect  :dismiss  :help"
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
            if ui.history_index < #ctx.history then
                ui.history_index = ui.history_index + 1
                ctx.editor:set_text(ctx.history[ui.history_index])
            end
            return
        end

        if pressed(event, terminal.KEY_CTRL_N) then
            if ui.history_index > 1 then
                ui.history_index = ui.history_index - 1
                ctx.editor:set_text(ctx.history[ui.history_index])
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

        if escape then
            ctx.state.focus = "sidebar"
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
