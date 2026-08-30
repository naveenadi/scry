-- tests/export/csv_test.lua — unit tests for CSV export

package.path = "./?.lua;./src/?.lua;./tests/?.lua;" .. package.path

local h = require("test_helper")
local csv = require("export.csv")

h.test("basic: simple table", function()
    local cols = {"id", "name"}
    local rows = {{1, "Alice"}, {2, "Bob"}}
    local result = csv.to_string(cols, rows)
    h.assert_true(result:find("id,name\n") ~= nil, "has header")
    h.assert_true(result:find("1,Alice\n") ~= nil, "has row 1")
    h.assert_true(result:find("2,Bob\n") ~= nil, "has row 2")
end)

h.test("quoting: values with commas are quoted", function()
    local cols = {"val"}
    local rows = {{"a,b"}}
    local result = csv.to_string(cols, rows)
    h.assert_true(result:find('"a,b"') ~= nil, "comma value quoted")
end)

h.test("quoting: values with newlines are quoted", function()
    local cols = {"val"}
    local rows = {{"line1\nline2"}}
    local result = csv.to_string(cols, rows)
    h.assert_true(result:find('"line1\nline2"') ~= nil, "newline value quoted")
end)

h.test("quoting: values with double-quotes are escaped by doubling", function()
    local cols = {"val"}
    local rows = {{'say "hello"'}}
    local result = csv.to_string(cols, rows)
    h.assert_true(result:find('"say ""hello"""') ~= nil, "double-quote escaped")
end)

h.test("NULL: nil values become empty string", function()
    local cols = {"val"}
    local rows = {{nil}}
    local result = csv.to_string(cols, rows)
    -- Should have an empty field
    h.assert_true(result:find("val\n\n") ~= nil or result:find(",\n") ~= nil, "nil becomes empty")
end)

h.test("NULL: adapter.NULL becomes empty string", function()
    local cols = {"val"}
    local rows = {{{ is_null = true }}}
    local result = csv.to_string(cols, rows)
    h.assert_true(result:find("val\n\n") ~= nil or result:find(",\n") ~= nil, "NULL becomes empty")
end)

h.test("UTF-8: preserved as-is", function()
    local cols = {"val"}
    local rows = {{"日本語"}}
    local result = csv.to_string(cols, rows)
    h.assert_true(result:find("日本語") ~= nil, "UTF-8 preserved")
end)

h.test("trailing newline", function()
    local cols = {"a"}
    local rows = {{1}}
    local result = csv.to_string(cols, rows)
    h.assert_eq(result:sub(-1), "\n", "ends with newline")
end)

h.test("empty rows", function()
    local cols = {"id", "name"}
    local rows = {}
    local result = csv.to_string(cols, rows)
    h.assert_true(result:find("id,name\n") ~= nil, "has header even with no rows")
end)

h.summary()
