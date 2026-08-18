# scry — build spec

"See the future in your data." A fast, Vim-inspired terminal SQL client, similar in scope to Lazygit but for SQL (and, later, NoSQL).

## Assumptions

- Target repository is empty unless existing files are supplied.
- One native binary per target OS/arch. LuaSQL and terminal-library native deps may require platform packages — document exact prerequisites.
- Functional correctness is the priority. Measure binary size, cold startup, and idle memory on the build host; report actual results rather than inventing claims.
- MVP result paging is client-side over a completed query result. Do not rewrite arbitrary user SQL to add database-level pagination.
- Out of scope for MVP: Phase 2 MongoDB/Redis, autocomplete, result tabs, plugins, extra themes beyond dark/light.

## Glossary

- **Connection profile** — a config entry under `connections.*`. Defines how to connect; never a live session.
- **Connection** — the live session created from a Connection profile via `client.lua`'s `connect()`. Never used to mean the profile.
- **Buffer** — the editor's full text content for one editing session.
- **Selection** — a contiguous range within the Buffer. When present, overrides "whole Buffer" as the scope for `Ctrl+r`.
- **Statement** — one syntactically complete SQL command extracted from the Buffer (or Selection). The unit the adapter's `execute(sql)` receives and the read-only classifier checks. Splitting a Buffer into Statements must be string- and comment-aware — a naive split on `;` breaks on semicolons inside string literals and on Postgres dollar-quoted blocks (`$$ ... $$`), and would disagree with the read-only classifier's own comment-stripping step about where a Statement ends.
- **Execution** — one `Ctrl+r` press. Runs one or more Statements in order against the current Connection, **halt-on-first-failure** (see Design Decisions below): every Statement before the failure still produces a displayed Result set; the failed Statement's error is shown; remaining Statements are not run.
- **Result set** — the output of one Statement: either rows + columns, or an error.
- **Page** — a contiguous slice of a Result set shown in the grid at one time, sized by `general.default_page_size`. Paging is purely client-side over already-materialized rows.

## Design decisions

**Multi-statement failure strategy: halt-on-first.** An Execution stops at the first failed Statement. Statements before it keep their Result sets on screen; the failed Statement's error is shown; remaining Statements in the Buffer/Selection are not sent to the driver. Chosen over run-all/report-per-statement because a mid-buffer failure inside a `BEGIN; ...; COMMIT` block leaves an ambiguous transaction state that differs by driver — halting avoids committing on top of a failure. Matches LuaSQL's natural batch-abort behavior. A `--continue-on-error` mode is deferred to Phase 2, once the grid supports multi-result-set display.

**Parser architecture: one shared module, `src/utils/sql_parse.lua`.** A single streaming state machine tracks single-quoted strings, double-quoted identifiers, backtick-quoted identifiers (MySQL), Postgres dollar-quoting (`$tag$...$tag$`, matched by exact tag — not truly nested), line comments (`--`), and block comments (`/* ... */`, non-nested for MVP — documented limitation). It exposes:
- `split_statements(buffer_text) → Statement[]` — the sole authority on statement boundaries.
- `classify_statement(sql_text) → { type, keyword }` — receives only pre-split Statement text, never raw buffer text, so it structurally cannot read across a boundary.

`src/utils/read_only.lua` calls `classify_statement()`; `src/utils/syntax.lua` reuses the tokenizer portion for highlighting; the Execution loop calls `split_statements()` before dispatching to the adapter. This keeps the splitter/classifier boundary invariant enforced by construction rather than by convention.

**Known MVP limitation:** nested block comments (`/* outer /* inner */ still outer */`) may mis-split. Documented in README; not handled in Phase 1.

**Adapter contract: `send_query()`/`poll()`/`get_result()`, single-Statement, non-blocking.** The Execution loop calls `sql_parse.split_statements()` once, then per Statement: `send_query(sql)`, then `poll()` each UI tick (the same tick that reads keyboard input) until it reports completion, then `get_result()` — halting per the strategy above on failure. The driver never sees multi-statement SQL — matches LuaSQL's one-result-set-per-call cursor model. This isn't just cancellation plumbing: LuaJIT is single-threaded here, so a single blocking call would freeze the event loop for the query's duration — no repaint, and `Ctrl+c` would never be reachable at all. Polling on the same tick as input is what makes both responsiveness and cancellation possible; it's a core execution requirement, not an optimization.

**No transaction control in the adapter contract for MVP.** `BEGIN`/`COMMIT`/`ROLLBACK` are ordinary Statements the user types; the adapter doesn't interpret or auto-wrap them. Auto-transaction wrapping is deferred to Phase 2.

**Cancellation and query execution are async, not blocking — this is now a core MVP requirement, not a stretch goal.** Verified against LuaSQL source: no driver exposes a cancel method, and the raw connection handles needed for driver-native cancel (`PGconn`/`PQcancel`, `MYSQL`/`mysql_kill`, `sqlite3`/`sqlite3_interrupt`) are buried in version-dependent userdata structs — FFI bypass isn't viable. But all three drivers uniformly expose `send_query()`/`poll()`/`get_result()`. This matters beyond cancellation: LuaJIT here is single-threaded, so a blocking `execute()` call freezes the entire event loop for the query's duration — no repaint, and critically, **no keyboard input processing, so `Ctrl+c` could never be received while a query runs at all.** The async path is therefore load-bearing, not optional polish. The Execution loop drives `send_query()` then polls in the same tick as UI input/redraw for every Statement; `Ctrl+c` during polling sets an abandon flag and closes the Connection (uniform across all three drivers, no raw handle needed) with the confirmation-prompt reconnect flow. `list_tables()`/`get_columns()`/`ping()` stay simple blocking calls — fast catalog queries, not worth the complexity.

**SSH tunnel lifecycle: one tunnel per Connection.** Starts in `connect()`, stops in `close()`. Restarts on reconnect. Multiple simultaneous Connections with tunnels run separate `ssh` processes on separate local ports — this is fine. Local port comes from `ssh_tunnel.local_port` in config; if absent or `0`, bind to port `0` locally to get an OS-assigned free ephemeral port, then pass that to `ssh -L` (don't hand-roll a port scan).

**Catalog queries per driver, for `list_tables()`/`get_columns()`:**
| Driver | `list_tables()` | `get_columns(table_name)` |
|---|---|---|
| Postgres | `information_schema.tables` | `information_schema.columns` |
| MySQL/MariaDB | `SHOW TABLES` | `SHOW COLUMNS FROM <table>` |
| SQLite | `sqlite_master` (`type='table'`) | `PRAGMA table_info(<table>)` |

The sidebar UI calls only these two adapter methods — it never issues raw catalog SQL itself, keeping per-database differences inside the adapter.

## 1. Acceptance criteria

A successful delivery:

1. Builds and launches on Linux, macOS, and Windows using documented commands.
2. Connects to PostgreSQL 12+, MySQL 8+/MariaDB 10.5+, and SQLite 3 through a shared adapter API.
3. Lets a user edit and execute SQL, view results, filter/sort/navigate them, export them, and quit safely.
4. Enforces configured or CLI read-only mode before sending unsafe statements to the database.
5. Includes tests/runnable checks for config merging, read-only SQL classification, exports, and arg parsing.
6. Includes documentation, examples, MIT license, and CI.

## 2. Constraints and non-negotiables

| Constraint | Value | Notes |
|---|---|---|
| Binary size | < 3 MB | Static linking preferred |
| Cold startup | < 50 ms | Includes config load; measured on build host |
| Idle memory | < 50 MB | With one connection |
| Min terminal size | 80×24 | Clear error + resize suggestion below that |
| Character encoding | UTF-8 | Full support, as far as terminal backend allows |
| Mouse input | Optional | Only when `general.mouse_enabled` is true |
| Default theme | Dark | Light theme available |
| Debug log path (Unix) | `$XDG_STATE_HOME/scry/scry.log` | Falls back to `~/.local/state/scry/scry.log` |
| Debug log path (Windows) | `%LOCALAPPDATA%\scry\scry.log` | Only written with `--debug` |

## 3. Stack (mandatory)

- Host launcher: `src/main.c`, < 100 lines, embeds LuaJIT 2.1.0-beta3.
- Application: LuaJIT 2.1, Lua 5.1 semantics, FFI where useful.
- TUI: termbox-compatible primitives via FFI, behind a single small wrapper so the rest of the UI doesn't depend on the backend.
- Drivers:
  - PostgreSQL → `luasql.postgres`
  - MySQL/MariaDB → `luasql.mysql`
  - SQLite → `luasql.sqlite3`
- Config: executable Lua files returning tables. No TOML/YAML deps.
- SSH forwarding via the platform `ssh` binary — no additional dependency.
- License: MIT.

## 4. Source layout

```text
src/main.c
src/scry.lua
src/config.lua
src/db/client.lua
src/db/postgres.lua
src/db/mysql.lua
src/db/sqlite.lua
src/db/mongo.lua        # Phase 2 stub — returns a clear "Phase 2" error
src/db/redis.lua        # Phase 2 stub — returns a clear "Phase 2" error
src/ui/tui.lua
src/ui/sidebar.lua
src/ui/editor.lua
src/ui/grid.lua
src/ui/status.lua
src/utils/export.lua
src/utils/history.lua
src/utils/read_only.lua      # calls sql_parse.classify_statement()
src/utils/sql_parse.lua      # shared statement splitter + classifier (see Design decisions)
src/utils/syntax.lua         # reuses sql_parse's tokenizer for highlighting
src/utils/vim_keys.lua
config.lua.example
.scry_config.lua.example
Makefile
build.sh
install.sh
.github/workflows/ci.yml
README.md
LICENSE
```

`src/db/client.lua` defines the adapter contract; every Phase 1 adapter implements it:

```lua
connect(config)                 -- opens the Connection; starts the SSH tunnel if configured (see Design decisions)
send_query(sql)                 -- begins execution of exactly ONE Statement (caller splits via sql_parse first); non-blocking, returns immediately
poll()                          -- called once per UI tick, the same tick that reads keyboard input; reports whether the query is still running
get_result()                    -- called once poll() reports completion; returns a Result set or an error
cancel()                        -- called on Ctrl+c while a query is in flight; abandons the poll loop and closes the Connection (no driver-native cancel exists — see Design decisions). Uniform across all three drivers.
list_tables()                   -- returns table names via the driver's catalog query (see Design decisions); simple blocking call
get_columns(table_name)         -- returns column info via the driver's catalog query; simple blocking call
ping()                          -- health check; simple blocking call
close()                         -- closes the Connection; tears down the SSH tunnel if one was started
```

No transaction methods (`begin`/`commit`/`rollback`) in the MVP contract — see Design decisions.

## 5. Layout (fixed for MVP)

```text
┌──────────────┬──────────────────────────────────────┐
│ Sidebar      │ Query Editor (40%)                    │
│ Connections  │                                        │
│ + Tables     ├──────────────────────────────────────┤
│              │ Results Grid (60%)                    │
│              │                                        │
├──────────────┴──────────────────────────────────────┤
│ Status: [conn] [READ ONLY] Page 1/5  123 rows  12 ms │
└─────────────────────────────────────────────────────┘
```

- Sidebar width defaults to 30 columns, configurable.
- `Tab` / `Shift+Tab` cycles focus. `h/j/k/l` navigate unconditionally in the sidebar and grid; the editor is always-insert (no modal Vim editing), so `h/j/k/l` type literal characters there — editor navigation uses arrows, Home/End, `Ctrl+a/e` instead (see Query editor).
- Result-set tabs deferred to Phase 2.

| Key | Action |
|---|---|
| `Tab` / `Shift+Tab` | Cycle focus: sidebar → editor → grid |
| `h/j/k/l` | Navigate — sidebar and grid only; editor treats these as literal input |
| `Ctrl+r` | Execute query / refresh results |
| `Ctrl+p` / `Ctrl+n` | Navigate query history |
| `:history` | Open history search |
| `Ctrl+f` / `Ctrl+b` | Page forward / backward in results |
| `gg` / `G` | First / last row |
| `Enter` | Toggle sort on column header; open full-value modal on a cell |
| `/` | Case-insensitive fuzzy row filter |
| `H` / `L` | Scroll columns horizontally |
| `Ctrl+e` | Export CSV (JSON export uses a separate, documented binding) |
| `q` | Quit, with confirmation if a query is running or the editor has unsaved text |
| `Ctrl+c` | Cancel active operation where driver support permits |
| `Esc` | Move focus to sidebar (from editor) |
| `?` | Help overlay |

## 6. Configuration

Load and deep-merge, project overriding global:

- `general`, `query_editor`, `keybindings`: merged **key-by-key, recursively**.
- `connections`: merged **by name at the top level only**. A connection name present in only one layer is included as-is. A connection name present in *both* layers is **replaced wholesale** by the project layer's entry — its individual fields are never merged with the global entry's fields, to avoid a Frankenstein connection (e.g. project's `host` paired with global's `password`). Put shared credentials in global config, environment-specific overrides in project config, as distinct named connections rather than partial overrides of the same name.

1. Global:
   - Unix: `$XDG_CONFIG_HOME/scry/config.lua`, falling back to `~/.config/scry/config.lua`
   - Windows: `%APPDATA%\scry\config.lua`
2. Project: `.scry_config.lua`, discovered walking cwd → parents, stopping at the repo root if present.

Config files are executable Lua — `os.getenv()`, string concat, functions are all valid.

```lua
return {
  general = {
    default_page_size = 100,
    sidebar_width = 30,
    mouse_enabled = true,
    theme = "dark",          -- "dark" | "light" — colors only (fg/bg/accent for sidebar, editor, grid, status bar, syntax highlighting, modals); layout/keybindings/behavior identical across themes
    connect_timeout_seconds = 10,
  },
  connections = {
    local_dev = {
      type = "postgres",     -- "postgres" | "mysql" | "sqlite"
      host = "localhost",
      port = 5432,
      database = "mydb",
      user = "dev",
      password = os.getenv("DB_DEV_PASSWORD"),  -- preferred; plaintext allowed for local dev only
      read_only = false,
      ssh_tunnel = {          -- optional
        host = "bastion.example.com",
        username = "deploy",
        key_path = os.getenv("HOME") .. "/.ssh/id_ed25519",
        local_port = 5433,
      },
    },
    production = {
      type = "postgres",
      read_only = true,
    },
  },
  query_editor = {
    syntax_highlighting = true,
    history_size = 1000,
  },
  keybindings = {             -- optional overrides
    quit = "q",
    run_query = "Ctrl-r",
  },
}
```

Ship `config.lua.example` and `.scry_config.lua.example`.

## 7. Connections

- CLI: `scry [--connection NAME] [--read-only] [--debug] [--help]`
- Selection from the sidebar or `--connection`.
- Health check after connect:
  - PostgreSQL / MySQL: `SELECT version()`
  - SQLite: `SELECT sqlite_version()`
- Green/yellow/red connection status in the UI.
- 10s configurable connect timeout.
- SSH forwarding via `ssh -L`, spawned on connect, torn down on disconnect/exit; driver connects to the local forwarded port.
- Confirmation prompt before reconnecting after a lost connection.

## 8. Query editor

Always-insert style, no modal Vim editing.

- Multi-line buffer, multi-statement execution via `src/utils/sql_parse.split_statements()`.
- `Ctrl+r` runs the whole buffer, or the selection if one exists — halt-on-first-failure (see Design decisions): Statements before a failure keep their Result sets; the failed Statement's error is shown; later Statements don't run.
- SQL keyword/string/comment/function highlighting via lightweight local Lua pattern matching — no external deps.
- History persisted to `history.lua` in the platform state directory as executable Lua: `return { { sql = "...", timestamp = ..., connection_name = "local_dev", success = true }, ... }`. One entry per **Execution** (not per Statement) — `sql` is the full buffer/selection text as run, even when multi-statement. Appended on every Execution regardless of outcome; oldest entries pruned once count exceeds `query_editor.history_size`; the file is rewritten on each append. `Ctrl+p`/`Ctrl+n` navigate, `:history` searches by substring match on `sql`.
- Arrows, Home/End, `Ctrl+a/e`, `Ctrl+k/u`, `Ctrl+l` clear.
- `Esc` moves focus to the sidebar.

## 9. Results grid

- Default page size from `general.default_page_size`.
- Client-side paging over materialized rows: `Ctrl+f`/`Ctrl+b` next/prev page, `gg`/`G` first/last row.
- `Enter` on a column header toggles asc/desc sort.
- `/` opens a case-insensitive fuzzy row filter.
- `Ctrl+r` refreshes the current query.
- `Enter` on a data cell opens a modal with the full value.
- `H`/`L` scroll columns horizontally.
- `Ctrl+e` exports CSV; a distinct, documented binding exports JSON (pretty or minified). File output first; add clipboard only if a supported native command is available.
- CSV export follows RFC 4180: values are double-quoted when they contain a comma, newline, or double quote; embedded double quotes are escaped by doubling (`"` → `""`). NULL cells render as an empty string in CSV, and as JSON's `null` type in JSON export (not the string `"null"`).
- Status bar shows page X/Y, row count, and elapsed query time.

## 10. Global commands and read-only enforcement

- `:` command mode: `:connect NAME`, `:quit`, `:help`, `:history`
- `?` help overlay: a static modal listing the full keybinding table (§5's table — generated from one source in code, not hand-duplicated, so it can't drift from the spec). No context-sensitivity or search for MVP; both deferred to Phase 2. Closes on any keypress or `Esc`.
- `q` quits, with confirmation if a query is running or the editor has unsaved text
- `Ctrl+c` cancels the active operation when driver support permits; otherwise returns control safely

Read-only, enabled by a connection's `read_only = true` or `--read-only`:

- Red `[READ ONLY]` badge in the status bar.
- Before execution, each Statement — already boundary-clean from `sql_parse.split_statements()` — is classified by `sql_parse.classify_statement()`.
- Allow `SELECT`, `EXPLAIN`, `SHOW`, `DESCRIBE`, safe `SET`.
- Block `INSERT`, `UPDATE`, `DELETE`, `DROP`, `TRUNCATE`, `ALTER`, `CREATE`, `REPLACE`, `MERGE` (case-insensitive) with a clear local error — nothing blocked reaches the driver.
- Document explicitly: this is client-side protection only; database-level permissions remain the authoritative safeguard.

## 11. Build, CI, docs

- `Makefile`: debug and release targets.
- `build.sh`: strips release artifacts; targets Linux x86_64, macOS x86_64/arm64 (universal when both toolchains are present), Windows x86_64.
- `install.sh` for end-user install of a prebuilt binary.
- `.github/workflows/ci.yml`: builds on Linux, macOS, Windows for PRs.
- `README.md` covers: prerequisites; build/install (prebuilt binaries, `install.sh`, Homebrew formula sketch, AUR sketch); config guide; full keybinding table; read-only usage; supported DBs (Phase 1 vs 2); troubleshooting; tests; contributing.
- `LICENSE`: MIT.

## 12. Verification before delivery

1. Run the available build and test commands.
2. Verify: `--help`, config loading (global + project merge), read-only classification, CSV export, JSON export, and SQLite execution without any external service.
3. Final report includes:
   - files created,
   - commands run and their results,
   - measured binary size / startup / idle memory where measurable,
   - remaining platform-specific prerequisites or limitations.

Keep the implementation small, readable, direct. Comment only where it explains non-obvious FFI, terminal, process-lifecycle, or SQL-safety behavior.
