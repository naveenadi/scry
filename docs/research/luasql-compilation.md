# LuaSQL C Module Static Linking into a LuaJIT Binary

Research for embedding LuaSQL drivers as statically linked C modules in a
standalone LuaJIT binary. Primary sources: `vendor/luasql/src/*.c`,
`vendor/LuaJIT/src/lauxlib.h`, the existing `Makefile`, and
`src/main.c`.

---

## 1. LuaSQL C Module Loading

### Entry point convention

Every LuaSQL driver exports a single C function following the Lua module
naming convention `luaopen_<modname>`:

| Driver | Source file | Entry point | Lua require path |
|--------|------------|-------------|------------------|
| SQLite3 | `ls_sqlite3.c` | `luaopen_luasql_sqlite3` | `luasql.sqlite3` |
| PostgreSQL | `ls_postgres.c` | `luaopen_luasql_postgres` | `luasql.postgres` |
| MySQL | `ls_mysql.c` | `luaopen_luasql_mysql` | `luasql.mysql` |

The `.def` files in `vendor/luasql/src/` confirm these are the sole exports
per driver (e.g. `sqlite3.def` contains only `luaopen_luasql_sqlite3`).

### What each entry point does

All three drivers follow an identical pattern (from `ls_sqlite3.c:694`,
`ls_postgres.c:694`, `ls_mysql.c:803`):

```c
LUASQL_API int luaopen_luasql_sqlite3(lua_State *L) {
    struct luaL_Reg driver[] = {
        {"sqlite3", create_environment},
        {NULL, NULL},
    };
    create_metatables(L);       // registers env/conn/cursor metatables
    lua_newtable(L);
    luaL_setfuncs(L, driver, 0);
    luasql_set_info(L);         // sets _COPYRIGHT, _DESCRIPTION, _VERSION
    // ... driver-specific _CLIENTVERSION ...
    return 1;                   // returns the driver table
}
```

The returned table has one key (`"sqlite3"`, `"postgres"`, or `"mysql"`) whose
value is the `create_environment` factory function. Lua code calls
`require("luasql").sqlite3()` (or `.postgres()`, `.mysql()`) to get an
environment object.

### How Lua finds C modules dynamically

Lua's `require("luasql.sqlite3")` searches `package.cpath` for a shared
library named `luasql/sqlite3.so` (or `.dylib`/`.dll`), then calls
`luaopen_luasql_sqlite3` via `dlsym`. This is the standard dynamic loading
path -- not used in the static build.

---

## 2. Static Linking via `package.preload`

Instead of loading `.so` files, the host binary registers the C entry point
in `package.preload` before any Lua code runs. When Lua calls
`require("luasql.sqlite3")`, it finds the function in `package.preload` and
calls it directly -- no filesystem lookup, no `dlopen`.

The existing `src/main.c` already does this:

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

To add PostgreSQL or MySQL, the pattern is identical:

```c
extern int luaopen_luasql_postgres(lua_State *L);
extern int luaopen_luasql_mysql(lua_State *L);

// In main(), after luaL_openlibs:
lua_getglobal(L, "package");
lua_getfield(L, -1, "preload");
lua_pushcfunction(L, luaopen_luasql_postgres);
lua_setfield(L, -2, "luasql.postgres");
lua_pushcfunction(L, luaopen_luasql_mysql);
lua_setfield(L, -2, "luasql.mysql");
lua_pop(L, 2);
```

Lua code then does `require("luasql").postgres()` transparently -- it does
not care whether the module was loaded from a `.so` or preloaded statically.

---

## 3. The `luaL_setfuncs` Conflict

### The problem

LuaSQL's `luasql.c` provides its own `luaL_setfuncs` for Lua 5.1
compatibility (lines 64-80):

```c
#if !defined LUA_VERSION_NUM || LUA_VERSION_NUM==501
void luaL_setfuncs(lua_State *L, const luaL_Reg *l, int nup) {
    // ... implementation ...
}
#endif
```

LuaJIT 2.1 (which reports `LUA_VERSION_NUM == 501`) also provides
`luaL_setfuncs` in its `lauxlib.h` (line 88):

```c
LUALIB_API void (luaL_setfuncs) (lua_State *L, const luaL_Reg *l, int nup);
```

When both `luasql.o` and `libluajit.a` are linked into the same binary, the
symbol `luaL_setfuncs` is defined twice -- a linker duplicate-symbol error.

### The fix (already in the Makefile)

The Makefile patches `luasql.c` at build time to remove the Lua 5.1
compatibility block:

```makefile
LUASQL_PATCHED = build/luasql.c
$(LUASQL_PATCHED): $(LUASQL_DIR)/luasql.c $(VENDOR_STAMP)
    @mkdir -p build
    @python3 -c "import re; p=open('$<').read(); \
      p,n=re.subn(r'#if !defined LUA_VERSION_NUM ... #endif', \
      '/* luaL_setfuncs is provided by LuaJIT 2.1 */', \
      p, count=1, flags=re.S); \
      assert n == 1; open('$@','w').write(p)"
```

This replaces the `#if !defined LUA_VERSION_NUM || LUA_VERSION_NUM==501`
block through its matching `#endif` with a comment. The patched file is
written to `build/luasql.c` (never touching `vendor/`). The `luasql.o`
object is then compiled from the patched copy.

The `luasql.h` header also declares the prototype under the same guard:

```c
#if !defined LUA_VERSION_NUM || LUA_VERSION_NUM==501
void luaL_setfuncs(lua_State *L, const luaL_Reg *l, int nup);
#endif
```

This header declaration is harmless -- it is only a prototype, not a
definition. The linker resolves it to LuaJIT's implementation. No patch
needed for the header.

---

## 4. Compilation Flags for Object Files

The Makefile compiles each LuaSQL `.c` file as a relocatable object (`-c`),
not a shared library. Key flags:

```makefile
src/luasql.o: $(LUASQL_PATCHED) $(VENDOR_STAMP)
    $(CC) $(CPPFLAGS) $(CFLAGS) -fPIC \
      -I$(LUAJIT_INC) -I$(LUASQL_DIR) $(SQLITE_CFLAGS) \
      -DLUASQL_VERSION_NUMBER=\"$(LUASQL_VERSION)\" \
      -c $(LUASQL_PATCHED) -o $@

src/ls_sqlite3.o: $(LUASQL_DIR)/ls_sqlite3.c $(VENDOR_STAMP)
    $(CC) $(CPPFLAGS) $(CFLAGS) -fPIC \
      -I$(LUAJIT_INC) -I$(LUASQL_DIR) $(SQLITE_CFLAGS) \
      -c $< -o $@
```

Flag breakdown:

| Flag | Purpose |
|------|---------|
| `-fPIC` | Position-independent code. Required on Linux for any code that ends up in a final binary (even static linking benefits from PIE). Harmless on macOS. |
| `-I$(LUAJIT_INC)` | Points to `vendor/LuaJIT/src/` for `lua.h`, `lauxlib.h`, `lualib.h`. |
| `-I$(LUASQL_DIR)` | Points to `vendor/luasql/src/` for `luasql.h` and `sqlite3.h` (sqlite3.h comes from the system via `SQLITE_CFLAGS`). |
| `$(SQLITE_CFLAGS)` | From `pkg-config --cflags sqlite3`. Locates the system `sqlite3.h`. |
| `-DLUASQL_VERSION_NUMBER=\"2.8.1\"` | Only needed for `luasql.o` (used in `luasql_set_info` to set `_VERSION`). |
| `-c` | Compile to `.o` only, do not link. |

The final link step combines everything:

```makefile
scry: src/main.c src/luasql.o src/ls_sqlite3.o $(LUAJIT_LIB) ...
    $(CC) ... -o $@ -I$(LUAJIT_INC) \
      src/main.c src/luasql.o src/ls_sqlite3.o \
      $(LUAJIT_LIB) $(SQLITE_LIBS) -lm
```

`$(LUAJIT_LIB)` is `vendor/LuaJIT/src/libluajit.a` -- a static archive.
`$(SQLITE_LIBS)` is `-lsqlite3` (dynamic) or whatever `pkg-config` returns.

---

## 5. PostgreSQL and MySQL Drivers

### PostgreSQL (`ls_postgres.c`)

**Entry point:** `luaopen_luasql_postgres` (line 694)

**System dependency:** `libpq` (PostgreSQL client library)

- Header: `#include "libpq-fe.h"` (line 14)
- Link flag: `-lpq` or `pkg-config --libs libpq`
- pkg-config package name: `libpq`

**Compile flags:**
```makefile
PQ_CFLAGS = $(shell pkg-config --cflags libpq 2>/dev/null)
PQ_LIBS   = $(shell pkg-config --libs libpq 2>/dev/null || printf '%s' '-lpq')

src/luasql_postgres.o: $(LUASQL_PATCHED) $(VENDOR_STAMP)
    $(CC) $(CPPFLAGS) $(CFLAGS) -fPIC \
      -I$(LUAJIT_INC) -I$(LUASQL_DIR) $(PQ_CFLAGS) \
      -DLUASQL_VERSION_NUMBER=\"$(LUASQL_VERSION)\" \
      -c $(LUASQL_PATCHED) -o $@

src/ls_postgres.o: $(LUASQL_DIR)/ls_postgres.c $(VENDOR_STAMP)
    $(CC) $(CPPFLAGS) $(CFLAGS) -fPIC \
      -I$(LUAJIT_INC) -I$(LUASQL_DIR) $(PQ_CFLAGS) \
      -c $< -o $@
```

**Static linking note:** Static `libpq` pulls in OpenSSL/libcrypto, kerberos,
and other dependencies. On Linux this is painful. Prefer dynamic linking with
`-lpq` and document `libpq` as a runtime requirement, or ship
`libpq.dylib`/`libpq.so` alongside the binary with an rpath.

### MySQL (`ls_mysql.c`)

**Entry point:** `luaopen_luasql_mysql` (line 803)

**System dependency:** Either `libmysqlclient` (Oracle MySQL) or
`libmariadb` (MariaDB Connector/C)

- Header: `#include "mysql.h"` and `#include "errmsg.h"` (lines 18-19)
- Link flags: `-lmysqlclient` or `-lmariadb`
- pkg-config package names: `mysqlclient` or `libmariadb`

**Compile flags:**
```makefile
MYSQL_CFLAGS = $(shell pkg-config --cflags mysqlclient 2>/dev/null || \
                pkg-config --cflags libmariadb 2>/dev/null)
MYSQL_LIBS   = $(shell pkg-config --libs mysqlclient 2>/dev/null || \
                pkg-config --libs libmariadb 2>/dev/null || \
                printf '%s' '-lmysqlclient')

src/ls_mysql.o: $(LUASQL_DIR)/ls_mysql.c $(VENDOR_STAMP)
    $(CC) $(CPPFLAGS) $(CFLAGS) -fPIC \
      -I$(LUAJIT_INC) -I$(LUASQL_DIR) $(MYSQL_CFLAGS) \
      -c $< -o $@
```

**MariaDB vs Oracle client:** The `ls_mysql.c` source handles both via the
`MARIADB_CLIENT_VERSION_STR` preprocessor check (line 813). MariaDB
Connector/C is generally easier to build and package than Oracle's
libmysqlclient.

**Static linking note:** Same story as libpq -- prefer dynamic. MariaDB
Connector/C static builds are somewhat more self-contained than libpq but
still pull in TLS.

---

## Summary: Adding a New Driver to the Static Binary

The recipe for each driver is:

1. **Compile `luasql.o`** from the patched `build/luasql.c` (already done for
   sqlite3; shared across all drivers -- only one copy needed).

2. **Compile `ls_<driver>.o`** from `vendor/luasql/src/ls_<driver>.c` with
   `-fPIC -I$(LUAJIT_INC) -I$(LUASQL_DIR)` plus the driver's pkg-config
   flags.

3. **Add `extern int luaopen_luasql_<driver>(lua_State *L);`** and a
   `package.preload` registration in `src/main.c`.

4. **Link** the `.o` files, `libluajit.a`, and the driver's system library
   (`-lpq`, `-lmysqlclient`, etc.) into the final binary.

No `.so`/`.dylib`/`.dll` files are produced. The driver is fully embedded.
