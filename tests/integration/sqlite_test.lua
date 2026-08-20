-- tests/integration/sqlite_test.lua — SQLite adapter tests

package.path = "src/?.lua;" .. package.path

local ok_luasql, _ = pcall(require, "luasql.sqlite3")
if not ok_luasql then
    print("SKIP: luasql.sqlite3 not available (must run through scry binary)")
    os.exit(0)
end
local sqlite = require("src.db.sqlite")
local adapter_mod = require("src.db.adapter")

local function assert_eq(a, b, msg)
    if a ~= b then
        error(string.format("%s: expected %q, got %q", msg or "assertion", tostring(b), tostring(a)), 2)
    end
end

local function assert_true(val, msg)
    if not val then
        error(string.format("%s: expected true", msg or "assertion"), 2)
    end
end

local tests_passed = 0
local tests_failed = 0

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        tests_passed = tests_passed + 1
        io.write(".")
    else
        tests_failed = tests_failed + 1
        io.write("F")
        io.stderr:write(string.format("\nFAIL: %s\n  %s\n", name, err))
    end
end

-- === SQLite adapter tests ===

test("connect to :memory:", function()
    local db = sqlite.new()
    local ok, err = db:connect({ database = ":memory:" })
    assert_true(ok, "connect: " .. (err or ""))
    assert_eq(db:state(), adapter_mod.READY, "state")
    db:close()
end)

test("execute SELECT", function()
    local db = sqlite.new()
    db:connect({ database = ":memory:" })

    local ok, err = db:send_query("SELECT 1 as num, 'hello' as msg")
    assert_true(ok, "send_query: " .. (err or ""))
    assert_eq(db:state(), adapter_mod.RESULT_READY, "state after send_query")

    ok, err = db:get_result()
    assert_true(ok, "get_result: " .. (err or ""))
    assert_eq(db:state(), adapter_mod.FETCHING, "state after get_result")

    local cols = db:columns()
    assert_eq(#cols, 2, "column count")

    local row = db:next_row()
    assert_true(row ~= nil, "first row not nil")
    assert_eq(row.num, 1, "num value")
    assert_eq(row.msg, "hello", "msg value")

    local row2 = db:next_row()
    assert_true(row2 == nil, "second row is nil (EOF)")

    db:close_result()
    assert_eq(db:state(), adapter_mod.READY, "state after close_result")
    db:close()
end)

test("execute INSERT", function()
    local db = sqlite.new()
    db:connect({ database = ":memory:" })
    db:send_query("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")
    db:get_result()
    db:close_result()

    local ok, err = db:send_query("INSERT INTO t VALUES (1, 'test')")
    assert_true(ok, "send_query: " .. (err or ""))
    db:get_result()
    db:close_result()
    assert_eq(db:state(), adapter_mod.READY, "state")
    db:close()
end)

test("list_tables", function()
    local db = sqlite.new()
    db:connect({ database = ":memory:" })
    db:send_query("CREATE TABLE users (id INTEGER)")
    db:get_result()
    db:close_result()
    db:send_query("CREATE TABLE posts (id INTEGER)")
    db:get_result()
    db:close_result()

    local tables = db:list_tables()
    assert_true(#tables >= 2, "at least 2 tables")
    db:close()
end)

test("get_columns", function()
    local db = sqlite.new()
    db:connect({ database = ":memory:" })
    db:send_query("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
    db:get_result()
    db:close_result()

    local cols = db:get_columns("t")
    assert_eq(#cols, 2, "column count")
    assert_eq(cols[1].name, "id", "first column name")
    assert_eq(cols[2].name, "name", "second column name")
    assert_true(cols[2].notnull, "name is NOT NULL")
    db:close()
end)

test("ping", function()
    local db = sqlite.new()
    db:connect({ database = ":memory:" })
    assert_true(db:ping(), "ping works")
    db:close()
end)

test("capabilities", function()
    local db = sqlite.new()
    db:connect({ database = ":memory:" })
    local caps = db:capabilities()
    assert_true(not caps.query_async, "query_async is false")
    assert_true(caps.result_streaming, "result_streaming is true")
    assert_true(not caps.result_fetch_async, "result_fetch_async is false")
    assert_true(not caps.early_close_requires_drain, "early_close_requires_drain is false")
    db:close()
end)

test("NULL sentinel", function()
    local db = sqlite.new()
    db:connect({ database = ":memory:" })
    db:send_query("SELECT NULL as val")
    db:get_result()
    local row = db:next_row()
    assert_true(row ~= nil, "row not nil")
    assert_true(adapter_mod.is_null(row.val), "NULL value is sentinel")
    db:close_result()
    db:close()
end)

test("error on bad SQL", function()
    local db = sqlite.new()
    db:connect({ database = ":memory:" })
    local ok, err = db:send_query("INVALID SQL SYNTAX")
    assert_true(not ok, "should fail")
    assert_true(err ~= nil, "error message present")
    db:close()
end)

io.write(string.format("\n\n%d passed, %d failed\n", tests_passed, tests_failed))
if tests_failed > 0 then
    os.exit(1)
end
