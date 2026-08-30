-- tests/export/json_test.lua — unit tests for JSON export

package.path = "./?.lua;./src/?.lua;./tests/?.lua;" .. package.path

local h = require("test_helper")
local json = require("export.json")

h.test("basic: array of objects", function()
    local cols = {"id", "name"}
    local rows = {{1, "Alice"}, {2, "Bob"}}
    local result = json.to_string(cols, rows)
    h.assert_true(result:find('"id":1') ~= nil, "has id:1")
    h.assert_true(result:find('"name":"Alice"') ~= nil, "has name:Alice")
    h.assert_true(result:find('"id":2') ~= nil, "has id:2")
    h.assert_true(result:find('"name":"Bob"') ~= nil, "has name:Bob")
end)

h.test("null: nil becomes JSON null", function()
    local cols = {"val"}
    local rows = {{nil}}
    local result = json.to_string(cols, rows)
    h.assert_true(result:find('"val":null') ~= nil, "nil becomes null")
end)

h.test("null: adapter.NULL becomes JSON null", function()
    local cols = {"val"}
    local rows = {{{ is_null = true }}}
    local result = json.to_string(cols, rows)
    h.assert_true(result:find('"val":null') ~= nil, "NULL becomes null")
end)

h.test("boolean: true and false", function()
    local cols = {"val"}
    local rows = {{true}, {false}}
    local result = json.to_string(cols, rows)
    h.assert_true(result:find('"val":true') ~= nil, "true preserved")
    h.assert_true(result:find('"val":false') ~= nil, "false preserved")
end)

h.test("number: integers and floats", function()
    local cols = {"val"}
    local rows = {{42}, {3.14}}
    local result = json.to_string(cols, rows)
    h.assert_true(result:find('"val":42') ~= nil, "integer preserved")
    h.assert_true(result:find('"val":3.14') ~= nil, "float preserved")
end)

h.test("string: special characters escaped", function()
    local cols = {"val"}
    local rows = {{'say "hello"\nnew\tline'}}
    local result = json.to_string(cols, rows)
    h.assert_true(result:find('\\"hello\\"') ~= nil, "double-quote escaped")
    h.assert_true(result:find('\\n') ~= nil, "newline escaped")
    h.assert_true(result:find('\\t') ~= nil, "tab escaped")
end)

h.test("binary: table values become [binary]", function()
    local cols = {"val"}
    local rows = {{{ 1, 2, 3 }}}  -- non-NULL table = binary
    local result = json.to_string(cols, rows)
    h.assert_true(result:find('"val":"%[binary%]"', 1, false) ~= nil, "binary encoded")
end)

h.test("NaN: becomes null", function()
    local cols = {"val"}
    local rows = {{0/0}}
    local result = json.to_string(cols, rows)
    h.assert_true(result:find('"val":null') ~= nil, "NaN becomes null")
end)

h.test("empty rows: empty array", function()
    local cols = {"id"}
    local rows = {}
    local result = json.to_string(cols, rows)
    h.assert_eq(result, "[]", "empty array")
end)

h.test("UTF-8: preserved", function()
    local cols = {"val"}
    local rows = {{"日本語"}}
    local result = json.to_string(cols, rows)
    h.assert_true(result:find("日本語") ~= nil, "UTF-8 preserved")
end)

h.summary()
