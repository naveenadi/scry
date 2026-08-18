# Adapter contract: async execution, single-Statement per call, no transaction API

The adapter contract is:

```
connect(config)        → Connection
send_query(sql)        → void            (non-blocking, starts the query)
poll()                 → boolean         (returns true when result is ready)
get_result()           → Result set      (retrieves the completed result)
cancel()               → void            (abandons current query, closes connection)
list_tables()          → string[]        (blocking — fast catalog query)
get_columns(table)     → column metadata (blocking — fast catalog query)
ping()                 → boolean         (blocking — fast health check)
close()                → void
```

## Why async for Statement execution

LuaJIT is single-threaded. A blocking `execute(sql)` call freezes the entire event loop — no keyboard input, no UI repaint. This means:
- `Ctrl+c` cannot be detected during a running query
- The TUI shows a blank/frozen screen with no progress indicator
- Slow queries (full table scans, cross-joins) leave the user staring at nothing

LuaSQL exposes `send_query`/`poll`/`get_result` on all three drivers. The Execution loop drives these in the same tick as UI input and redraw. `list_tables()`, `get_columns()`, and `ping()` stay blocking — they're fast catalog queries where a frozen millisecond isn't a problem.

## Statement execution model

Each Statement in an Execution follows this cycle:

1. `send_query(sql)` — starts the query non-blocking
2. Loop: `poll()` — check if result is ready; if not, process UI input/redraw
3. `get_result()` — retrieve the completed Result set

`send_query(sql)` accepts exactly one Statement. The Execution loop (not the adapter) owns multi-Statement splitting via `sql_parse.split_statements()`. This matches LuaSQL's cursor model.

`BEGIN`, `COMMIT`, `ROLLBACK` are just Statements. The adapter exposes no transaction API. Auto-transaction wrapping was rejected because it would require the adapter to decide when to roll back on mid-buffer failure — the ambiguity halt-on-first was chosen to avoid.

## Cancellation during polling

`Ctrl+c` during the poll loop sets an abandon flag. The next poll iteration detects it, calls `cancel()` which closes the Connection, and the reconnect-confirmation flow runs. No raw handle extraction needed — uniform across all three drivers. See ADR-0004.
