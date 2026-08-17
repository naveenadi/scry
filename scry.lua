-- scry.lua — prototype smoke test
-- Proves: LuaJIT + SQLite + termbox2 link and run

local ffi = require("ffi")

-- termbox2 FFI declarations (minimal subset)
ffi.cdef[[
typedef uint32_t uintattr_t;
struct tb_event { uint8_t type; uint8_t mod; uint16_t key; uint32_t ch; int32_t w; int32_t h; int32_t x; int32_t y; };
int tb_init(void);
int tb_shutdown(void);
int tb_width(void);
int tb_height(void);
int tb_clear(void);
int tb_present(void);
int tb_set_cell(int x, int y, uint32_t ch, uintattr_t fg, uintattr_t bg);
int tb_poll_event(struct tb_event *event);
]]

local TB = ffi.load("termbox2")
local TB_DEFAULT = 0
local TB_GREEN   = 1 << 1   -- 0x02
local TB_RED     = 1 << 2   -- 0x04
local TB_BOLD    = 1 << 9   -- 0x200

-- Load SQLite via LuaSQL
local luasql = require("luasql.sqlite3")
local env = luasql.sqlite3()
local conn = env:connect(":memory:")

-- Create test table and insert data
conn:execute("CREATE TABLE demo (id INTEGER PRIMARY KEY, name TEXT, value REAL)")
conn:execute("INSERT INTO demo VALUES (1, 'alpha', 3.14)")
conn:execute("INSERT INTO demo VALUES (2, 'beta', 2.72)")
conn:execute("INSERT INTO demo VALUES (3, 'gamma', 1.62)")

-- Query
local cur = conn:execute("SELECT id, name, value FROM demo ORDER BY id")

-- Init termbox
if TB.tb_init() ~= 0 then
    io.stderr:write("error: tb_init failed\n")
    os.exit(1)
end

local y = 0
local w = TB.tb_width()
local h = TB.tb_height()

-- Header
local header = "scry 0.1.0-prototype — SQLite demo"
for i = 1, #header do
    TB.tb_set_cell(i - 1, y, string.byte(header, i), TB_GREEN + TB_BOLD, TB_DEFAULT)
end
y = y + 2

-- Column headers
local cols = { "ID", "NAME", "VALUE" }
local col_x = { 0, 6, 20 }
for ci, col in ipairs(cols) do
    for i = 1, #col do
        TB.tb_set_cell(col_x[ci] + i - 1, y, string.byte(col, i), TB_BOLD, TB_DEFAULT)
    end
end
y = y + 1

-- Rows
local row = cur:fetch({}, "a")
while row do
    local line = string.format("%-5s %-12s %s", row.id, row.name, row.value)
    for i = 1, #line do
        TB.tb_set_cell(i - 1, y, string.byte(line, i), TB_DEFAULT, TB_DEFAULT)
    end
    y = y + 1
    row = cur:fetch({}, "a")
end
cur:close()

-- Footer
y = y + 2
local footer = "Press any key to exit..."
for i = 1, #footer do
    TB.tb_set_cell(i - 1, y, string.byte(footer, i), TB_DEFAULT, TB_DEFAULT)
end

TB.tb_present()

-- Wait for keypress
local ev = ffi.new("struct tb_event")
TB.tb_poll_event(ev)

-- Cleanup
TB.tb_shutdown()
conn:close()
env:close()

print("prototype complete")
