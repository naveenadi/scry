-- src/connection/manager.lua – Connection profile lifecycle
-- Owns profile selection, adapter creation, SSH tunnel setup, and teardown.

local tunnel_mod = require("src.ssh.tunnel")

local M = {}

local adapter_factories = {
    sqlite = function() return require("src.db.sqlite").new() end,
    postgres = function() return require("src.db.postgres").new() end,
    mysql = function() return require("src.db.mysql").new() end,
}

local function copy_profile(profile)
    local copy = {}
    for key, value in pairs(profile) do
        if key ~= "ssh_tunnel" then copy[key] = value end
    end
    return copy
end

function M.new(config, platform, opts)
    opts = opts or {}
    local self = {
        _config = config or {},
        _platform = platform,
        _adapter = nil,
        _profile_name = nil,
        _profile = nil,
        _tunnel = nil,
        _factories = opts.adapter_factories or adapter_factories,
        _tunnel_factory = opts.tunnel_factory or tunnel_mod.new,
    }

    local function profile_for(name)
        local profile = self._config.connections and self._config.connections[name]
        if not profile then return nil, "connection '" .. tostring(name) .. "' not found" end
        if not profile.type then return nil, "connection '" .. tostring(name) .. "' has no type" end
        return profile
    end

    function self:switch(name)
        local profile, err = profile_for(name)
        if not profile then return false, err end

        local factory = self._factories[profile.type]
        if not factory then return false, "unsupported database type: " .. tostring(profile.type) end
        local new_adapter = factory()
        if not new_adapter then return false, "failed to create adapter for " .. profile.type end

        local new_tunnel
        local connect_profile = copy_profile(profile)
        if profile.ssh_tunnel then
            if not profile.ssh_tunnel.local_port or profile.ssh_tunnel.local_port == 0 then
                return false, "SSH tunnel requires an explicit local_port"
            end
            new_tunnel = self._tunnel_factory(self._platform)
            local local_port, tunnel_err = new_tunnel:start(profile.ssh_tunnel)
            if not local_port then
                return false, "SSH tunnel failed: " .. (tunnel_err or "unknown error")
            end
            connect_profile.host = "localhost"
            connect_profile.port = local_port
        end

        local ok, connect_err = new_adapter:connect(connect_profile)
        if not ok then
            if new_tunnel then new_tunnel:stop() end
            pcall(function() new_adapter:close() end)
            return false, connect_err or "connection failed"
        end

        self:close()
        self._adapter = new_adapter
        self._profile_name = name
        self._profile = profile
        self._tunnel = new_tunnel
        return true
    end

    function self:reconnect()
        if not self._profile_name then return false, "no connection to reconnect" end
        return self:switch(self._profile_name)
    end

    function self:get_adapter()
        return self._adapter
    end

    function self:get_connection_config()
        return self._profile
    end

    function self:get_profile_name()
        return self._profile_name
    end

    function self:close()
        if self._adapter then
            pcall(function() self._adapter:close() end)
            self._adapter = nil
        end
        if self._tunnel then
            pcall(function() self._tunnel:stop() end)
            self._tunnel = nil
        end
    end

    return self
end

return M
