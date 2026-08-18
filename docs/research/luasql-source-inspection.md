# LuaSQL Source Inspection Report

**Date**: 2026-07-17
**Files inspected**:
- `vendor/luasql/src/ls_postgres.c`
- `vendor/luasql/src/ls_mysql.c`
- `vendor/luasql/src/ls_sqlite3.c`
- `vendor/luasql/src/luasql.c`
- `vendor/luasql/src/luasql.h`

---

## 1. PostgreSQL Driver (ls_postgres.c)

### Q1: send_query() blocking

`conn_send_query()` does the following:
1. `PQsetnonblocking(conn->pg_conn, 1)` - force non-blocking mode
2. `PQsendQuery(conn->pg_conn, statement)` - enqueue the query into libpq's outgoing buffer. Returns immediately; does NOT wait for the server.
3. `PQflush(conn->pg_conn)` - flush the outgoing buffer to the socket. Returns 0 (fully flushed), 1 (still flushing), or -1 (error).

**Verdict: Non-blocking.** `PQsendQuery` is a pure enqueue operation. `PQflush` performs a non-blocking write to the socket. Neither call blocks on server response.

Returns: `true, flush_res` where `flush_res` is 0 (fully sent) or 1 (still flushing).

### Q2: poll() exact behavior

`conn_poll()` does:
1. `PQconsumeInput(conn->pg_conn)` - reads whatever data is available on the socket without blocking. Returns 0 on error.
2. `PQisBusy(conn->pg_conn)` - checks whether a complete result has been assembled.

**Verdict: One continuation step. No internal loop.** It reads one chunk of available input and checks status. Maximum work: one non-blocking socket read plus a boolean check.

### Q3: get_result() allocation

`conn_get_result()` does:
1. `PQgetResult(conn->pg_conn)` - returns the next complete `PGresult`, or NULL if no more results.

If PGRES_COMMAND_OK: pushes `atof(PQcmdTuples(res))` as a number, calls `PQclear(res)`.
If PGRES_TUPLES_OK: calls `create_cursor(L, 1, res)` which stores `res` in `cur->pg_res`.

**Verdict: Yes, materializes the entire result.** `PQgetResult()` returns a fully-formed `PGresult` containing all rows. The entire result set is in memory after this call.

### Q4: close_result() and connection state

`cur_nullify()` does:
```c
cur->closed = 1;
PQclear(cur->pg_res);
luaL_unref(L, LUA_REGISTRYINDEX, cur->conn);
luaL_unref(L, LUA_REGISTRYINDEX, cur->colnames);
luaL_unref(L, LUA_REGISTRYINDEX, cur->coltypes);
```

It calls `PQclear` on the current `PGresult`. It does **NOT** drain remaining results from the connection.

`cur_gc()` and `cur_close()` both call `cur_nullify()`.

**If consumer stops reading before EOF:**
- `cur_fetch()` only nullifies when `tuple >= PQntuples(cur->pg_res)` - i.e., all rows consumed. If the consumer calls `cur_close()` or the cursor is GC'd before all rows are read, `PQclear` is called on the current result.
- **Connection state after premature close:** For Postgres, if there are unread results in the `PQgetResult` chain (multi-statement queries, or if the result set had pending async data), `PQclear` on the current result does **NOT** leave the connection in a clean state. The connection will have unread data that must be consumed by calling `PQgetResult()` until it returns NULL before the next query can be sent.
- **Critical issue:** The driver has NO mechanism to drain remaining results on cursor close. If you close a cursor early on a connection that has pending results, the connection becomes unusable until those results are drained. There is no `conn_drain_results()` method.

### Q5: Multi-result handling

**Verdict: Not handled.** `conn_get_result()` calls `PQgetResult()` once. There is no loop, no check for additional results. For multi-statement queries or stored procedures returning multiple result sets, only the first result is returned. Subsequent results would remain unread on the connection.

There is no `nextresult()` or `hasnextresult()` method on the Postgres cursor.

### Q6: Error states

- `conn_send_query()`: `PQsendQuery` returning 0 = query rejected (could be syntax error or connection issue). `PQflush` returning -1 = socket write error (connection-level).
- `conn_poll()`: `PQconsumeInput` returning 0 = error reading from socket (typically connection lost).
- `conn_get_result()`: result status not COMMAND_OK or TUPLES_OK = query execution error.

The driver does NOT explicitly distinguish "query error" from "connection lost." Both are reported through `PQerrorMessage()`. Connection-lost errors would surface as failures in `PQsendQuery`, `PQflush`, or `PQconsumeInput`.

---

## 2. MySQL Driver (ls_mysql.c)

### Q1: send_query() blocking

`conn_send_query()` has two compile-time paths:

**With `#ifdef MYSQL_OPT_NONBLOCK`:**
```c
conn->query_started = 1;
status = mysql_real_query_start(&ret, conn->my_conn, statement, st_len);
```
This is the MariaDB/MySQL async API. Non-blocking.

**With `#else` (standard MySQL without async):**
```c
conn->query_started = 1;
ret = mysql_real_query(conn->my_conn, statement, st_len);
status = 0;
```
**This is BLOCKING.** `mysql_real_query` blocks until the query completes. `status = 0` means "done."

**Verdict: Non-blocking only when compiled with `MYSQL_OPT_NONBLOCK`. Blocking otherwise.** This is a critical difference.

Returns: `status, ret` where status is the async continuation state (0 = done).

### Q2: poll() exact behavior

**With `#ifdef MYSQL_OPT_NONBLOCK`:**
```c
status = mysql_real_query_cont(&ret, conn->my_conn, status);
```
Single continuation step. One call advances the async state machine.

**With `#else`:**
```c
ret = 0;
status = 0;
```
No-op. Always reports done (because send_query already completed synchronously).

**Verdict: One continuation step with non-blocking API. No-op without it.**

### Q3: get_result() allocation

`conn_get_result()` does:
```c
res = mysql_store_result(conn->my_conn);
```

**Yes, calls `mysql_store_result()`.** This fetches the entire result set from the server into client memory. All rows are materialized.

For non-SELECT statements (INSERT/UPDATE/DELETE), `mysql_store_result()` returns NULL and `mysql_field_count()` returns 0. The driver then pushes `mysql_affected_rows()`.

### Q4: close_result() and connection state

`cur_nullify()` does:
```c
cur->closed = 1;
mysql_free_result(cur->my_res);
luaL_unref(L, LUA_REGISTRYINDEX, cur->conn);
luaL_unref(L, LUA_REGISTRYINDEX, cur->colnames);
luaL_unref(L, LUA_REGISTRYINDEX, cur->coltypes);
```

**If consumer stops reading before EOF:**
- `cur_fetch()` nullifies when `mysql_fetch_row()` returns NULL (all rows consumed).
- If closed early, `mysql_free_result()` is called.
- After `mysql_store_result()`, ALL data is already in client memory. `mysql_free_result()` frees that memory.
- **Connection state: CLEAN.** Since `mysql_store_result()` already pulled all data from the server, the connection is in a clean state after `mysql_free_result()` regardless of how many rows were actually read. The connection is NOT "out of sync."

This is safe because the protocol-level data transfer happens during `mysql_store_result()`, not during `mysql_fetch_row()`.

### Q5: Multi-result handling

**Verdict: Fully handled.** The MySQL driver has dedicated methods:

- `cur_next_result()` / `cur.nextresult`: Calls `mysql_more_results()` to check, then `mysql_next_result()` to advance, then `mysql_store_result()` to fetch. Returns true/false.
- `cur_has_next_result()` / `cur.hasnextresult`: Calls `mysql_more_results()`.
- `conn_get_result()` also handles multi-results via the `query_started` flag:
  - First call after send_query: uses `query_started=1`, fetches first result
  - Subsequent calls: checks `mysql_more_results()`, calls `mysql_next_result()`, fetches next result

### Q6: Error states

- `cur_next_result()` explicitly distinguishes:
  - `CR_COMMANDS_OUT_OF_SYNC` - protocol desync
  - `CR_SERVER_GONE_ERROR` - server disconnected
  - `CR_SERVER_LOST` - connection lost during query
  - `CR_UNKNOWN_ERROR` - other
- `conn_ping()` specifically checks for `CR_SERVER_GONE_ERROR` to report connection status.
- `conn_get_result()`: checks `mysql_errno()` for errors after `mysql_store_result()`.

Connection-lost errors are `CR_SERVER_GONE_ERROR` and `CR_SERVER_LOST`.

### Q7: MYSQL_OPT_NONBLOCK gate

**What is gated:**

| Code path | With `MYSQL_OPT_NONBLOCK` | Without (`#else`) |
|---|---|---|
| `conn_send_query` | `mysql_real_query_start(&ret, ...)` | `ret = mysql_real_query(...); status = 0;` |
| `conn_poll` | `mysql_real_query_cont(&ret, ...)` | `ret = 0; status = 0;` |

Additionally, in `env_connect()`, there's a separate `#ifdef MARIADB_PACKAGE_VERSION` that calls:
```c
mysql_options(conn, MYSQL_OPT_NONBLOCK, 0);
```

**Without `MYSQL_OPT_NONBLOCK`:**
- `send_query` is synchronous (blocks until `mysql_real_query` returns)
- `poll` is a no-op (always returns done)
- The async protocol is completely broken - send_query blocks, poll does nothing

**Verdict: The non-blocking API is only functional when compiled against MariaDB (or MySQL with async support). Standard MySQL client libraries will get synchronous behavior despite the async method names.**

---

## 3. SQLite3 Driver (ls_sqlite3.c)

### Q1: send_query() blocking

`conn_send_query()` does:
1. Finalizes any existing `pending_vm`
2. `sqlite3_prepare_v2(conn->sql_conn, statement, -1, &vm, &tail)` - compiles SQL to bytecode
3. Optionally binds parameters
4. Stores `vm` in `conn->pending_vm`

`sqlite3_prepare_v2` is synchronous CPU work (parsing, code generation). No I/O. No network.

**Verdict: Synchronous but CPU-only.** No blocking on I/O. For SQLite, this is effectively non-blocking since there's no network roundtrip.

### Q2: poll() exact behavior

```c
static int conn_poll(lua_State *L) {
  lua_pushboolean(L, 0);
  return 1;
}
```

**Verdict: No-op. Always returns false (not busy).** SQLite has no concept of polling since everything is local.

### Q3: get_result() allocation

`conn_get_result()` does:
1. Takes `vm` from `conn->pending_vm`, sets `pending_vm = NULL`
2. `sqlite3_step(vm)` - executes ONE step
3. If SQLITE_ROW or (SQLITE_DONE with numcols > 0): creates cursor with the vm
4. If SQLITE_DONE with numcols == 0: finalizes, returns `sqlite3_changes()`

**Verdict: Does NOT materialize the entire result.** `sqlite3_step()` is called once. The cursor holds the vm, and subsequent `cur_fetch()` calls `sqlite3_step()` one row at a time. This is lazy row-by-row evaluation.

### Q4: close_result() and connection state

**Cursor lifecycle:**
- `cur_nullify()`: Sets `cur->sql_vm = NULL`, decrements `conn->cur_counter`, unrefs. Does NOT call `sqlite3_finalize()`.
- `cur_gc()`: Calls `sqlite3_finalize(cur->sql_vm)` THEN `cur_nullify()`.
- `cur_close()`: Sets `cur->closed = 1`, calls `sqlite3_finalize(cur->sql_vm)`, then `cur_nullify()`.
- `finalize()` (called from `cur_fetch` on SQLITE_DONE): Calls `sqlite3_finalize(cur->sql_vm)` then `cur_nullify()`.

**If consumer stops reading before SQLITE_DONE:**
- `cur_close()` or `cur_gc()` will call `sqlite3_finalize()`.
- Per SQLite docs, `sqlite3_finalize()` can be called at any time to destroy a prepared statement. It properly cleans up, even if execution hasn't completed.
- **Connection state: CLEAN.** The connection remains usable after `sqlite3_finalize()` on an incomplete statement.

**Additional safeguard:** `conn_data` has `cur_counter` that tracks open cursors. `conn_close()` refuses to close if `cur_counter > 0`, preventing premature connection closure with active cursors.

### Q5: Multi-result handling

**Verdict: Not applicable.** SQLite does not support multi-result sets. One statement = one result.

### Q6: Error states

- `conn_send_query()`: `sqlite3_prepare_v2` failure (SQL syntax error, etc.)
- `conn_get_result()`: `sqlite3_step` returning unexpected code (not SQLITE_ROW, SQLITE_DONE, or SQLITE_ERROR-like)
- `conn_execute()`: prepare or step failure

SQLite errors are SQL-level errors, not connection-level errors (since it's local). The code uses `sqlite3_errmsg()` for all errors. There's no connection-lost scenario for SQLite.

### Q8: SQLite getfd() hack

```c
static int conn_getfd(lua_State *L) {
  conn_data *conn = getconnection(L);
  int fd = -1;
  void *pFile = NULL;
  int res = sqlite3_file_control(conn->sql_conn, "main", SQLITE_FCNTL_FILE_POINTER, &pFile);
  if (res == SQLITE_OK && pFile) {
    /* Trick to get the FD from unixFile structure */
    fd = *((int*)((char*)pFile + 2 * sizeof(void*)));
  }
  /* Fallback: return stdin if we cannot get the real FD, or it's a memory DB */
  if (fd < 0) fd = 0;
  lua_pushinteger(L, fd);
  return 1;
}
```

**What it does:**
1. Uses `sqlite3_file_control` with `SQLITE_FCNTL_FILE_POINTER` to get a `void*` to the internal `unixFile` struct
2. Assumes the struct layout is `[vfs_methods_ptr, db_path_ptr, fd]` and reads `fd` at offset `2 * sizeof(void*)`
3. Falls back to fd=0 (stdin) if anything fails

**Assessment:**
- This is a **struct offset hack** that assumes SQLite's internal `unixFile` layout. It's not part of SQLite's public API.
- The struct layout could change between SQLite versions, causing it to read garbage.
- `SQLITE_FCNTL_FILE_POINTER` is itself a private/undocumented opcode.
- It's only used for the `getfd()` method, which is used for event-loop integration (epoll/kqueue registration).
- For memory databases (`:memory:`), the fallback to fd=0 is used.
- **Verdict: Not critical for core query functionality.** It's only needed if the Scry adapter wants to do event-loop-driven polling of the SQLite fd. For the adapter contract, this can be safely ignored - SQLite doesn't need async I/O anyway since everything is local and fast.

---

## Summary Table

| Question | PostgreSQL | MySQL | SQLite3 |
|---|---|---|---|
| **1. send_query blocks?** | No. `PQsendQuery` + `PQflush`, both non-blocking | Depends: `MYSQL_OPT_NONBLOCK` = non-blocking; `#else` = **BLOCKS** on `mysql_real_query` | Synchronous CPU-only (`sqlite3_prepare_v2`), no I/O |
| **2. poll() behavior** | One step: `PQconsumeInput` + `PQisBusy` | One step: `mysql_real_query_cont` (or no-op without `MYSQL_OPT_NONBLOCK`) | No-op. Always returns false |
| **3. get_result allocates all?** | Yes. `PQgetResult` returns complete `PGresult` | Yes. `mysql_store_result` fetches everything | No. One `sqlite3_step` call; rows fetched lazily |
| **4. Early close safe?** | **NO.** `PQclear` does NOT drain pending results. Connection may be unusable | **YES.** `mysql_free_result` is safe because `mysql_store_result` already pulled all data | **YES.** `sqlite3_finalize` cleans up incomplete statements |
| **5. Multi-result support** | **Not handled.** No nextresult method. Only first result returned | **Fully handled.** `nextresult`, `hasnextresult`, and `conn_get_result` all support it | N/A. SQLite has no multi-result |
| **6. Connection-lost detection** | No explicit check. Errors via `PQerrorMessage` only | Yes. `CR_SERVER_GONE_ERROR`, `CR_SERVER_LOST` explicitly checked | N/A. SQLite is local, no connection-lost concept |
| **7. MYSQL_OPT_NONBLOCK gate** | N/A | `send_query`: async vs sync. `poll`: continuation vs no-op | N/A |
| **8. getfd() hack** | Clean: `PQsocket()` | Clean: `mysql_get_socket()` | **Struct offset hack.** Unsafe, version-dependent. Not critical |

---

## Critical Findings for Adapter Contract

### 1. PostgreSQL early-close is unsafe (BLOCKING ISSUE)

If the grid reaches `max_result_rows` and stops reading, closing the cursor does NOT drain remaining results from the libpq connection. The next `send_query` or `get_result` call will encounter unread data and potentially fail or return stale results.

**Mitigation options:**
- Add a `conn_drain()` method that calls `PQgetResult()` in a loop until NULL
- In the adapter, always consume all rows (but this defeats `max_result_rows` purpose)
- Track pending results in the cursor and drain on close

### 2. MySQL send_query blocks without MYSQL_OPT_NONBLOCK (BLOCKING ISSUE)

If the build doesn't define `MYSQL_OPT_NONBLOCK` (standard MySQL client), `send_query` calls `mysql_real_query` which blocks the entire Lua thread until the query completes. The `poll()` method becomes a no-op.

**Mitigation:** Ensure the build uses MariaDB client library or MySQL with async support. The `#ifdef MARIADB_PACKAGE_VERSION` in `env_connect` suggests this was written for MariaDB.

### 3. SQLite getfd() is a struct-offset hack (LOW RISK)

The `getfd()` implementation assumes internal SQLite struct layout. It's only needed for event-loop integration and falls back gracefully. Can be ignored for the adapter contract unless event-loop fd-watching is required.

### 4. MySQL connection is safe after early close (GOOD)

Unlike PostgreSQL, MySQL's `mysql_store_result()` already pulled all data before the cursor is created. `mysql_free_result()` on a partially-read cursor is safe.

### 5. PostgreSQL has no multi-result support (DESIGN NOTE)

If stored procedures or multi-statement queries are needed with Postgres, the adapter would need to add draining logic. For standard single-statement queries, this is not an issue.

### 6. The `query_started` flag in MySQL driver

`conn_data.query_started` is set to 1 in `send_query()` and checked in `get_result()`. When 1, it fetches the first result. When 0, it checks `mysql_more_results()` for subsequent results. This flag is the mechanism that makes multi-result work through `conn_get_result()`.
