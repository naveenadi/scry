# Research: Scry LuaSQL build feasibility

Ticket: [#3 Research Scry LuaSQL build feasibility](https://github.com/naveenadi/scry/issues/3)

## Question

How can the mandatory LuaJIT 2.1 + LuaSQL PostgreSQL/MySQL/SQLite stack be built and packaged for Linux x86_64, macOS x86_64/arm64, and Windows x86_64?

## Recommendation

**Build a host binary that statically embeds LuaJIT and application Lua bytecode, and links LuaSQL drivers as either statically compiled-in C modules or private shared libraries shipped beside the binary.** Prefer:

1. **SQLite**: static link amalgamation or system/static `libsqlite3` into `luasql_sqlite3` — easiest fully-offline path; primary smoke target.
2. **PostgreSQL**: link against **libpq** (dynamic by default on most distros; static possible but pulls SSL/crypto and is painful). Document `libpq` as a runtime prerequisite unless release builds vendor a static/private libpq.
3. **MySQL/MariaDB**: link against **libmysqlclient** or **libmariadb** (dynamic). Same story as libpq for static linking — prefer dynamic + document, or vendor private shared libs in the release tarball.

Do **not** rely on end users installing LuaRocks. Scry's Makefile/`build.sh` should compile LuaSQL drivers from source ([lunarmodules/luasql](https://github.com/lunarmodules/luasql)) against pinned client SDK paths in CI.

## Stack facts (primary sources)

### LuaJIT 2.1
- Embed as external library built with its own build system; do not drop individual LuaJIT `.c` files into the app tree ([Installation](https://luajit.org/install.html)).
- Use `luaL_newstate` + `luaL_openlibs`; keep the `jit` library.
- POSIX static embed that still `require()`s C modules needs exported symbols (`-Wl,-E` on Linux).
- Windows: dynamic `lua51.dll` if loading C modules at runtime; static LuaJIT on Windows only if no runtime Lua/C modules.
- Embed Lua modules via `luajit -b` object files linked into the host ([Running LuaJIT](https://luajit.org/running.html)).
- macOS needs `MACOSX_DEPLOYMENT_TARGET` set for the LuaJIT build.

### LuaSQL
- Maintained at [lunarmodules/luasql](https://github.com/lunarmodules/luasql) (MIT/X11, same spirit as Lua 5.1) — [license](https://lunarmodules.github.io/luasql/license.html), [manual](https://lunarmodules.github.io/luasql/manual.html).
- Each driver = `luasql.c` + `ls_<driver>.c`, producing `luasql.<driver>` with open fn `luaopen_luasql<driver>`.
- Can be **linked into the application** or loaded dynamically from `package.cpath` under a `luasql/` folder ([manual §Compiling](https://lunarmodules.github.io/luasql/manual.html)).
- Drivers needed for Phase 1: postgres, mysql, sqlite3.
- API is cursor/row oriented — Scry's adapter must materialize full result sets client-side for paging (matches spec).

### Client libraries
- **libpq**: build/link via headers + `-lpq` / `pkg-config`; see [PostgreSQL libpq build docs](https://www.postgresql.org/docs/current/libpq-build.html). Static link is non-trivial (SSL, locale, etc.).
- **MySQL/MariaDB C client**: platform packages or Oracle/MariaDB Connector/C; Windows historically needs correct `libmysql` vs `mysqlclient` naming (LuaRocks issues confirm this footgun).
- **SQLite3**: amalgamation is the reliable static option.

## Per-target packaging matrix

| Target | LuaJIT | LuaSQL drivers | DB clients | Notes |
|---|---|---|---|---|
| Linux x86_64 | static `.a` into `scry` | static into `scry` **or** `lib/luasql/*.so` next to binary | sqlite static; libpq/libmysql dynamic or private rpath | CI: Ubuntu with `libpq-dev`, `libmysqlclient-dev`/`libmariadb-dev`, `libsqlite3-dev` |
| macOS x86_64/arm64 | static `.a`; set deployment target; universal via lipo when both present | same as Linux | Homebrew or CI-provided SDKs; `@loader_path` for private dylibs | `build.sh` universal when both toolchains exist |
| Windows x86_64 | `lua51.dll` + `scry.exe` **or** static if drivers compiled in | prefer **compiled-in** drivers to avoid DLL hell | ship/vendor `libpq.dll`, `libmysql.dll`, `sqlite3` static | MSVC or MinGW; pin SDK paths in CI |

## Static vs dynamic (hard limits)

- **Fully static single binary including libpq + libmysql + TLS** is usually unrealistic and legally/operationally messy (OpenSSL, glibc on Linux). Treat **<3 MB fully static with all drivers** as aspirational.
- Credible MVP packaging:
  - **sqlite-only static binary** can approach the size budget.
  - **Full three-driver release**: host + private shared client libs, total install tree measured; document if >3 MB.
- Functional correctness over meeting the size number when they conflict (map Notes).

## Reproducible CI approach

```text
.github/workflows/ci.yml
  matrix: ubuntu-latest, macos-latest, windows-latest
  steps:
    - build LuaJIT 2.1 (pinned commit/tag)
    - install/build DB client SDKs
    - build luasql postgres/mysql/sqlite3 against those SDKs
    - build src/main.c host, embed Lua bytecode
    - run unit checks (config merge, read-only classifier, export, args)
    - smoke: scry --help; sqlite file query
    - upload artifacts (binary + required DLLs/dylibs/so)
tag workflow:
  - same matrix
  - publish GitHub Release assets per OS/arch
```

Pin:
- LuaJIT git SHA (v2.1 branch tip or release tag),
- LuaSQL git SHA,
- client library major versions used in CI.

## Measurement plan

Run on the build host after a release-stripped build:

1. **Binary size**: `wc -c` / `ls -l` on the main binary; separately sum shipped shared libs; report both "main binary" and "install footprint".
2. **Cold startup**: `hyperfine` or `/usr/bin/time` on `scry --help` and on `scry` exiting immediately after config load with no connect; ≥50 runs, median.
3. **Idle memory**: start, connect to local SQLite, wait steady state; sample RSS via `/usr/bin/time -v` or `ps`; report RSS.
4. Record OS/arch, link mode (static/dynamic), and whether drivers are embedded.

Do not invent numbers; the prototype ticket produces the first Linux baseline.

## Adapter implications (for later tickets)

- LuaJIT is Lua 5.1 ABI — LuaSQL 5.1-compatible open functions are correct.
- Cancellation (`Ctrl+c`): LuaSQL has no standard async cancel; plan is best-effort (interrupt where client API allows; otherwise abandon and reconnect). Flag as fog until adapter design ticket.
- Multi-result / multi-statement: driver-dependent; materialize sequentially in the adapter.

## Unknowns

1. Measured install footprint with all three drivers + TLS on each OS.
2. Whether vendoring private libpq/libmysql is worth the release complexity vs documenting system packages.
3. MariaDB Connector/C vs Oracle libmysql as the canonical MySQL client for CI.
4. Windows toolchain choice (MSVC vs MinGW) interaction with LuaJIT's recommended build.

## Sources

- https://luajit.org/install.html
- https://luajit.org/running.html
- https://luajit.org/ext_ffi.html
- https://github.com/lunarmodules/luasql
- https://lunarmodules.github.io/luasql/manual.html
- https://lunarmodules.github.io/luasql/license.html
- https://www.postgresql.org/docs/current/libpq-build.html
