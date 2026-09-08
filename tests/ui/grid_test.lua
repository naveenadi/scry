-- tests/ui/grid_test.lua — grid view state tests

package.path = "./?.lua;./src/?.lua;./tests/?.lua;" .. package.path

local h = require("test_helper")
local grid = require("ui.grid")

h.test("filter: case-insensitive substring", function()
    local view = grid.new(100)
    view.filter = "bob"
    local result = {
        columns = { "name" },
        rows = { { "Alice" }, { "Bobby" }, { "carol" } },
    }
    local prepared = grid.prepare(result, view)
    h.assert_eq(prepared.total_rows, 1, "filtered count")
end)

h.test("sort: toggles ascending and descending", function()
    local view = grid.new(100)
    view.sort_col = 1
    local result = {
        columns = { "n" },
        rows = { { 3 }, { 1 }, { 2 } },
    }
    local prepared = grid.prepare(result, view)
    h.assert_eq(prepared.all_rows[1][1], 1, "asc first")
    grid.toggle_sort(view, 1)
    prepared = grid.prepare(result, view)
    h.assert_eq(prepared.all_rows[1][1], 3, "desc first")
end)

h.test("format_cell: NULL and binary hex", function()
    h.assert_eq(grid.format_cell(nil), "NULL", "nil")
    h.assert_eq(grid.format_cell({ is_null = true }), "NULL", "sentinel")
    h.assert_eq(grid.format_cell({ 0xAB, 0xCD }), "abcd", "binary")
end)

h.summary()
