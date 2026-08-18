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
One `Ctrl+r` press. Runs one or more Statements from the Buffer (or Selection) using an async poll loop (`send_query` → poll with UI redraw → `get_result`). Halts on first failure but surfaces all prior Result sets. `Ctrl+c` during the poll loop cancels via close-and-reconnect.
_Avoid_: query execution, run

**Result set**:
The tabular rows returned by one Statement.
_Avoid_: query result, grid

**Page**:
A contiguous slice of a Result set displayed in the grid at one time, sized by `general.default_page_size`. Paging is client-side over already-materialized rows.
_Avoid_: page of results
