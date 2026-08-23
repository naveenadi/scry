-- tests/integration/sqlite_test.lua — SQLite adapter tests

package.path = "src/?.lua;" .. package.path

local ok_luasql, _ = pcall(require, "luasql.sqlite3")
if not ok_luasql then
    print("SKIP: luasql.sqlite3 not available (must run through scry binary)")
    os.exit(0)
end

local h = require("tests.test_helper")
local sqlite = require("src.db.sqlite")
local adapter_mod = require("src.db.adapter")


-- === SQLite adapter tests ===

h.test("connect to :memory:", function()
    local db = sqlite.new()
    local ok, err = db:connect({ database = ":memory:" })
    h.assert_true(ok, "connect: " .. (err or ""))
    h.assert_eq(db:state(), adapter_mod.READY, "state")
    db:close()
end)

h.test("execute SELECT", function()
    local db = sqlite.new()
    db:connect({ database = ":memory:" })

    local ok, err = db:send_query("SELECT 1 as num, 'hello' as msg")
    h.assert_true(ok, "send_query: " .. (err or ""))
    h.assert_eq(db:state(), adapter_mod.RESULT_READY, "state after send_query")

    ok, err = db:get_result()
    h.assert_true(ok, "get_result: " .. (err or ""))
    h.assert_eq(db:state(), adapter_mod.FETCHING, "state after get_result")

    local cols = db:columns()
    h.assert_eq(#cols, 2, "column count")

    local row = db:next_row()
    h.assert_true(row ~= nil, "first row not nil")
    h.assert_eq(row.num, 1, "num value")
    h.assert_eq(row.msg, "hello", "msg value")

    local row2 = db:next_row()
    h.assert_true(row2 == nil, "second row is nil (EOF)")

    db:close_result()
    h.assert_eq(db:state(), adapter_mod.READY, "state after close_result")
    db:close()
end)

h.test("execute INSERT", function()
    local db = sqlite.new()
    db:connect({ database = ":memory:" })
    db:send_query("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")
    db:get_result()
    db:close_result()

    local ok, err = db:send_query("INSERT INTO t VALUES (1, 'test')")
    h.assert_true(ok, "send_query: " .. (err or ""))
    db:get_result()
    db:close_result()
    h.assert_eq(db:state(), adapter_mod.READY, "state")
    db:close()
end)

h.test("list_tables", function()
    local db = sqlite.new()
    db:connect({ database = ":memory:" })
    db:send_query("CREATE TABLE users (id INTEGER)")
    db:get_result()
    db:close_result()
    db:send_query("CREATE TABLE posts (id INTEGER)")
    db:get_result()
    db:close_result()

    local tables = db:list_tables()
    h.assert_true(#tables >= 2, "at least 2 tables")
    db:close()
end)

h.test("get_columns", function()
    local db = sqlite.new()
    db:connect({ database = ":memory:" })
    db:send_query("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
    db:get_result()
    db:close_result()

    local cols = db:get_columns("t")
    h.assert_eq(#cols, 2, "column count")
    h.assert_eq(cols[1].name, "id", "first column name")
    h.assert_eq(cols[2].name, "name", "second column name")
    h.assert_true(cols[2].notnull, "name is NOT NULL")
    db:close()
end)

h.test("ping", function()
    local db = sqlite.new()
    db:connect({ database = ":memory:" })
    h.assert_true(db:ping(), "ping works")
    db:close()
end)

h.test("capabilities", function()
    local db = sqlite.new()
    db:connect({ database = ":memory:" })
    local caps = db:capabilities()
    h.assert_true(not caps.query_async, "query_async is false")
    h.assert_true(caps.result_streaming, "result_streaming is true")
    h.assert_true(not caps.result_fetch_async, "result_fetch_async is false")
    h.assert_true(not caps.early_close_requires_drain, "early_close_requires_drain is false")
    db:close()
end)

h.test("NULL sentinel", function()
    local db = sqlite.new()
    db:connect({ database = ":memory:" })
    db:send_query("SELECT NULL as val")
    db:get_result()
    local row = db:next_row()
    h.assert_true(row ~= nil, "row not nil")
    h.assert_true(adapter_mod.is_null(row.val), "NULL value is sentinel")
    h.assert_true(adapter_mod.is_null(row[1]), "positional NULL value is sentinel")
    db:close_result()
    db:close()
end)

h.test("error on bad SQL", function()
    local db = sqlite.new()
    db:connect({ database = ":memory:" })
    -- LuaSQL's execute() returns (nil, error_message) for invalid SQL.
    local ok, err = db:send_query("INVALID SQL SYNTAX")
    h.assert_true(not ok, "should fail")
    h.assert_true(err ~= nil, "error message present")
    h.assert_true(err:find("syntax error") ~= nil, "error mentions syntax")
    db:close()
end)

h.summary()
