-- tests/utils_json_test.lua — data-only JSON decoder tests

package.path = "./?.lua;./src/?.lua;./tests/?.lua;" .. package.path

local h = require("test_helper")
local json = require("utils.json")

h.test("decode: history object", function()
    local value, err = json.decode('{"sql":"SELECT 1","outcome":"success","truncated":false}')
    h.assert_true(value ~= nil, err or "decoded value")
    h.assert_eq(value.sql, "SELECT 1", "sql")
    h.assert_eq(value.truncated, false, "truncated")
end)

h.test("decode: escaped string", function()
    local value = json.decode('{"sql":"say \\"hi\\"\\nnext"}')
    h.assert_eq(value.sql, 'say "hi"\nnext', "escaped sql")
end)

h.test("decode: rejects executable input", function()
    local value = json.decode('{"sql":"x"}; os.execute("touch /tmp/scry-json-should-not-run")')
    h.assert_nil(value, "malformed JSON")
end)

h.test("decode: rejects trailing data", function()
    local value = json.decode('{"sql":"x"} garbage')
    h.assert_nil(value, "trailing data")
end)

h.test("encode: history object roundtrip", function()
    local entry = {
        sql = "SELECT 1",
        outcome = "success",
        timestamp = 123,
        truncated = false,
    }
    local text = json.encode(entry)
    local value = json.decode(text)
    h.assert_eq(value.sql, "SELECT 1", "sql")
    h.assert_eq(value.outcome, "success", "outcome")
    h.assert_eq(value.timestamp, 123, "timestamp")
    h.assert_eq(value.truncated, false, "truncated")
end)

h.test("encode: escapes special characters", function()
    local text = json.encode({ sql = 'say "hi"\nnext' })
    local value = json.decode(text)
    h.assert_eq(value.sql, 'say "hi"\nnext', "sql")
end)

h.summary()
