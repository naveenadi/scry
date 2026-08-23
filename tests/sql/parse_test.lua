-- tests/sql/parse_test.lua — tests for the SQL parser

package.path = "src/?.lua;" .. package.path

local h = require("tests.test_helper")
local parse = require("sql.parse")


-- === split_statements tests ===

h.test("split: single statement", function()
    local stmts = parse.split_statements("SELECT 1")
    h.assert_eq(#stmts, 1, "count")
    h.assert_eq(stmts[1].text, "SELECT 1", "text")
end)

h.test("split: two statements", function()
    local stmts = parse.split_statements("SELECT 1; SELECT 2")
    h.assert_eq(#stmts, 2, "count")
    h.assert_eq(stmts[1].text, "SELECT 1", "first")
    h.assert_eq(stmts[2].text, "SELECT 2", "second")
end)

h.test("split: semicolon in single-quoted string", function()
    local stmts = parse.split_statements("SELECT ';'")
    h.assert_eq(#stmts, 1, "count")
    h.assert_eq(stmts[1].text, "SELECT ';'", "text")
end)

h.test("split: semicolon in double-quoted identifier", function()
    local stmts = parse.split_statements('SELECT ";"')
    h.assert_eq(#stmts, 1, "count")
end)

h.test("split: semicolon in backtick identifier", function()
    local stmts = parse.split_statements("SELECT `;`")
    h.assert_eq(#stmts, 1, "count")
end)

h.test("split: doubled backtick in identifier", function()
    local stmts = parse.split_statements("SELECT `a``;b`; SELECT 2")
    h.assert_eq(#stmts, 2, "count")
    h.assert_eq(stmts[1].text, "SELECT `a``;b`", "first")
end)

h.test("split: semicolon in line comment", function()
    local stmts = parse.split_statements("SELECT 1 -- comment;\n; SELECT 2")
    h.assert_eq(#stmts, 2, "count")
end)

h.test("split: semicolon in block comment", function()
    local stmts = parse.split_statements("SELECT 1 /* ; */ SELECT 2")
    h.assert_eq(#stmts, 1, "count") -- no semicolon, so one statement
end)

h.test("split: semicolon in dollar-quoted block", function()
    local stmts = parse.split_statements("SELECT $func$; $func$")
    h.assert_eq(#stmts, 1, "count")
end)

h.test("split: different dollar-quote tags", function()
    local stmts = parse.split_statements("SELECT $outer$ $inner$; $inner$ $outer$")
    h.assert_eq(#stmts, 1, "count")
end)

h.test("split: empty statements filtered", function()
    local stmts = parse.split_statements("SELECT 1;; SELECT 2;")
    h.assert_eq(#stmts, 2, "count")
    h.assert_eq(stmts[1].text, "SELECT 1", "first")
    h.assert_eq(stmts[2].text, "SELECT 2", "second")
end)

h.test("split: trailing semicolon", function()
    local stmts = parse.split_statements("SELECT 1;")
    h.assert_eq(#stmts, 1, "count")
    h.assert_eq(stmts[1].text, "SELECT 1", "text")
end)

h.test("split: preserves byte offsets", function()
    local stmts = parse.split_statements("  SELECT 1;  SELECT 2")
    h.assert_eq(stmts[1].start_pos, 1, "first start")
    h.assert_eq(stmts[1].end_pos, 10, "first end")
    h.assert_eq(stmts[2].start_pos, 12, "second start")
    h.assert_eq(stmts[2].end_pos, 21, "second end")
end)

h.test("split: escaped single-quote", function()
    local stmts = parse.split_statements("SELECT 'it''s'")
    h.assert_eq(#stmts, 1, "count")
end)

h.test("split: backslash escape in single-quote", function()
    local stmts = parse.split_statements("SELECT '\\''; SELECT 2")
    h.assert_eq(#stmts, 2, "count")
end)

h.test("split: empty input", function()
    local stmts = parse.split_statements("")
    h.assert_eq(#stmts, 0, "count")
end)

h.test("split: nil input", function()
    local stmts = parse.split_statements(nil)
    h.assert_eq(#stmts, 0, "count")
end)

h.test("split: whitespace only", function()
    local stmts = parse.split_statements("   \n\t  ")
    h.assert_eq(#stmts, 0, "count")
end)

-- === classify_statement tests ===

h.test("classify: SELECT", function()
    local c = parse.classify_statement("SELECT 1")
    h.assert_eq(c.type, parse.TYPE_SELECT, "type")
    h.assert_eq(c.keyword, "SELECT", "keyword")
    h.assert_nil(c.blocked_keyword, "blocked")
end)

h.test("classify: select (lowercase)", function()
    local c = parse.classify_statement("select 1")
    h.assert_eq(c.type, parse.TYPE_SELECT, "type")
    h.assert_eq(c.keyword, "SELECT", "keyword")
end)

h.test("classify: INSERT", function()
    local c = parse.classify_statement("INSERT INTO t VALUES (1)")
    h.assert_eq(c.type, parse.TYPE_INSERT, "type")
    h.assert_eq(c.blocked_keyword, "INSERT", "blocked")
end)

h.test("classify: UPDATE", function()
    local c = parse.classify_statement("UPDATE t SET x=1")
    h.assert_eq(c.type, parse.TYPE_UPDATE, "type")
    h.assert_eq(c.blocked_keyword, "UPDATE", "blocked")
end)

h.test("classify: DELETE", function()
    local c = parse.classify_statement("DELETE FROM t")
    h.assert_eq(c.type, parse.TYPE_DELETE, "type")
    h.assert_eq(c.blocked_keyword, "DELETE", "blocked")
end)

h.test("classify: DROP", function()
    local c = parse.classify_statement("DROP TABLE t")
    h.assert_eq(c.type, parse.TYPE_DROP, "type")
    h.assert_eq(c.blocked_keyword, "DROP", "blocked")
end)

h.test("classify: CREATE", function()
    local c = parse.classify_statement("CREATE TABLE t (id INT)")
    h.assert_eq(c.type, parse.TYPE_CREATE, "type")
    h.assert_eq(c.blocked_keyword, "CREATE", "blocked")
end)

h.test("classify: ALTER", function()
    local c = parse.classify_statement("ALTER TABLE t ADD COLUMN x INT")
    h.assert_eq(c.type, parse.TYPE_ALTER, "type")
    h.assert_eq(c.blocked_keyword, "ALTER", "blocked")
end)

h.test("classify: TRUNCATE", function()
    local c = parse.classify_statement("TRUNCATE TABLE t")
    h.assert_eq(c.type, parse.TYPE_TRUNCATE, "type")
    h.assert_eq(c.blocked_keyword, "TRUNCATE", "blocked")
end)

h.test("classify: REPLACE", function()
    local c = parse.classify_statement("REPLACE INTO t VALUES (1)")
    h.assert_eq(c.type, parse.TYPE_REPLACE, "type")
    h.assert_eq(c.blocked_keyword, "REPLACE", "blocked")
end)

h.test("classify: EXPLAIN", function()
    local c = parse.classify_statement("EXPLAIN SELECT 1")
    h.assert_eq(c.type, parse.TYPE_EXPLAIN, "type")
    h.assert_nil(c.blocked_keyword, "blocked")
end)

h.test("classify: SHOW", function()
    local c = parse.classify_statement("SHOW TABLES")
    h.assert_eq(c.type, parse.TYPE_SHOW, "type")
    h.assert_nil(c.blocked_keyword, "blocked")
end)

h.test("classify: DESCRIBE", function()
    local c = parse.classify_statement("DESCRIBE t")
    h.assert_eq(c.type, parse.TYPE_DESCRIBE, "type")
    h.assert_nil(c.blocked_keyword, "blocked")
end)

h.test("classify: DESC", function()
    local c = parse.classify_statement("DESC t")
    h.assert_eq(c.type, parse.TYPE_DESCRIBE, "type")
end)

h.test("classify: PRAGMA", function()
    local c = parse.classify_statement("PRAGMA table_info(t)")
    h.assert_eq(c.type, parse.TYPE_PRAGMA, "type")
    h.assert_nil(c.blocked_keyword, "blocked")
end)

h.test("classify: SET", function()
    local c = parse.classify_statement("SET search_path TO public")
    h.assert_eq(c.type, parse.TYPE_SET, "type")
    h.assert_nil(c.blocked_keyword, "blocked")
end)

h.test("classify: WITH read-only CTE", function()
    local c = parse.classify_statement("WITH x AS (SELECT 1) SELECT * FROM x")
    h.assert_eq(c.type, parse.TYPE_WITH, "type")
    h.assert_nil(c.blocked_keyword, "blocked")
end)

h.test("classify: WITH write CTE (DELETE)", function()
    local c = parse.classify_statement("WITH x AS (DELETE FROM t RETURNING *) SELECT * FROM x")
    h.assert_eq(c.type, parse.TYPE_WITH, "type")
    h.assert_eq(c.blocked_keyword, "DELETE", "blocked")
end)

h.test("classify: WITH write CTE (INSERT)", function()
    local c = parse.classify_statement("WITH x AS (INSERT INTO t VALUES (1) RETURNING *) SELECT * FROM x")
    h.assert_eq(c.blocked_keyword, "INSERT", "blocked")
end)

h.test("classify: blocked keyword in string is ignored", function()
    local c = parse.classify_statement("SELECT 'DELETE FROM t'")
    h.assert_nil(c.blocked_keyword, "blocked")
end)

h.test("classify: blocked keyword in comment is ignored", function()
    local c = parse.classify_statement("SELECT 1 -- DELETE FROM t")
    h.assert_nil(c.blocked_keyword, "blocked")
end)

h.test("classify: blocked keyword in block comment is ignored", function()
    local c = parse.classify_statement("SELECT 1 /* DELETE FROM t */")
    h.assert_nil(c.blocked_keyword, "blocked")
end)

h.test("classify: blocked keyword in double-quoted identifier is ignored", function()
    local c = parse.classify_statement('SELECT "DELETE"')
    h.assert_nil(c.blocked_keyword, "blocked")
end)

h.test("classify: empty input", function()
    local c = parse.classify_statement("")
    h.assert_eq(c.type, parse.TYPE_OTHER, "type")
    h.assert_nil(c.keyword, "keyword")
end)

h.test("classify: nil input", function()
    local c = parse.classify_statement(nil)
    h.assert_eq(c.type, parse.TYPE_OTHER, "type")
end)

-- === is_read_only tests ===

h.test("read_only: SELECT is safe", function()
    h.assert_true(parse.is_read_only("SELECT 1"))
end)

h.test("read_only: INSERT is blocked", function()
    h.assert_true(not parse.is_read_only("INSERT INTO t VALUES (1)"))
end)

h.test("read_only: DELETE is blocked", function()
    h.assert_true(not parse.is_read_only("DELETE FROM t"))
end)

h.test("read_only: CTE with read-only body is safe", function()
    h.assert_true(parse.is_read_only("WITH x AS (SELECT 1) SELECT * FROM x"))
end)

h.test("read_only: CTE with write body is blocked", function()
    h.assert_true(not parse.is_read_only("WITH x AS (DELETE FROM t RETURNING *) SELECT * FROM x"))
end)

h.summary()
