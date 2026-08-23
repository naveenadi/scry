# Research: LuaJIT FFI Bindings for termbox2

Sources: `vendor/termbox2.h` (v2.5.0), [termbox2 README](https://github.com/termbox/termbox2), [LuaJIT FFI docs](https://luajit.org/ext_ffi.html), [LuaJIT FFI API](https://luajit.org/ext_ffi_api.html), [LuaJIT FFI semantics](https://luajit.org/ext_ffi_semantics.html), termbox2 `Makefile`, `demo/example.py`.

---

## 1. Core termbox2 Functions for a TUI

The minimal set for a working TUI loop:

```c
// Lifecycle
int tb_init(void);                // init library, open /dev/tty
int tb_init_file(const char *path); // init with custom tty path
int tb_shutdown(void);            // restore terminal state

// Screen geometry
int tb_width(void);               // terminal width in columns
int tb_height(void);              // terminal height in rows

// Drawing
int tb_clear(void);               // clear back buffer
int tb_present(void);             // flush back buffer to terminal
int tb_set_cell(int x, int y, uint32_t ch, uintattr_t fg, uintattr_t bg);
int tb_print(int x, int y, uintattr_t fg, uintattr_t bg, const char *str);
int tb_printf(int x, int y, uintattr_t fg, uintattr_t bg, const char *fmt, ...);

// Cursor
int tb_set_cursor(int cx, int cy);
int tb_hide_cursor(void);

// Events
int tb_poll_event(struct tb_event *event);           // blocking wait
int tb_peek_event(struct tb_event *event, int timeout_ms); // timed wait

// Configuration
int tb_set_input_mode(int mode);   // TB_INPUT_ESC, TB_INPUT_ALT, TB_INPUT_MOUSE
int tb_set_output_mode(int mode);  // TB_OUTPUT_NORMAL, TB_OUTPUT_256, TB_OUTPUT_TRUECOLOR
int tb_set_clear_attrs(uintattr_t fg, uintattr_t bg);

// Utility
const char *tb_version(void);
int tb_has_truecolor(void);
int tb_has_egc(void);
int tb_attr_width(void);
```

**Note on `uintattr_t`:** Width depends on compile-time `TB_OPT_ATTR_W` (16, 32, or 64 bits). Default is 16. For truecolor support, must be >= 32. The shared library build (`make lib`) forces `TB_OPT_ATTR_W=64` via `TB_LIB_OPTS`.

---

## 2. Event Handling: `tb_event` Struct and Event Types

### Struct layout (from `termbox2.h`)

```c
struct tb_event {
    uint8_t type;  // one of TB_EVENT_KEY (1), TB_EVENT_RESIZE (2), TB_EVENT_MOUSE (3)
    uint8_t mod;   // bitwise OR of TB_MOD_ALT (1), TB_MOD_CTRL (2), TB_MOD_SHIFT (4), TB_MOD_MOTION (8)
    uint16_t key;  // one of TB_KEY_* constants (0 for printable chars)
    uint32_t ch;   // Unicode codepoint (0 for special keys)
    int32_t w;     // new width on resize events
    int32_t h;     // new height on resize events
    int32_t x;     // mouse x on mouse events
    int32_t y;     // mouse y on mouse events
};
```

### Event dispatch pattern

For `TB_EVENT_KEY`: either `key` (non-zero for special keys like arrows, F-keys) or `ch` (non-zero for printable Unicode codepoints) -- never both. Check `mod` for Alt/Ctrl/Shift.

For `TB_EVENT_RESIZE`: `w` and `h` hold the new terminal dimensions.

For `TB_EVENT_MOUSE`: `key` is one of `TB_KEY_MOUSE_LEFT`, `TB_KEY_MOUSE_RIGHT`, `TB_KEY_MOUSE_MIDDLE`, `TB_KEY_MOUSE_RELEASE`, `TB_KEY_MOUSE_WHEEL_UP`, `TB_KEY_MOUSE_WHEEL_DOWN`. `x` and `y` hold the coordinates.

### Key constants

Special keys use the range `0xffff - N` (computed via `tb_key_i(N)`):

```c
#define TB_KEY_F1               (0xffff - 0)
#define TB_KEY_F2               (0xffff - 1)
// ... through F12
#define TB_KEY_INSERT           (0xffff - 12)
#define TB_KEY_DELETE           (0xffff - 13)
#define TB_KEY_HOME             (0xffff - 14)
#define TB_KEY_END              (0xffff - 15)
#define TB_KEY_PGUP             (0xffff - 16)
#define TB_KEY_PGDN             (0xffff - 17)
#define TB_KEY_ARROW_UP         (0xffff - 18)
#define TB_KEY_ARROW_DOWN       (0xffff - 19)
#define TB_KEY_ARROW_LEFT       (0xffff - 20)
#define TB_KEY_ARROW_RIGHT      (0xffff - 21)
#define TB_KEY_BACK_TAB         (0xffff - 22)
#define TB_KEY_MOUSE_LEFT       (0xffff - 23)
#define TB_KEY_MOUSE_RIGHT      (0xffff - 24)
#define TB_KEY_MOUSE_MIDDLE     (0xffff - 25)
#define TB_KEY_MOUSE_RELEASE    (0xffff - 26)
#define TB_KEY_MOUSE_WHEEL_UP   (0xffff - 27)
#define TB_KEY_MOUSE_WHEEL_DOWN (0xffff - 28)
```

ASCII keys: `TB_KEY_CTRL_A` (0x01) through `TB_KEY_CTRL_Z` (0x1a), `TB_KEY_ESC` (0x1b), `TB_KEY_SPACE` (0x20), `TB_KEY_BACKSPACE` (0x08), `TB_KEY_TAB` (0x09), `TB_KEY_ENTER` (0x0d).

---

## 3. Representing Constants in LuaJIT FFI

LuaJIT's `ffi.cdef` does **not** run a C preprocessor. `#define` macros are not parsed. Constants must be declared as Lua values or as C enums/static consts.

### Recommended approach: Lua table of constants

```lua
local tb = {
    -- Event types
    EVENT_KEY       = 1,
    EVENT_RESIZE    = 2,
    EVENT_MOUSE     = 3,

    -- Modifiers (bitwise)
    MOD_ALT         = 1,
    MOD_CTRL        = 2,
    MOD_SHIFT       = 4,
    MOD_MOTION      = 8,

    -- Colors
    DEFAULT         = 0x0000,
    BLACK           = 0x0001,
    RED             = 0x0002,
    GREEN           = 0x0003,
    YELLOW          = 0x0004,
    BLUE            = 0x0005,
    MAGENTA         = 0x0006,
    CYAN            = 0x0007,
    WHITE           = 0x0008,

    -- Attributes (16-bit mode)
    BOLD            = 0x0100,
    UNDERLINE       = 0x0200,
    REVERSE         = 0x0400,
    ITALIC          = 0x0800,
    BLINK           = 0x1000,
    HI_BLACK        = 0x2000,
    BRIGHT          = 0x4000,
    DIM             = 0x8000,

    -- Input modes
    INPUT_CURRENT   = 0,
    INPUT_ESC       = 1,
    INPUT_ALT       = 2,
    INPUT_MOUSE     = 4,

    -- Output modes
    OUTPUT_CURRENT  = 0,
    OUTPUT_NORMAL   = 1,
    OUTPUT_256      = 2,
    OUTPUT_216      = 3,
    OUTPUT_GRAYSCALE = 4,
    OUTPUT_TRUECOLOR = 5,

    -- Return codes
    OK              = 0,
    ERR             = -1,
    ERR_NO_EVENT    = -6,
    ERR_NOT_INIT    = -8,

    -- Special keys (computed as 0xffff - N)
    KEY_ESC         = 0x1b,
    KEY_ENTER       = 0x0d,
    KEY_BACKSPACE   = 0x08,
    KEY_TAB         = 0x09,
    KEY_SPACE       = 0x20,
    KEY_F1          = 0xffff - 0,
    KEY_F2          = 0xffff - 1,
    KEY_F3          = 0xffff - 2,
    KEY_F4          = 0xffff - 3,
    KEY_F5          = 0xffff - 4,
    KEY_F6          = 0xffff - 5,
    KEY_F7          = 0xffff - 6,
    KEY_F8          = 0xffff - 7,
    KEY_F9          = 0xffff - 8,
    KEY_F10         = 0xffff - 9,
    KEY_F11         = 0xffff - 10,
    KEY_F12         = 0xffff - 11,
    KEY_INSERT      = 0xffff - 12,
    KEY_DELETE      = 0xffff - 13,
    KEY_HOME        = 0xffff - 14,
    KEY_END         = 0xffff - 15,
    KEY_PGUP        = 0xffff - 16,
    KEY_PGDN        = 0xffff - 17,
    KEY_ARROW_UP    = 0xffff - 18,
    KEY_ARROW_DOWN  = 0xffff - 19,
    KEY_ARROW_LEFT  = 0xffff - 20,
    KEY_ARROW_RIGHT = 0xffff - 21,
    KEY_BACK_TAB    = 0xffff - 22,
    KEY_MOUSE_LEFT  = 0xffff - 23,
    KEY_MOUSE_RIGHT = 0xffff - 24,
    KEY_MOUSE_MIDDLE = 0xffff - 25,
    KEY_MOUSE_RELEASE = 0xffff - 26,
    KEY_MOUSE_WHEEL_UP = 0xffff - 27,
    KEY_MOUSE_WHEEL_DOWN = 0xffff - 28,
}
```

### Alternative: C enums in ffi.cdef

```lua
ffi.cdef[[
enum {
    TB_EVENT_KEY = 1,
    TB_EVENT_RESIZE = 2,
    TB_EVENT_MOUSE = 3,
    TB_MOD_ALT = 1,
    TB_MOD_CTRL = 2,
    TB_MOD_SHIFT = 4,
    // ...
};
]]
```

This works but pollutes the C namespace and doesn't scale well for the full constant set. The Lua table approach is cleaner and allows namespacing (`tb.BOLD`).

### Attribute width consideration

The attribute constants differ based on `TB_OPT_ATTR_W`. With the default 16-bit mode, `TB_BOLD = 0x0100`. With 32/64-bit mode, `TB_BOLD = 0x01000000`. The shared library build uses 64-bit. **Must match the library's compile-time setting.**

---

## 4. Building termbox2 as a Shared Library

termbox2 is a single-header library. Two approaches:

### Option A: Use the Makefile (recommended)

```bash
cd vendor/termbox2  # or wherever termbox2.h lives

# Shared library (auto-detects macOS .dylib vs Linux .so)
make libtermbox2.so

# Or explicitly:
make lib
# Produces: libtermbox2.so (or libtermbox2.dylib on macOS)
#           libtermbox2.a
#           termbox2.h.lib (header with TB_LIB_OPTS baked in)
```

The Makefile's `lib` target:
1. Compiles `termbox2.h` with `-DTB_IMPL -DTB_LIB_OPTS -fPIC` into `termbox2.o`
2. Links into a shared library with proper soname/install_name
3. Generates `termbox2.h.lib` which has `TB_LIB_OPTS` enabled (ensures `TB_OPT_ATTR_W=64` and `TB_OPT_EGC` are consistent between library and consumer)

### Option B: Manual compilation

```bash
# Compile object
cc -std=c99 -DTB_IMPL -DTB_LIB_OPTS -fPIC -xc -c termbox2.h -o termbox2.o

# macOS: shared library
cc -shared -Wl,-install_name,libtermbox2.2.dylib termbox2.o -o libtermbox2.2.0.0
ln -sf libtermbox2.2.0.0 libtermbox2.2.dylib
ln -sf libtermbox2.2.0.0 libtermbox2.dylib

# Linux: shared library
cc -shared -Wl,-soname,libtermbox2.so.2 termbox2.o -o libtermbox2.so.2.0.0
ln -sf libtermbox2.so.2.0.0 libtermbox2.so.2
ln -sf libtermbox2.so.2.0.0 libtermbox2.so
```

### Option C: Compile into the host executable

If embedding LuaJIT in a C host, compile termbox2 directly into the host:

```c
// In exactly one .c file:
#define TB_IMPL
#include "termbox2.h"
```

Then expose `tb_*` symbols. LuaJIT FFI can access them via `ffi.C` (the default namespace) on POSIX, or via `ffi.load` on the executable/dll.

### Key compile flags

| Flag | Purpose |
|------|---------|
| `-DTB_IMPL` | Include the implementation (not just declarations) |
| `-DTB_LIB_OPTS` | Force consistent compile options for shared lib usage |
| `-fPIC` | Position-independent code (required for shared libs) |
| `-xc` | Treat input as C (needed when compiling a `.h` file) |

---

## 5. LuaJIT FFI: Loading and Calling C Functions

### Basic pattern

```lua
local ffi = require("ffi")

-- 1. Declare C types and functions (no #define, no #include)
ffi.cdef[[
typedef uint16_t uintattr_t;  // must match library's TB_OPT_ATTR_W

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
int tb_print(int x, int y, uintattr_t fg, uintattr_t bg, const char *str);
int tb_poll_event(struct tb_event *event);
int tb_peek_event(struct tb_event *event, int timeout_ms);
int tb_set_input_mode(int mode);
int tb_set_output_mode(int mode);
int tb_hide_cursor(void);
int tb_set_cursor(int cx, int cy);
const char *tb_version(void);
]]

-- 2. Load the shared library
local lib = ffi.load("termbox2")  -- finds libtermbox2.so / libtermbox2.dylib

-- 3. Call functions
lib.tb_init()
local w = lib.tb_width()
local h = lib.tb_height()
lib.tb_clear()
lib.tb_set_cell(0, 0, string.byte("H"), 0x02 | 0x0100, 0x00)
lib.tb_present()

-- 4. Poll events
local ev = ffi.new("struct tb_event")
lib.tb_poll_event(ev)
print("event type:", ev.type, "key:", ev.key, "ch:", ev.ch)

lib.tb_shutdown()
```

### `ffi.load` search behavior

| Platform | `ffi.load("termbox2")` looks for |
|----------|----------------------------------|
| Linux | `libtermbox2.so` in `LD_LIBRARY_PATH`, `/usr/lib`, `/usr/local/lib`, etc. |
| macOS | `libtermbox2.dylib` in `DYLD_LIBRARY_PATH`, `/usr/lib`, `/usr/local/lib`, etc. |
| Windows | `termbox2.dll` in `PATH`, system directories |

You can pass an absolute or relative path: `ffi.load("/path/to/libtermbox2.dylib")`.

### `ffi.C` vs `ffi.load`

- `ffi.C` -- accesses symbols from the default C namespace (libc, plus any symbols exported from the host executable on POSIX). Use this when termbox2 is compiled into the host binary.
- `ffi.load("termbox2")` -- loads a separate shared library. Use this when termbox2 is a `.so`/`.dylib`/`.dll`.

### Allocating `tb_event`

```lua
-- Stack-allocated (GC-managed, zero-initialized)
local ev = ffi.new("struct tb_event")

-- Pass pointer to poll function (ffi automatically takes address of struct cdata)
lib.tb_poll_event(ev)

-- Access fields
if ev.type == 1 then  -- TB_EVENT_KEY
    if ev.ch ~= 0 then
        -- printable character
    elseif ev.key ~= 0 then
        -- special key
    end
end
```

### String handling

Lua strings auto-convert to `const char *` for function arguments:

```lua
lib.tb_print(0, 0, 0x03, 0x00, "hello")  -- works directly
```

C strings returned by functions need `ffi.string()` to convert:

```lua
local ver = ffi.string(lib.tb_version())
```

### `uintattr_t` width must match

The `uintattr_t` typedef in `ffi.cdef` must match the library's compile-time width. The shared library build (`make lib`) uses 64-bit. If using the default 16-bit, change the typedef:

```lua
-- For default 16-bit build:
typedef uint16_t uintattr_t;

-- For shared lib build (TB_LIB_OPTS, 64-bit):
typedef uint64_t uintattr_t;
```

Attribute constant values also differ (see section 3).

---

## 6. Cross-Platform Differences

### Library naming

| Platform | Shared lib | ffi.load name | Notes |
|----------|-----------|---------------|-------|
| Linux | `libtermbox2.so` (symlink to `libtermbox2.so.2.0.0`) | `ffi.load("termbox2")` | `LD_LIBRARY_PATH` or install to `/usr/local/lib` |
| macOS | `libtermbox2.dylib` (symlink to `libtermbox2.2.0.0.dylib`) | `ffi.load("termbox2")` | `DYLD_LIBRARY_PATH` restricted by SIP; prefer absolute path or install to `/usr/local/lib` |
| Windows | `termbox2.dll` | `ffi.load("termbox2")` | `PATH` or same directory as executable |

### macOS SIP caveat

macOS System Integrity Protection (SIP) strips `DYLD_LIBRARY_PATH` from child processes of system binaries. Solutions:
- Install the `.dylib` to `/usr/local/lib` (standard)
- Use an absolute path in `ffi.load`
- Compile termbox2 into the host executable and use `ffi.C`

### Windows notes

- termbox2 Windows support is **not merged** (PR #123 open). The header currently uses POSIX APIs (`termios`, `select`, `ioctl`).
- If/when Windows lands, the shared lib will be `termbox2.dll`. LuaJIT on Windows auto-appends `.dll`.
- For now, a separate Win32 Console backend implementing the same `tb_*` API surface is the practical path.

### Platform detection in Lua

```lua
local lib_name
if ffi.os == "OSX" then
    lib_name = "termbox2"  -- finds libtermbox2.dylib
elseif ffi.os == "Linux" then
    lib_name = "termbox2"  -- finds libtermbox2.so
elseif ffi.os == "Windows" then
    lib_name = "termbox2"  -- finds termbox2.dll
end
local lib = ffi.load(lib_name)
```

Or with an absolute path relative to the script:

```lua
local script_dir = debug.getinfo(1, "S").source:match("@?(.*/)")
local lib = ffi.load(script_dir .. "../lib/libtermbox2")
```

---

## 7. Complete Minimal Example

```lua
#!/usr/bin/env luajit
local ffi = require("ffi")

ffi.cdef[[
typedef uint64_t uintattr_t;

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
int tb_print(int x, int y, uintattr_t fg, uintattr_t bg, const char *str);
int tb_poll_event(struct tb_event *event);
int tb_set_input_mode(int mode);
int tb_hide_cursor(void);
]]

local lib = ffi.load("termbox2")

-- Constants (must match TB_OPT_ATTR_W=64 build)
local GREEN   = 0x0003
local BOLD    = 0x01000000
local DEFAULT = 0x0000

local rc = lib.tb_init()
if rc ~= 0 then
    io.stderr:write("tb_init failed: " .. rc .. "\n")
    os.exit(1)
end

lib.tb_hide_cursor()
lib.tb_clear()

local y = 0
lib.tb_print(0, y, GREEN, DEFAULT, "Hello from LuaJIT + termbox2")
y = y + 1
lib.tb_print(0, y, DEFAULT, DEFAULT, "Press any key...")
lib.tb_present()

local ev = ffi.new("struct tb_event")
lib.tb_poll_event(ev)

lib.tb_clear()
lib.tb_print(0, 0, GREEN | BOLD, DEFAULT, "Goodbye!")
lib.tb_present()

-- Brief pause then exit
lib.tb_poll_event(ev)
lib.tb_shutdown()
```

---

## 8. Gotchas and Tips

1. **No preprocessor in ffi.cdef.** All `#define` constants must be expressed as Lua values or C enums. You cannot `#include "termbox2.h"`.

2. **Vararg functions.** `tb_printf` uses C varargs. LuaJIT FFI supports vararg calls, but Lua numbers default to `double` for vararg params. To pass an integer, use `ffi.new("int", value)` or `ffi.cast("int", value)`.

3. **Struct alignment.** `tb_event` is naturally packed (uint8, uint8, uint16, uint32, int32 x4). No padding issues expected, but `ffi.sizeof("struct tb_event")` should be 20 bytes.

4. **GC and pointers.** If you store a pointer to a cdata struct (e.g., passing `&ev` to C), keep the Lua reference to the struct alive. The GC does not follow C pointers.

5. **tb_printf is convenient but tb_print is simpler for FFI.** Prefer `tb_print` for static strings to avoid vararg conversion issues.

6. **Error checking.** All `tb_*` functions return `int`. Check for `TB_OK` (0). Negative values are errors. `tb_poll_event` returns 0 on success.

7. **Thread safety.** termbox2 is not thread-safe. All calls must happen from one thread (the LuaJIT main thread).

8. **Signal handling.** termbox2 installs a `SIGWINCH` handler for resize events. This is compatible with LuaJIT's signal handling but be aware it exists.
