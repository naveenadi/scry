-- tests/ui/commands_test.lua — command-mode parsing

package.path = "src/?.lua;" .. package.path

local h = require("tests.test_helper")
local commands = require("src.ui.commands")

h.test("commands: quit aliases", function()
    h.assert_eq(commands.parse("q"), "quit", "q")
    h.assert_eq(commands.parse(" :q! "), "quit", "q!")
    h.assert_eq(commands.parse("quit"), "quit", "quit")
end)

h.test("commands: supported commands", function()
    h.assert_eq(commands.parse("reconnect"), "reconnect", "reconnect")
    h.assert_eq(commands.parse("dismiss"), "dismiss", "dismiss")
    h.assert_eq(commands.parse("help"), "help", "help")
end)

h.test("commands: unknown preserves input", function()
    local command, argument = commands.parse("  nope  ")
    h.assert_eq(command, "unknown", "command")
    h.assert_eq(argument, "nope", "argument")
end)

h.summary()
