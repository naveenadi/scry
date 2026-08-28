-- tests/ui/draw_test.lua — rendering must not run blocking catalog queries

package.path = "src/?.lua;" .. package.path

local h = require("tests.test_helper")
local draw = require("src.ui.draw")

local term = {
    text = function() end,
    cell = function() end,
}
local terminal = { GREEN = 1, YELLOW = 2, RED = 3 }
local theme = {
    bg = 0,
    fg = 0,
    keyword = 0,
    sidebar_fg = 0,
}
local region = { x = 0, y = 0, width = 30, height = 10 }

h.test("sidebar: rendering does not run blocking catalog query", function()
    local calls = 0
    local adapter = {
        list_tables = function()
            calls = calls + 1
            return { "users" }
        end,
    }
    local app_state = {
        connection_status = "connected",
        connection_name = "local",
        tables = { "users" },
    }

    draw.sidebar(term, app_state, region, theme, terminal)
    h.assert_eq(calls, 0, "list_tables calls during render")
end)

h.summary()
