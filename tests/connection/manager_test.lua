-- tests/connection/manager_test.lua – Connection profile manager tests

package.path = "./?.lua;./src/?.lua;./tests/?.lua;" .. package.path

local h = require("test_helper")
local manager_mod = require("connection.manager")

local function mock_platform()
    return { spawn = function() return 1 end, waitpid = function() return nil end,
        kill = function() return true end }
end

local function mock_adapter_factory(log, name)
    return function()
        local adapter = { name = name, state_value = "DISCONNECTED" }
        function adapter:connect(config)
            self.config = config
            self.state_value = "READY"
            log[#log + 1] = "connect:" .. name
            return true
        end
        function adapter:close()
            self.state_value = "DISCONNECTED"
            log[#log + 1] = "close:" .. name
        end
        return adapter
    end
end

local function mock_tunnel_factory(log)
    return function()
        local tunnel = {}
        function tunnel:start(config)
            self.config = config
            log[#log + 1] = "tunnel:start"
            return config.local_port
        end
        function tunnel:stop()
            log[#log + 1] = "tunnel:stop"
        end
        return tunnel
    end
end

local config = {
    connections = {
        local_sqlite = { type = "sqlite", database = ":memory:" },
        tunneled = {
            type = "postgres", host = "db.internal", port = 5432,
            ssh_tunnel = { host = "bastion", local_port = 15432, remote_port = 5432 },
        },
    },
}

h.test("manager: switches profile and exposes adapter", function()
    local log = {}
    local manager = manager_mod.new(config, mock_platform(), {
        adapter_factories = { sqlite = mock_adapter_factory(log, "sqlite") },
    })
    local ok, err = manager:switch("local_sqlite")
    h.assert_true(ok, err)
    h.assert_eq(manager:get_profile_name(), "local_sqlite")
    h.assert_eq(manager:get_adapter().config.database, ":memory:")
    manager:close()
    h.assert_eq(log[1], "connect:sqlite")
    h.assert_eq(log[2], "close:sqlite")
end)

h.test("manager: starts tunnel and rewrites endpoint", function()
    local log = {}
    local manager = manager_mod.new(config, mock_platform(), {
        adapter_factories = { postgres = mock_adapter_factory(log, "postgres") },
        tunnel_factory = mock_tunnel_factory(log),
    })
    local ok, err = manager:switch("tunneled")
    h.assert_true(ok, err)
    local adapter = manager:get_adapter()
    h.assert_eq(adapter.config.host, "localhost")
    h.assert_eq(adapter.config.port, 15432)
    manager:close()
    h.assert_eq(log[1], "tunnel:start")
    h.assert_eq(log[2], "connect:postgres")
    h.assert_eq(log[3], "close:postgres")
    h.assert_eq(log[4], "tunnel:stop")
end)

h.test("manager: rejects ephemeral tunnel ports", function()
    local manager = manager_mod.new({ connections = {
        tunneled = { type = "sqlite", ssh_tunnel = { host = "bastion", local_port = 0 } },
    } }, mock_platform(), { adapter_factories = { sqlite = function() return {} end } })
    local ok, err = manager:switch("tunneled")
    h.assert_true(not ok)
    h.assert_true(err:find("explicit local_port") ~= nil)
end)

h.test("manager: reconnects the active profile", function()
    local log = {}
    local manager = manager_mod.new(config, mock_platform(), {
        adapter_factories = { sqlite = mock_adapter_factory(log, "sqlite") },
    })
    manager:switch("local_sqlite")
    local ok, err = manager:reconnect()
    h.assert_true(ok, err)
    h.assert_eq(manager:get_profile_name(), "local_sqlite")
    h.assert_eq(#log, 3)
    manager:close()
end)

h.test("manager: reports missing and unsupported profiles", function()
    local manager = manager_mod.new({ connections = {} }, mock_platform())
    local ok, err = manager:switch("missing")
    h.assert_true(not ok)
    h.assert_true(err:find("not found") ~= nil)

    manager = manager_mod.new({ connections = { other = { type = "oracle" } } }, mock_platform())
    ok, err = manager:switch("other")
    h.assert_true(not ok)
    h.assert_true(err:find("unsupported") ~= nil)
end)

h.summary()
