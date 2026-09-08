-- src/ui/keys/command.lua — command-mode handling (:quit, :connect, :reconnect, etc.)

local commands = require("src.ui.commands")
local adapter_factory = require("src.db.factory")
local grid_mod = require("src.ui.grid")

local M = {}

function M.run(ctx, ui, text)
    local command, argument = commands.parse(text)

    local function finish()
        ui.command_mode = false
        ui.command_buffer = ""
    end

    if command == "quit" then
        ctx.loop:stop()

    elseif command == "connect" then
        if argument and argument ~= "" then
            local conn_config = ctx.config.connections[argument]
            if conn_config then
                ctx.adapter:close()
                local new_adapter, factory_err = adapter_factory.create(conn_config.type)
                if not new_adapter then
                    ctx.state.status_message = (factory_err or "adapter creation failed")
                    finish()
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
                    ctx.execution = require("src.core.execution").new(
                        new_adapter, ctx.config, ctx.read_only)
                    ctx.attach_execution(ctx.execution)
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

    elseif command == "rollback" then
        if ctx.execution:is_running() then
            ctx.state.status_message = "Cannot rollback while query is running"
        else
            ui.exec_start_ms = ctx.platform.monotonic_ms()
            ui.result_consumed = false
            ctx.execution:execute("ROLLBACK")
            ctx.state.status_message = "Running ROLLBACK..."
            grid_mod.reset(ui.grid_view)
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

    finish()
end

return M
