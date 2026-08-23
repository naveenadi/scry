-- tests/config/merge_test.lua — tests for config merge semantics

package.path = "src/?.lua;" .. package.path

local h = require("tests.test_helper")
local merge = require("src.config.merge")


-- === merge_config tests ===

h.test("merge: nil override returns base", function()
    local base = { general = { theme = "dark" } }
    local result = merge.merge_config(base, nil)
    h.assert_eq(result.general.theme, "dark")
end)

h.test("merge: nil base returns override", function()
    local override = { general = { theme = "light" } }
    local result = merge.merge_config(nil, override)
    h.assert_eq(result.general.theme, "light")
end)

h.test("merge: scalar override wins", function()
    local base = { general = { theme = "dark", page_size = 100 } }
    local override = { general = { theme = "light" } }
    local result = merge.merge_config(base, override)
    h.assert_eq(result.general.theme, "light")
    h.assert_eq(result.general.page_size, 100)
end)

h.test("merge: recursive merge for general", function()
    local base = { general = { theme = "dark", sidebar_width = 30 } }
    local override = { general = { theme = "light" } }
    local result = merge.merge_config(base, override)
    h.assert_eq(result.general.theme, "light")
    h.assert_eq(result.general.sidebar_width, 30)
end)

h.test("merge: recursive merge for keybindings", function()
    local base = { keybindings = { quit = "q", help = "?" } }
    local override = { keybindings = { quit = "Q" } }
    local result = merge.merge_config(base, override)
    h.assert_eq(result.keybindings.quit, "Q")
    h.assert_eq(result.keybindings.help, "?")
end)

h.test("merge: connections merge by name", function()
    local base = {
        connections = {
            dev = { type = "postgres", host = "localhost" },
            prod = { type = "postgres", host = "prod.example.com" },
        }
    }
    local override = {
        connections = {
            dev = { type = "postgres", host = "dev.example.com", port = 5433 },
        }
    }
    local result = merge.merge_config(base, override)
    h.assert_eq(result.connections.dev.host, "dev.example.com")
    h.assert_eq(result.connections.dev.port, 5433)
    h.assert_eq(result.connections.prod.host, "prod.example.com")
end)

h.test("merge: project connection replaces global wholesale", function()
    local base = {
        connections = {
            dev = { type = "postgres", host = "localhost", port = 5432, password = "secret" },
        }
    }
    local override = {
        connections = {
            dev = { type = "postgres", host = "dev.example.com" },
        }
    }
    local result = merge.merge_config(base, override)
    -- The override replaces the entire connection entry
    h.assert_eq(result.connections.dev.host, "dev.example.com")
    h.assert_true(result.connections.dev.port == nil, "port should be nil (not merged from base)")
    h.assert_true(result.connections.dev.password == nil, "password should be nil (not merged from base)")
end)

h.test("merge: new connection from override added", function()
    local base = {
        connections = {
            dev = { type = "postgres" },
        }
    }
    local override = {
        connections = {
            staging = { type = "mysql" },
        }
    }
    local result = merge.merge_config(base, override)
    h.assert_true(result.connections.dev ~= nil, "dev exists")
    h.assert_true(result.connections.staging ~= nil, "staging exists")
    h.assert_eq(result.connections.staging.type, "mysql")
end)

h.test("merge: empty override", function()
    local base = { general = { theme = "dark" } }
    local result = merge.merge_config(base, {})
    h.assert_eq(result.general.theme, "dark")
end)

h.summary()
