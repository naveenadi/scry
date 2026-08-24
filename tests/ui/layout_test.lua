-- tests/ui/layout_test.lua — layout region invariants

package.path = "src/?.lua;" .. package.path

local h = require("tests.test_helper")
local layout = require("src.ui.layout")

local terminal = {
    width = function() return 80 end,
    height = function() return 24 end,
}

h.test("layout: rejects terminals below minimum size", function()
    local small = {
        width = function() return 79 end,
        height = function() return 24 end,
    }
    h.assert_nil(layout.calculate(small, {}), "width below minimum")
end)

h.test("layout: grid stops before status bar", function()
    local regions = layout.calculate(terminal, { general = { sidebar_width = 30 } })
    h.assert_true(regions ~= nil, "layout exists")
    h.assert_eq(regions.status.y, 23, "status row")
    h.assert_eq(regions.grid.y + regions.grid.height, regions.status.y, "grid ends before status")
end)

h.test("layout: regions fit within terminal", function()
    local regions = layout.calculate(terminal, { general = { sidebar_width = 30 } })
    h.assert_true(regions.sidebar.x + regions.sidebar.width <= regions.width, "sidebar fits")
    h.assert_true(regions.editor.x + regions.editor.width <= regions.width, "editor fits")
    h.assert_true(regions.grid.x + regions.grid.width <= regions.width, "grid fits")
    h.assert_true(regions.status.y + regions.status.height <= regions.height, "status fits")
end)

h.summary()
