# Cancellation: async polling enables it, close-and-reconnect implements it

## Why async execution is the prerequisite

LuaJIT is single-threaded. A blocking `execute()` call freezes the event loop — `Ctrl+c` can never be received during a running query, because nothing is polling the keyboard. The only way to make cancellation possible at all is to run Statement execution asynchronously via LuaSQL's `send_query`/`poll`/`get_result` methods, which are exposed on all three drivers (Postgres, MySQL, SQLite).

The async polling loop (`send_query` → poll with UI input/redraw → `get_result`) is also what keeps the TUI responsive during slow queries — the user sees a "query running" indicator and can press `Ctrl+c` at any point during the poll.

## Cancellation flow

1. User presses `Ctrl+c` during the poll loop
2. An abandon flag is set (checked on next poll iteration)
3. `cancel()` closes the Connection — no raw handle extraction, no driver-specific FFI bypass, uniform across all three drivers
4. UI shows reconnect-confirmation prompt
5. On confirm, a new Connection is opened from the same Connection profile

## What stays blocking

`list_tables()`, `get_columns()`, and `ping()` are fast catalog queries — blocking is acceptable. A frozen millisecond for `SHOW TABLES` isn't the same problem as a frozen minute for `SELECT * FROM large_table`.
