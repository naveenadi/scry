-- tests/db/base_fetch_test.lua — catalog fetch helper

package.path = "./?.lua;./src/?.lua;./tests/?.lua;" .. package.path

local h = require("test_helper")
local base = require("db.base")
local adapter_mod = require("db.adapter")

h.test("_fetch_all: maps rows when READY", function()
    local rows = { { name = "users" }, { name = "orders" } }
    local index = 0
    local closed = false

    local self = base.new()
    self._state = adapter_mod.READY
    self._conn = {
        execute = function()
            return {
                fetch = function()
                    index = index + 1
                    return rows[index]
                end,
                close = function() closed = true end,
            }
        end,
    }

    local out = self:_fetch_all("SELECT name FROM t", function(row) return row.name end)
    h.assert_eq(#out, 2, "count")
    h.assert_eq(out[1], "users", "first")
    h.assert_eq(out[2], "orders", "second")
    h.assert_true(closed, "cursor closed")
end)

h.test("_fetch_all: empty when not READY", function()
    local self = base.new()
    self._state = adapter_mod.QUERYING
    self._conn = {
        execute = function() error("should not execute") end,
    }

    local out = self:_fetch_all("SELECT 1", function(row) return row end)
    h.assert_eq(#out, 0, "count")
end)

h.summary()
