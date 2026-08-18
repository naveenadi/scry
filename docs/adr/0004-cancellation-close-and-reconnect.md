# Cancellation: async polling enables it, close-and-reconnect implements it

## Why async execution is the prerequisite

LuaJIT is single-threaded. A blocking `execute()` call freezes the event loop — `Ctrl+c` can never be received during a running query, because nothing is polling the keyboard. The only way to make cancellation possible at all is cooperative async execution, which we get from `lunarmodules/luasql` master (PR #201, pinned to a commit SHA — see ADR-0003 for the per-driver reality).

The async polling loop (`send_query` → `poll` with UI input/redraw → `columns()` + repeated `next_row()` until `nil` → `close_result()`) is also what keeps the TUI responsive during slow queries — the user sees a "query running" indicator and can press `Ctrl+c` at any point during the poll.

## Cancellation flow

1. User presses `Ctrl+c` during the poll loop
2. An abandon flag is set (checked on next poll iteration)
3. `cancel()` closes the Connection — no raw handle extraction, no driver-specific FFI bypass, uniform across all three drivers
4. UI shows reconnect-confirmation prompt
5. On confirm, a new Connection is opened from the same Connection profile

## Why close-and-reconnect instead of driver-native cancel

The "real" cancel paths exist in each client library: libpq's `PQcancel`, MySQL/MariaDB's `mysql_kill` (and `_cont` flow), SQLite's `sqlite3_interrupt(db)`. They are not used because:

- `PGconn` / `MYSQL` / `sqlite3*` are version-dependent userdata structs buried inside luasql's connection metatable. Reaching into them via LuaJIT FFI is a fragile per-driver version-pin that costs more code than the value it adds.
- LuaJIT is single-threaded. Closing the Connection and reopening it is uniform, simple, and the reconnect-confirmation flow already handles lost connections. We don't need finer-grained cancel; "abandon and reconnect" is the same user-visible behavior.

The tradeoff is one wasted Connection open per cancellation, which is acceptable.

## What stays blocking

`list_tables()`, `get_columns()`, and `ping()` are fast catalog queries — blocking is acceptable. A frozen millisecond for `SHOW TABLES` isn't the same problem as a frozen minute for `SELECT * FROM large_table`.

## SQLite note

luasql master `ls_sqlite3.c`'s `poll()` is a stub that always returns `false`. SQLite still benefits from the `send_query` / first-`next_row()` split (luasql-internal `get_result` does `sqlite3_prepare_v2` then `sqlite3_step` separately, so the cancel-check happens between prepare and step), and `sqlite3_interrupt` would be reachable via FFI in Phase 2 if mid-step cancellation turns out to matter for very long-running SQLite operations.
