-- tests/sql/parse_test.lua — tests for the SQL parser

package.path = "src/?.lua;" .. package.path

local parse = require("sql.parse")

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

local function assert_nil(val, msg)
    if val ~= nil then
        error(string.format("%s: expected nil, got %q", msg or "assertion", tostring(val)), 2)
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

-- === split_statements tests ===

test("split: single statement", function()
    local stmts = parse.split_statements("SELECT 1")
    assert_eq(#stmts, 1, "count")
    assert_eq(stmts[1].text, "SELECT 1", "text")
end)

test("split: two statements", function()
    local stmts = parse.split_statements("SELECT 1; SELECT 2")
    assert_eq(#stmts, 2, "count")
    assert_eq(stmts[1].text, "SELECT 1", "first")
    assert_eq(stmts[2].text, "SELECT 2", "second")
end)

test("split: semicolon in single-quoted string", function()
    local stmts = parse.split_statements("SELECT ';'")
    assert_eq(#stmts, 1, "count")
    assert_eq(stmts[1].text, "SELECT ';'", "text")
end)

test("split: semicolon in double-quoted identifier", function()
    local stmts = parse.split_statements('SELECT ";"')
    assert_eq(#stmts, 1, "count")
end)

test("split: semicolon in backtick identifier", function()
    local stmts = parse.split_statements("SELECT `;`")
    assert_eq(#stmts, 1, "count")
end)

test("split: semicolon in line comment", function()
    local stmts = parse.split_statements("SELECT 1 -- comment;\n; SELECT 2")
    assert_eq(#stmts, 2, "count")
end)

test("split: semicolon in block comment", function()
    local stmts = parse.split_statements("SELECT 1 /* ; */ SELECT 2")
    assert_eq(#stmts, 1, "count") -- no semicolon, so one statement
end)

test("split: semicolon in dollar-quoted block", function()
    local stmts = parse.split_statements("SELECT $func$; $func$")
    assert_eq(#stmts, 1, "count")
end)

test("split: different dollar-quote tags", function()
    local stmts = parse.split_statements("SELECT $outer$ $inner$; $inner$ $outer$")
    assert_eq(#stmts, 1, "count")
end)

test("split: empty statements filtered", function()
    local stmts = parse.split_statements("SELECT 1;; SELECT 2;")
    assert_eq(#stmts, 2, "count")
    assert_eq(stmts[1].text, "SELECT 1", "first")
    assert_eq(stmts[2].text, "SELECT 2", "second")
end)

test("split: trailing semicolon", function()
    local stmts = parse.split_statements("SELECT 1;")
    assert_eq(#stmts, 1, "count")
    assert_eq(stmts[1].text, "SELECT 1", "text")
end)

test("split: preserves byte offsets", function()
    local stmts = parse.split_statements("  SELECT 1;  SELECT 2")
    assert_eq(stmts[1].start_pos, 1, "first start")
    assert_eq(stmts[1].end_pos, 10, "first end")
    assert_eq(stmts[2].start_pos, 12, "second start")
    assert_eq(stmts[2].end_pos, 21, "second end")
end)

test("split: escaped single-quote", function()
    local stmts = parse.split_statements("SELECT 'it''s'")
    assert_eq(#stmts, 1, "count")
end)

test("split: backslash escape in single-quote", function()
    local stmts = parse.split_statements("SELECT '\\''; SELECT 2")
    assert_eq(#stmts, 2, "count")
end)

test("split: empty input", function()
    local stmts = parse.split_statements("")
    assert_eq(#stmts, 0, "count")
end)

test("split: nil input", function()
    local stmts = parse.split_statements(nil)
    assert_eq(#stmts, 0, "count")
end)

test("split: whitespace only", function()
    local stmts = parse.split_statements("   \n\t  ")
    assert_eq(#stmts, 0, "count")
end)

-- === classify_statement tests ===

test("classify: SELECT", function()
    local c = parse.classify_statement("SELECT 1")
    assert_eq(c.type, parse.TYPE_SELECT, "type")
    assert_eq(c.keyword, "SELECT", "keyword")
    assert_nil(c.blocked_keyword, "blocked")
end)

test("classify: select (lowercase)", function()
    local c = parse.classify_statement("select 1")
    assert_eq(c.type, parse.TYPE_SELECT, "type")
    assert_eq(c.keyword, "SELECT", "keyword")
end)

test("classify: INSERT", function()
    local c = parse.classify_statement("INSERT INTO t VALUES (1)")
    assert_eq(c.type, parse.TYPE_INSERT, "type")
    assert_eq(c.blocked_keyword, "INSERT", "blocked")
end)

test("classify: UPDATE", function()
    local c = parse.classify_statement("UPDATE t SET x=1")
    assert_eq(c.type, parse.TYPE_UPDATE, "type")
    assert_eq(c.blocked_keyword, "UPDATE", "blocked")
end)

test("classify: DELETE", function()
    local c = parse.classify_statement("DELETE FROM t")
    assert_eq(c.type, parse.TYPE_DELETE, "type")
    assert_eq(c.blocked_keyword, "DELETE", "blocked")
end)

test("classify: DROP", function()
    local c = parse.classify_statement("DROP TABLE t")
    assert_eq(c.type, parse.TYPE_DROP, "type")
    assert_eq(c.blocked_keyword, "DROP", "blocked")
end)

test("classify: CREATE", function()
    local c = parse.classify_statement("CREATE TABLE t (id INT)")
    assert_eq(c.type, parse.TYPE_CREATE, "type")
    assert_eq(c.blocked_keyword, "CREATE", "blocked")
end)

test("classify: ALTER", function()
    local c = parse.classify_statement("ALTER TABLE t ADD COLUMN x INT")
    assert_eq(c.type, parse.TYPE_ALTER, "type")
    assert_eq(c.blocked_keyword, "ALTER", "blocked")
end)

test("classify: TRUNCATE", function()
    local c = parse.classify_statement("TRUNCATE TABLE t")
    assert_eq(c.type, parse.TYPE_TRUNCATE, "type")
    assert_eq(c.blocked_keyword, "TRUNCATE", "blocked")
end)

test("classify: REPLACE", function()
    local c = parse.classify_statement("REPLACE INTO t VALUES (1)")
    assert_eq(c.type, parse.TYPE_REPLACE, "type")
    assert_eq(c.blocked_keyword, "REPLACE", "blocked")
end)

test("classify: EXPLAIN", function()
    local c = parse.classify_statement("EXPLAIN SELECT 1")
    assert_eq(c.type, parse.TYPE_EXPLAIN, "type")
    assert_nil(c.blocked_keyword, "blocked")
end)

test("classify: SHOW", function()
    local c = parse.classify_statement("SHOW TABLES")
    assert_eq(c.type, parse.TYPE_SHOW, "type")
    assert_nil(c.blocked_keyword, "blocked")
end)

test("classify: DESCRIBE", function()
    local c = parse.classify_statement("DESCRIBE t")
    assert_eq(c.type, parse.TYPE_DESCRIBE, "type")
    assert_nil(c.blocked_keyword, "blocked")
end)

test("classify: DESC", function()
    local c = parse.classify_statement("DESC t")
    assert_eq(c.type, parse.TYPE_DESCRIBE, "type")
end)

test("classify: PRAGMA", function()
    local c = parse.classify_statement("PRAGMA table_info(t)")
    assert_eq(c.type, parse.TYPE_PRAGMA, "type")
    assert_nil(c.blocked_keyword, "blocked")
end)

test("classify: SET", function()
    local c = parse.classify_statement("SET search_path TO public")
    assert_eq(c.type, parse.TYPE_SET, "type")
    assert_nil(c.blocked_keyword, "blocked")
end)

test("classify: WITH read-only CTE", function()
    local c = parse.classify_statement("WITH x AS (SELECT 1) SELECT * FROM x")
    assert_eq(c.type, parse.TYPE_WITH, "type")
    assert_nil(c.blocked_keyword, "blocked")
end)

test("classify: WITH write CTE (DELETE)", function()
    local c = parse.classify_statement("WITH x AS (DELETE FROM t RETURNING *) SELECT * FROM x")
    assert_eq(c.type, parse.TYPE_WITH, "type")
    assert_eq(c.blocked_keyword, "DELETE", "blocked")
end)

test("classify: WITH write CTE (INSERT)", function()
    local c = parse.classify_statement("WITH x AS (INSERT INTO t VALUES (1) RETURNING *) SELECT * FROM x")
    assert_eq(c.blocked_keyword, "INSERT", "blocked")
end)

test("classify: blocked keyword in string is ignored", function()
    local c = parse.classify_statement("SELECT 'DELETE FROM t'")
    assert_nil(c.blocked_keyword, "blocked")
end)

test("classify: blocked keyword in comment is ignored", function()
    local c = parse.classify_statement("SELECT 1 -- DELETE FROM t")
    assert_nil(c.blocked_keyword, "blocked")
end)

test("classify: blocked keyword in block comment is ignored", function()
    local c = parse.classify_statement("SELECT 1 /* DELETE FROM t */")
    assert_nil(c.blocked_keyword, "blocked")
end)

test("classify: blocked keyword in double-quoted identifier is ignored", function()
    local c = parse.classify_statement('SELECT "DELETE"')
    assert_nil(c.blocked_keyword, "blocked")
end)

test("classify: empty input", function()
    local c = parse.classify_statement("")
    assert_eq(c.type, parse.TYPE_OTHER, "type")
    assert_nil(c.keyword, "keyword")
end)

test("classify: nil input", function()
    local c = parse.classify_statement(nil)
    assert_eq(c.type, parse.TYPE_OTHER, "type")
end)

-- === is_read_only tests ===

test("read_only: SELECT is safe", function()
    assert_true(parse.is_read_only("SELECT 1"))
end)

test("read_only: INSERT is blocked", function()
    assert_true(not parse.is_read_only("INSERT INTO t VALUES (1)"))
end)

test("read_only: DELETE is blocked", function()
    assert_true(not parse.is_read_only("DELETE FROM t"))
end)

test("read_only: CTE with read-only body is safe", function()
    assert_true(parse.is_read_only("WITH x AS (SELECT 1) SELECT * FROM x"))
end)

test("read_only: CTE with write body is blocked", function()
    assert_true(not parse.is_read_only("WITH x AS (DELETE FROM t RETURNING *) SELECT * FROM x"))
end)

-- Print results
io.write(string.format("\n\n%d passed, %d failed\n", tests_passed, tests_failed))
if tests_failed > 0 then
    os.exit(1)
end
