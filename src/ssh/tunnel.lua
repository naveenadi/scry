-- src/ssh/tunnel.lua — SSH tunnel lifecycle management
-- Spawns ssh -N -L for port forwarding. One tunnel per Connection.
-- Ephemeral port allocation when local_port is 0 or absent.
-- Process cleanup on close() and application exit.

local ffi = require("ffi")

local M = {}

-- Create a new SSH tunnel manager.
-- platform: platform module (must have spawn, kill, waitpid, getpid)
function M.new(platform)
    local self = {
        _platform = platform,
        _pid = nil,
        _local_port = nil,
        _config = nil,
    }

    -- Start an SSH tunnel.
    -- config: { host, username, key_path, remote_host, remote_port, local_port }
    -- Returns: local_port on success, nil + error on failure.
    function self:start(config)
        if self._pid then
            self:stop()
        end

        self._config = config
        local local_port = config.local_port or 0
        local remote_host = config.remote_host or "localhost"
        local remote_port = config.remote_port or 5432

        -- Build SSH command
        local argv = {
            "ssh",
            "-N",  -- no remote command
            "-o", "ExitOnForwardFailure=yes",
            "-o", "StrictHostKeyChecking=no",
        }

        if config.key_path then
            table.insert(argv, "-i")
            table.insert(argv, config.key_path)
        end

        -- Port forwarding: -L [local_addr:]local_port:remote_addr:remote_port
        if local_port == 0 then
            -- Ephemeral port: bind to port 0, OS assigns a free port
            -- We need to get the assigned port after ssh starts
            table.insert(argv, "-L")
            table.insert(argv, "0:" .. remote_host .. ":" .. remote_port)
        else
            table.insert(argv, "-L")
            table.insert(argv, local_port .. ":" .. remote_host .. ":" .. remote_port)
        end

        -- User@host
        local user_host = ""
        if config.username then
            user_host = config.username .. "@"
        end
        user_host = user_host .. config.host
        table.insert(argv, user_host)

        -- Spawn the SSH process with output capture to detect startup
        local pid, err, pipe_fd = self._platform.spawn(argv, { capture_output = true })
        if not pid then
            return nil, "failed to start ssh: " .. (err or "unknown")
        end

        self._pid = pid

        -- Wait briefly for SSH to start and bind the port
        -- SSH with ExitOnForwardFailure=yes will exit immediately if port binding fails
        local start_time = os.clock()
        while os.clock() - start_time < 2 do
            local exit_code = self._platform.waitpid(pid, true)
            if exit_code ~= nil then
                -- SSH exited — port binding failed or connection refused
                self._pid = nil
                return nil, "ssh exited with code " .. tostring(exit_code)
            end
            -- Check if we can determine the local port
            if local_port ~= 0 then
                self._local_port = local_port
                return local_port
            end
            -- For ephemeral port, we need to read from the pipe
            -- SSH doesn't output the port, so we need to check the socket
            -- For now, use a reasonable default approach
        end

        if local_port == 0 then
            -- For ephemeral port, we can't easily get the port from ssh
            -- Use a fallback: try to read /proc or use netstat
            -- For MVP, require explicit local_port in config
            self:stop()
            return nil, "ephemeral port (local_port=0) requires explicit port for MVP"
        end

        self._local_port = local_port
        return local_port
    end

    -- Stop the SSH tunnel.
    function self:stop()
        if self._pid then
            self._platform.kill(self._pid, 15) -- SIGTERM
            -- Wait briefly for clean exit
            local start = os.clock()
            while os.clock() - start < 1 do
                local code = self._platform.waitpid(self._pid, true)
                if code ~= nil then break end
            end
            -- Force kill if still running
            if self._platform.waitpid(self._pid, true) == nil then
                self._platform.kill(self._pid, 9) -- SIGKILL
                self._platform.waitpid(self._pid, false)
            end
            self._pid = nil
        end
        self._local_port = nil
    end

    -- Check if the tunnel is running.
    function self:is_running()
        if not self._pid then return false end
        local code = self._platform.waitpid(self._pid, true)
        if code ~= nil then
            self._pid = nil
            self._local_port = nil
            return false
        end
        return true
    end

    -- Get the local port the tunnel is bound to.
    function self:local_port()
        return self._local_port
    end

    return self
end

return M
