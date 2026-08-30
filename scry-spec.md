# scry — build spec

"See the future in your data." A fast, Vim-inspired terminal SQL client, similar in scope to Lazygit but for SQL (Phase 2: NoSQL).



## Assumptions

- Target repository is empty unless existing files are supplied.
- LuaJIT 2.1 (pinned to a commit SHA on the `v2.1` branch) + `lunarmodules/luasql` master (pinned to a commit SHA containing PR #201), plus the platform's DB client libraries and the terminal backend — all may require platform packages; document exact prerequisites. Both pins are recorded in build metadata so a release is reproducible from the spec alone.
- Functional correctness is the priority. Measure binary size, cold startup, and idle memory on the build host; report actual results rather than inventing claims. The `<3 MB` binary target is a stretch goal — correctness and portability win if native client libraries make it impractical.
- MVP result paging is client-side over a completed (and capped) query result. Do not rewrite arbitrary user SQL to add database-level pagination.
- Out of scope for MVP: Phase 2 MongoDB/Redis, autocomplete, result tabs, plugins, extra themes beyond dark/light.

## Glossary

- **Connection profile** — a config entry under `connections.*`. Defines how to connect; never a live session.
- **Connection** — the live session created from a Connection profile via the adapter's `connect()`. Never used to mean the profile.
- **Buffer** — the editor's full text content for one editing session.
- **Selection** — a contiguous range within the Buffer. When present, overrides "whole Buffer" as the scope for `Ctrl+r`.
- **Statement** — one syntactically complete SQL command extracted from the Buffer (or Selection). The unit the adapter's `execute(sql)` / `send_query(sql)` receives and the read-only classifier checks. Splitting a Buffer into Statements must be string- and comment-aware — a naive split on `;` breaks on semicolons inside string literals and on Postgres dollar-quoted blocks (`$$ ... $$`), and would disagree with the read-only classifier's own comment-stripping step about where a Statement ends.
- **Execution** — one `Ctrl+r` press. Runs one or more Statements in order against the current Connection, **halt-on-first-failure** (see Design Decisions below): every Statement before the failure still produces a displayed Result set; the failed Statement's error is shown; remaining Statements are not run.
- **Result set** — the output of one Statement: either rows + columns, or an error.
- **Page** — a contiguous slice of a Result set shown in the grid at one time, sized by `general.default_page_size`. Paging is purely client-side over already-materialized rows.

## Design decisions

**Multi-statement failure strategy: halt-on-first.** An Execution stops at the first failed Statement. Statements before it keep their Result sets on screen; the failed Statement's error is shown; remaining Statements in the Buffer/Selection are not sent to the driver. Chosen over run-all/report-per-statement because a mid-buffer failure inside a `BEGIN; ...; COMMIT` block leaves an ambiguous transaction state that differs by driver — halting avoids committing on top of a failure. Matches luasql's natural batch-abort behavior. A `--continue-on-error` mode is deferred to Phase 2, once the grid supports multi-result-set display.

**Multi-statement result display.** Phase 1 displays only the most recent successful Result set from an Execution. Execution metadata retains per-statement outcome information (success/error per statement, row counts), but Phase 1 does not retain arbitrary prior result rows after their result resources are released. Result-set tabs (Phase 2) will make all Result sets from an Execution accessible.

**Transaction state after failure.** The execution engine does not interpret `BEGIN`/`COMMIT`/`ROLLBACK` — they are ordinary Statements. When a mid-transaction Statement fails and execution halts, the transaction may remain open. The UI surfaces this as `ERROR — transaction state may require ROLLBACK` with three options: `[Rollback]` (issues `ROLLBACK` as a new statement), `[Reconnect]` (close and re-establish the connection), `[Dismiss]` (continue on the current connection). The adapter never auto-rollbacks.

**Parser architecture: one shared module, `src/sql/parse.lua`.** A single streaming state machine tracks `NORMAL`, `SINGLE_QUOTE`, `DOUBLE_QUOTE`, `BACKTICK` (MySQL), `DOLLAR_QUOTE` (Postgres `$tag$...$tag$`, matched by exact, case-sensitive tag — different-tag dollar-quoted strings can occur inside an outer dollar-quoted string and are correctly treated as content of the outer string; same-tag sequences terminate at the first matching delimiter, no nesting-depth tracking required), `LINE_COMMENT` (`--`), and `BLOCK_COMMENT` (`/* ... */`, non-nested for MVP — documented limitation). It exposes:
- `split_statements(buffer_text) → Statement[]` — the sole authority on statement boundaries.
- `classify_statement(sql_text) → { type, keyword, blocked_keyword }` — receives only pre-split Statement text, never raw buffer text, so it structurally cannot read across a boundary. `blocked_keyword` reports any data-modifying keyword found anywhere in the tokenized Statement, used by the CTE-aware read-only classifier (see Read-only enforcement).

`src/utils/read_only.lua` calls `classify_statement()`; `src/utils/syntax.lua` reuses the tokenizer portion for highlighting; the Execution loop calls `split_statements()` before dispatching to the adapter. The splitter/classifier boundary invariant is enforced by construction rather than convention.

**Known MVP limitation:** nested block comments (`/* outer /* inner */ still outer */`) may mis-split. Documented in README; not handled in Phase 1.

**Driver strategy: `lunarmodules/luasql` master (pinned to a commit containing PR #201), not a tagged release.** Stock luasql 2.8.1 (Feb 2026, latest release) does not expose the async methods the contract depends on. PR #201 added `send_query`/`poll`/`get_result`/`getfd` to all three drivers (Postgres, MySQL, SQLite3). The build pins a specific commit SHA of luasql master; no tagged release is acceptable.

Why async is a load-bearing MVP requirement, not a polish item: LuaJIT here is single-threaded, so a blocking `execute()` call freezes the entire event loop for the query's duration — no repaint, and **no keyboard input processing, so `Ctrl+c` could never be received while a query runs at all.** A Lua coroutine cannot yield while a synchronous C call is executing; the driver must provide a continuation API or the work must run on another thread. The async path is what makes both responsiveness and cancellation possible.

Per-driver async reality under luasql master (not all three are equal — the spec must be honest):

| Driver | Async mechanism | Notes |
|---|---|---|
| **Postgres** | cooperative network async via libpq | Real socket-driven: `PQsendQuery` / `PQsetnonblocking(1)` / `PQconsumeInput` / `PQisBusy` / `PQflush` / `PQgetResult`. The Execution loop depends on this. |
| **MySQL/MariaDB** | cooperative network async for **query execution only**, when built against **LuaSQL PR #201 + MariaDB Connector/C** | The MySQL adapter must enable MariaDB nonblocking mode with `mysql_options(mysql, MYSQL_OPT_NONBLOCK, 0)` before connecting. The luasql PR #201 implementation wraps MariaDB's `mysql_real_query_start`/`_cont` for the query phase: call `_start` once, then call `_cont` on each UI tick according to its wait-status flags; when `MYSQL_WAIT_TIMEOUT` is returned, use `mysql_get_timeout_value()` to determine the next wait deadline. However, result retrieval uses the synchronous `mysql_store_result()` — there is no `mysql_store_result_start`/`_cont` usage. This means the query is non-blocking, but the result transfer from server to client blocks the event loop. Stock MySQL's libmysqlclient may define `MYSQL_OPT_NONBLOCK` for compatibility, but it does not provide the MariaDB `_start`/`_cont` symbols that this implementation wraps; luasql therefore falls back to fully synchronous `mysql_real_query`, which is dishonest about the contract. The build therefore links MariaDB Connector/C. A Phase 2 improvement could use MariaDB Connector/C's nonblocking result-fetch APIs (`mysql_store_result_start`/`_cont`) or stock MySQL's `mysql_store_result_nonblocking()`/`mysql_fetch_row_nonblocking()` to make result transfer non-blocking too.
| **SQLite** | prepare/step split; poll is non-networking/stubbed | `send_query` calls `sqlite3_prepare_v2` only; `get_result` performs the first `sqlite3_step`; `poll` always returns `false`. No socket readiness is involved — SQLite is local-file fast enough that this is acceptable for MVP, but the spec does not pretend SQLite has the same event-driven cancellation semantics as Postgres. |

Note the asymmetry: Postgres provides **cooperative network async** (the FD drives readiness, `poll()` reports it) for both query execution and result retrieval. MySQL/MariaDB provides **cooperative network async for query execution only** — result materialization via `mysql_store_result()` blocks the event loop. SQLite provides only a **prepare/step split** — the same `next_row()`/cursor interface, but without networking-style cancellation in the middle of a long step. Cancellation across all three goes through close-and-reconnect (see below).

**SQLite cancellation latency caveat (documented user-facing behavior):** because `sqlite3_step` runs without yielding to the event loop, `Ctrl+c` is observable **between** `sqlite3_step` calls, not inside a long step. For local-file queries this is invisible to the user. For a very long-running SQLite statement (e.g. a recursive CTE over a large DB) cancellation latency equals the remaining step time, not a network round-trip — seconds to minutes in pathological cases. Document this expectation in the README so users aren't surprised. If mid-step cancellation on SQLite ever becomes a real requirement, the path is direct FFI to `sqlite3_interrupt(db)` in `src/ffi/sqlite.lua`, deferred to Phase 2.

**Cancellation strategy: close-and-reconnect.** `Ctrl+c` during the poll loop sets an abandon flag, the next poll iteration detects it, `cancel()` closes the Connection (uniform across all three drivers, no raw handle extraction needed — `libpq`'s `PQcancel`/`mysql_kill`/`sqlite3_interrupt` would require FFI bypass of version-dependent userdata structs). UI shows the reconnect-confirmation prompt; on confirm, a new Connection is opened from the same Connection profile. This is a core execution requirement, not an optimization.

Cancellation means "abandon this connection and establish a fresh connection", not "ask the database to cancel only the current statement." This prevents users from expecting driver-specific millisecond cancellation. Native database cancellation is intentionally deferred because obtaining driver-native handles through LuaSQL would introduce version-dependent FFI coupling. Phase 2 may add native cancellation per driver (e.g. `adapter.cancel({ strategy = "native" })`) where a stable native cancellation interface becomes available.

**No transaction control in the adapter contract for MVP.** `BEGIN`/`COMMIT`/`ROLLBACK` are ordinary Statements the user types; the adapter doesn't interpret or auto-wrap them. Auto-transaction wrapping is deferred to Phase 2.

**SSH tunnel lifecycle: one tunnel per Connection.** Starts in `connect()`, stops in `close()`. Restarts on reconnect. Multiple simultaneous Connections with tunnels run separate `ssh` processes on separate local ports — this is fine. Local port comes from `ssh_tunnel.local_port` in config; if absent or `0`, bind to port `0` locally to get an OS-assigned free ephemeral port via `getsockname()`, then pass that to `ssh -L` (don't hand-roll a port scan). Recommended flags: `-N -L ... -o ExitOnForwardFailure=yes`.

**Catalog queries per driver, for the sidebar's `list_tables()` / `get_columns()`:**
| Driver | `list_tables()` | `get_columns(table_name)` |
|---|---|---|
| Postgres | `information_schema.tables` | `information_schema.columns` |
| MySQL/MariaDB | `SHOW TABLES` | `SHOW COLUMNS FROM <table>` |
| SQLite | `sqlite_master` (`type='table'`) | `PRAGMA table_info(<table>)` |

The sidebar calls only these two adapter methods — never raw catalog SQL itself. Catalog code must bind/escape identifiers rather than string-concatenate user-controlled table names (Phase 2 schema-aware catalog API builds on this rule; Phase 1 UI is flat).

**Platform abstraction.** Platform-specific behavior (process spawn/termination, environment paths, terminal size, signals/cancellation, file paths, temp files, socket readiness) lives behind `src/platform/unix.lua` / `src/platform/windows.lua` — not as scattered conditionals in UI/db code. The TUI wrapper (`src/tui/terminal.lua`) is the same kind of seam for the terminal backend.

**Secrets rule.** Passwords and other secrets never appear in debug logs, query history, error messages, or status UI. Anywhere we'd otherwise print a connection profile, mask credentials.

## 1. Acceptance criteria

A successful delivery:

1. Builds and launches on Linux, macOS, and Windows using documented commands.
2. Connects to PostgreSQL 12+, MySQL 8+/MariaDB 10.5+ (built against MariaDB Connector/C for honest async), and SQLite 3 through a shared adapter API.
3. Lets a user edit and execute SQL, view results, filter/sort/navigate them, export them, and quit safely.
4. Enforces configured or CLI read-only mode before sending unsafe statements to the database.
5. Includes tests for config merging, read-only classification (including CTE cases), exports, arg parsing, history load/append, and a fuzz target for the SQL splitter.

### Fuzz target exit criteria

The fuzz target lives in `tests/sql/fuzz_split_statements.lua` (or equivalent) and uses libFuzzer-style parameters scaled to a streaming LuaJIT parser. "Fuzz passes" means **all** of the following hold in a single CI run:

| Parameter | Value | Rationale |
|---|---|---|
| Per-input timeout | **2 seconds** | libFuzzer's default 1200 s is far too long for a state machine that should complete in microseconds. 2 s catches real infinite loops and pathological quadratic behavior without false positives on slow CI runners. Aligns with sqlsmith's `statement_timeout = 1s` discipline (PostgreSQL community), with slack. |
| Max input length | **65 536 bytes (64 KB)** | Large enough to stress edge cases and contain many statement boundaries; small enough that 100 k inputs ≈ 3 GB processed, manageable in CI. |
| RSS cap | **256 MB** | Catches unbounded allocations in the tokenizer. LuaJIT processes have low baseline RSS. |
| Total wall time | **300 seconds (5 min)** per CI run | Enough iterations to exercise most paths; longer runs can be scheduled outside CI. |
| Exit codes | `0` = pass; `77` on timeout or crash/leak | libFuzzer standard. |
| Minimum iterations in CI | **100 000** | Lower bound; libFuzzer runs as many as `--max_total_time` allows. |
| Seed corpus | Hand-written SQL fixtures: CTE cases (read-only and data-modifying), dollar-quoted blocks, comments containing `;`, unclosed/malformed quotes, multi-statement buffers, all keyword forms (`SELECT`/`INSERT`/etc.), UTF-8 edge cases | Without seeds libFuzzer explores mostly empty state. |

Sources: libFuzzer docs (https://llvm.org/docs/LibFuzzer.html), sqlsmith timeout practice (PostgreSQL mailing list archives).
6. Includes documentation, examples, MIT license, and CI.

## 2. Constraints and non-negotiables

| Constraint | Value | Notes |
|---|---|---|
| Binary size | < 3 MB (stretch) | Static linking preferred; correctness wins if impractical. **Feasibility reference** (not measured): static binary ≈ 870 KB (LuaJIT ~700 KB + termbox2 ~30 KB + luasql drivers ~90 KB + scry code ~50 KB); installed footprint including libpq + libmariadb + libsqlite3 ≈ 1.4 MB. Target is achievable with margin; measure against the real artifact. |
| Cold startup | < 50 ms (P50), report P95 too | Includes config load; measured on build host |
| Idle memory | < 50 MB at startup | Report RSS at connected-idle and at 100/10k/100k rows |
| Min terminal size | 80×24 | Show "Terminal too small. Please resize to at least 80×24." instead of drawing below that |
| Character encoding | UTF-8 | Full support, as far as terminal backend allows |
| Mouse input | Optional | Only when `general.mouse_enabled` is true |
| Default theme | Dark | Light theme available |
| Debug log path (Unix) | `$XDG_STATE_HOME/scry/scry.log` | Falls back to `~/.local/state/scry/scry.log` |
| Debug log path (Windows) | `%LOCALAPPDATA%\scry\scry.log` | Only written with `--debug`; secrets masked |

## 3. Stack (mandatory)

- Host launcher: `src/main.c`, < 100 lines, embeds LuaJIT 2.1 built from a pinned commit SHA on the `v2.1` branch (LuaJIT is distributed through its Git repo rather than official release tarballs; pinning the exact commit makes the build reproducible).
- Application: LuaJIT 2.1, Lua 5.1 semantics, FFI where useful.
- TUI: termbox-compatible primitives via FFI, behind one small internal wrapper (`src/tui/terminal.lua`: `init` / `shutdown` / `size` / `clear` / `present` / `cell` / `text` / `poll_event`). The rest of the app never touches the terminal backend directly.
- Drivers: **`lunarmodules/luasql` master pinned to a commit containing PR #201** (NOT a tagged release — 2.8.1 and earlier are sync-only):
  - PostgreSQL → `luasql.postgres` (libpq async)
  - MySQL/MariaDB → `luasql.mysql` built against **MariaDB Connector/C** (build requirement for the documented async contract). The adapter enables MariaDB nonblocking mode with `mysql_options(mysql, MYSQL_OPT_NONBLOCK, 0)` before connecting. Stock MySQL 8.0.16+ has its own async C API (`mysql_real_query_nonblocking` and friends), but the luasql PR #201 implementation we depend on wraps MariaDB's `_start`/`_cont` API. Stock `libmysqlclient` may define `MYSQL_OPT_NONBLOCK` for compatibility, but lacks the MariaDB `_start`/`_cont` symbols, so the MySQL adapter silently falls back to synchronous execution while still exposing the async contract — dishonest. The release therefore requires MariaDB Connector/C.
  - SQLite → `luasql.sqlite3` (prepare/step split; poll is a stub)
- Config: executable Lua files returning tables. No TOML/YAML deps.
- SSH forwarding via the platform `ssh` binary — no additional dependency.
- License: MIT.

## 4. Source layout

```text
scry/
├── src/
│   ├── main.c
│   ├── app.lua
│   ├── core/
│   │   ├── state.lua
│   │   ├── event_loop.lua
│   │   ├── execution.lua
│   │   └── errors.lua
│   ├── db/
│   │   ├── adapter.lua            # contract definition (§6)
│   │   ├── postgres.lua
│   │   ├── mysql.lua
│   │   ├── sqlite.lua
│   │   ├── mongo.lua              # Phase 2 stub — returns a clear "Phase 2" error
│   │   └── redis.lua              # Phase 2 stub — returns a clear "Phase 2" error
│   ├── ffi/
│   │   ├── postgres.lua           # direct libpq bindings (only if §8 forces native FFI; otherwise absent)
│   │   ├── mysql.lua
│   │   └── sqlite.lua
│   ├── sql/
│   │   ├── parse.lua              # split_statements() + classify_statement()
│   │   └── dialect.lua
│   ├── utils/
│   │   ├── read_only.lua          # calls sql.parse.classify_statement()
│   │   ├── syntax.lua             # reuses sql.parse's tokenizer for highlighting
│   │   ├── export.lua             # dispatches to export/csv.lua + export/json.lua
│   │   └── vim_keys.lua
│   ├── ui/
│   │   ├── layout.lua
│   │   ├── sidebar.lua
│   │   ├── editor.lua
│   │   ├── grid.lua
│   │   ├── modal.lua
│   │   ├── status.lua
│   │   └── help.lua
│   ├── tui/
│   │   └── terminal.lua           # single thin wrapper over the termbox backend
│   ├── config/
│   │   ├── loader.lua
│   │   ├── defaults.lua
│   │   └── merge.lua
│   ├── history/
│   │   └── store.lua              # history.jsonl (§9)
│   ├── export/
│   │   ├── csv.lua
│   │   └── json.lua
│   ├── ssh/
│   │   └── tunnel.lua
│   └── platform/
│       ├── unix.lua
│       └── windows.lua
├── tests/
│   ├── sql/                       # split/classify unit tests + fuzz target for split_statements() (exit criteria in §1)
│   ├── config/
│   ├── readonly/                  # includes CTE cases
│   ├── export/
│   ├── history/
│   └── integration/
├── examples/
│   ├── config.lua.example
│   └── .scry_config.lua.example
├── Makefile
├── build.sh
├── install.sh
├── README.md
├── LICENSE
└── .github/workflows/ci.yml
```

`src/db/adapter.lua` defines the adapter contract; every Phase 1 adapter implements it:

```lua
connect(config)                  -- opens the Connection; starts the SSH tunnel if configured (see Design decisions)
send_query(sql)                  -- begins execution of exactly ONE Statement (caller splits via sql.parse first); non-blocking, returns immediately. MUST perform only bounded, non-blocking work and return without waiting for server/network completion. Testable: an intentionally delayed query must not block the event loop.
poll()                           -- called once per UI tick, the same tick that reads keyboard input; reports whether the query is still running. Driver-specific continuation state (e.g. MySQL socket readiness flags) is private to each adapter; poll() exposes only the common progress contract.
get_result()                    -- transitions a completed execution into result consumption. May perform driver-specific result initialization. MAY BLOCK for drivers whose result-fetch capability is synchronous (see capabilities()). The adapter must expose this through capabilities().
state()                          -- current state-machine value (CONNECTING / READY / QUERYING / RESULT_READY / MATERIALIZING / FETCHING / ERROR / CANCELED / CONNECTION_LOST)
error()                          -- last error, if any
columns()                        -- column metadata for the current Result set; valid once state() reports columns are available
next_row()                       -- pull the next row once columns() is available; nil = end of results (a real signal, not a row)
close_result()                   -- releases the current result and initiates disposal of the remaining result stream. The adapter must not report the Connection as READY until all results belonging to the Statement have been consumed/discarded. If additional network input is required (Postgres multi-result), the adapter remains in an internal draining state and progresses through poll(). Never performs an unbounded network wait. For MySQL: mysql_free_result (safe — mysql_store_result already pulled all data; connection is clean after free). For SQLite: sqlite3_finalize (safe at any point).
cancel()                         -- called on Ctrl+c. During QUERYING: abandons the server operation, closes the Connection, triggers reconnect-confirmation. During FETCHING: stops local result consumption via close_result(), returns to READY without reconnecting (the query already completed on the server). See Design decisions.
list_tables()                    -- returns table names via the driver's catalog query (see Design decisions); simple blocking call
get_columns(table_name)          -- returns column info via the driver's catalog query; simple blocking call
ping()                           -- health check; simple blocking call
close()                          -- closes the Connection; tears down the SSH tunnel if one was started
capabilities()                  -- returns a table describing driver capabilities:
                                     query_async        — send_query() is non-blocking
                                     result_streaming   — next_row() pulls from server incrementally
                                     result_fetch_async — get_result() does not block the event loop
                                     early_close_requires_drain — close_result() must drain unread results
```

Driver capability table (Phase 1):

| Driver | query_async | result_streaming | result_fetch_async | early_close_requires_drain |
|---|---|---|---|---|
| PostgreSQL | true | true | true | true |
| MySQL/MariaDB | true | false | false | false |
| SQLite | false | true | false | false |

MySQL Phase 1 limitation: `result_streaming=false` because LuaSQL PR #201 uses `mysql_store_result()` (materializes entire result). MariaDB Connector/C provides `mysql_use_result()` + `mysql_fetch_row_start/cont()` for nonblocking streaming, but PR #201 does not expose them. Phase 2 can upgrade without changing the execution model.

**Driver capability tests** (mandatory, not informational):

| Driver | Test |
|---|---|
| PostgreSQL | `send_query` does not block |
| PostgreSQL | `poll` does not block |
| PostgreSQL | `get_result` after poll-ready does not block |
| PostgreSQL | Early result close eventually reaches READY via bounded drain |
| PostgreSQL | Multi-result drain never blocks inside a single poll tick |
| MySQL | `send_query` does not block (with `MYSQL_OPT_NONBLOCK` enabled via `mysql_options`) |
| MySQL | `poll` does not block |
| MySQL | `MATERIALIZING` explicitly permits blocking |
| MySQL | `mysql_store_result` materialization is observable via capabilities |
| SQLite | `prepare`/`send_query` does not execute the query |
| SQLite | `step`/`get_result` may block (CPU-bound) |
| SQLite | Cancellation is only observed between steps |

These tests verify the adapter contract against the actual driver behavior, not just the LuaSQL API surface.

Notes on the contract:
- **`get_result()` acquires the Result set; `next_row()` is the only row-consumption primitive.** `get_result()` may perform driver-specific initialization or blocking result transfer, but it must not be used to materialize the whole Result set for consumers. The grid and export build their own behavior on top of `next_row()` — the grid caps at `max_result_rows`, while export streams to file. This prevents a naive consumer from materializing 100 000 rows before it gets control.
- `columns()` is valid only after `state()` reports `FETCHING` or `READY`. It returns an empty list (not nil) if the Result set has no columns (e.g. an `UPDATE` that affected rows).
- `next_row()` returns `nil` at end-of-results. A row whose first column is the explicit `NULL` sentinel is **not** end-of-results; only `nil` is.
- `close_result()` is mandatory. The cursor / prepared statement holds client-library resources until released; leaking it across many Executions accumulates server-side state and eventually fails. After `close_result()`, calling `next_row()` again on the same Result set is undefined.
- No transaction methods (`begin`/`commit`/`rollback`) in the MVP contract — see Design decisions.
- Secrets never leave `connect()`'s config: passwords are passed through and never appear in `error()`, `state()` debug messages, or `history`.
- **`poll()` is cooperative and bounded.** Each call performs at most one driver continuation step (one `PQconsumeInput`/`PQisBusy` check, one `mysql_real_query_cont` call). The event loop calls `poll()` once per tick, guaranteeing fairness across terminal input, DB polling, SSH polling, and rendering. No subsystem monopolizes the tick.
- **`close_result()` must leave the connection reusable.** For Postgres, this means draining unread results through a readiness-aware state machine: `PQconsumeInput`/`PQisBusy` guarantees `PQgetResult` won't block for the next result; after consuming that result, return to the readiness check for any additional results. The drain never performs an unbounded network wait. `close_result()` does not promise instantaneous return to READY if unread server results still need to arrive — the adapter remains in an internal draining state and progresses through `poll()`. For MySQL, `mysql_free_result()` is safe because `mysql_store_result()` already pulled all data. For SQLite, `sqlite3_finalize()` cleans up at any point.
- **Cancellation is phase-aware.** During `QUERYING`, `cancel()` abandons the server operation and closes the connection (reconnect required). During `FETCHING`, `cancel()` calls `close_result()` and returns to `READY` without reconnecting — the query already completed on the server; the user just wants to stop consuming rows.

Adapter state machine:

```text
DISCONNECTED → CONNECTING → READY → QUERYING → RESULT_READY → MATERIALIZING* → FETCHING → READY
                    │            │                    │               │
                    ▼            │                    ▼               │
                  ERROR          │              CANCELING → CANCELED  │
                                 │                                    │
                                 └────────────────────────────────────┘

* MATERIALIZING is entered only when get_result() may block (MySQL).
  For Postgres, RESULT_READY → get_result() → FETCHING (non-blocking).
  For SQLite, RESULT_READY → get_result() → FETCHING (CPU-only).

READY (lost mid-session) → CONNECTION_LOST → (UI offers reconnect, with confirmation prompt)
```

The event loop drives: `send_query()` → `poll()` (returns true/false) → on false: `get_result()` → `columns()` → `next_row()` loop → `close_result()`. For MySQL, `get_result()` calls `mysql_store_result()` which blocks; the UI should display "Transferring results…" before entering MATERIALIZING.

Non-blocking event loop:

```text
while running:
    poll terminal
    poll database adapter (poll() + get_result() when RESULT_READY)
    poll SSH/process state
    execute bounded application work
    render
```

`send_query()` never waits for server completion; `poll()` performs only bounded work per call. `get_result()` may block for drivers with synchronous result-fetch (MySQL); the UI should indicate MATERIALIZING state before calling it.


## 4b. Execution lifecycle

The execution engine (`src/core/execution.lua`) drives multi-statement Executions through the adapter contract. It owns Execution state; adapters own Connection/driver state.

### State ownership

```text
Execution (execution.lua)          Adapter (db/*.lua)
├── statements[]                   ├── connection state
├── current_statement              ├── driver continuation state
├── execution_status               ├── current result
├── statement_results[]            └── protocol/drain state
├── current_result
├── failure
└── cancellation state
```

Do not create a second execution state machine inside `state.lua`.

### Execution state machine

```text
IDLE
 │
 │ Ctrl+r
 ▼
SPLITTING
 │
 ▼
CLASSIFYING
 │
 ├── blocked (read-only) → BLOCKED
 │
 ▼
SEND_QUERY
 │
 ▼
QUERYING
 │
 ├── Ctrl+C → CANCELING → RECONNECT_CONFIRM
 │
 └── poll-ready
       ↓
GETTING_RESULT
 │
 ├── MATERIALIZING* → get_result() → FETCHING   (* MySQL only)
 │
 ├── result → FETCHING
 │
 └── no result → STATEMENT_COMPLETE
                    │
                    ├── more statements → SEND_QUERY
                    └── done → COMPLETE

FETCHING
 │
 ├── row → bounded consume → FETCHING
 │
 ├── EOF → CLOSING_RESULT
 │
 ├── max_result_rows → CLOSING_RESULT
 │
 └── Ctrl+C → CLOSING_RESULT (no reconnect)

CLOSING_RESULT
 │
 ├── adapter needs drain → DRAINING
 │                              │
 │                              └── poll → DRAINING / READY
 │
 └── READY
       │
       ├── failed → EXECUTION_FAILED
       ├── more statements → SEND_QUERY
       └── done → COMPLETE
```

### Statement lifecycle

One Statement may be active at a time. The next Statement is never sent until the previous Statement's complete result lifecycle reaches adapter READY. This is load-bearing for PostgreSQL: `PQsendQuery()` cannot be issued again until the preceding `PQgetResult()` sequence returns NULL.

```text
Statement N: send_query → poll → get_result → consume → close_result → READY
Statement N+1: send_query → ...
```

### Statement completion

A Statement produces a normalized outcome:

```lua
{
    status = "success" | "error",
    columns = {...},
    affected_rows = number_or_nil,
    error = string_or_nil,
}
```

The adapter translates driver-specific result semantics. For PostgreSQL, a fatal result still requires the result-reading sequence to continue until `PQgetResult()` returns NULL.

### Failure propagation

Halt immediately, but finish protocol cleanup:

```text
SELECT → success
UPDATE → error → record error → finish/discard Statement 2 result lifecycle → STOP
DELETE → NOT SENT
```

Transaction state after failure: `ERROR — transaction state may require ROLLBACK` with `[Rollback]` / `[Reconnect]` / `[Dismiss]`. No automatic rollback — the adapter does not interpret transactions.

### Grid max_result_rows

The grid must not continue consuming rows just to reach EOF:

```text
next_row() → store in grid buffer → cap reached? → close_result() → adapter drains → READY
```

For PostgreSQL, result disposal may require further readiness-driven processing (DRAINING state).

### Ctrl+C semantics

| Execution state | Ctrl+C | Effect |
|---|---|---|
| IDLE | No-op | — |
| QUERYING | Cancel/abandon | adapter.cancel() → connection closed → reconnect confirmation |
| MATERIALIZING | Cannot reliably interrupt | MySQL store_result is synchronous; Ctrl+C not observable |
| FETCHING | Stop local consumption | close_result() → drain if necessary → READY (no reconnect) |
| DRAINING | Don't interrupt protocol cleanup | wait for drain to complete |
| COMPLETE | No-op | — |
| ERROR | UI-dependent dismiss | — |

Ctrl+C while displaying a large result should not unnecessarily destroy a healthy connection. The adapter handles protocol cleanup, then returns to READY.

### Result retention

Execution retains metadata, not historical rows:

```lua
{
    sql = original_text,
    statements = {
        { sql = "...", status = "success", elapsed_ms = 12, row_count = 100, columns = {...} },
        { sql = "...", status = "error", error = "..." },
    },
    failed_statement = 2,
}
```

Previous Statement buffers/results are released. Only the currently displayed result belongs to the grid. Phase 1 displays only the last result set.

### Result ownership

The Execution layer owns the lifecycle; the Grid owns only materialized rows:

```text
Adapter → next_row() → Execution → row → Grid buffer
```

The Grid must never call adapter methods directly. `execution:next_row()` and `execution:close_result()` are the only interfaces. This prevents UI code from violating adapter state transitions, result cleanup, PostgreSQL draining, or MySQL materialization semantics.

### Row consumption budget

`next_row()` calls are bounded per UI tick. A million-row fast local cursor must not monopolize the TUI:

```text
one UI tick → consume bounded number of rows → return to event loop → render → next tick
```

The row-consumption budget is a configurable internal constant (e.g. 1000 rows per tick).

### Key invariants

1. One active Statement at a time.
2. Next Statement is never sent until the previous Statement reaches adapter READY.
3. Execution owns execution state; adapter owns connection state.
4. A Statement failure prevents all later Statements from being sent.
5. Result cleanup happens even on failure, cancellation, and grid-cap termination.
6. Grid never consumes beyond `max_result_rows`.
7. `next_row()` work is bounded per UI tick.
8. QUERYING cancellation and FETCHING cancellation have different semantics.
9. No adapter method performs an unbounded network wait unless explicitly documented.
10. PostgreSQL result cleanup progresses through readiness checks, not an unconditional PQgetResult loop.

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
└──────────────────────────────────────────────────────┘
```

- Sidebar width defaults to 30 columns, configurable.
- `Tab` / `Shift+Tab` cycles focus. `h/j/k/l` navigate unconditionally in the sidebar and grid; the editor is always-insert (no modal Vim editing), so `h/j/k/l` type literal characters there — editor navigation uses arrows, Home/End, `Ctrl+a/e/k/u/l` instead.
- If the terminal is below 80×24: show "Terminal too small. Please resize to at least 80×24." instead of attempting to draw.
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
| `/` | Case-insensitive substring row filter (full fuzzy matching deferred) |
| `H` / `L` | Scroll columns horizontally |
| `Ctrl+e` | Export CSV |
| `Ctrl+Shift+e` | Export JSON (distinct binding; not the same key as CSV) |
| `q` | Insert the literal character `q` in the editor; quit through command mode with `:q` |
| `Ctrl+c` | Cancel active operation; abandon and reconnect via confirmation prompt |
| `Esc` | Enter command mode from the editor; exit command mode when already in command mode |
| `?` | Help overlay |

Vim navigation applies only to navigable views (sidebar, grid); the editor never treats `h/j/k/l`/`g`/`G` as commands.

## 6. Configuration

Load and deep-merge, project overriding global:

- `general`, `query_editor`, `keybindings`: merged **key-by-key, recursively**.
- `connections`: merged **by name at the top level only**. A connection name present in only one layer is included as-is. A connection name present in *both* layers is **replaced wholesale** by the project layer's entry — its individual fields are never merged with the global entry's fields, to avoid a Frankenstein connection (e.g. project's `host` paired with global's `password`). Put shared credentials in global config, environment-specific overrides in project config, as distinct named connections rather than partial overrides of the same name.

1. Global:
   - Unix: `$XDG_CONFIG_HOME/scry/config.lua`, falling back to `~/.config/scry/config.lua`
   - Windows: `%APPDATA%\scry\config.lua`
2. Project: `.scry_config.lua`, discovered walking cwd → parents, stopping at the repo root if present.

Config files are executable Lua — `os.getenv()`, string concat, functions are all valid. Users should be aware project config is executable code and shouldn't be trusted from untrusted repos.

```lua
return {
  general = {
    default_page_size = 100,
    max_result_rows = 100000,     -- stop buffering past this, report the limit clearly
    sidebar_width = 30,
    mouse_enabled = true,
    theme = "dark",               -- "dark" | "light" — colors only; layout/keybindings/behavior identical
    connect_timeout_seconds = 10,
  },
  connections = {
    local_dev = {
      type = "postgres",          -- "postgres" | "mysql" | "sqlite"
      host = "localhost",
      port = 5432,
      database = "mydb",
      user = "dev",
      password = os.getenv("DB_DEV_PASSWORD"),  -- preferred; plaintext allowed for local dev only
      read_only = false,
      ssh_tunnel = {              -- optional
        host = "bastion.example.com",
        username = "deploy",
        key_path = os.getenv("HOME") .. "/.ssh/id_ed25519",
        local_port = 5433,
      },
    },
    production = { type = "postgres", read_only = true },
  },
  query_editor = {
    syntax_highlighting = true,
    history_limit = 1000,
    history_max_entry_bytes = 1024 * 1024,
  },
  keybindings = {                 -- optional overrides
    quit = "q",
    run_query = "Ctrl-r",
  },
}
```

Ship `config.lua.example` and `.scry_config.lua.example`.

## 7. Connections

- CLI: `scry [--connection NAME] [--read-only] [--debug] [--version] [--help]`
- Selection from the sidebar or `--connection`.
- Health check after connect:
  - PostgreSQL / MySQL: `SELECT version()`
  - SQLite: `SELECT sqlite_version()`
- Green/yellow/red connection status in the UI.
- 10s configurable connect timeout.
- SSH forwarding via `ssh -L`, spawned on connect, torn down on disconnect/exit; driver connects to the local forwarded port.
- Confirmation prompt before reconnecting after a lost connection.
- Secrets rule: passwords/secrets never appear in debug logs, query history, error messages, or status UI.

## 8. Query editor

The editor uses always-insert mode. Command mode is a separate, visible mode for global commands; it is not modal Vim editing.

- Multi-line buffer, multi-statement execution via `src/sql/parse.split_statements()`.
- `Ctrl+r` runs the whole buffer, or the selection if one exists — halt-on-first-failure (see Design decisions): Statements before a failure keep their Result sets; the failed Statement's error is shown; later Statements don't run.
- SQL keyword/string/comment/function highlighting via the shared tokenizer — no external deps. Highlighting preserves all source whitespace, so `SELECT * FROM users` remains visibly separated.
- History persisted to `history.jsonl` in the platform state directory (plain data, one JSON object per line — see Design decisions; **not** executable Lua). One entry per **Execution** (not per Statement) — `sql` is the full buffer/selection text as run, even when multi-statement. Appended on every Execution regardless of outcome; oldest entries pruned once count exceeds `query_editor.history_limit`; entries over `query_editor.history_max_entry_bytes` truncated/flagged rather than silently dropped; the file is rewritten on each append. `Ctrl+p`/`Ctrl+n` navigate, `:history` searches by substring on `sql`. History is never executed as code.
- Arrows, Home/End, `Backspace`, `Delete`, `Enter`, `Ctrl+a/e`, `Ctrl+k/u`, and `Ctrl+l` work in the editor. Backspace accepts both the `0x08` and `0x7f` terminal encodings.
- `:` or `Esc` enters command mode from the editor. The status bar displays `[INSERT]` or `[COMMAND]` so the active mode is clear.
- In command mode, type `q` or `:q` and press `Enter` to quit. Press `Esc` to return to insert mode.
- A literal `q` typed in the editor is inserted into the Buffer and never quits the application.
- `Tab` changes focus between the sidebar, editor, and grid.

## 9. Results grid, result model, memory policy

**Result model:** distinguish `NULL`, empty string, numeric, boolean, string, and binary values explicitly. Represent SQL `NULL` as an explicit sentinel (e.g. `{ is_null = true }`), never bare Lua `nil` in a row array — bare `nil` silently breaks array length and structure. Binary values render hex-encoded; raw bytes are never written to the terminal.

**Memory policy and result-stream consumers.** The adapter's result stream has **two independent consumers**, both reading off `next_row()`:

- **Grid consumer** — materializes rows into the in-memory page buffer; stops buffering once `general.max_result_rows` is reached and reports the limit clearly. Sorting/filtering apply to the loaded (possibly capped) result. No disk-backed result storage required for Phase 1.
- **Export consumer** — `Ctrl+e` (CSV) and `Ctrl+Shift+e` (JSON) read off the row stream directly and write to the output file as rows arrive. **Not** bounded by `max_result_rows`.

The two consumers must not share a materialized buffer. If the implementation first materializes the whole result and then exports from that buffer, the memory guarantee on the grid is meaningless and a large export still costs the same memory as the grid — defeating the point. `get_result()` acquires or prepares the Result set; it is not a materialize-everything operation. Each consumer pulls what it needs from `next_row()`. Document this distinction (grid: capped, export: full) in the README so it isn't surprising.

**Driver-level buffering asymmetry.** `next_row()` is the sole logical row-pull primitive, but the adapter contract does not guarantee identical physical buffering semantics across drivers:

| Driver | Result behavior |
|---|---|
| PostgreSQL | Streaming-oriented — libpq returns results incrementally via `PQgetResult`. |
| MySQL/MariaDB | Driver materializes the entire result via `mysql_store_result()` before `next_row()` can consume rows. Result transfer from server to client is synchronous (blocks the event loop). Phase 1 documented limitation; Phase 2 may use nonblocking result-fetch APIs. |
| SQLite | Row production is driven by `sqlite3_step()` — local, blocking per step. |

`general.max_result_rows` is a **grid materialization cap** — it limits rows materialized by scry's grid consumer. It does not limit memory allocated internally by a database client library (e.g. `mysql_store_result()`) and does not cause scry to rewrite SQL with `LIMIT`. Do not claim scry never uses more than X memory for results; claim the grid never materializes more than `max_result_rows` rows itself.

**Grid behavior:**
- Default page size from `general.default_page_size`.
- Client-side paging over materialized rows: `Ctrl+f`/`Ctrl+b` next/prev page, `gg`/`G` first/last row.
- Column widths are based on column names and loaded cell values, with cell display text capped at 30 characters. Columns are padded to those widths and separated with `|`; the header is followed by a matching `-+-` separator row.
- `NULL` values render as `NULL`, empty strings remain empty, and binary values render as `[binary]`.
- `Enter` on a column header toggles asc/desc sort.
- `/` opens a case-insensitive substring row filter.
- `Ctrl+r` refreshes the current query.
- `Enter` on a data cell opens a modal with the full value.
- `H`/`L` scroll columns horizontally.
- Status bar shows page X/Y, row count, and elapsed query time.

**Export:**
- `Ctrl+e` → CSV, RFC 4180: values double-quoted when containing comma/newline/double-quote; embedded quotes escaped by doubling (`"` → `""`). NULL → empty string. UTF-8 output.
- `Ctrl+Shift+e` → JSON: NULL → JSON `null`, boolean → JSON boolean, numeric → JSON number when type info is reliable, string → JSON string, binary → encoded string. Never silently stringify every value.
- File output first; add clipboard only if a supported native command is available.
- **Export is an independent execution.** The grid and export are alternative consumers of a result stream — they never consume the same result concurrently. For Phase 1, export is permitted only when the current Execution consists of exactly one classified read-only SELECT statement (as determined by `classify_statement()`). Export re-executes that statement using a fresh result stream. Export is unavailable for non-SELECT statements, multi-statement Executions, or statements containing side-effecting functions — show a warning in these cases. This avoids the half-consumed cursor problem and the danger of re-executing writes.

## 10. Global commands and read-only enforcement

- `:` or `Esc` enters command mode from the editor. The status bar shows `[COMMAND]`; normal editing shows `[INSERT]`.
- Command mode accepts `:connect NAME`, `:quit`/`:q`, `:help`, and `:history`. The leading colon is optional because `:` is already displayed as the command prompt; `:q` and `q` therefore have the same effect.
- `Esc` exits command mode and returns to insert mode.
- A literal `q` in the editor is not a quit command and is inserted into the Buffer.
- `?` help overlay: a static modal listing the full keybinding table (§5's table — generated from one source in code, not hand-duplicated, so it can't drift from the spec). No context-sensitivity or search for MVP; both deferred to Phase 2. Closes on any keypress or `Esc`.
- `Ctrl+c` cancels the active operation when driver support permits; otherwise returns control safely

Read-only, enabled by a connection's `read_only = true` or `--read-only`:

- Red `[READ ONLY]` badge in the status bar.
- Each Statement — already boundary-clean from `src/sql/parse.split_statements()` — is classified by `src/sql/parse.classify_statement()` before execution.
- **Default-deny policy.** Allow-list: `SELECT`, `EXPLAIN`, `SHOW`, `DESCRIBE`/`DESC`, `PRAGMA`, and dialect-aware safe `SET`.
- Block (case-insensitive), anywhere in the tokenized Statement — not just as the leading keyword: `INSERT`, `UPDATE`, `DELETE`, `DROP`, `TRUNCATE`, `ALTER`, `CREATE`, `REPLACE`, `MERGE`.
- **`WITH`/CTE handling:** blanket-blocking `WITH` throws out the common case — read-only reporting CTEs — for no real safety gain, since `classify_statement()` already tokenizes the whole Statement string- and comment-aware. `classify_statement()` returns not just `{type, keyword}` but `blocked_keyword` indicating the presence of any write keyword across the tokenized Statement. `WITH x AS (SELECT ...) SELECT ...` passes (no write keyword anywhere); `WITH x AS (DELETE ...) SELECT ...` is blocked because `DELETE` shows up in the anywhere-in-Statement scan, regardless of which CTE arm it's nested in. Same protection as blocking `WITH` outright, without losing legitimate CTE-based reads.
- Document explicitly: this is client-side protection only; database-level permissions remain the authoritative safeguard.

## 11. Build, CI, docs

- `Makefile`: debug and release targets. Pins both LuaJIT (commit on the `v2.1` branch) and luasql (commit on master containing PR #201). Records the pinned SHAs in build metadata (see `build/SOURCES.txt` below) so a release is reproducible from the spec alone.

### Reproducible dependency metadata (`build/SOURCES.txt`)

The build emits a `build/SOURCES.txt` file recording the exact pin for every external dependency. A release is reproducible only if this file is preserved alongside the binary. Minimum fields:

```text
LuaJIT:
  repository = https://github.com/LuaJIT/LuaJIT
  branch     = v2.1
  commit     = <EXACT VERIFIED SHA>

LuaSQL:
  repository = https://github.com/lunarmodules/luasql
  branch     = master
  commit     = <EXACT VERIFIED SHA CONTAINING PR #201 (async-io by lvitals)>

MariaDB Connector/C:
  repository = https://github.com/mariadb-corporation/mariadb-connector-c
  version/commit = <EXACT VERIFIED VERSION OR SHA>

libpq:
  distribution = system package (e.g. libpq5 on Debian/Ubuntu, postgresql-libs on Arch)
  version = <DISTRIBUTION VERSION>

libsqlite3:
  distribution = system package (e.g. libsqlite3-0 on Debian/Ubuntu)
  version = <DISTRIBUTION VERSION>

Terminal backend:
  name = termbox2
  repository = https://github.com/termbox/termbox2
  version/commit = <PINNED VERSION (e.g. v2.5.0)>
```

Builds must resolve dependencies from these pins, not from moving branches.
- `build.sh`: strips release artifacts; targets Linux x86_64, macOS x86_64/arm64 (universal when both toolchains are present), Windows x86_64. MySQL build links against MariaDB Connector/C (mandatory for the documented async contract).
- `install.sh` for end-user install of a prebuilt binary.
- `.github/workflows/ci.yml`: builds + runs unit/parser/export/history tests and SQLite integration on Linux, macOS, Windows for PRs; Postgres/MySQL integration where a service container is available.
- `README.md` covers: prerequisites (including the luasql master pin and MariaDB Connector/C for MySQL builds); build/install (prebuilt binaries, `install.sh`, Homebrew formula sketch, AUR sketch); config guide; full keybinding table; read-only usage; supported DBs (Phase 1 vs 2); troubleshooting; tests; contributing.
- `LICENSE`: MIT.

## 12. Verification before delivery

1. Run the available build and test commands.
2. Verify: `--help`, `--version`, config loading (global + project merge), read-only classification (including CTE cases), CSV export, JSON export, history append/load/prune, SQLite execution without any external service, and the SQL splitter fuzz target.
3. Final report includes:
   - files created,
   - commands run and their results (PASS/FAIL per category),
   - measured binary size / startup P50 & P95 / idle memory (at startup, connected-idle, 100/10k/100k rows) per platform where measurable,
   - remaining platform-specific prerequisites or limitations (pinned LuaJIT commit, pinned luasql commit, MariaDB Connector/C requirement, parser nested-comment limitation, cancellation close-and-reconnect, binary-size deviations).

Keep the implementation small, readable, direct. Comment only where it explains non-obvious FFI, terminal, process-lifecycle, or SQL-safety behavior.
