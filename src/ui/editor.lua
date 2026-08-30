-- src/ui/editor.lua — always-insert SQL editor

local M = {}

-- Create a new editor.
function M.new()
    local self = {
        lines = {""},
        cursor_x = 0,  -- column (0-indexed)
        cursor_y = 0,  -- line (0-indexed)
        scroll_y = 0,  -- vertical scroll offset
    }

    -- Get the full buffer text.
    function self:get_text()
        return table.concat(self.lines, "\n")
    end

    -- Set the buffer text.
    function self:set_text(text)
        self.lines = {}
        for line in (text .. "\n"):gmatch("([^\n]*)\n") do
            table.insert(self.lines, line)
        end
        if #self.lines == 0 then
            self.lines = {""}
        end
        self.cursor_x = 0
        self.cursor_y = 0
        self.scroll_y = 0
    end

    -- Insert a character at the cursor position.
    function self:insert_char(ch)
        local line = self.lines[self.cursor_y + 1]
        local before = line:sub(1, self.cursor_x)
        local after = line:sub(self.cursor_x + 1)
        self.lines[self.cursor_y + 1] = before .. ch .. after
        self.cursor_x = self.cursor_x + #ch
    end

    -- Insert a string at the cursor position.
    function self:insert_text(text)
        for ch in text:gmatch(".") do
            if ch == "\n" then
                self:insert_newline()
            else
                self:insert_char(ch)
            end
        end
    end

    -- Insert a newline.
    function self:insert_newline()
        local line = self.lines[self.cursor_y + 1]
        local before = line:sub(1, self.cursor_x)
        local after = line:sub(self.cursor_x + 1)
        self.lines[self.cursor_y + 1] = before
        table.insert(self.lines, self.cursor_y + 2, after)
        self.cursor_y = self.cursor_y + 1
        self.cursor_x = 0
    end

    -- Delete character before cursor (backspace).
    function self:backspace()
        if self.cursor_x > 0 then
            local line = self.lines[self.cursor_y + 1]
            local before = line:sub(1, self.cursor_x - 1)
            local after = line:sub(self.cursor_x + 1)
            self.lines[self.cursor_y + 1] = before .. after
            self.cursor_x = self.cursor_x - 1
        elseif self.cursor_y > 0 then
            -- Join with previous line
            local prev = self.lines[self.cursor_y]
            local curr = self.lines[self.cursor_y + 1]
            self.cursor_x = #prev
            self.lines[self.cursor_y] = prev .. curr
            table.remove(self.lines, self.cursor_y + 1)
            self.cursor_y = self.cursor_y - 1
        end
    end

    -- Delete character at cursor (delete).
    function self:delete()
        local line = self.lines[self.cursor_y + 1]
        if self.cursor_x < #line then
            local before = line:sub(1, self.cursor_x)
            local after = line:sub(self.cursor_x + 2)
            self.lines[self.cursor_y + 1] = before .. after
        elseif self.cursor_y + 1 < #self.lines then
            -- Join with next line
            self.lines[self.cursor_y + 1] = line .. self.lines[self.cursor_y + 2]
            table.remove(self.lines, self.cursor_y + 2)
        end
    end

    -- Move cursor up.
    function self:move_up()
        if self.cursor_y > 0 then
            self.cursor_y = self.cursor_y - 1
            local line_len = #self.lines[self.cursor_y + 1]
            if self.cursor_x > line_len then
                self.cursor_x = line_len
            end
        end
    end

    -- Move cursor down.
    function self:move_down()
        if self.cursor_y + 1 < #self.lines then
            self.cursor_y = self.cursor_y + 1
            local line_len = #self.lines[self.cursor_y + 1]
            if self.cursor_x > line_len then
                self.cursor_x = line_len
            end
        end
    end

    -- Move cursor left.
    function self:move_left()
        if self.cursor_x > 0 then
            self.cursor_x = self.cursor_x - 1
        elseif self.cursor_y > 0 then
            self.cursor_y = self.cursor_y - 1
            self.cursor_x = #self.lines[self.cursor_y + 1]
        end
    end

    -- Move cursor right.
    function self:move_right()
        local line_len = #self.lines[self.cursor_y + 1]
        if self.cursor_x < line_len then
            self.cursor_x = self.cursor_x + 1
        elseif self.cursor_y + 1 < #self.lines then
            self.cursor_y = self.cursor_y + 1
            self.cursor_x = 0
        end
    end

    -- Move cursor to start of line.
    function self:move_home()
        self.cursor_x = 0
    end

    -- Move cursor to end of line.
    function self:move_end()
        self.cursor_x = #self.lines[self.cursor_y + 1]
    end

    -- Move cursor to start of buffer.
    function self:move_buffer_start()
        self.cursor_x = 0
        self.cursor_y = 0
    end

    -- Move cursor to end of buffer.
    function self:move_buffer_end()
        self.cursor_y = #self.lines - 1
        self.cursor_x = #self.lines[self.cursor_y + 1]
    end

    -- Delete from cursor to end of line.
    function self:kill_line()
        local line = self.lines[self.cursor_y + 1]
        self.lines[self.cursor_y + 1] = line:sub(1, self.cursor_x)
    end

    -- Delete from cursor to start of line.
    function self:kill_line_start()
        local line = self.lines[self.cursor_y + 1]
        self.lines[self.cursor_y + 1] = line:sub(self.cursor_x + 1)
        self.cursor_x = 0
    end

    -- Clear the entire line.
    function self:clear_line()
        self.lines[self.cursor_y + 1] = ""
        self.cursor_x = 0
    end

    return self
end

return M
