# Spec Claims Verification Report

Verified 2026-08-21. Primary sources only; no blog posts as primary evidence.

---

## 1. luasql PR #201 — async-io by lvitals

**Claim:** PR #201 on lunarmodules/luasql master adds `send_query`/`poll`/`get_result`/`getfd` to Postgres, MySQL, and SQLite3 drivers.

**Verdict: Confirmed with nuance**

- **PR exists:** Yes. Author: Leandro Vital (lvitals). Branch: `lvitals/async-io`.
- **Merged:** Yes. OpenHub commit log shows "Merge pull request #201 from lvitals/async-io" merged by Tomás Guisasola approximately 5 months before August 2026 (i.e., ~March 2026). Subsequent PRs (#212, etc.) from the same author were also merged after #201.
- **What it adds:** 11 commits covering:
  - Postgres: `getfd`, `send_query`, `consume_input`, `is_busy`, `get_result` methods
  - MySQL: `getfd`, `send_query`, `query_cont`, `get_result` methods; `MYSQL_OPT_NONBLOCK` in `env_connect`; MariaDB `_start`/`_cont` API when available, with fallback for standard MySQL
  - SQLite3: `getfd`, `send_query`, `get_result` methods; `pending_vm` for prepared statements across async calls; file descriptor via `SQLITE_FCNTL_FILE_POINTER`
- **Nuance:** The method name in SQLite is not exactly `poll` in the original PR — a later commit "unify async API with common 'poll' method" was added per-driver. The unified `poll` method was added as a separate commit in the same PR.

**Sources:**
- https://github.com/lunarmodules/luasql/pull/201 (PR page, commit messages)
- https://openhub.net/p/luasql/commits (commit log confirming merge)

---

## 2. MySQL async requires MariaDB Connector/C

**Claim:** Building luasql's MySQL driver against stock libmysqlclient (MySQL's own C client) cannot provide the MariaDB `_start`/`_cont` nonblocking path, causing the driver to fall back to synchronous `mysql_real_query`.

**Verdict: Partially confirmed — needs correction on mechanism**

- **MYSQL_OPT_NONBLOCK in stock MySQL:** It IS present in MySQL's `mysql.h` enum (value after `MYSQL_PROGRESS_CALLBACK=5999`), but labeled as `/* MariaDB options */` in the header. It exists for ABI compatibility but is not functionally equivalent to MariaDB's implementation.
- **The real incompatibility:** Stock MySQL 8.0.16+ provides its own async API with `_nonblocking` suffix functions (`mysql_real_query_nonblocking()`, `mysql_store_result_nonblocking()`), NOT the `_start`/`_cont` pattern that MariaDB Connector/C uses. The luasql PR #201 wraps MariaDB's `mysql_real_query_start`/`mysql_real_query_cont`, which are NOT available in stock MySQL's libmysqlclient.
- **Initialization requirement:** MariaDB's documented activation sequence calls `mysql_options(mysql, MYSQL_OPT_NONBLOCK, 0)` before `mysql_real_connect()`. The nonblocking API returns wait-status flags; callers continue with the `_cont` function and handle `MYSQL_WAIT_TIMEOUT` using `mysql_get_timeout_value()` before retrying.
- **Fallback behavior:** The PR commit message confirms: "Used MariaDB non-blocking API (`_start`, `_cont`) when available. Provided fallback for standard MySQL." The fallback is synchronous `mysql_real_query`.
- **Correction to spec:** `MYSQL_OPT_NONBLOCK` is present in stock MySQL's enum for compatibility, but the MariaDB `_start`/`_cont` symbols are absent from stock `libmysqlclient`. The functional result is the same (sync fallback), but the mechanism is missing API symbols, not an undefined macro.

**Sources:**
- https://github.com/google/mysql/blob/master/include/mysql.h (enum shows `MYSQL_OPT_NONBLOCK` under `/* MariaDB options */`)
- https://mariadb.com/docs/server/reference/product-development/mariadb-internals/using-mariadb-with-your-programs-api/non-blocking-client-library/using-the-non-blocking-library (MariaDB activation and `_start`/`_cont` API)
- https://github.com/mariadb-corporation/mariadb-connector-c/wiki/activate_non_blocking (first-party activation sequence)
- https://github.com/mariadb-corporation/mariadb-connector-c/wiki/example_non_blocking (first-party continuation and wait-status example)
- https://dev.mysql.com/doc/c-api/8.0/en/mysql-real-query-nonblocking.html (MySQL 8.0.16+ uses `_nonblocking` suffix, different API)

---

## 3. PostgreSQL libpq async functions

**Claim:** The spec lists `PQsendQuery`, `PQsetnonblocking`, `PQconsumeInput`, `PQisBusy`, `PQflush`, `PQgetResult` and describes a cooperative async pattern.

**Verdict: Confirmed**

All six functions exist in the libpq API and the described cooperative pattern is accurate per the official PostgreSQL documentation:

- `PQsendQuery(conn, query)` — submits command without waiting for results. Returns 1 on success.
- `PQsetnonblocking(conn, arg)` — sets nonblocking mode. Required for truly nonblocking operation.
- `PQconsumeInput(conn)` — reads available data from the backend into internal buffers.
- `PQisBusy(conn)` — returns 1 if `PQgetResult` would block (i.e., no data ready yet).
- `PQflush(conn)` — flushes queued data to the server; needed on nonblocking connections before `select()`.
- `PQgetResult(conn)` — returns next result; must be called repeatedly until NULL. Blocks only if data hasn't been read by `PQconsumeInput`.

The cooperative pattern described in the spec matches the official docs exactly: `PQsendQuery` → poll with `PQconsumeInput`/`PQisBusy` → `PQgetResult` when not busy → repeat until NULL.

**Source:**
- https://www.postgresql.org/docs/7.3/libpq-async.html (and identical content in current docs)
- https://postgrespro.com/docs/postgresql/15/libpq-async (PostgreSQL 15 docs confirming same API)

---

## 4. MySQL mysql_store_result blocking

**Claim:** MySQL result retrieval via `mysql_store_result()` is synchronous and blocks the event loop, even when query execution is async.

**Verdict: Confirmed**

Oracle MySQL documentation states explicitly: "`mysql_store_result()` is a synchronous function. Its asynchronous counterpart is `mysql_store_result_nonblocking()`."

The function "reads the entire result of a query to the client" — it materializes the full result set into client memory in a blocking call. Even if the query itself was dispatched asynchronously (e.g., via `mysql_real_query_nonblocking`), calling `mysql_store_result()` blocks until all rows are transferred from server to client.

This is a blocking network I/O operation — it must receive all rows from the server before returning.

**Source:**
- https://dev.mysql.com/doc/c-api/8.0/en/mysql-store-result.html
- https://docs.oracle.com/cd/E17952_01/c-api-8.0-en/mysql-store-result.html

---

## 5. termbox2

**Claim:** The repo at https://github.com/termbox/termbox2 exists.

**Verdict: Confirmed**

- Repository exists at https://github.com/termbox/termbox2
- 720 stars, 62 forks
- Single-file header library (termbox2.h)
- MIT license
- Latest version: **v2.5.0** (released December 28, 2024, per Go packages; FreeBSD ports confirm timestamp December 2024)
- The spec mentions `v2.5.0` as a pinned version example — this matches.

**Sources:**
- https://github.com/termbox/termbox2
- https://pkg.go.dev/github.com/termbox/termbox2 (shows v2.5.0)
- https://www.freshports.org/devel/termbox2 (confirms v2.5.0)

---

## 6. LuaJIT v2.1 branch

**Claim:** The `v2.1` branch exists on https://github.com/LuaJIT/LuaJIT.

**Verdict: Confirmed**

- The `v2.1` branch exists on GitHub (files viewable at `github.com/LuaJIT/LuaJIT/blob/v2.1/`)
- It is the recommended production branch per luajit.org/status.html: "v2.1: Maintained = yes, Recommended Use = Production"
- Uses rolling releases — version is `v2.1.ROLLING` based on commit timestamp
- Active development: recent commits visible on repo.or.cz mirror (as of August 2026)
- The spec's approach of pinning to a specific commit SHA on this branch is consistent with LuaJIT's rolling release model (no release tarballs)

**Sources:**
- https://github.com/LuaJIT/LuaJIT/blob/v2.1/README
- https://luajit.org/status.html (branch status table)
- https://luajit.org/download.html (rolling releases, no tarballs)

---

## 7. SQLite sqlite3_step blocking

**Claim:** `sqlite3_step` runs without yielding to the event loop and cancellation is only observable between step calls.

**Verdict: Confirmed**

The SQLite C API documentation describes `sqlite3_step()` as:

> "This routine is used to evaluate a prepared statement... The statement is evaluated up to the point where the first row of results are available."

The function is synchronous and single-threaded — it runs bytecode evaluation to the next row boundary (or completion for non-SELECT statements) and returns. There is no mechanism for `sqlite3_step` to yield to an event loop or callback during execution.

Cancellation is via `sqlite3_interrupt(db)`, which can be called from a different thread. Per the Bun issue (#31014) discussion: "the event loop doesn't yield during a sync FFI call, so the timer can't fire while sqlite3_step() is running." The `sqlite3_interrupt` function causes `sqlite3_step` to return `SQLITE_INTERRUPT` at the next safe point (typically the next row boundary), but the step call itself does not yield.

The spec's characterization is accurate: cancellation is observable between `sqlite3_step` calls (or at the next row boundary within a step), not mid-operation in an event-loop sense.

**Sources:**
- https://www.sqlite.org/c3ref/step.html (official sqlite3_step documentation)
- https://github.com/oven-sh/bun/issues/31014 (corroborating discussion on synchronous FFI and event loop)
- https://sqlite.org/draft/isolation.html (SQLite isolation model confirms single-connection, non-yielding behavior)

---

## 8. MariaDB Connector/C nonblocking APIs

**Claim:** The spec mentions `mysql_store_result_start`/`_cont` and `mysql_real_query_start`/`_cont` as MariaDB-specific async APIs.

**Verdict: Confirmed**

The MariaDB non-blocking API reference explicitly lists both:

```c
int mysql_real_query_start(int *ret, MYSQL *mysql, const char *stmt_str, unsigned long length)
int mysql_real_query_cont(int *ret, MYSQL *mysql, int ready_status)

int mysql_store_result_start(MYSQL_RES **ret, MYSQL *mysql)
int mysql_store_result_cont(MYSQL_RES **ret, MYSQL *mysql, int ready_status)
```

These are part of the MariaDB Connector/C non-blocking client API. For every blocking function that may do socket I/O, MariaDB provides `_start` and `_cont` counterparts. The `mysql_store_result_start`/`_cont` pair allows non-blocking result materialization.

The spec's Phase 2 note about using these APIs is accurate — they exist and could be used to make MySQL result transfer non-blocking.

**Source:**
- https://mariadb.com/docs/server/reference/product-development/mariadb-internals/using-mariadb-with-your-programs-api/non-blocking-client-library/non-blocking-api-reference

---

## 9. Lua/C event-loop integration requirement

**Claim:** In a single-threaded Lua/LuaJIT application, a synchronous C database call blocks the VM and prevents the event loop from processing input or rendering. Coroutines alone cannot yield from inside a blocking C call; the driver must expose a continuation-style API, or the blocking work must run outside the event-loop thread.

**Verdict: Confirmed**

The consequence follows from the execution model used by this project: the event loop and Lua code run on one thread, while a synchronous C call does not return control to Lua until its I/O or CPU work completes. A Lua coroutine can yield at Lua-level suspension points, but it cannot make an already-running synchronous foreign-function call return early. MariaDB's first-party nonblocking API addresses this with an explicit `_start`/`_cont` protocol: the caller starts the operation, waits for the returned socket readiness flags or timeout, and resumes it with `_cont`. Without such a continuation API or a worker-thread boundary, calling the synchronous client function freezes repaint and keyboard processing for the duration of the call.

This is an architectural constraint rather than a claim that every Lua database binding must use coroutines. A worker thread is an alternative, but it introduces cross-thread connection ownership, result transfer, cancellation, and lifecycle concerns. The MVP's chosen approach is cooperative continuation through the driver API.

**Sources:**
- https://github.com/mariadb-corporation/mariadb-connector-c/wiki/example_non_blocking (first-party nonblocking start/continue loop)
- https://www.lua.org/manual/5.1/manual.html#2.11 (Lua coroutine semantics)
- https://luajit.org/ext_ffi.html (LuaJIT FFI calls and C interaction)

---

## Summary

| # | Claim | Verdict |
|---|---|---|
| 1 | luasql PR #201 adds async methods | **Confirmed** — merged, adds send_query/poll/get_result/getfd to all three drivers |
| 2 | MySQL async requires MariaDB Connector/C | **Partially confirmed** — the functional requirement stands, but the incompatibility is missing `_start`/`_cont` symbols, not an undefined macro. `MYSQL_OPT_NONBLOCK` is in the enum but labeled "MariaDB options." |
| 3 | libpq async functions exist | **Confirmed** — all six functions verified against official PostgreSQL docs |
| 4 | mysql_store_result blocks | **Confirmed** — Oracle docs explicitly state it is synchronous |
| 5 | termbox2 repo exists | **Confirmed** — v2.5.0 is latest |
| 6 | LuaJIT v2.1 branch exists | **Confirmed** — production branch, rolling releases |
| 7 | sqlite3_step is blocking/non-yielding | **Confirmed** — synchronous bytecode evaluation, no event loop yield |
| 8 | MariaDB Connector/C has _start/_cont APIs | **Confirmed** — both mysql_store_result_start/cont and mysql_real_query_start/cont exist |

### Action items for the spec

1. **Claim 2:** Updated above. The spec now states that stock `libmysqlclient` may define `MYSQL_OPT_NONBLOCK` for compatibility but lacks the MariaDB `_start`/`_cont` symbols used by luasql PR #201, so the driver falls back to synchronous execution.
