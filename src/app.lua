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
        term.text(region.x + 1, region.y, "No results", theme.comment, theme.bg)
        return
    end

    local columns = result.columns
    local rows = result.rows or {}
    local col_count = #columns

    -- Draw column headers
    local col_x = region.x + 1
    for ci, col_name in ipairs(columns) do
        local name = tostring(col_name)
        col_x = term.text(col_x, region.y, name, theme.keyword, theme.bg)
        col_x = col_x + 2 -- spacing
    end

    -- Draw separator
    local sep = string.rep("─", region.width - 2)
    term.text(region.x + 1, region.y + 1, sep, theme.border, theme.bg)

    -- Draw rows (paged)
    local start_row = (page - 1) * page_size + 1
    local end_row = math.min(start_row + page_size - 1, #rows)

    for ri = start_row, end_row do
        local row = rows[ri]
        local screen_y = region.y + 2 + (ri - start_row)
        if screen_y >= region.y + region.height then break end

        local col_x = region.x + 1
        for ci = 1, col_count do
            local val = row[ci]
            local text
            if val == nil or (type(val) == "table" and val.is_null) then
                text = "NULL"
                col_x = term.text(col_x, screen_y, text, theme.comment, theme.bg)
            elseif type(val) == "table" then
                text = "[binary]"
                col_x = term.text(col_x, screen_y, text, theme.comment, theme.bg)
            else
                text = tostring(val)
                if #text > 30 then
                    text = text:sub(1, 27) .. "..."
                end
                col_x = term.text(col_x, screen_y, text, theme.fg, theme.bg)
            end
            col_x = col_x + 2
        end
    end

    -- Show row count / limit message
    if result.row_count and result.row_count > 0 then
        local msg = string.format("%d rows", result.row_count)
        term.text(region.x + 1, region.y + region.height - 1, msg, theme.comment, theme.bg)
    end
end

-- Draw the status bar.
local function draw_status(term, app_state, region, theme)
    -- Fill background
    for x = region.x, region.x + region.width - 1 do
        term.cell(x, region.y, 0, theme.status_fg, theme.status_bg)
    end

    local parts = {}

    -- Connection name
    if app_state.connection_name then
        table.insert(parts, app_state.connection_name)
    end

    -- Read-only badge
    if app_state.execution and app_state.execution.adapter and app_state.execution.adapter._read_only then
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

    -- Status message
    if app_state.status_message ~= "" then
        table.insert(parts, app_state.status_message)
    end

    local text = " " .. table.concat(parts, " │ ")
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
    term.text(region.x + 1, region.y + 1, "● " .. (app_state.connection_name or "none"), status_color, theme.bg)

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
    local msg = "Terminal too small. Please resize to at least 80×24."
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

    -- Override read-only from CLI
    if cli.read_only then
        -- Will be applied to the adapter
    end

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

    -- History
    local history = {}
    local history_index = 0

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

        -- Ctrl+R: execute query
        if key == terminal.KEY_CTRL_R then
            local text = ed:get_text()
            if text and text:match("%S") then
                local start_time = os.clock()
                exec:execute(text)
                local elapsed = (os.clock() - start_time) * 1000
                app_state.elapsed_ms = math.floor(elapsed)
                -- Get result after execution completes
                local result = exec:get_result()
                if result then
                    last_result = result
                    app_state.row_count = result.row_count or 0
                    if result.error then
                        app_state.status_message = result.error
                    else
                        app_state.status_message = ""
                    end
                end
                grid_page = 1
            end
            return
        end

        -- Ctrl+C: cancel
        if key == terminal.KEY_CTRL_C then
            if exec:is_running() then
                exec:cancel()
                app_state.status_message = "Cancelled"
            end
            return
        end

        -- Ctrl+P: history previous
        if key == terminal.KEY_CTRL_P then
            if history_index < #history then
                history_index = history_index + 1
                ed:set_text(history[history_index])
            end
            return
        end

        -- Ctrl+N: history next
        if key == terminal.KEY_CTRL_N then
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
        if key == terminal.KEY_TAB then
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
        if key == terminal.KEY_ESC then
            app_state.focus = "sidebar"
            return
        end

        -- Editor keys (when editor has focus)
        if app_state.focus == "editor" then
            if key == terminal.KEY_ARROW_UP then
                ed:move_up()
            elseif key == terminal.KEY_ARROW_DOWN then
                ed:move_down()
            elseif key == terminal.KEY_ARROW_LEFT then
                ed:move_left()
            elseif key == terminal.KEY_ARROW_RIGHT then
                ed:move_right()
            elseif key == terminal.KEY_HOME then
                ed:move_home()
            elseif key == terminal.KEY_END then
                ed:move_end()
            elseif key == terminal.KEY_ENTER then
                ed:insert_newline()
            elseif key == terminal.KEY_BACKSPACE then
                ed:backspace()
            elseif key == terminal.KEY_DELETE then
                ed:delete()
            elseif key == terminal.KEY_CTRL_A then
                ed:move_home()
            elseif key == terminal.KEY_CTRL_E then
                ed:move_end()
            elseif key == terminal.KEY_CTRL_K then
                ed:kill_line()
            elseif key == terminal.KEY_CTRL_U then
                ed:kill_line_start()
            elseif key == terminal.KEY_CTRL_L then
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

        -- Global: q to quit
        if ch == "q" or ch == "Q" then
            if not exec:is_running() then
                loop:stop()
            end
        end
    end

    -- Render function
    loop.render_fn = function()
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
        draw_status(terminal, app_state, regions.status, theme)

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
