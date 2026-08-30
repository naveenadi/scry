-- tests/history/store_test.lua — unit tests for history store

package.path = "./?.lua;./src/?.lua;./tests/?.lua;" .. package.path

local h = require("test_helper")
local store_mod = require("history.store")

-- Mock platform with a temp file path
local function mock_platform(path)
    return { history_path = function() return path end }
end

-- Clean up temp file
local function cleanup(path)
    os.remove(path)
end

h.test("load: empty file returns no entries", function()
    local path = "/tmp/scry_test_history_" .. os.time() .. ".jsonl"
    cleanup(path)
    local s = store_mod.new(mock_platform(path), { history_limit = 10 })
    s:load()
    h.assert_eq(s:count(), 0)
    cleanup(path)
end)

h.test("append: adds entry and persists", function()
    local path = "/tmp/scry_test_history_" .. os.time() .. ".jsonl"
    cleanup(path)
    local s = store_mod.new(mock_platform(path), { history_limit = 10 })
    s:load()
    s:append("SELECT 1", "success")
    h.assert_eq(s:count(), 1)
    local entries = s:entries()
    h.assert_eq(entries[1].sql, "SELECT 1")
    h.assert_eq(entries[1].outcome, "success")
    h.assert_true(entries[1].timestamp > 0)
    h.assert_true(not entries[1].truncated)
    cleanup(path)
end)

h.test("append: persists across load", function()
    local path = "/tmp/scry_test_history_" .. os.time() .. ".jsonl"
    cleanup(path)
    local s1 = store_mod.new(mock_platform(path), { history_limit = 10 })
    s1:load()
    s1:append("SELECT 1", "success")
    s1:append("SELECT 2", "error")

    -- Load fresh store from same file
    local s2 = store_mod.new(mock_platform(path), { history_limit = 10 })
    s2:load()
    h.assert_eq(s2:count(), 2)
    local entries = s2:entries()
    h.assert_eq(entries[1].sql, "SELECT 2")  -- newest first
    h.assert_eq(entries[2].sql, "SELECT 1")
    cleanup(path)
end)

h.test("prune: removes oldest when limit exceeded", function()
    local path = "/tmp/scry_test_history_" .. os.time() .. ".jsonl"
    cleanup(path)
    local s = store_mod.new(mock_platform(path), { history_limit = 3 })
    s:load()
    s:append("q1", "success")
    s:append("q2", "success")
    s:append("q3", "success")
    s:append("q4", "success")
    h.assert_eq(s:count(), 3)
    local entries = s:entries()
    h.assert_eq(entries[1].sql, "q4")  -- newest kept
    h.assert_eq(entries[2].sql, "q3")
    h.assert_eq(entries[3].sql, "q2")
    cleanup(path)
end)

h.test("truncation: large entries are truncated and flagged", function()
    local path = "/tmp/scry_test_history_" .. os.time() .. ".jsonl"
    cleanup(path)
    local s = store_mod.new(mock_platform(path), { history_limit = 10, history_max_entry_bytes = 20 })
    s:load()
    local big_sql = string.rep("x", 50)
    s:append(big_sql, "success")
    local entries = s:entries()
    h.assert_eq(#entries[1].sql, 20)
    h.assert_true(entries[1].truncated)
    cleanup(path)
end)

h.test("search: finds by substring (case-insensitive)", function()
    local path = "/tmp/scry_test_history_" .. os.time() .. ".jsonl"
    cleanup(path)
    local s = store_mod.new(mock_platform(path), { history_limit = 10 })
    s:load()
    s:append("SELECT * FROM orders", "success")
    s:append("INSERT INTO users VALUES (1)", "success")
    s:append("select name from products", "success")

    local results = s:search("select")
    h.assert_eq(#results, 2)
    h.assert_eq(results[1].sql, "select name from products")  -- newest first
    h.assert_eq(results[2].sql, "SELECT * FROM orders")
    cleanup(path)
end)

h.test("search: empty query returns all", function()
    local path = "/tmp/scry_test_history_" .. os.time() .. ".jsonl"
    cleanup(path)
    local s = store_mod.new(mock_platform(path), { history_limit = 10 })
    s:load()
    s:append("SELECT 1", "success")
    s:append("SELECT 2", "success")
    local results = s:search("")
    h.assert_eq(#results, 2)
    cleanup(path)
end)

h.test("sql_list: returns SQL strings newest first", function()
    local path = "/tmp/scry_test_history_" .. os.time() .. ".jsonl"
    cleanup(path)
    local s = store_mod.new(mock_platform(path), { history_limit = 10 })
    s:load()
    s:append("first", "success")
    s:append("second", "success")
    local list = s:sql_list()
    h.assert_eq(list[1], "second")
    h.assert_eq(list[2], "first")
    cleanup(path)
end)

h.test("append: empty sql is ignored", function()
    local path = "/tmp/scry_test_history_" .. os.time() .. ".jsonl"
    cleanup(path)
    local s = store_mod.new(mock_platform(path), { history_limit = 10 })
    s:load()
    s:append("", "success")
    s:append(nil, "success")
    h.assert_eq(s:count(), 0)
    cleanup(path)
end)

h.test("append: records outcome correctly", function()
    local path = "/tmp/scry_test_history_" .. os.time() .. ".jsonl"
    cleanup(path)
    local s = store_mod.new(mock_platform(path), { history_limit = 10 })
    s:load()
    s:append("SELECT 1", "success")
    s:append("BAD SQL", "error")
    s:append("SELECT 2", "cancelled")
    local entries = s:entries()
    h.assert_eq(entries[1].outcome, "cancelled")
    h.assert_eq(entries[2].outcome, "error")
    h.assert_eq(entries[3].outcome, "success")
    cleanup(path)
end)

h.summary()
