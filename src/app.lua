-- src/app.lua — application entry point
-- Wires together config, terminal, adapter, execution engine, event loop, and UI.

local config_loader = require("src.config.loader")
local terminal = require("src.tui.terminal")
local layout = require("src.ui.layout")
local editor_mod = require("src.ui.editor")
local event_loop = require("src.core.event_loop")
local execution = require("src.core.execution")
local state = require("src.core.state")
local syntax = require("src.utils.syntax")
local sqlite = require("src.db.sqlite")
local parse = require("src.sql.parse")
local platform = require("src.platform")

local M = {}

-- Theme colors
local themes = {
    dark = {
        bg = terminal.DEFAULT,
        fg = terminal.DEFAULT,
        keyword = terminal.CYAN + terminal.BOLD,
        string_color = terminal.GREEN,
        comment = terminal.YELLOW + terminal.DIM,
        number = terminal.MAGENTA,
        status_bg = terminal.BLACK,
        status_fg = terminal.WHITE,
        sidebar_fg = terminal.DEFAULT,
        sidebar_selected = terminal.BLACK + terminal.REVERSE,
        error_fg = terminal.RED + terminal.BOLD,
        border = terminal.WHITE,
        cursor = terminal.DEFAULT,
    },
    light = {
        bg = terminal.DEFAULT,
        fg = terminal.DEFAULT,
        keyword = terminal.BLUE + terminal.BOLD,
        string_color = terminal.GREEN,
        comment = terminal.YELLOW + terminal.DIM,
        number = terminal.MAGENTA,
        status_bg = terminal.WHITE,
        status_fg = terminal.BLACK,
        sidebar_fg = terminal.DEFAULT,
        sidebar_selected = terminal.WHITE + terminal.REVERSE,
        error_fg = terminal.RED + terminal.BOLD,
        border = terminal.BLACK,
        cursor = terminal.DEFAULT,
    },
}

-- Parse CLI arguments.
local function parse_args(args)
    local result = {
        connection = nil,
        read_only = false,
        debug = false,
        version = false,
        help = false,
    }

    local i = 1
    while i <= #args do
        local arg = args[i]
        if arg == "--connection" and i + 1 <= #args then
            result.connection = args[i + 1]
            i = i + 2
        elseif arg:sub(1, 13) == "--connection=" then
            result.connection = arg:sub(14)
            i = i + 1
        elseif arg == "--read-only" then
            result.read_only = true
            i = i + 1
        elseif arg == "--debug" then
            result.debug = true
            i = i + 1
        elseif arg == "--version" then
            result.version = true
            i = i + 1
        elseif arg == "--help" or arg == "-h" then
            result.help = true
            i = i + 1
        else
            i = i + 1
        end
    end

    return result
end

-- Show help text.
local function show_help()
    print("scry — terminal SQL client")
    print("")
    print("Usage: scry [OPTIONS]")
    print("")
    print("Options:")
    print("  --connection NAME  Connect to a named connection profile")
    print("  --read-only        Enable read-only mode")
    print("  --debug            Enable debug logging")
    print("  --version          Show version")
    print("  --help, -h         Show this help")
end

-- Show version.
local function show_version()
    print("scry 0.1.0")
end

-- Draw the editor area.
local function draw_editor(term, ed, region, theme)
    local lines = ed.lines
    local visible_lines = region.height - 1 -- leave room for border

    -- Ensure cursor is visible
    if ed.cursor_y < ed.scroll_y then
        ed.scroll_y = ed.cursor_y
    end
    if ed.cursor_y >= ed.scroll_y + visible_lines then
        ed.scroll_y = ed.cursor_y - visible_lines + 1
    end

    for row = 0, visible_lines - 1 do
        local line_idx = ed.scroll_y + row + 1
        local line = lines[line_idx] or ""

        -- Draw line number
        local ln = string.format("%3d ", line_idx)
        term.text(region.x, region.y + row, ln, theme.comment, theme.bg)

        -- Draw syntax-highlighted line
        local tokens = syntax.tokenize_line(line)
        local col = region.x + 4
        for _, tok in ipairs(tokens) do
            local color
            if tok.type == syntax.TOKEN_KEYWORD then
                color = theme.keyword
            elseif tok.type == syntax.TOKEN_STRING then
                color = theme.string_color
            elseif tok.type == syntax.TOKEN_COMMENT then
                color = theme.comment
            elseif tok.type == syntax.TOKEN_NUMBER then
                color = theme.number
            else
                color = theme.fg
            end
            col = term.text(col, region.y + row, tok.text, color, theme.bg)
            if col >= region.x + region.width then break end
        end
    end

    -- Draw cursor
    local cursor_screen_y = region.y + (ed.cursor_y - ed.scroll_y)
    local cursor_screen_x = region.x + 4 + ed.cursor_x
    if cursor_screen_y >= region.y and cursor_screen_y < region.y + visible_lines then
        term.set_cursor(cursor_screen_x, cursor_screen_y)
    end
end

-- Draw the results grid.
local function draw_grid(term, result, region, theme, page, page_size)
    if not result or not result.columns then
        if result and result.error then
            term.text(region.x + 1, region.y, "Error: " .. result.error, theme.error_fg, theme.bg)
        else
            term.text(region.x + 1, region.y, "No results", theme.comment, theme.bg)
        end
        return
    end

    local columns = result.columns
    local rows = result.rows or {}
    local col_count = #columns
    local widths = {}

    local function cell_text(val)
        if val == nil or (type(val) == "table" and val.is_null) then
            return "NULL"
        elseif type(val) == "table" then
            return "[binary]"
        end
        local text = tostring(val)
        return #text > 30 and text:sub(1, 27) .. "..." or text
    end

    for ci, col_name in ipairs(columns) do
        widths[ci] = #tostring(col_name)
    end
    for _, row in ipairs(rows) do
        for ci = 1, col_count do
            widths[ci] = math.max(widths[ci], #cell_text(row[ci]))
        end
    end

    local function draw_row(row, y, color)
        local x = region.x + 1
        for ci = 1, col_count do
            local text = row and cell_text(row[ci]) or tostring(columns[ci])
            term.text(x, y, text .. string.rep(" ", widths[ci] - #text), color, theme.bg)
            x = x + widths[ci]
            if ci < col_count then
                term.text(x, y, " | ", theme.border, theme.bg)
                x = x + 3
            end
        end
    end

    -- Draw aligned column headers and separator.
    draw_row(nil, region.y, theme.keyword)
    local separator = {}
    for ci = 1, col_count do
        separator[ci] = string.rep("-", widths[ci])
    end
    term.text(region.x + 1, region.y + 1, table.concat(separator, "-+-"), theme.border, theme.bg)

    -- Draw rows (paged).
    local start_row = (page - 1) * page_size + 1
    local end_row = math.min(start_row + page_size - 1, #rows)

    for ri = start_row, end_row do
        local screen_y = region.y + 2 + (ri - start_row)
        if screen_y >= region.y + region.height then break end
        draw_row(rows[ri], screen_y, theme.fg)
    end

    -- Show row count / limit message
    if result.row_count and result.row_count > 0 then
        local msg = string.format("%d rows", result.row_count)
        term.text(region.x + 1, region.y + region.height - 1, msg, theme.comment, theme.bg)
    end
end

-- Draw the status bar.
local function draw_status(term, app_state, region, theme, exec, command_mode)
    -- Fill background
    for x = region.x, region.x + region.width - 1 do
        term.cell(x, region.y, string.byte(" "), theme.status_fg, theme.status_bg)
    end

    local parts = {}

    -- Connection name
    if app_state.connection_name then
        table.insert(parts, app_state.connection_name)
    end

    -- Read-only badge
    if exec and exec:is_read_only() then
        table.insert(parts, "READ ONLY")
    end

    -- Row count
    if app_state.row_count > 0 then
        table.insert(parts, string.format("%d rows", app_state.row_count))
    end

    -- Elapsed time
    if app_state.elapsed_ms > 0 then
        table.insert(parts, string.format("%d ms", app_state.elapsed_ms))
    end

    table.insert(parts, 1, command_mode and "[COMMAND]" or "[INSERT]")

    -- Status message
    if app_state.status_message ~= "" then
        table.insert(parts, app_state.status_message)
    end

    local text = " " .. table.concat(parts, " | ")
    term.text(region.x, region.y, text, theme.status_fg, theme.status_bg)
end

-- Draw the sidebar.
local function draw_sidebar(term, app_state, region, theme, adapter)
    -- Title
    term.text(region.x + 1, region.y, "Connections", theme.keyword, theme.bg)

    -- Connection status
    local status_color
    if app_state.connection_status == "connected" then
        status_color = terminal.GREEN
    elseif app_state.connection_status == "connecting" then
        status_color = terminal.YELLOW
    else
        status_color = terminal.RED
    end
    term.text(region.x + 1, region.y + 1, "* " .. (app_state.connection_name or "none"), status_color, theme.bg)

    -- Tables
    if adapter and app_state.connection_status == "connected" then
        local tables = adapter:list_tables()
        term.text(region.x + 1, region.y + 3, "Tables", theme.keyword, theme.bg)
        for i, tbl in ipairs(tables) do
            if region.y + 3 + i >= region.y + region.height then break end
            term.text(region.x + 2, region.y + 3 + i, tbl, theme.sidebar_fg, theme.bg)
        end
    end
end

-- Draw "terminal too small" message.
local function draw_too_small(term)
    term.clear()
    local msg = "Terminal too small. Please resize to at least 80x24."
    local w = term.width()
    local h = term.height()
    local x = math.floor((w - #msg) / 2)
    local y = math.floor(h / 2)
    term.text(x, y, msg, terminal.RED, terminal.DEFAULT)
    term.present()
end

-- Main application entry point.
function M.run(args)
    local cli = parse_args(args or {})

    if cli.version then
        show_version()
        return 0
    end

    if cli.help then
        show_help()
        return 0
    end

    -- Load configuration
    local config = config_loader.load()

    -- Select connection
    local connection_name = cli.connection
    local connection_config = nil

    if connection_name then
        connection_config = config.connections[connection_name]
        if not connection_config then
            io.stderr:write("error: connection '" .. connection_name .. "' not found in config\n")
            return 1
        end
    else
        -- Use the first connection
        for name, conn in pairs(config.connections or {}) do
            connection_name = name
            connection_config = conn
            break
        end
    end

    if not connection_config then
        io.stderr:write("error: no connections configured\n")
        return 1
    end

    -- Initialize terminal
    if not terminal.init() then
        io.stderr:write("error: failed to initialize terminal\n")
        return 1
    end

    -- Check terminal size
    if terminal.width() < 80 or terminal.height() < 24 then
        draw_too_small(terminal)
        terminal.shutdown()
        return 1
    end

    -- Create adapter
    local adapter
    if connection_config.type == "sqlite" then
        adapter = sqlite.new()
    else
        terminal.shutdown()
        io.stderr:write("error: unsupported database type: " .. (connection_config.type or "nil") .. "\n")
        return 1
    end

    -- Apply read-only
    if cli.read_only or connection_config.read_only then
        adapter._read_only = true
    end

    -- Connect
    local ok, err = adapter:connect(connection_config)
    if not ok then
        terminal.shutdown()
        io.stderr:write("error: " .. (err or "connection failed") .. "\n")
        return 1
    end

    -- Create application state
    local app_state = state.new()
    app_state.connection_name = connection_name
    app_state.connection_status = "connected"

    -- Create editor
    local ed = editor_mod.new()

    -- Create execution engine
    local exec = execution.new(adapter, config)

    -- Create event loop
    local loop = event_loop.new(terminal, app_state, exec)

    -- Theme
    local theme = themes[config.general.theme] or themes.dark

    -- Grid state
    local grid_page = 1
    local grid_page_size = config.general.default_page_size or 100
    local last_result = nil
    local exec_start_ms = nil
    local result_consumed = true

    -- History
    local history = {}
    local history_index = 0
    local command_mode = false
    local command_buffer = ""

    -- Record history entries
    exec.on_history_entry = function(text)
        table.insert(history, 1, text)
        if #history > (config.query_editor.history_limit or 1000) then
            table.remove(history)
        end
        history_index = 0
    end

    -- Key handler
    loop.key_handler_fn = function(event)
        local key = event.key
        local ch = event.char

        -- Termbox reports printable keys through ch and control/navigation keys
        -- through key. Some terminals report control keys through ch instead.
        local function pressed(expected)
            return key == expected or event.ch == expected
        end
        local enter = pressed(terminal.KEY_ENTER)
        local escape = pressed(terminal.KEY_ESC)
        local backspace = pressed(terminal.KEY_BACKSPACE)
            or key == terminal.KEY_BACKSPACE2
            or event.ch == 0x7f

        -- Command mode: ':' followed by a command and Enter.
        if command_mode then
            if escape then
                command_mode = false
                command_buffer = ""
                app_state.status_message = ""
                return
            elseif enter then
                local command = command_buffer:match("^%s*(.-)%s*$")
                if command == "q" or command == "quit" or command == "q!" then
                    loop:stop()
                elseif command == "reconnect" then
                    if exec.state == execution.RECONNECT_CONFIRM and exec:confirm_reconnect() then
                        local ok, err = adapter:connect(connection_config)
                        if ok then
                            app_state.connection_status = "connected"
                            app_state.status_message = "Reconnected"
                        else
                            app_state.status_message = "Reconnect failed: " .. (err or "?")
                        end
                    else
                        app_state.status_message = "Nothing to reconnect"
                    end
                elseif command == "dismiss" then
                    if exec.state == execution.RECONNECT_CONFIRM then
                        exec:confirm_reconnect()
                        app_state.status_message = "Continuing on abandoned connection"
                    else
                        app_state.status_message = "Nothing to dismiss"
                    end
                elseif command == "help" then
                    app_state.status_message = ":q  :reconnect  :dismiss  :help"
                else
                    app_state.status_message = "Unknown command: :" .. command
                end
                command_mode = false
                command_buffer = ""
                return
            elseif backspace then
                command_buffer = command_buffer:sub(1, -2)
                return
            elseif event.type == "char" and ch then
                -- The colon is already shown as the command prompt, but accept
                -- it if the user types it after Esc.
                if not (command_buffer == "" and ch == ":") then
                    command_buffer = command_buffer .. ch
                end
                return
            end
            return
        end

        -- ':' or Esc enters command mode from the editor.
        if app_state.focus == "editor"
            and ((event.type == "char" and ch == ":") or escape) then
            command_mode = true
            command_buffer = ""
            app_state.status_message = ""
            return
        end

        -- Ctrl+R: execute query
        if pressed(terminal.KEY_CTRL_R) then
            local text = ed:get_text()
            if text and text:match("%S") then
                exec_start_ms = platform.monotonic_ms()
                result_consumed = false
                exec:execute(text)
                app_state.status_message = "Running..."
                grid_page = 1
            end
            return
        end

        -- Ctrl+C: cancel
        if pressed(terminal.KEY_CTRL_C) then
            if exec:is_running() then
                exec:cancel()
                app_state.status_message = "Cancelled"
            elseif exec.state == execution.RECONNECT_CONFIRM then
                -- Stay on RECONNECT_CONFIRM; user must choose via :reconnect / :dismiss
                app_state.status_message = "Connection abandoned — :reconnect or :dismiss"
            end
            return
        end

        -- Ctrl+P: history previous
        if pressed(terminal.KEY_CTRL_P) then
            if history_index < #history then
                history_index = history_index + 1
                ed:set_text(history[history_index])
            end
            return
        end

        -- Ctrl+N: history next
        if pressed(terminal.KEY_CTRL_N) then
            if history_index > 1 then
                history_index = history_index - 1
                ed:set_text(history[history_index])
            else
                history_index = 0
                ed:set_text("")
            end
            return
        end

        -- Tab: cycle focus
        if pressed(terminal.KEY_TAB) then
            if app_state.focus == "editor" then
                app_state.focus = "grid"
            elseif app_state.focus == "grid" then
                app_state.focus = "sidebar"
            else
                app_state.focus = "editor"
            end
            return
        end

        -- Esc: focus sidebar
        if escape then
            app_state.focus = "sidebar"
            return
        end

        -- Editor keys (when editor has focus)
        if app_state.focus == "editor" then
            if pressed(terminal.KEY_ARROW_UP) then
                ed:move_up()
            elseif pressed(terminal.KEY_ARROW_DOWN) then
                ed:move_down()
            elseif pressed(terminal.KEY_ARROW_LEFT) then
                ed:move_left()
            elseif pressed(terminal.KEY_ARROW_RIGHT) then
                ed:move_right()
            elseif pressed(terminal.KEY_HOME) then
                ed:move_home()
            elseif pressed(terminal.KEY_END) then
                ed:move_end()
            elseif enter then
                ed:insert_newline()
            elseif backspace then
                ed:backspace()
            elseif pressed(terminal.KEY_DELETE) then
                ed:delete()
            elseif pressed(terminal.KEY_CTRL_A) then
                ed:move_home()
            elseif pressed(terminal.KEY_CTRL_E) then
                ed:move_end()
            elseif pressed(terminal.KEY_CTRL_K) then
                ed:kill_line()
            elseif pressed(terminal.KEY_CTRL_U) then
                ed:kill_line_start()
            elseif pressed(terminal.KEY_CTRL_L) then
                ed:clear_line()
            elseif event.type == "char" and ch then
                ed:insert_char(ch)
            end
            return
        end

        -- Grid keys (when grid has focus)
        if app_state.focus == "grid" then
            if key == terminal.KEY_CTRL_F then
                -- Page forward
                local max_pages = math.ceil((last_result and #last_result.rows or 0) / grid_page_size)
                if grid_page < max_pages then
                    grid_page = grid_page + 1
                end
            elseif key == terminal.KEY_CTRL_B then
                -- Page backward
                if grid_page > 1 then
                    grid_page = grid_page - 1
                end
            end
            return
        end

        -- Sidebar keys
        if app_state.focus == "sidebar" then
            -- j/k navigation would go here
            return
        end

    end

    -- Render function
    loop.render_fn = function()
        -- The Execution may finish on a later event-loop tick. Pick up the
        -- result once per execution (transition-gated, not steady-state, so
        -- later status messages aren't clobbered every frame).
        if result_consumed == false
            and (exec.state == execution.COMPLETE or exec.state == execution.EXECUTION_FAILED)
            and not command_mode then
            local result = exec:get_result()
            last_result = result
            app_state.row_count = result.row_count or 0
            app_state.status_message = result.error or ""
            if exec_start_ms then
                app_state.elapsed_ms = platform.monotonic_ms() - exec_start_ms
                exec_start_ms = nil
            end
            result_consumed = true
        end

        -- Reconnect confirmation prompt (spec §4b: cancel → reconnect confirm).
        if exec.state == execution.RECONNECT_CONFIRM and not command_mode then
            app_state.status_message = "Connection abandoned — :reconnect or :dismiss"
        end

        if command_mode then
            app_state.status_message = ":" .. command_buffer
        end

        terminal.clear()

        local regions = layout.calculate(terminal, config)
        if not regions then
            draw_too_small(terminal)
            return
        end

        -- Draw sidebar
        draw_sidebar(terminal, app_state, regions.sidebar, theme, adapter)

        -- Draw editor
        draw_editor(terminal, ed, regions.editor, theme)

        -- Draw grid
        draw_grid(terminal, last_result, regions.grid, theme, grid_page, grid_page_size)

        -- Draw status bar
        draw_status(terminal, app_state, regions.status, theme, exec, command_mode)

        terminal.present()
    end

    -- Run the event loop
    loop:run()

    -- Cleanup
    adapter:close()
    terminal.shutdown()

    return 0
end

return M
