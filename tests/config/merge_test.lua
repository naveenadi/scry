-- tests/config/merge_test.lua — tests for config merge semantics

package.path = "src/?.lua;" .. package.path

local merge = require("src.config.merge")

local function assert_eq(a, b, msg)
    if a ~= b then
        error(string.format("%s: expected %q, got %q", msg or "assertion", tostring(b), tostring(a)), 2)
    end
end

local function assert_true(val, msg)
    if not val then
        error(string.format("%s: expected true", msg or "assertion"), 2)
    end
end

local tests_passed = 0
local tests_failed = 0

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        tests_passed = tests_passed + 1
        io.write(".")
    else
        tests_failed = tests_failed + 1
        io.write("F")
        io.stderr:write(string.format("\nFAIL: %s\n  %s\n", name, err))
    end
end

-- === merge_config tests ===

test("merge: nil override returns base", function()
    local base = { general = { theme = "dark" } }
    local result = merge.merge_config(base, nil)
    assert_eq(result.general.theme, "dark")
end)

test("merge: nil base returns override", function()
    local override = { general = { theme = "light" } }
    local result = merge.merge_config(nil, override)
    assert_eq(result.general.theme, "light")
end)

test("merge: scalar override wins", function()
    local base = { general = { theme = "dark", page_size = 100 } }
    local override = { general = { theme = "light" } }
    local result = merge.merge_config(base, override)
    assert_eq(result.general.theme, "light")
    assert_eq(result.general.page_size, 100)
end)

test("merge: recursive merge for general", function()
    local base = { general = { theme = "dark", sidebar_width = 30 } }
    local override = { general = { theme = "light" } }
    local result = merge.merge_config(base, override)
    assert_eq(result.general.theme, "light")
    assert_eq(result.general.sidebar_width, 30)
end)

test("merge: recursive merge for keybindings", function()
    local base = { keybindings = { quit = "q", help = "?" } }
    local override = { keybindings = { quit = "Q" } }
    local result = merge.merge_config(base, override)
    assert_eq(result.keybindings.quit, "Q")
    assert_eq(result.keybindings.help, "?")
end)

test("merge: connections merge by name", function()
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
    assert_eq(result.connections.dev.host, "dev.example.com")
    assert_eq(result.connections.dev.port, 5433)
    assert_eq(result.connections.prod.host, "prod.example.com")
end)

test("merge: project connection replaces global wholesale", function()
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
    assert_eq(result.connections.dev.host, "dev.example.com")
    assert_true(result.connections.dev.port == nil, "port should be nil (not merged from base)")
    assert_true(result.connections.dev.password == nil, "password should be nil (not merged from base)")
end)

test("merge: new connection from override added", function()
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
    assert_true(result.connections.dev ~= nil, "dev exists")
    assert_true(result.connections.staging ~= nil, "staging exists")
    assert_eq(result.connections.staging.type, "mysql")
end)

test("merge: empty override", function()
    local base = { general = { theme = "dark" } }
    local result = merge.merge_config(base, {})
    assert_eq(result.general.theme, "dark")
end)

io.write(string.format("\n\n%d passed, %d failed\n", tests_passed, tests_failed))
if tests_failed > 0 then
    os.exit(1)
end
