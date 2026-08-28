-- src/app.lua — application wiring

local cli = require("src.cli")
local config_loader = require("src.config.loader")
local terminal = require("src.tui.terminal")
local layout = require("src.ui.layout")
local editor_mod = require("src.ui.editor")
local draw = require("src.ui.draw")
local keys_mod = require("src.ui.keys")
local event_loop = require("src.core.event_loop")
local execution = require("src.core.execution")
local sqlite = require("src.db.sqlite")
local platform = require("src.platform")

local M = {}

local themes = {
    dark = {
        bg = terminal.DEFAULT, fg = terminal.DEFAULT,
        keyword = terminal.CYAN + terminal.BOLD,
        string_color = terminal.GREEN, comment = terminal.YELLOW + terminal.DIM,
        number = terminal.MAGENTA, status_bg = terminal.BLACK,
        status_fg = terminal.WHITE, sidebar_fg = terminal.DEFAULT,
        sidebar_selected = terminal.BLACK + terminal.REVERSE,
        error_fg = terminal.RED + terminal.BOLD, border = terminal.WHITE,
        cursor = terminal.DEFAULT,
    },
    light = {
        bg = terminal.DEFAULT, fg = terminal.DEFAULT,
        keyword = terminal.BLUE + terminal.BOLD,
        string_color = terminal.GREEN, comment = terminal.YELLOW + terminal.DIM,
        number = terminal.MAGENTA, status_bg = terminal.WHITE,
        status_fg = terminal.BLACK, sidebar_fg = terminal.DEFAULT,
        sidebar_selected = terminal.WHITE + terminal.REVERSE,
        error_fg = terminal.RED + terminal.BOLD, border = terminal.BLACK,
        cursor = terminal.DEFAULT,
    },
}

function M.run(args)
    local options = cli.parse_args(args or {})
    if options.version then print(cli.version_text()); return 0 end
    if options.help then print(cli.help_text()); return 0 end

    local config = config_loader.load()
    local connection_name = options.connection
    local connection_config
    if connection_name then
        connection_config = config.connections[connection_name]
        if not connection_config then
            io.stderr:write("error: connection '" .. connection_name .. "' not found in config\n")
            return 1
        end
    else
        for name, conn in pairs(config.connections or {}) do
            connection_name, connection_config = name, conn
            break
        end
    end
    if not connection_config then
        io.stderr:write("error: no connections configured\n")
        return 1
    end

    if not terminal.init() then
        io.stderr:write("error: failed to initialize terminal\n")
        return 1
    end
    if terminal.width() < 80 or terminal.height() < 24 then
        draw.too_small(terminal, terminal)
        terminal.shutdown()
        return 1
    end

    local adapter
    if connection_config.type == "sqlite" then
        adapter = sqlite.new()
    else
        terminal.shutdown()
        io.stderr:write("error: unsupported database type: " .. (connection_config.type or "nil") .. "\n")
        return 1
    end
    local read_only = options.read_only or connection_config.read_only == true

    local ok, err = adapter:connect(connection_config)
    if not ok then
        terminal.shutdown()
        io.stderr:write("error: " .. (err or "connection failed") .. "\n")
        return 1
    end

    local app_state = {
        connection_name = connection_name,
        connection_status = "connected",
        tables = adapter:list_tables(),
        focus = "editor",
        status_message = "",
        elapsed_ms = 0,
        row_count = 0,
    }
    local editor = editor_mod.new()
    local exec = execution.new(adapter, config, read_only)
    local loop = event_loop.new(terminal, app_state, exec)
    local theme = themes[config.general.theme] or themes.dark
    local ui = {
        grid_page = 1,
        grid_page_size = config.general.default_page_size or 100,
        last_result = nil,
        exec_start_ms = nil,
        result_consumed = true,
        command_mode = false,
        command_buffer = "",
        history_index = 0,
    }
    local history = {}

    exec.on_history_entry = function(text)
        table.insert(history, 1, text)
        if #history > (config.query_editor.history_limit or 1000) then table.remove(history) end
        ui.history_index = 0
    end

    local context = {
        terminal = terminal,
        platform = platform,
        loop = loop,
        state = app_state,
        ui = ui,
        editor = editor,
        execution = exec,
        adapter = adapter,
        connection_config = connection_config,
        history = history,
    }
    loop.key_handler_fn = keys_mod.new(context)

    loop.render_fn = function()
        if not ui.result_consumed
            and (exec.state == execution.COMPLETE or exec.state == execution.EXECUTION_FAILED)
            and not ui.command_mode then
            ui.last_result = exec:get_result()
            app_state.row_count = ui.last_result.row_count or 0
            app_state.status_message = ui.last_result.error or ""
            if ui.exec_start_ms then
                app_state.elapsed_ms = platform.monotonic_ms() - ui.exec_start_ms
                ui.exec_start_ms = nil
            end
            ui.result_consumed = true
        end
        if exec.state == execution.RECONNECT_CONFIRM and not ui.command_mode then
            app_state.status_message = "Connection abandoned — :reconnect or :dismiss"
        end
        if ui.command_mode then app_state.status_message = ":" .. ui.command_buffer end

        terminal.clear()
        local regions = layout.calculate(terminal, config)
        if not regions then draw.too_small(terminal, terminal); return end
        draw.sidebar(terminal, app_state, regions.sidebar, theme, terminal)
        draw.editor(terminal, editor, regions.editor, theme)
        draw.grid(terminal, ui.last_result, regions.grid, theme, ui.grid_page, ui.grid_page_size)
        draw.status(terminal, app_state, regions.status, theme, exec, ui.command_mode)
        terminal.present()
    end

    loop:run()
    adapter:close()
    terminal.shutdown()
    return 0
end

return M
