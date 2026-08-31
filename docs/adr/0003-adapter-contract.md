# Adapter contract: async execution, single-Statement per call, result acquisition plus streaming row access

The adapter contract is:

```
connect(config)        → Connection
send_query(sql)        → void            (non-blocking, starts the query)
poll()                 → boolean         (returns true when result is still in flight)
state()                → string          (CONNECTING / READY / QUERYING / RESULT_READY / MATERIALIZING / FETCHING / ERROR / CANCELED / CONNECTION_LOST)
error()                → string|nil
get_result()           → result | nil    (acquire/prepare the current result; may be driver-dependent or blocking)
columns()              → column metadata (valid once state() reports columns are available)
next_row()             → row | nil       (the only row-consumption primitive; real end-of-results signal)
close_result()         → void            (release per-result client-library resources)
cancel()               → void            (closes the Connection; reconnect-confirmation flow runs)
list_tables()          → string[]        (blocking — fast catalog query)
get_columns(table)     → column metadata (blocking — fast catalog query)
ping()                 → boolean         (blocking — fast health check)
close()                → void
```

## Result acquisition and streaming row access

The contract includes `get_result()` as a result-acquisition hook. It transitions a completed Statement into Result set consumption and may perform driver-specific initialization or blocking result transfer. Consumers must not use it to materialize rows.

`next_row()` is the only row-consumption primitive. Consumers (grid, export) build whatever convenience they need on top of it themselves. This prevents a wrapper from materializing the entire Result set before the grid or export consumer gets control, preserving the grid's `max_result_rows` cap and the export's "stream straight to disk" property.

The adapter's `get_result()` may call the underlying client library's result-acquisition method, but its row contract remains streaming-only: callers consume rows through `next_row()` until it returns `nil`.

## Why async for Statement execution

LuaJIT is single-threaded. A blocking `execute(sql)` call freezes the entire event loop — no keyboard input, no UI repaint. This means:
- `Ctrl+c` cannot be detected during a running query
- The TUI shows a blank/frozen screen with no progress indicator
- Slow queries (full table scans, cross-joins) leave the user staring at nothing

So we need cooperative async execution. We get it from `lunarmodules/luasql` master (PR #201 by lvitals, merged ~Mar 2026), which added `send_query` / `poll` / `get_result` / `getfd` to all three drivers (Postgres, MySQL, SQLite3). **This is master only — luasql 2.8.1 (Feb 2026, latest tagged release) does not include these methods.** The build pins a specific commit SHA on luasql master, not a release tag.

The Execution loop drives `send_query` → `poll` (in the same tick as UI input/redraw) → `columns()` + repeated `next_row()` until `nil` → `close_result()`. `list_tables()`, `get_columns()`, and `ping()` stay blocking — they're fast catalog queries where a frozen millisecond isn't a problem.

## Per-driver async reality (not all three are equal)

- **Postgres** — cooperative network async via libpq: `PQsendQuery` + `PQsetnonblocking(1)` + `PQconsumeInput` / `PQisBusy` / `PQflush` / `PQgetResult`. This is what the Execution loop actually relies on.
- **MySQL/MariaDB** — cooperative network async for **query execution only**, when built against **luasql PR #201 + MariaDB Connector/C**. The luasql PR #201 implementation wraps MariaDB's `mysql_real_query_start`/`_cont` (gated by `MYSQL_OPT_NONBLOCK`) for the query phase. However, result retrieval uses the synchronous `mysql_store_result()` — there is no `mysql_store_result_start`/`_cont` usage. This means the query is non-blocking, but the result transfer from server to client blocks the event loop. Building against stock MySQL's libmysqlclient leaves `MYSQL_OPT_NONBLOCK` undefined and the driver silently falls back to fully synchronous `mysql_real_query`. CI builds against MariaDB Connector/C so the documented async contract is honest for this implementation. A Phase 2 improvement could use MariaDB Connector/C's nonblocking result-fetch APIs or stock MySQL's `mysql_store_result_nonblocking()`/`mysql_fetch_row_nonblocking()`.
- **SQLite** — prepare/step split; `poll` is non-networking/stubbed. `send_query` does `sqlite3_prepare_v2` only; the first `next_row()` / `get_result` (luasql-internal) does the first `sqlite3_step`; `poll` always returns `false`. No socket readiness is involved — the same cursor/row interface, but without networking-style cancellation in the middle of a long step. SQLite is local-file fast enough that this is acceptable for MVP.

Note the asymmetry: Postgres provides **cooperative network async** (the FD drives readiness, `poll()` reports it) for both query execution and result retrieval. MySQL/MariaDB provides **cooperative network async for query execution only** — result materialization via `mysql_store_result()` blocks. SQLite provides only a **prepare/step split**. Cancellation across all three goes through close-and-reconnect (see ADR-0004).

## Statement execution model

Each Statement in an Execution follows this cycle:

1. `send_query(sql)` — starts the query non-blocking (one Statement at a time; the Execution loop owns splitting via `sql.parse.split_statements()`)
2. Loop: `poll()` — if still in flight, process UI input/redraw and check the abandon flag
3. `columns()` — once `poll()` reports done and `state()` is `FETCHING`/`READY`, fetch column metadata
4. Loop: `next_row()` — pull rows until `nil` (real end-of-results)
5. `close_result()` — release the per-result client-library resources

`send_query(sql)` accepts exactly one Statement. The Execution loop (not the adapter) owns multi-Statement splitting via `sql.parse.split_statements()`. This matches luasql's cursor model.

`BEGIN`, `COMMIT`, `ROLLBACK` are just Statements. The adapter exposes no transaction API. Auto-transaction wrapping was rejected because it would require the adapter to decide when to roll back on mid-buffer failure — the ambiguity halt-on-first was chosen to avoid.

## `close_result()` is mandatory

The cursor / prepared statement holds client-library resources until released:
- SQLite: `sqlite3_finalize` on the prepared statement
- Postgres: `PQclear` on the `PGresult`, plus any remaining result chain from the cursor
- MariaDB: `mysql_free_result` on the result set (safe — `mysql_store_result` already pulled all data; connection is clean after free)

Leaking `close_result()` across many Executions accumulates server-side state and eventually fails. Every consumer (grid, export, error path) must call `close_result()` when it's done with the row stream, even on early termination. After `close_result()`, further `next_row()` calls on the same Result set are undefined.

## Cancellation during polling

`Ctrl+c` during the poll loop sets an abandon flag. The next poll iteration detects it, calls `cancel()` which closes the Connection, and the reconnect-confirmation flow runs. No raw handle extraction needed — uniform across all three drivers. See ADR-0004.
