# Embedding LuaJIT 2.1 in a C Host Program

Research findings from primary sources: LuaJIT source Makefile, `luaconf.h`, luajit.org/install.html, luajit.org/doc/ext_*.html.

## 1. Building LuaJIT from Source as a Static Library

LuaJIT's build system has two Makefiles:

- **Top-level `Makefile`** — handles installation (PREFIX, install targets). Delegates to `src/Makefile`.
- **`src/Makefile`** — the real build logic. Compiles minilua, buildvm, then the LuaJIT VM and library.

### Default build (mixed mode)

```sh
cd vendor/LuaJIT
make
```

This produces **three artifacts** in `src/`:
- `luajit` — the standalone interpreter binary
- `libluajit.a` — static library
- `libluajit.so` — shared library (on Linux)

The default `BUILDMODE=mixed` builds all three. On macOS, the shared lib is `libluajit.dylib`.

### Static-only build

```sh
make BUILDMODE=static
```

This produces only `luajit` and `libluajit.a`. No shared library.

### What Scry does

Scry's Makefile runs:

```makefile
$(MAKE) -C $(LUAJIT_DIR) MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET)
```

This invokes the top-level Makefile, which delegates to `src/Makefile`. The result is `vendor/LuaJIT/src/libluajit.a`. The binary links against it:

```makefile
scry: src/main.c ... $(LUAJIT_LIB)
	$(CC) ... -I$(LUAJIT_INC) src/main.c ... $(LUAJIT_LIB) $(SQLITE_LIBS) -lm
```

### Key make variables (from `src/Makefile`)

| Variable | Purpose | Default |
|----------|---------|---------|
| `CC` | C compiler | `gcc` |
| `CFLAGS` | User C flags | (empty) |
| `XCFLAGS` | Extra feature flags | (empty) |
| `BUILDMODE` | `mixed`, `static`, or `dynamic` | `mixed` |
| `PREFIX` | Install prefix | `/usr/local` |
| `MULTILIB` | Library directory name | `lib` |
| `CROSS` | Cross-compile toolchain prefix | (empty) |
| `HOST_CC` | Host compiler (for minilua/buildvm) | `$(CC)` |
| `TARGET_SYS` | Target OS (auto-detected) | `$(HOST_SYS)` |
| `TARGET_CC` | Target compiler | `$(CROSS)$(CC)` |
| `TARGET_CFLAGS` | Target-specific C flags | (empty) |
| `TARGET_LDFLAGS` | Target-specific linker flags | (empty) |
| `MACOSX_DEPLOYMENT_TARGET` | macOS min version | (required on Darwin) |

### Important XCFLAGS

```sh
# Disable FFI (smaller binary)
make XCFLAGS=-DLUAJIT_DISABLE_FFI

# Disable JIT (interpreter only)
make XCFLAGS=-DLUAJIT_DISABLE_JIT

# Disable GC64 mode (x64 only, uses 32-bit GC refs)
make XCFLAGS=-DLUAJIT_DISABLE_GC64

# Enable Lua 5.2 compat
make XCFLAGS=-DLUAJIT_ENABLE_LUA52COMPAT

# Debug assertions (API checks)
make XCFLAGS=-DLUA_USE_APICHECK
```

### Amalgamated build

```sh
make amalg
```

Compiles the entire LuaJIT VM as a single `ljamalg.o` — faster compile, potentially better optimization.

## 2. Embedding LuaJIT in a C Host Program

### Headers

```c
#include <lua.h>      // Core Lua API
#include <lualib.h>   // Standard libraries (luaL_openlibs)
#include <lauxlib.h>  // Auxiliary functions (luaL_newstate, luaL_dostring, etc.)
```

LuaJIT also provides `luajit.h` for JIT-specific extensions:

```c
#include <luajit.h>   // luaJIT_setmode, version info
```

Include path: `-I vendor/LuaJIT/src`

### Minimal embedding

```c
#include <stdio.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

int main(void) {
    lua_State *L = luaL_newstate();   // Create Lua state
    if (!L) return 1;

    luaL_openlibs(L);                 // Open standard libraries

    // Execute Lua code
    if (luaL_dostring(L, "print('hello from Lua')") != 0) {
        fprintf(stderr, "error: %s\n", lua_tostring(L, -1));
    }

    lua_close(L);                     // Destroy state
    return 0;
}
```

Compile and link:

```sh
cc -O2 -o embed embed.c -I vendor/LuaJIT/src vendor/LuaJIT/src/libluajit.a -lm
```

On Linux, add `-ldl` (for `dlopen` used by `package.loadlib`).

### Loading and running a Lua file

```c
if (luaL_dofile(L, "script.lua") != 0) {
    fprintf(stderr, "error: %s\n", lua_tostring(L, -1));
}
```

### Calling a Lua function from C

```c
lua_getglobal(L, "my_function");     // Push function
lua_pushinteger(L, 42);              // Push argument
if (lua_pcall(L, 1, 1, 0) != 0) {   // 1 arg, 1 result
    fprintf(stderr, "error: %s\n", lua_tostring(L, -1));
}
int result = lua_tointeger(L, -1);   // Get result
lua_pop(L, 1);                       // Clean up
```

### Registering a C function into Lua

```c
static int my_add(lua_State *L) {
    double a = luaL_checknumber(L, 1);
    double b = luaL_checknumber(L, 2);
    lua_pushnumber(L, a + b);
    return 1;  // number of return values
}

// After luaL_openlibs(L):
lua_pushcfunction(L, my_add);
lua_setglobal(L, "my_add");
```

### Preloading a C module (LuaSQL pattern from Scry)

```c
extern int luaopen_luasql_sqlite3(lua_State *L);

static void preload_sqlite3(lua_State *L) {
    lua_getglobal(L, "package");
    lua_getfield(L, -1, "preload");
    lua_pushcfunction(L, luaopen_luasql_sqlite3);
    lua_setfield(L, -2, "luasql.sqlite3");
    lua_pop(L, 2);
}
```

This registers the module so `require("luasql.sqlite3")` loads it without needing a `.so` file.

### Setting package.path and package.cpath

```c
lua_getglobal(L, "package");

// Lua module search path
lua_pushstring(L, "src/?.lua;?.lua;?/init.lua");
lua_setfield(L, -2, "path");

// C module search path (for ffi.load and require of .so/.dll)
lua_pushstring(L, "./?.so;./lib/?.so");
lua_setfield(L, -2, "cpath");

lua_pop(L, 1);
```

### JIT control from C

```c
#include <luajit.h>

// Turn off JIT compiler
luaJIT_setmode(L, 0, LUAJIT_MODE_ENGINE | LUAJIT_MODE_OFF);

// Flush all compiled code
luaJIT_setmode(L, 0, LUAJIT_MODE_ENGINE | LUAJIT_MODE_FLUSH);
```

### C++ exception wrapper

```c++
static int wrap_exceptions(lua_State *L, lua_CFunction f) {
    try {
        return f(L);
    } catch (const char *s) {
        lua_pushstring(L, s);
    } catch (std::exception& e) {
        lua_pushstring(L, e.what());
    } catch (...) {
        lua_pushliteral(L, "caught (...)");
    }
    return lua_error(L);
}

// During init:
lua_pushlightuserdata(L, (void *)wrap_exceptions);
luaJIT_setmode(L, -1, LUAJIT_MODE_WRAPCFUNC | LUAJIT_MODE_ON);
lua_pop(L, 1);
```

## 3. Cross-Compilation

LuaJIT's `src/Makefile` supports cross-compilation via these variables:

| Variable | Purpose |
|----------|---------|
| `CROSS` | Toolchain prefix (e.g., `aarch64-linux-gnu-`) |
| `HOST_CC` | Compiler for host tools (minilua, buildvm) |
| `TARGET_SYS` | Target OS name (must differ from host for cross) |
| `TARGET_CC` | Target C compiler |
| `TARGET_CFLAGS` | Target-specific flags |
| `TARGET_LDFLAGS` | Target-specific linker flags |

### Constraint

Host and target must have the **same pointer size**. For 32-bit targets on 64-bit hosts, use `HOST_CC="gcc -m32"`.

### Linux x86_64 (native on Linux)

```sh
make
```

### Linux x86_64 (cross from macOS)

```sh
make CROSS=x86_64-linux-gnu- TARGET_SYS=Linux \
     HOST_CC=cc
```

### macOS x86_64

```sh
MACOSX_DEPLOYMENT_TARGET=10.15 make
```

### macOS arm64 (Apple Silicon)

```sh
MACOSX_DEPLOYMENT_TARGET=11.0 make
```

LuaJIT auto-detects the architecture from the compiler. On macOS, the build sets:
- `TARGET_XCFLAGS += -DLUAJIT_UNWIND_EXTERNAL`
- `TARGET_XSHLDFLAGS = -dynamiclib -undefined dynamic_lookup -fPIC`
- `LJVM_MODE = machasm` (Mach-O assembly format)

### macOS universal binary

LuaJIT doesn't have native universal build support. Build separately and lipo:

```sh
# x86_64
MACOSX_DEPLOYMENT_TARGET=10.15 make CC="clang -arch x86_64" clean all
cp src/libluajit.a libluajit-x86_64.a

# arm64
MACOSX_DEPLOYMENT_TARGET=11.0 make CC="clang -arch arm64" clean all
cp src/libluajit.a libluajit-arm64.a

# Combine
lipo -create libluajit-x86_64.a libluajit-arm64.a -output libluajit.a
```

### Windows x86_64 (MinGW cross from Linux/macOS)

```sh
make CROSS=x86_64-w64-mingw32- TARGET_SYS=Windows \
     HOST_CC=cc
```

Produces `lua51.dll` and `luajit.exe`.

### Windows (MSVC native)

```cmd
cd src
msvcbuild
```

Uses `src/msvcbuild.bat`. Open the appropriate "Visual Studio Command Prompt" for the target architecture.

### Key cross-compilation notes

- Always set `TARGET_SYS` when host OS differs from target OS.
- For ARM: set `-mfloat-abi=` in `TARGET_CFLAGS`.
- For embedded/minimal targets: use `TARGET_SYS=Other` and possibly disable the built-in allocator.
- The `CROSS` prefix has a trailing dash (e.g., `arm-linux-gnueabihf-`).

## 4. MACOSX_DEPLOYMENT_TARGET

### What it is

`MACOSX_DEPLOYMENT_TARGET` sets the **minimum macOS version** the binary will run on. It controls:

- Which system APIs are available at compile time
- Which linker behaviors are used
- The `LC_VERSION_MIN_MACOSX` or `LC_BUILD_VERSION` load command in the Mach-O binary

### Why LuaJIT requires it

From `src/Makefile`:

```makefile
ifeq (Darwin,$(TARGET_SYS))
  ifeq (,$(MACOSX_DEPLOYMENT_TARGET))
    $(error missing: export MACOSX_DEPLOYMENT_TARGET=XX.YY)
  endif
```

LuaJIT **errors out** on macOS if it's not set. This is because:

1. LuaJIT uses `-DLUAJIT_UNWIND_EXTERNAL` on macOS, which interacts with the system's unwinding mechanism. The deployment target affects which unwinding format is used.
2. The `-dynamiclib` linker flag and `-install_name` paths depend on the deployment target.
3. LuaJIT's Mach-O assembly (`vm_x64.dasc` → `lj_vm.S`) generates code that must be compatible with the target ABI.

### How Scry handles it

```makefile
MACOSX_DEPLOYMENT_TARGET ?= 10.15
```

Passed through to LuaJIT's build:

```makefile
$(MAKE) -C $(LUAJIT_DIR) MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET)
```

### Common values

| Value | macOS version | Notes |
|-------|---------------|-------|
| `10.13` | High Sierra | Minimum for most modern C features |
| `10.15` | Catalina | Scry's default. Good baseline. |
| `11.0` | Big Sur | Required for arm64 (Apple Silicon) |
| `12.0` | Monterey | If using newer APIs |
| `13.0` | Ventura | Recent baseline |

**Important**: Setting a lower deployment target than the build machine's OS version is fine (forward compatibility). Setting it higher means the binary won't run on older macOS versions.

### Effect on the build

The variable is exported as an **environment variable** (not a compiler flag). The system toolchain reads it directly. It affects:

- `clang`'s `-mmacosx-version-min=` behavior
- `ld`'s `-macosx_version_min=` behavior
- Availability macros (`__API_AVAILABLE`, `@available`, etc.)

## 5. Dynamic Library Loading for FFI

### How LuaJIT's FFI loads libraries

From `doc/ext_ffi_api.html`:

```lua
local ffi = require("ffi")
local clib = ffi.load("name")
```

`ffi.load(name)` works as follows:

**POSIX (Linux, macOS):**
- If `name` contains no dot, appends `.so` (Linux) or searches as-is
- Prepends `lib` if not present
- Calls `dlopen()` to load the shared library
- Returns a C library namespace object for symbol lookup via `dlsym()`

**macOS specifics:**
- `ffi.load("z")` looks for `libz.dylib` (not `.so`)
- Actually, LuaJIT on macOS appends `.so` but the system's `dlopen` also searches `.dylib`
- For explicit control, pass the full path: `ffi.load("/usr/lib/libz.dylib")`

**Windows:**
- Appends `.dll` if no dot in name
- Calls `LoadLibraryA()` / `GetProcAddress()`

### The `ffi.C` default namespace

`ffi.C` binds to the **default symbol namespace** — all symbols already loaded into the process:

- On POSIX: includes libc, libm, libdl, libgcc, and all symbols from the LuaJIT executable/library itself
- On Windows: includes lua51.dll, msvcrt, kernel32, user32, gdi32

### `package.cpath` for `require()`

`ffi.load` is separate from Lua's `require()`. For loading Lua C modules (traditional Lua/C API modules, not FFI), `package.cpath` controls the search:

From `luaconf.h`:

```c
// POSIX default:
#define LUA_CPATH_DEFAULT  "./?.so" LUA_LCPATH1 LUA_RCPATH LUA_LCPATH2
// Where:
//   LUA_LCPATH1 = ";/usr/local/lib/lua/5.1/?.so"
//   LUA_LCPATH2 = ";/usr/local/lib/lua/5.1/loadall.so"

// Windows default:
#define LUA_CPATH_DEFAULT  ".\\?.dll;" LUA_CDIR"?.dll;" LUA_CDIR"loadall.dll"
```

### Setting cpath in an embedded application

```c
lua_getglobal(L, "package");

// For .so files alongside the binary (Linux)
lua_pushstring(L, "./?.so;./lib/?.so;./lib/?/init.so");
lua_setfield(L, -2, "cpath");

lua_pop(L, 1);
```

For macOS, use `.dylib` or `.so` — both work with `dlopen`:

```c
// macOS: search both extensions
lua_pushstring(L, "./?.so;./?.dylib;./lib/?.so;./lib/?.dylib");
```

### Platform-specific cpath patterns

| Platform | Extension | Example cpath |
|----------|-----------|---------------|
| Linux | `.so` | `./?.so;/usr/local/lib/lua/5.1/?.so` |
| macOS | `.so` or `.dylib` | `./?.so;./?.dylib` |
| Windows | `.dll` | `.\\?.dll;lua\\?.dll` |

### FFI library search with ffi.load

```lua
-- Searches system paths (dlopen/LoadLibrary)
local zlib = ffi.load("z")        -- finds libz.so / libz.dylib / zlib.dll

-- Explicit path
local mylib = ffi.load("./lib/mylib.so")

-- Global namespace loading (POSIX only)
local clib = ffi.load("mylib", true)  -- symbols go into global namespace
```

### Environment variables

LuaJIT respects these for path overrides (from `luaconf.h`):

- `LUA_PATH` — overrides `package.path`
- `LUA_CPATH` — overrides `package.cpath`
- `LUA_INIT` — code to run on startup

### Embedding with bundled .so/.dylib files

For a self-contained distribution, set `package.cpath` relative to the executable:

```c
// Assume .so files are in a lib/ directory next to the executable
lua_getglobal(L, "package");
lua_pushstring(L, "./?.so;./lib/?.so;./lib/?/init.so");
lua_setfield(L, -2, "cpath");
lua_pop(L, 1);
```

On macOS with `@loader_path`:

```c
// If using dylibs with rpath
lua_pushstring(L, "./?.dylib;./lib/?.dylib");
```

The binary must be linked with the appropriate `-rpath`:

```makefile
# macOS
LDFLAGS += -Wl,-rpath,@loader_path/lib

# Linux
LDFLAGS += -Wl,-rpath,'$$ORIGIN/lib'
```

## Summary: Scry's Current Setup

Scry already does this correctly:

1. **Build**: `make -C vendor/LuaJIT` with `MACOSX_DEPLOYMENT_TARGET` → produces `libluajit.a`
2. **Link**: `cc -I vendor/LuaJIT/src src/main.c vendor/LuaJIT/src/libluajit.a -lm`
3. **Embed**: `luaL_newstate()` → `luaL_openlibs()` → preload modules → `luaL_dofile()` or `lua_pcall()`
4. **Module preloading**: Uses `package.preload` table to register built-in C modules (LuaSQL)
5. **Termbox**: Built as a shared library (`libtermbox2.dylib`) with `-Wl,-rpath,@loader_path`

What's **not** currently configured:
- `package.cpath` is not set (no FFI `.so`/`.dylib` loading from Lua code)
- No `LUA_PATH`/`LUA_CPATH` environment variable handling
- No JIT control (fine for most use cases)
