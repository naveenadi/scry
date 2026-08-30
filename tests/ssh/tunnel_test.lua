-- tests/ssh/tunnel_test.lua — unit tests for SSH tunnel lifecycle

package.path = "./?.lua;./src/?.lua;./tests/?.lua;" .. package.path

local h = require("test_helper")
local tunnel_mod = require("ssh.tunnel")

-- Mock platform that simulates process lifecycle
local function mock_platform(opts)
    opts = opts or {}
    local processes = {}
    local next_pid = 1000

    return {
        spawn = function(argv, spawn_opts)
            if opts.spawn_fails then
                return nil, "mock spawn failure"
            end
            local pid = next_pid
            next_pid = next_pid + 1
            processes[pid] = { argv = argv, alive = true, exit_code = nil }
            if opts.spawn_exits_immediately then
                processes[pid].alive = false
                processes[pid].exit_code = 1
            end
            return pid, nil, nil
        end,
        waitpid = function(pid, nohang)
            local proc = processes[pid]
            if not proc then return nil, "no such process" end
            if not proc.alive then
                return proc.exit_code
            end
            if nohang then
                return nil -- still running
            end
            -- Blocking wait — just mark dead
            proc.alive = false
            return proc.exit_code or 0
        end,
        kill = function(pid, sig)
            local proc = processes[pid]
            if proc then
                proc.alive = false
                proc.exit_code = -15
            end
            return true
        end,
        getpid = function() return 1 end,
    }
end

h.test("start: spawns ssh process", function()
    local p = mock_platform()
    local t = tunnel_mod.new(p)
    local port, err = t:start({
        host = "bastion.example.com",
        username = "deploy",
        remote_host = "localhost",
        remote_port = 5432,
        local_port = 5433,
    })
    h.assert_eq(port, 5433)
    h.assert_true(t:is_running())
    t:stop()
end)

h.test("start: fails when spawn fails", function()
    local p = mock_platform({ spawn_fails = true })
    local t = tunnel_mod.new(p)
    local port, err = t:start({
        host = "bastion.example.com",
        local_port = 5433,
        remote_port = 5432,
    })
    h.assert_true(port == nil)
    h.assert_true(err:find("spawn failure") ~= nil)
end)

h.test("start: fails when ssh exits immediately", function()
    local p = mock_platform({ spawn_exits_immediately = true })
    local t = tunnel_mod.new(p)
    local port, err = t:start({
        host = "bastion.example.com",
        local_port = 5433,
        remote_port = 5432,
    })
    h.assert_true(port == nil)
    h.assert_true(err:find("exited") ~= nil)
end)

h.test("stop: kills ssh process", function()
    local p = mock_platform()
    local t = tunnel_mod.new(p)
    t:start({
        host = "bastion.example.com",
        local_port = 5433,
        remote_port = 5432,
    })
    h.assert_true(t:is_running())
    t:stop()
    h.assert_true(not t:is_running())
end)

h.test("stop: safe to call twice", function()
    local p = mock_platform()
    local t = tunnel_mod.new(p)
    t:start({
        host = "bastion.example.com",
        local_port = 5433,
        remote_port = 5432,
    })
    t:stop()
    t:stop() -- should not error
    h.assert_true(not t:is_running())
end)

h.test("start: stops existing tunnel before starting new one", function()
    local p = mock_platform()
    local t = tunnel_mod.new(p)
    t:start({
        host = "bastion.example.com",
        local_port = 5433,
        remote_port = 5432,
    })
    h.assert_true(t:is_running())
    t:start({
        host = "other.example.com",
        local_port = 5434,
        remote_port = 5432,
    })
    h.assert_eq(t:local_port(), 5434)
    t:stop()
end)

h.test("local_port: returns bound port", function()
    local p = mock_platform()
    local t = tunnel_mod.new(p)
    t:start({
        host = "bastion.example.com",
        local_port = 9999,
        remote_port = 5432,
    })
    h.assert_eq(t:local_port(), 9999)
    t:stop()
end)

h.test("local_port: nil when not running", function()
    local p = mock_platform()
    local t = tunnel_mod.new(p)
    h.assert_true(t:local_port() == nil)
end)

h.summary()
