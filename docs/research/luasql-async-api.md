# LuaSQL Async API — Per-Driver Source Analysis

Research date: 2026-04-16. Source: `vendor/luasql/src/` (PR #201 async-io by lvitals).

## Summary table

| Method | Postgres | MySQL | SQLite3 |
|---|---|---|---|
| `send_query(sql)` | `PQsendQuery` + `PQflush` | `mysql_real_query_start` (MariaDB) or sync fallback | `sqlite3_prepare_v2` only |
| `poll(...)` | `PQconsumeInput` / `PQisBusy` | `mysql_real_query_cont` (needs status arg) | Stub: always returns `false` |
| `get_result()` | `PQgetResult` → cursor or count | `mysql_store_result` → cursor or count | `sqlite3_step` (first) → cursor or count |
| `getfd()` | `PQsocket` | `mysql_get_socket` | Unsafe struct-offset hack |
| Async quality | Real cooperative network | Real cooperative (MariaDB only) | Prepare/step split, no network |
| `poll()` signature | `conn:poll() → boolean` | `conn:poll(status) → boolean, int` | `conn:poll() → boolean` |

## 1. PostgreSQL (`ls_postgres.c`)

### Registered methods (connection metatable)

```c
{"getfd",         conn_getfd},
{"send_query",    conn_send_query},
{"poll",          conn_poll},
{"get_result",    conn_get_result},
```

### `conn:getfd()` → `integer`

```c
static int conn_getfd (lua_State *L) {
    conn_data *conn = getconnection (L);
    int fd = PQsocket(conn->pg_conn);
    if (fd < 0) return luasql_failmsg(L, "invalid socket descriptor", NULL);
    lua_pushinteger(L, fd);
    return 1;
}
```

Returns the libpq socket FD via `PQsocket`. Error if fd < 0 (connection lost).

### `conn:send_query(statement)` → `boolean, integer`

```c
static int conn_send_query (lua_State *L) {
    conn_data *conn = getconnection (L);
    const char *statement = luaL_checkstring (L, 2);
    PQsetnonblocking(conn->pg_conn, 1);
    if (PQsendQuery(conn->pg_conn, statement) == 0) {
        return luasql_failmsg(L, "error sending query. PostgreSQL: ", PQerrorMessage(conn->pg_conn));
    }
    int flush_res = PQflush(conn->pg_conn);
    if (flush_res == -1) {
        return luasql_failmsg(L, "error flushing query. PostgreSQL: ", PQerrorMessage(conn->pg_conn));
    }
    lua_pushboolean(L, 1);
    lua_pushinteger(L, flush_res); /* 0 = flushed, 1 = still flushing */
    return 2;
}
```

- Forces non-blocking mode (`PQsetnonblocking(1)`) before every send.
- Sends via `PQsendQuery`, then flushes via `PQflush`.
- Returns `true, 0` (fully sent) or `true, 1` (still flushing to socket).
- Error returns `nil, errmsg`.

### `conn:poll()` → `boolean`

```c
static int conn_poll (lua_State *L) {
    conn_data *conn = getconnection (L);
    if (PQconsumeInput(conn->pg_conn) == 0) {
        return luasql_failmsg(L, "error polling input. PostgreSQL: ", PQerrorMessage(conn->pg_conn));
    }
    lua_pushboolean(L, PQisBusy(conn->pg_conn));
    return 1;
}
```

- Reads available data from the socket via `PQconsumeInput`.
- Returns `true` if query still running (`PQisBusy`), `false` if results are ready.
- **No parameters needed** — libpq internally manages non-blocking state.

### `conn:get_result()` → `cursor | number | nil`

```c
static int conn_get_result (lua_State *L) {
    conn_data *conn = getconnection (L);
    PGresult *res = PQgetResult(conn->pg_conn);
    if (!res) { lua_pushnil(L); return 1; }
    if (PQresultStatus(res) == PGRES_COMMAND_OK) {
        lua_pushnumber(L, atof(PQcmdTuples(res)));
        PQclear(res); return 1;
    }
    else if (PQresultStatus(res) == PGRES_TUPLES_OK) {
        return create_cursor(L, 1, res);
    }
    else {
        const char *err = PQresultErrorMessage(res);
        PQclear(res);
        return luasql_failmsg(L, "error retrieving result. PostgreSQL: ", err);
    }
}
```

- Calls `PQgetResult` (returns next result in chain, or NULL when done).
- `PGRES_COMMAND_OK` → returns affected row count (number).
- `PGRES_TUPLES_OK` → returns cursor object (has `fetch`, `getcolnames`, `getcoltypes`, `numrows`, `close`).
- Error status → returns `nil, errmsg`.
- `nil` return means no more results (call after cursor is consumed or for commands).

### How the async loop works (Postgres)

```
conn:send_query("SELECT ...")     -- PQsendQuery + PQflush, non-blocking
repeat
    local busy = conn:poll()       -- PQconsumeInput + PQisBusy
until not busy
local result = conn:get_result()  -- PQgetResult → cursor
-- iterate cursor:cursor:fetch() for rows
cursor:close()                     -- PQclear
```

**True cooperative network async.** The FD from `getfd()` can be registered with an event loop (epoll/kqueue/poll); `poll()` is called when the socket is readable. This is the gold standard the Execution loop depends on.

### Connection defaults

`create_connection` sets `PQsetnonblocking(pg_conn, 1)` at creation time. The synchronous `conn_execute` forces `PQsetnonblocking(0)` before `PQexec`, then the connection stays blocking until the next `send_query` call resets it.

---

## 2. MySQL (`ls_mysql.c`)

### Registered methods (connection metatable)

```c
{"getfd",         conn_getfd},
{"send_query",    conn_send_query},
{"poll",          conn_poll},
{"get_result",    conn_get_result},
```

### `conn:getfd()` → `integer`

```c
static int conn_getfd (lua_State *L) {
    conn_data *conn = getconnection (L);
    int fd = mysql_get_socket(conn->my_conn);
    if (fd < 0) return luasql_failmsg(L, "invalid socket descriptor", NULL);
    lua_pushinteger(L, fd);
    return 1;
}
```

Returns the MySQL connection socket via `mysql_get_socket`.

### `conn:send_query(statement)` → `integer, integer`

```c
static int conn_send_query (lua_State *L) {
    conn_data *conn = getconnection (L);
    size_t st_len;
    const char *statement = luaL_checklstring (L, 2, &st_len);
    int status, ret;
    conn->query_started = 1;
#ifdef MYSQL_OPT_NONBLOCK
    status = mysql_real_query_start(&ret, conn->my_conn, statement, st_len);
#else
    ret = mysql_real_query(conn->my_conn, statement, st_len);
    status = 0;
#endif
    lua_pushinteger(L, status);
    lua_pushinteger(L, ret);
    return 2;
}
```

- Sets `query_started = 1` flag (used by `get_result`).
- **With `MYSQL_OPT_NONBLOCK` (MariaDB Connector/C):** calls `mysql_real_query_start(&ret, conn, stmt, len)`. Returns `status` (MariaDB async status bitmask: `MYSQL_WAIT_READ | MYSQL_WAIT_WRITE | MYSQL_WAIT_EXCEPT`) and `ret` (0 = started, error code otherwise).
- **Without `MYSQL_OPT_NONBLOCK` (stock MySQL):** falls back to **synchronous** `mysql_real_query`. Returns `status = 0` (meaning "done immediately").
- The `status` value is critical — the caller must pass it to `poll()`.

### `conn:poll(status)` → `boolean, integer`

```c
static int conn_poll (lua_State *L) {
    conn_data *conn = getconnection (L);
    int status = luaL_checkinteger(L, 2);
    int ret;
#ifdef MYSQL_OPT_NONBLOCK
    status = mysql_real_query_cont(&ret, conn->my_conn, status);
#else
    ret = 0; status = 0;
#endif
    lua_pushboolean(L, status != 0);
    lua_pushinteger(L, status);
    return 2;
}
```

- **Takes an integer argument** (`status`) — the socket readiness flags from the event loop (matching what `send_query` or a previous `poll` returned).
- **With `MYSQL_OPT_NONBLOCK`:** calls `mysql_real_query_cont(&ret, conn, status)`. Returns `true` if still running (status != 0), plus the new status.
- **Without `MYSQL_OPT_NONBLOCK`:** always returns `false, 0` (sync fallback — query already completed in `send_query`).
- **Signature mismatch with Postgres:** `poll()` takes a parameter here. The Lua adapter must store the status from `send_query`/previous `poll` and pass it back.

### `conn:get_result()` → `cursor | number | nil`

```c
static int conn_get_result (lua_State *L) {
    conn_data *conn = getconnection (L);
    MYSQL_RES *res = NULL;
    short has_result = 0;

    if (conn->query_started) {
        conn->query_started = 0;
        res = mysql_store_result(conn->my_conn);
        has_result = 1;
    } else {
        if (mysql_more_results(conn->my_conn)) {
            int ret = mysql_next_result(conn->my_conn);
            if (ret == 0) {
                res = mysql_store_result(conn->my_conn);
                has_result = 1;
            } else if (ret > 0) {
                return luasql_failmsg(L, "...", mysql_error(conn->my_conn));
            }
        }
    }
    if (!has_result) { lua_pushnil(L); return 1; }
    unsigned int num_cols = mysql_field_count(conn->my_conn);
    if (res) {
        return create_cursor(L, conn->my_conn, 1, res, num_cols);
    } else {
        if (num_cols == 0) {
            if (mysql_errno(conn->my_conn))
                return luasql_failmsg(L, "...", mysql_error(conn->my_conn));
            lua_pushnumber(L, mysql_affected_rows(conn->my_conn));
            return 1;
        } else
            return luasql_failmsg(L, "...", mysql_error(conn->my_conn));
    }
}
```

- Uses `query_started` flag to decide path: first call after `send_query` → `mysql_store_result`; subsequent calls → `mysql_more_results` / `mysql_next_result`.
- `mysql_store_result` **materializes the entire result set into client memory**. This is a blocking call for large results — a design tension with Scry's streaming contract.
- SELECT → cursor. Non-SELECT → affected row count. No more results → nil.
- Supports multi-result sets (stored procedures, multi-statement).

### How the async loop works (MySQL/MariaDB)

```
local status, ret = conn:send_query("SELECT ...")
while status ~= 0 do
    -- event loop: wait for socket readiness matching status flags
    local ready_flags = wait_for_socket(conn:getfd(), status)
    local busy, new_status = conn:poll(ready_flags)
    status = new_status
end
local result = conn:get_result()  -- mysql_store_result (BLOCKING)
-- iterate cursor:fetch() for rows
cursor:close()                     -- mysql_free_result
```

**Cooperative network async for query execution** (MariaDB only). But `get_result()` is still blocking — it calls `mysql_store_result` which reads the entire result set. The async benefit is limited to the query phase, not result retrieval.

### Conditional compilation

The `MYSQL_OPT_NONBLOCK` macro gates all async code:
- **Defined by:** MariaDB Connector/C (via `MARIADB_PACKAGE_VERSION`).
- **Not defined by:** stock MySQL `libmysqlclient`.
- The connection setup calls `mysql_options(conn, MYSQL_OPT_NONBLOCK, 0)` only when `MARIADB_PACKAGE_VERSION` is defined.

Without MariaDB Connector/C: `send_query` does a blocking `mysql_real_query`, `poll` always returns `false, 0`, `get_result` works normally. The async methods exist but are synchronous stubs.

---

## 3. SQLite3 (`ls_sqlite3.c`)

### Registered methods (connection metatable)

```c
{"getfd",         conn_getfd},
{"send_query",    conn_send_query},
{"poll",          conn_poll},
{"get_result",    conn_get_result},
```

### `conn:getfd()` → `integer`

```c
static int conn_getfd (lua_State *L) {
    conn_data *conn = getconnection (L);
    int fd = -1;
    void *pFile = NULL;
    int res = sqlite3_file_control(conn->sql_conn, "main", SQLITE_FCNTL_FILE_POINTER, &pFile);
    if (res == SQLITE_OK && pFile) {
        fd = *((int*)((char*)pFile + 2 * sizeof(void*)));
    }
    if (fd < 0) fd = 0;
    lua_pushinteger(L, fd);
    return 1;
}
```

- Uses `sqlite3_file_control` with `SQLITE_FCNTL_FILE_POINTER` to get the internal file object.
- **Unsafe struct offset hack:** dereferences `(char*)pFile + 2 * sizeof(void*)` assuming the FD is at that offset in the `unixFile` struct. This is version-dependent and will break if SQLite's internal layout changes.
- Fallback: returns `0` (stdin) for memory DBs or if extraction fails. Returns `0` silently rather than erroring.

### `conn:send_query(statement)` → `boolean`

```c
static int conn_send_query (lua_State *L) {
    conn_data *conn = getconnection (L);
    const char *statement = luaL_checkstring (L, 2);
    sqlite3_stmt *vm;
    const char *tail;
    int res;

    if (conn->pending_vm) {
        sqlite3_finalize(conn->pending_vm);
        conn->pending_vm = NULL;
    }

    res = sqlite3_prepare_v2(conn->sql_conn, statement, -1, &vm, &tail);
    if (res != SQLITE_OK) {
        return luasql_faildirect(L, sqlite3_errmsg(conn->sql_conn));
    }

    /* Bind parameters (if any) from arg 3+ */
    /* ... (supports table or positional args) ... */

    conn->pending_vm = vm;
    lua_pushboolean(L, 1);
    return 1;
}
```

- Calls `sqlite3_prepare_v2` only — **no execution**. Pure SQL parsing and compilation.
- Stores the prepared VM in `conn->pending_vm` (a staging field added by PR #201).
- Finalizes any previous `pending_vm` first (prevents leaks).
- Supports parameter binding (table or positional args, same as `conn_execute`).
- Returns `true` on success, `nil, errmsg` on error.

### `conn:poll()` → `boolean`

```c
static int conn_poll (lua_State *L) {
    lua_pushboolean(L, 0);
    return 1;
}
```

**Hardcoded stub.** Always returns `false`. No parameters. Does nothing.

### `conn:get_result()` → `cursor | number | nil`

```c
static int conn_get_result (lua_State *L) {
    conn_data *conn = getconnection (L);
    if (!conn->pending_vm) {
        lua_pushnil(L);
        return 1;
    }
    sqlite3_stmt *vm = conn->pending_vm;
    conn->pending_vm = NULL;

    int res = sqlite3_step(vm);
    int numcols = sqlite3_column_count(vm);

    if ((res == SQLITE_ROW) || ((res == SQLITE_DONE) && numcols)) {
        return create_cursor(L, 1, conn, vm, numcols);
    }
    if (res == SQLITE_DONE) {
        sqlite3_finalize(vm);
        lua_pushnumber(L, sqlite3_changes(conn->sql_conn));
        return 1;
    }
    const char *errmsg = sqlite3_errmsg(conn->sql_conn);
    sqlite3_finalize(vm);
    return luasql_faildirect(L, errmsg);
}
```

- Takes `pending_vm` from `send_query`, clears the staging field.
- Calls `sqlite3_step(vm)` — this is where actual execution happens. **Blocking for the duration of the first step.**
- `SQLITE_ROW` or `SQLITE_DONE` with columns → creates cursor (cursor has `first_fetch = 1`, so the already-stepped row is returned on first `fetch` call).
- `SQLITE_DONE` with no columns (INSERT/UPDATE/DELETE) → returns affected row count via `sqlite3_changes`.
- Error → returns `nil, errmsg`.

### How the async "loop" works (SQLite)

```
conn:send_query("SELECT ...")    -- sqlite3_prepare_v2 only
-- poll() is a no-op, skip it
local result = conn:get_result() -- sqlite3_step (BLOCKING)
-- iterate cursor:fetch() for rows (each fetch = sqlite3_step)
cursor:close()                    -- sqlite3_finalize
```

**Not truly async.** The prepare/step split only separates SQL parsing from execution. `sqlite3_step` in `get_result` blocks the event loop. For local-file queries this is fast enough; for pathological queries (recursive CTEs over large DBs), cancellation latency = the remaining step time.

The `pending_vm` field in `conn_data` is the key PR #201 addition for SQLite — it holds the prepared statement between `send_query` and `get_result`, enabling the two-call pattern.

---

## 4. Async API contract: ADR-0003 vs luasql reality

### Method mapping

| ADR-0003 contract | luasql underlying | Gap |
|---|---|---|
| `send_query(sql)` | `conn:send_query(sql)` | Direct. |
| `poll()` | `conn:poll()` (PG, SQLite) or `conn:poll(status)` (MySQL) | MySQL requires passing socket readiness flags. Adapter must store state. |
| `next_row()` | `cursor:fetch()` | Direct. Cursor is obtained from `get_result()`. |
| `columns()` | `cursor:getcolnames()` + `cursor:getcoltypes()` | Two calls needed, not one. |
| `close_result()` | `cursor:close()` | Direct. Maps to `PQclear` (PG), `mysql_free_result` (MySQL), `sqlite3_finalize` (SQLite). |
| `state()` | Nothing | **Must be implemented in the Lua adapter.** State machine is not in luasql. |
| `error()` | Error return values (`nil, errmsg`) | Adapter must capture and store. |
| `cancel()` | Nothing | **Must be implemented.** Strategy: close the connection (see ADR-0004). |
| `list_tables()` | Nothing | **Must be implemented.** Blocking catalog query per driver. |
| `get_columns(table)` | Nothing | **Must be implemented.** Blocking catalog query per driver. |
| `ping()` | MySQL has `conn:ping()` | PG/SQLite: adapter must implement. MySQL: `conn_ping` exists but not on the async path. |

### Key gaps the Lua adapter must bridge

1. **State machine** — luasql has no `state()`. The adapter tracks transitions: `READY → QUERYING` (on `send_query`) → `FETCHING` (on `get_result` returns cursor) → `READY` (on `next_row()` returns nil). Error states from `nil, errmsg` returns.

2. **MySQL `poll()` signature mismatch** — MySQL's `poll` takes an integer (socket readiness flags from the event loop). The adapter must:
   - Capture `status` from `send_query`'s second return value.
   - After each `poll` call, capture the new `status` from the second return.
   - Pass it to the next `poll` call.
   - Interpret `status == 0` as "done" (same as `poll` returning `false`).

3. **MySQL `get_result()` is blocking** — `mysql_store_result` materializes the entire result. The adapter cannot stream rows from the server; it can only stream from the materialized `MYSQL_RES` via `cursor:fetch()`. This is acceptable for MVP but defeats the streaming intent for very large results.

4. **SQLite `get_result()` is blocking** — `sqlite3_step` runs synchronously. The only "async" benefit is that `send_query` (prepare) is fast and non-blocking, so the UI is responsive between pressing Ctrl+r and the first step.

5. **SQLite `getfd()` is unreliable** — The struct offset hack is fragile. For event-loop integration, the adapter should treat SQLite as "poll returns false → call get_result immediately" and not actually select() on the FD.

6. **`get_result()` is internal to luasql, not in the Scry contract** — ADR-0003 explicitly says there is no `get_result()` method in the adapter contract. The adapter calls it internally after `poll()` returns `false`, then exposes rows via `next_row()` (wrapping `cursor:fetch()`).

7. **Error handling differs** — Postgres/MySQL return `nil, luasql_prefix .. driver_error`. SQLite returns `nil, driver_error` directly (via `luasql_faildirect`). The adapter must normalize.

8. **Cursor lifetime** — Postgres cursor wraps `PGresult`; MySQL cursor wraps `MYSQL_RES`; SQLite cursor wraps `sqlite3_stmt`. All three require explicit close (`PQclear`, `mysql_free_result`, `sqlite3_finalize`). Leaking causes server-side resource accumulation.

### Per-driver event-loop integration summary

**Postgres:**
```
send_query(sql) → poll loop (check PQisBusy via socket FD readiness) → get_result → fetch loop
```
Genuinely cooperative. The event loop can `select()`/`epoll()` on the FD from `getfd()`.

**MySQL (MariaDB Connector/C):**
```
send_query(sql) → [store status] → poll loop (pass status flags from event loop) → get_result (blocking store) → fetch loop
```
Cooperative for query execution. `get_result` is blocking. The adapter must thread `status` through `poll` calls.

**MySQL (stock libmysqlclient):**
```
send_query(sql) [blocking] → get_result → fetch loop
```
Fully synchronous. `poll` is a no-op. Async methods exist but are wrappers around blocking calls.

**SQLite:**
```
send_query(sql) [prepare only] → get_result [blocking step] → fetch loop
```
Not async. Prepare/step split gives UI responsiveness between Ctrl+r and first step only.

---

## 5. Discrepancies vs scry-spec.md and ADR-0003

| Issue | Severity | Details |
|---|---|---|
| MySQL `poll()` takes a parameter | Medium | Spec contract says `poll()` with no args. Adapter must bridge the `status` parameter. Not a bug — a design gap between luasql's API and the abstract contract. |
| MySQL `get_result` is blocking | Medium | `mysql_store_result` materializes all rows. The spec's streaming `next_row()` model works (rows come from the materialized `MYSQL_RES`) but server-side streaming is lost. Documented in ADR-0003 as acceptable. |
| SQLite `getfd()` is a hack | Low | Struct offset arithmetic is version-dependent. The adapter should not rely on this FD for event-loop integration — use the "poll returns false" shortcut instead. |
| SQLite `poll` is a stub | Low (documented) | Expected. Spec and ADR both document this. No event-loop readiness — just a prepare/step split. |
| `MARIADB_PACKAGE_VERSION` gate | Medium | Async code only compiles with MariaDB Connector/C. Stock MySQL builds get sync fallback silently. CI must build against MariaDB. |
| `conn_data.query_started` flag (MySQL) | Low | Internal bookkeeping for `get_result`. Not visible to Lua callers. |
| SQLite `pending_vm` staging field | Low | Internal to the prepare/step split. PR #201 addition, not in stock luasql. |
| No `state()`, `error()`, `columns()` in luasql | Expected | These are Scry adapter-layer abstractions. The adapter builds them on top of luasql's primitive return values. |
| `conn_execute` vs `conn_send_query` coexist | Info | All three drivers retain the synchronous `execute` method alongside the async methods. The Scry adapter uses only the async path. |
| Postgres: non-blocking set on every `send_query` | Info | `PQsetnonblocking(1)` is called every time. Idempotent but redundant if already non-blocking. |
