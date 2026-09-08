-- src/ui/keys.lua — keyboard dispatch for the TUI
-- Delegates command mode to keys/command.lua, help text to keys/help.lua.

local help_mod = require("src.ui.keys.help")
local command_mod = require("src.ui.keys.command")
local export_stream = require("src.export.stream")
local grid_mod = require("src.ui.grid")

local M = {}

M.HELP_LINES = help_mod.HELP_LINES

function M.new(ctx)
    local terminal = ctx.terminal
    local ui = ctx.ui

    local function pressed(event, expected)
        return event.key == expected or event.ch == expected
    end

    return function(event)
        local key, ch = event.key, event.char
        local enter = pressed(event, terminal.KEY_ENTER)
        local escape = pressed(event, terminal.KEY_ESC)
        local backspace = pressed(event, terminal.KEY_BACKSPACE)
            or key == terminal.KEY_BACKSPACE2 or event.ch == 0x7f

        -- Command mode: delegate to command handler
        if ui.command_mode then
            if escape then
                ui.command_mode = false
                ui.command_buffer = ""
                ctx.state.status_message = ""
            elseif enter then
                command_mod.run(ctx, ui, ui.command_buffer)
            elseif backspace then
                ui.command_buffer = ui.command_buffer:sub(1, -2)
            elseif event.type == "char" and ch then
                if not (ui.command_buffer == "" and ch == ":") then
                    ui.command_buffer = ui.command_buffer .. ch
                end
            end
            return
        end

        -- Help overlay / cell modal: any key dismisses
        if ui.show_help or ui.grid_view.cell_modal then
            ui.show_help = false
            ui.grid_view.cell_modal = nil
            return
        end

        -- Grid filter mode
        if ui.grid_view.filter_mode then
            if escape then
                ui.grid_view.filter_mode = false
                ui.grid_view.filter_buffer = ""
            elseif enter then
                ui.grid_view.filter = ui.grid_view.filter_buffer
                ui.grid_view.filter_mode = false
                ui.grid_view.filter_buffer = ""
                ui.grid_view.page = 1
                ui.grid_view.select_row = 1
            elseif backspace then
                ui.grid_view.filter_buffer = ui.grid_view.filter_buffer:sub(1, -2)
            elseif event.type == "char" and ch then
                ui.grid_view.filter_buffer = ui.grid_view.filter_buffer .. string.char(ch)
            end
            return
        end

        -- Enter command mode
        if ctx.state.focus == "editor"
            and ((event.type == "char" and ch == ":") or escape) then
            ui.command_mode = true
            ui.command_buffer = ""
            ctx.state.status_message = ""
            return
        end

        -- Global keys
        if pressed(event, terminal.KEY_CTRL_R) then
            local text = ctx.editor:get_text()
            if text and text:match("%S") then
                ui.exec_start_ms = ctx.platform.monotonic_ms()
                ui.result_consumed = false
                ctx.execution:execute(text)
                ctx.state.status_message = "Running..."
                grid_mod.reset(ui.grid_view)
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

        local function export_result(format, label, ext)
            if ctx.execution:is_running() then
                ctx.state.status_message = "Cannot export while query is running"
                return
            end
            local sql, err = export_stream.eligible_sql(ctx.execution:get_metadata())
            if not sql then
                ctx.state.status_message = err or "No results to export"
                return
            end
            local path = os.tmpname() .. ext
            local ok, info = export_stream.to_file(ctx.adapter, sql, format, path)
            if ok then
                ctx.state.status_message = string.format("Exported %s (%d rows): %s", label, info, path)
            else
                ctx.state.status_message = "Export failed: " .. (info or "?")
            end
        end

        -- Export: Ctrl+e = CSV, Ctrl+Shift+E = JSON (streams full result via adapter)
        if pressed(event, terminal.KEY_CTRL_E) and ctx.state.focus ~= "editor" then
            export_result("csv", "CSV", ".csv")
            return
        end
        if event.type == "char" and event.ch == string.byte("E") then
            export_result("json", "JSON", ".json")
            return
        end

        -- History navigation
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

        -- Focus cycling
        if pressed(event, terminal.KEY_TAB) then
            if ctx.state.focus == "editor" then
                ctx.state.focus = "grid"
            elseif ctx.state.focus == "grid" then
                ctx.state.focus = "sidebar"
            else
                ctx.state.focus = "editor"
            end
            return
        end

        -- Help toggle
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
                ctx.state.status_message = "Use :connect NAME to switch"
            end
            return
        end

        -- Editor input
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

        -- Grid interaction
        if ctx.state.focus == "grid" then
            local view = ui.grid_view
            local prepared = grid_mod.prepare(ui.last_result, view)
            if not prepared then return end

            if pressed(event, terminal.KEY_CTRL_F) then
                if view.page < prepared.total_pages then view.page = view.page + 1 end
                return
            elseif pressed(event, terminal.KEY_CTRL_B) and view.page > 1 then
                view.page = view.page - 1
                return
            end

            if event.ch == string.byte("/") then
                view.filter_mode = true
                view.filter_buffer = view.filter
                return
            end

            if event.ch == string.byte("g") then
                if view.pending_g then
                    grid_mod.go_first(view)
                    view.pending_g = false
                else
                    view.pending_g = true
                end
                return
            end
            if event.ch == string.byte("G") then
                grid_mod.go_last(view, prepared.total_rows, view.page_size)
                view.pending_g = false
                return
            end
            view.pending_g = false

            if event.ch == string.byte("H") then
                view.col_offset = math.max(0, view.col_offset - 1)
                return
            elseif event.ch == string.byte("L") then
                if view.col_offset < #prepared.columns - 1 then
                    view.col_offset = view.col_offset + 1
                end
                return
            elseif event.ch == string.byte("h") then
                if view.select_col > 1 then view.select_col = view.select_col - 1 end
                return
            elseif event.ch == string.byte("l") then
                if view.select_col < #prepared.columns then view.select_col = view.select_col + 1 end
                return
            elseif event.ch == string.byte("j") or pressed(event, terminal.KEY_ARROW_DOWN) then
                if view.select_row < prepared.total_rows then
                    view.select_row = view.select_row + 1
                    if view.select_row > 0 then
                        local page = math.ceil(view.select_row / view.page_size)
                        if page > view.page then view.page = page end
                    end
                end
                return
            elseif event.ch == string.byte("k") or pressed(event, terminal.KEY_ARROW_UP) then
                if view.select_row > 0 then
                    view.select_row = view.select_row - 1
                    if view.select_row > 0 then
                        local page = math.ceil(view.select_row / view.page_size)
                        if page < view.page then view.page = page end
                    end
                end
                return
            elseif enter then
                if view.select_row == 0 then
                    grid_mod.toggle_sort(view, view.select_col)
                elseif prepared.all_rows[view.select_row] then
                    local row = prepared.all_rows[view.select_row]
                    view.cell_modal = grid_mod.format_cell(row[view.select_col])
                end
                return
            end
        end
    end
end

return M
