-- src/tui/terminal.lua — thin FFI wrapper over termbox2
-- The rest of the app never touches the terminal backend directly.

local ffi = require("ffi")

ffi.cdef[[
typedef uint32_t uintattr_t;

struct tb_event {
    uint8_t type;
    uint8_t mod;
    uint16_t key;
    uint32_t ch;
    int32_t w;
    int32_t h;
    int32_t x;
    int32_t y;
};

int tb_init(void);
int tb_shutdown(void);
int tb_width(void);
int tb_height(void);
int tb_clear(void);
int tb_present(void);
int tb_set_cell(int x, int y, uint32_t ch, uintattr_t fg, uintattr_t bg);
int tb_set_cursor(int cx, int cy);
int tb_hide_cursor(void);
int tb_poll_event(struct tb_event *event);
int tb_peek_event(struct tb_event *event, int timeout);
void tb_set_input_mode(int mode);
void tb_set_output_mode(int mode);
]]

local TB = ffi.load("termbox2")

-- Event types
local TB_EVENT_KEY    = 1
local TB_EVENT_RESIZE = 2
local TB_EVENT_MOUSE  = 3

-- Key constants
local TB_KEY_F1          = 0xFFFF - 0
local TB_KEY_F2          = 0xFFFF - 1
local TB_KEY_F3          = 0xFFFF - 2
local TB_KEY_F4          = 0xFFFF - 3
local TB_KEY_F5          = 0xFFFF - 4
local TB_KEY_F6          = 0xFFFF - 5
local TB_KEY_F7          = 0xFFFF - 6
local TB_KEY_F8          = 0xFFFF - 7
local TB_KEY_F9          = 0xFFFF - 8
local TB_KEY_F10         = 0xFFFF - 9
local TB_KEY_F11         = 0xFFFF - 10
local TB_KEY_F12         = 0xFFFF - 11
local TB_KEY_INSERT      = 0xFFFF - 12
local TB_KEY_DELETE       = 0xFFFF - 13
local TB_KEY_HOME         = 0xFFFF - 14
local TB_KEY_END          = 0xFFFF - 15
local TB_KEY_PGUP         = 0xFFFF - 16
local TB_KEY_PGDN         = 0xFFFF - 17
local TB_KEY_ARROW_UP     = 0xFFFF - 18
local TB_KEY_ARROW_DOWN   = 0xFFFF - 19
local TB_KEY_ARROW_LEFT   = 0xFFFF - 20
local TB_KEY_ARROW_RIGHT  = 0xFFFF - 21
local TB_KEY_MOUSE_LEFT   = 0xFFFF - 22
local TB_KEY_MOUSE_RIGHT  = 0xFFFF - 23
local TB_KEY_MOUSE_MIDDLE = 0xFFFF - 24
local TB_KEY_MOUSE_RELEASE = 0xFFFF - 25
local TB_KEY_MOUSE_WHEEL_UP = 0xFFFF - 26
local TB_KEY_MOUSE_WHEEL_DOWN = 0xFFFF - 27

local TB_KEY_CTRL_A = 0x01
local TB_KEY_CTRL_B = 0x02
local TB_KEY_CTRL_C = 0x03
local TB_KEY_CTRL_D = 0x04
local TB_KEY_CTRL_E = 0x05
local TB_KEY_CTRL_F = 0x06
local TB_KEY_CTRL_K = 0x0B
local TB_KEY_CTRL_L = 0x0C
local TB_KEY_CTRL_N = 0x0E
local TB_KEY_CTRL_P = 0x10
local TB_KEY_CTRL_R = 0x12
local TB_KEY_CTRL_U = 0x15
local TB_KEY_TAB     = 0x09
local TB_KEY_ENTER   = 0x0D
local TB_KEY_ESC     = 0x1B
local TB_KEY_BACKSPACE = 0x08
local TB_KEY_SPACE   = 0x20

-- Modifier constants
local TB_MOD_ALT = 0x01

-- Colors
local TB_DEFAULT    = 0x00
local TB_BLACK      = 0x01
local TB_RED        = 0x02
local TB_GREEN      = 0x03
local TB_YELLOW     = 0x04
local TB_BLUE       = 0x05
local TB_MAGENTA    = 0x06
local TB_CYAN       = 0x07
local TB_WHITE      = 0x08

-- Attributes (bits 9-15)
local TB_BOLD      = 1 << 9
local TB_UNDERLINE = 1 << 10
local TB_REVERSE   = 1 << 11
local TB_ITALIC    = 1 << 12
local TB_BLINK     = 1 << 13
local TB_DIM       = 1 << 14

-- Input modes
local TB_INPUT_CURRENT = 0
local TB_INPUT_ESC     = 1
local TB_INPUT_ALT     = 2
local TB_INPUT_MOUSE   = 4

-- Output modes
local TB_OUTPUT_CURRENT   = 0
local TB_OUTPUT_NORMAL    = 1
local TB_OUTPUT_256       = 2
local TB_OUTPUT_216       = 3
local TB_OUTPUT_GRAYSCALE = 4
local TB_OUTPUT_TRUECOLOR = 5

local M = {}

-- Constants
M.EVENT_KEY    = TB_EVENT_KEY
M.EVENT_RESIZE = TB_EVENT_RESIZE
M.EVENT_MOUSE  = TB_EVENT_MOUSE

M.KEY_F1          = TB_KEY_F1
M.KEY_F2          = TB_KEY_F2
M.KEY_F3          = TB_KEY_F3
M.KEY_F4          = TB_KEY_F4
M.KEY_F5          = TB_KEY_F5
M.KEY_F6          = TB_KEY_F6
M.KEY_F7          = TB_KEY_F7
M.KEY_F8          = TB_KEY_F8
M.KEY_F9          = TB_KEY_F9
M.KEY_F10         = TB_KEY_F10
M.KEY_F11         = TB_KEY_F11
M.KEY_F12         = TB_KEY_F12
M.KEY_INSERT      = TB_KEY_INSERT
M.KEY_DELETE       = TB_KEY_DELETE
M.KEY_HOME         = TB_KEY_HOME
M.KEY_END          = TB_KEY_END
M.KEY_PGUP         = TB_KEY_PGUP
M.KEY_PGDN         = TB_KEY_PGDN
M.KEY_ARROW_UP     = TB_KEY_ARROW_UP
M.KEY_ARROW_DOWN   = TB_KEY_ARROW_DOWN
M.KEY_ARROW_LEFT   = TB_KEY_ARROW_LEFT
M.KEY_ARROW_RIGHT  = TB_KEY_ARROW_RIGHT
M.KEY_MOUSE_LEFT   = TB_KEY_MOUSE_LEFT
M.KEY_MOUSE_RIGHT  = TB_KEY_MOUSE_RIGHT
M.KEY_MOUSE_MIDDLE = TB_KEY_MOUSE_MIDDLE
M.KEY_MOUSE_RELEASE = TB_KEY_MOUSE_RELEASE
M.KEY_MOUSE_WHEEL_UP = TB_KEY_MOUSE_WHEEL_UP
M.KEY_MOUSE_WHEEL_DOWN = TB_KEY_MOUSE_WHEEL_DOWN

M.KEY_CTRL_A = TB_KEY_CTRL_A
M.KEY_CTRL_B = TB_KEY_CTRL_B
M.KEY_CTRL_C = TB_KEY_CTRL_C
M.KEY_CTRL_D = TB_KEY_CTRL_D
M.KEY_CTRL_E = TB_KEY_CTRL_E
M.KEY_CTRL_F = TB_KEY_CTRL_F
M.KEY_CTRL_K = TB_KEY_CTRL_K
M.KEY_CTRL_L = TB_KEY_CTRL_L
M.KEY_CTRL_N = TB_KEY_CTRL_N
M.KEY_CTRL_P = TB_KEY_CTRL_P
M.KEY_CTRL_R = TB_KEY_CTRL_R
M.KEY_CTRL_U = TB_KEY_CTRL_U
M.KEY_TAB     = TB_KEY_TAB
M.KEY_ENTER   = TB_KEY_ENTER
M.KEY_ESC     = TB_KEY_ESC
M.KEY_BACKSPACE = TB_KEY_BACKSPACE
M.KEY_SPACE   = TB_KEY_SPACE

M.MOD_ALT = TB_MOD_ALT

M.DEFAULT  = TB_DEFAULT
M.BLACK    = TB_BLACK
M.RED      = TB_RED
M.GREEN    = TB_GREEN
M.YELLOW   = TB_YELLOW
M.BLUE     = TB_BLUE
M.MAGENTA  = TB_MAGENTA
M.CYAN     = TB_CYAN
M.WHITE    = TB_WHITE

M.BOLD      = TB_BOLD
M.UNDERLINE = TB_UNDERLINE
M.REVERSE   = TB_REVERSE
M.ITALIC    = TB_ITALIC
M.BLINK     = TB_BLINK
M.DIM       = TB_DIM

-- Initialize the terminal. Returns true on success.
function M.init()
    return TB.tb_init() == 0
end

-- Shutdown the terminal.
function M.shutdown()
    TB.tb_shutdown()
end

-- Get terminal width.
function M.width()
    return TB.tb_width()
end

-- Get terminal height.
function M.height()
    return TB.tb_height()
end

-- Clear the internal buffer.
function M.clear()
    TB.tb_clear()
end

-- Sync the internal buffer with the terminal.
function M.present()
    TB.tb_present()
end

-- Set a cell at (x, y) with character ch, foreground fg, background bg.
-- ch is a Unicode codepoint (number).
function M.cell(x, y, ch, fg, bg)
    TB.tb_set_cell(x, y, ch, fg, bg)
end

-- Draw text starting at (x, y). Returns the x position after the last character.
function M.text(x, y, str, fg, bg)
    fg = fg or TB_DEFAULT
    bg = bg or TB_DEFAULT
    -- Iterate UTF-8 codepoints
    local i = 1
    local col = x
    while i <= #str do
        local c = str:byte(i)
        local cp, bytes
        if c < 0x80 then
            cp = c
            bytes = 1
        elseif c < 0xE0 then
            cp = (c - 0xC0) * 64 + (str:byte(i + 1) - 0x80)
            bytes = 2
        elseif c < 0xF0 then
            cp = (c - 0xE0) * 4096 + (str:byte(i + 1) - 0x80) * 64 + (str:byte(i + 2) - 0x80)
            bytes = 3
        else
            cp = (c - 0xF0) * 262144 + (str:byte(i + 1) - 0x80) * 4096 + (str:byte(i + 2) - 0x80) * 64 + (str:byte(i + 3) - 0x80)
            bytes = 4
        end
        TB.tb_set_cell(col, y, cp, fg, bg)
        col = col + 1
        i = i + bytes
    end
    return col
end

-- Set cursor position.
function M.set_cursor(x, y)
    TB.tb_set_cursor(x, y)
end

-- Hide the cursor.
function M.hide_cursor()
    TB.tb_hide_cursor()
end

-- Poll for an event. Returns a table with event info, or nil if no event.
-- timeout_ms: -1 = block forever, 0 = non-blocking, >0 = wait up to N ms
function M.poll_event(timeout_ms)
    local ev = ffi.new("struct tb_event")
    local ret
    if timeout_ms then
        ret = TB.tb_peek_event(ev, timeout_ms)
    else
        ret = TB.tb_poll_event(ev)
    end
    if ret < 0 then
        return nil
    end
    local event = {
        type = ev.type,
        mod = ev.mod,
        key = ev.key,
        ch = ev.ch,
        w = ev.w,
        h = ev.h,
        x = ev.x,
        y = ev.y,
    }
    -- Normalize: if key == 0, it's a character event
    if event.key == 0 and event.ch ~= 0 then
        event.type = "char"
        event.char = utf8.char(event.ch)
    elseif event.type == TB_EVENT_KEY then
        event.type = "key"
    elseif event.type == TB_EVENT_RESIZE then
        event.type = "resize"
    elseif event.type == TB_EVENT_MOUSE then
        event.type = "mouse"
    end
    return event
end

-- Enable mouse input.
function M.enable_mouse()
    TB.tb_set_input_mode(TB_INPUT_ESC + TB_INPUT_MOUSE)
end

-- Disable mouse input (ESC mode only).
function M.disable_mouse()
    TB.tb_set_input_mode(TB_INPUT_ESC)
end

-- Set truecolor output mode.
function M.set_truecolor()
    TB.tb_set_output_mode(TB_OUTPUT_TRUECOLOR)
end

return M
