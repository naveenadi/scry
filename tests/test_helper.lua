-- tests/test_helper.lua — shared test utilities

local M = {}

M.tests_passed = 0
M.tests_failed = 0

function M.assert_eq(a, b, msg)
    if a ~= b then
        error(string.format("%s: expected %q, got %q", msg or "assertion", tostring(b), tostring(a)), 2)
    end
end

function M.assert_true(val, msg)
    if not val then
        error(string.format("%s: expected true", msg or "assertion"), 2)
    end
end

function M.assert_nil(val, msg)
    if val ~= nil then
        error(string.format("%s: expected nil, got %q", msg or "assertion", tostring(val)), 2)
    end
end

function M.test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        M.tests_passed = M.tests_passed + 1
        io.write(".")
    else
        M.tests_failed = M.tests_failed + 1
        io.write("F")
        io.stderr:write(string.format("\nFAIL: %s\n  %s\n", name, err))
    end
end

function M.summary()
    io.write(string.format("\n\n%d passed, %d failed\n", M.tests_passed, M.tests_failed))
    if M.tests_failed > 0 then
        os.exit(1)
    end
end

return M
