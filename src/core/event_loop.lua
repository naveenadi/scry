-- src/core/event_loop.lua — non-blocking event loop
-- Polls terminal, database adapter, SSH/process state, executes bounded work, renders.

local M = {}

-- Create a new event loop.
-- terminal: the terminal module
-- state: the application state
-- execution: the execution engine
function M.new(terminal, state, execution)
    local self = {
        terminal = terminal,
        state = state,
        execution = execution,
        running = true,
        render_fn = nil,  -- set by the app
        key_handler_fn = nil, -- set by the app
    }

    -- Run one tick of the event loop.
    function self:tick()
        -- 1. Poll terminal for events
        local event = self.terminal.poll_event(0) -- non-blocking
        if event then
            self:_handle_event(event)
        end

        -- 2. Poll database adapter (via execution engine)
        if self.execution and self.execution:is_running() then
            self.execution:poll()
        end

        -- 3. Poll export (if active)
        if self.export and self.export:is_running() then
            self.export:poll()
        end

        -- 4. Render
        if self.render_fn then
            self.render_fn()
        end
    end

    -- Handle a terminal event.
    function self:_handle_event(event)
        if event.type == "resize" then
            -- Terminal resized, will re-render on next tick
            return
        end

        if event.type == "key" or event.type == "char" then
            if self.key_handler_fn then
                self.key_handler_fn(event)
            end
        end
    end

    -- Run the main loop.
    function self:run()
        while self.running do
            self:tick()
        end
    end

    -- Stop the loop.
    function self:stop()
        self.running = false
    end

    return self
end

return M
