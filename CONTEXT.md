# Scry

Scry is a terminal SQL client for querying configured relational databases.

## Language

**Connection profile**:
A named configuration entry in the config file defining how to establish a database connection (host, port, credentials, SSH tunnel, read-only flag).
_Avoid_: connection config, database config

**Connection**:
A live client session to a database, created from a connection profile. Never use "connection" to mean the profile.
_Avoid_: profile, datasource

**Buffer**:
The editor's full text content for one editing session. Contains one or more Statements separated by semicolons.
_Avoid_: editor text, query text

**Selection**:
A contiguous range within the Buffer. When present, `Ctrl+r` scopes execution to the Selection instead of the full Buffer.
_Avoid_: selected text, highlight

**Statement**:
One syntactically complete SQL command extracted from the Buffer by the statement splitter. The unit the adapter receives and the read-only classifier checks.
_Avoid_: query, SQL command

**Execution**:
One `Ctrl+r` press. Runs one or more Statements from the Buffer (or Selection) using an async poll loop (`send_query` → poll with UI redraw → `columns()` + repeated `next_row()` until `nil` → `close_result()`). Halts on first failure but surfaces all prior Result sets. `Ctrl+c` during the poll loop cancels via close-and-reconnect (see ADR-0004). The adapter contract exposes `next_row()` only — no `get_result()`-style materialize-everything method, by design (see ADR-0003).
_Avoid_: query execution, run

**Result set**:
The tabular rows returned by one Statement. Rows model `NULL` as an explicit `{ is_null = true }` sentinel — never bare Lua `nil`, which silently breaks array length. Binary values render hex-encoded.
_Avoid_: query result, grid

**Page**:
A contiguous slice of a Result set displayed in the grid at one time, sized by `general.default_page_size`. Paging is client-side over materialized rows, which are themselves capped by `general.max_result_rows`. Export (`Ctrl+e` CSV, `Ctrl+Shift+e` JSON) is **not** bounded by `max_result_rows` — it streams off the adapter's `next_row()` for the full result.
_Avoid_: page of results

**History**:
A list of past Executions persisted to `history.jsonl` in the platform state directory as plain data (one JSON object per line). Not executable Lua — runtime-generated, never hand-authored, so loading it back as code would be a self-inflicted code-execution surface for no benefit. One entry per Execution (full buffer/selection text, even multi-statement), appended regardless of outcome.
