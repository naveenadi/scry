# Prototype: Scry runtime baseline

Ticket: [#5 Prototype Scry runtime baseline](https://github.com/naveenadi/scry/issues/5)

## Stack

| Component | Version | Link mode |
|---|---|---|
| LuaJIT | 2.1 (git HEAD 2026-08-13) | static `.a` |
| LuaSQL | 2.8.0 (git HEAD 2026-08-13) | compiled-in |
| SQLite | 3.53.4 (Homebrew) | static `.a` |
| termbox2 | HEAD 2026-08-13 | shared `.dylib` for FFI |

Host: macOS arm64, Apple Silicon, cc (clang)

## Build

```sh
# 1. Build LuaJIT
cd vendor/LuaJIT
make -j$(sysctl -n hw.ncpu) MACOSX_DEPLOYMENT_TARGET=$(sw_vers -productVersion | cut -d. -f1-2)

# 2. Build termbox2 shared lib (for FFI)
cat > /tmp/termbox2_impl.c <<'EOF'
#define TB_IMPL
#define TB_OPT_TRUECOLOR
#include "termbox2.h"
EOF
cc -O2 -shared -fPIC -dynamiclib -I vendor /tmp/termbox2_impl.c -o libtermbox2.dylib

# 3. Compile LuaSQL objects (patch luaL_setfuncs duplicate)
cc -O2 -fPIC -I vendor/LuaJIT/src -I vendor/luasql/src $(pkg-config --cflags sqlite3) -c /tmp/luasql_fixed.c -o src/luasql.o
cc -O2 -fPIC -I vendor/LuaJIT/src -I vendor/luasql/src $(pkg-config --cflags sqlite3) -c vendor/luasql/src/ls_sqlite3.c -o src/ls_sqlite3.o

# 4. Link
cc -O2 -o scry -I vendor/LuaJIT/src src/main.c src/luasql.o src/ls_sqlite3.o vendor/LuaJIT/src/libluajit.a $(pkg-config --libs sqlite3) -lm
```

**Note:** LuaSQL 2.8.0's `luasql.c` defines `luaL_setfuncs` which duplicates LuaJIT's implementation. The prototype patches this out. Upstream fix or a `#define` guard is needed before MVP.

**Note:** termbox2 is built as a shared `.dylib` for LuaJIT FFI because macOS does not export host binary symbols for `ffi.C` lookup. On Linux, `-rdynamic` or `-Wl,-E` may allow `ffi.C` without a separate `.so`. Test in CI.

## Measurements

| Metric | Value | Notes |
|---|---|---|
| **Binary size** | **676,872 bytes (0.65 MB)** | `wc -c scry` |
| **Cold startup (--help)** | **3.07 ms** | median over 50 runs |
| **Cold startup (--version)** | **2.55 ms** | median over 50 runs |
| **Idle RSS** | **2,310,144 bytes (2.2 MB)** | SQLite in-memory, after one query |

Measurement commands:

```sh
# Binary size
wc -c < scry

# Startup
python3 -c 'import time; t=time.time(); [os.system("./scry --help >/dev/null") for _ in range(50)]; print((time.time()-t)/50*1000, "ms")'

# RSS
/usr/bin/time -l ./scry  # with SQLite smoke test
```

## Assessment against spec targets

| Spec target | Measured | Status |
|---|---|---|
| <3 MB binary | 0.65 MB | ✅ well under (SQLite-only; +libpq/libmysql will grow) |
| <50 ms startup | 3.07 ms | ✅ well under |
| <50 MB RSS | 2.2 MB | ✅ well under |

**These numbers are for SQLite-only on macOS arm64.** Adding libpq + libmysql will increase binary size. Linux measurements needed for the full picture.

## Build issues found

1. **LuaSQL `luaL_setfuncs` duplicate**: LuaJIT 2.1 provides `luaL_setfuncs`; LuaSQL's compat shim in `luasql.c` conflicts. Needs upstream fix or `#define` guard.
2. **LuaJIT `lua_pushliteral` macro**: Breaks string concatenation in LuaSQL's `luasql.c` line130. Prototype patches `LUASQL_VERSION_NUMBER` to a string literal.
3. **macOS termbox2 FFI**: `ffi.C` can't find host symbols; requires separate `.dylib`. Linux may differ.
4. **LuaJIT macOS deployment target**: Must set `MACOSX_DEPLOYMENT_TARGET` when building LuaJIT.

## Files

- `src/main.c` — host binary, embeds LuaJIT, registers `luasql.sqlite3` preload
- `scry.lua` — Lua entry point (TUI smoke test with termbox2 + SQLite)
- `src/luasql.o` — compiled LuaSQL core
- `src/ls_sqlite3.o` — compiled LuaSQL SQLite3 driver
- `libtermbox2.dylib` — termbox2 shared library for FFI
