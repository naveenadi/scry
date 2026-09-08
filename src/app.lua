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
local adapter_factory = require("src.db.factory")
local platform = require("src.platform")
local grid_mod = require("src.ui.grid")
local history_store = require("src.history.store")

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

    local adapter, adapter_err = adapter_factory.create(connection_config.type)
    if not adapter then
        terminal.shutdown()
        io.stderr:write("error: " .. (adapter_err or "adapter creation failed") .. "\n")
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
        grid_view = grid_mod.new(config.general.default_page_size or 100),
        last_result = nil,
        prepared_grid = nil,
        exec_start_ms = nil,
        result_consumed = true,
        command_mode = false,
        command_buffer = "",
        history_index = 0,
        show_help = false,
        help_lines = nil,  -- nil = use default HELP_LINES
        help_title = nil,
        sidebar_state = { selected = 1, scroll = 0 },
    }
    local history = history_store.new(platform, {
        history_limit = config.query_editor and config.query_editor.history_limit or 1000,
        history_max_entry_bytes = config.query_editor and config.query_editor.history_max_entry_bytes or 100000,
    })
    history:load()

    local function attach_execution(active_exec)
        active_exec.on_history_entry = function(text, outcome)
            history:append(text, outcome or "success")
            ui.history_index = 0
        end
        loop.execution = active_exec
    end
    attach_execution(exec)

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
        config = config,
        read_only = read_only,
        attach_execution = attach_execution,
    }
    loop.key_handler_fn = keys_mod.new(context)

    loop.render_fn = function()
        local active_exec = context.execution
        if not ui.result_consumed
            and (active_exec.state == execution.COMPLETE or active_exec.state == execution.EXECUTION_FAILED)
            and not ui.command_mode then
            ui.last_result = active_exec:get_result()
            grid_mod.reset(ui.grid_view)
            ui.prepared_grid = grid_mod.prepare(ui.last_result, ui.grid_view)
            app_state.row_count = ui.last_result.row_count or 0
            local message = ui.last_result.error or ""
            -- may_need_rollback: BEGIN without COMMIT/ROLLBACK on error
            if active_exec.execution_status == "error"
                and active_exec.buffer_text
                and active_exec.buffer_text ~= ""
            then
                local upper = active_exec.buffer_text:upper()
                if upper:find("%f[%w]BEGIN%f[%W]")
                    and not upper:find("%f[%w]COMMIT%f[%W]")
                    and not upper:find("%f[%w]ROLLBACK%f[%W]")
                then
                    if message ~= "" then message = message .. " — " end
                    message = message .. "transaction may require ROLLBACK — :rollback :reconnect :dismiss"
                end
            end
            app_state.status_message = message
            if ui.exec_start_ms then
                app_state.elapsed_ms = platform.monotonic_ms() - ui.exec_start_ms
                ui.exec_start_ms = nil
            end
            ui.result_consumed = true
        end
        if active_exec.state == execution.RECONNECT_CONFIRM and not ui.command_mode then
            app_state.status_message = "Connection abandoned — :reconnect or :dismiss"
        end
        if ui.command_mode then app_state.status_message = ":" .. ui.command_buffer end
        if ui.grid_view.filter_mode and not ui.command_mode then
            app_state.status_message = "/" .. ui.grid_view.filter_buffer
        end

        ui.prepared_grid = grid_mod.prepare(ui.last_result, ui.grid_view)
        app_state.page_info = grid_mod.page_info(ui.grid_view, ui.prepared_grid)

        terminal.clear()
        local regions = layout.calculate(terminal, config)
        if not regions then draw.too_small(terminal, terminal); return end
        draw.sidebar(terminal, app_state, regions.sidebar, theme, terminal, ui.sidebar_state)
        draw.editor(terminal, editor, regions.editor, theme)
        draw.grid(terminal, ui.prepared_grid, ui.grid_view, regions.grid, theme, app_state.focus == "grid")
        draw.status(terminal, app_state, regions.status, theme, active_exec, ui.command_mode, app_state.focus)
        if ui.grid_view.cell_modal then
            draw.modal(terminal, "Cell value", { ui.grid_view.cell_modal }, regions.grid, theme, terminal)
        elseif ui.show_help then
            local help_title = ui.help_title or "Help"
            local help_lines = ui.help_lines or keys_mod.HELP_LINES
            draw.modal(terminal, help_title, help_lines, regions.editor, theme, terminal)
            ui.help_lines = nil  -- reset after drawing
            ui.help_title = nil
        end
        terminal.present()
    end

    loop:run()
    adapter:close()
    terminal.shutdown()
    return 0
end

return M
