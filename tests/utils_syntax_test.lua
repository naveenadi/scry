package.path = "src/?.lua;" .. package.path

local syntax = require("src.utils.syntax")
local tokens = syntax.tokenize_line("SELECT * FROM users WHERE name = 'Alice'")
local rendered = {}
for _, token in ipairs(tokens) do
    rendered[#rendered + 1] = token.text
end
local result = table.concat(rendered)
assert(result == "SELECT * FROM users WHERE name = 'Alice'", result)

local spaced = {}
for _, token in ipairs(syntax.tokenize_line("select * from users")) do
    spaced[#spaced + 1] = token.text
end
assert(table.concat(spaced) == "select * from users", table.concat(spaced))

local quoted = {}
for _, token in ipairs(syntax.tokenize_line("SELECT `a``;b` FROM t")) do
    quoted[#quoted + 1] = token.text
end
assert(table.concat(quoted) == "SELECT `a``;b` FROM t", table.concat(quoted))
print("syntax whitespace and shared scanner tests passed")
