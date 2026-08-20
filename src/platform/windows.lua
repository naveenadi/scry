-- src/platform/windows.lua — Windows platform abstraction
-- Stub for Phase 1; Unix is the primary development platform.

local M = {}

-- Windows-specific implementations would go here.
-- For Phase 1, this module provides the same API as unix.lua
-- but with Windows-appropriate defaults.

function M.getenv(name)
    return os.getenv(name)
end

function M.home_dir()
    return os.getenv("USERPROFILE") or "C:\\Users\\Default"
end

function M.config_dir()
    local appdata = os.getenv("APPDATA")
    if appdata then
        return appdata .. "\\scry"
    end
    return M.home_dir() .. "\\AppData\\Roaming\\scry"
end

function M.state_dir()
    local localappdata = os.getenv("LOCALAPPDATA")
    if localappdata then
        return localappdata .. "\\scry"
    end
    return M.home_dir() .. "\\AppData\\Local\\scry"
end

function M.log_path()
    return M.state_dir() .. "\\scry.log"
end

function M.history_path()
    return M.state_dir() .. "\\history.jsonl"
end

function M.mkdir_p(path)
    os.execute('mkdir "' .. path .. '" 2>nul')
end

function M.file_exists(path)
    local f = io.open(path, "r")
    if f then
        f:close()
        return true
    end
    return false
end

function M.read_file(path)
    local f, err = io.open(path, "r")
    if not f then
        return nil, err
    end
    local content = f:read("*a")
    f:close()
    return content
end

function M.write_file(path, content)
    local f, err = io.open(path, "w")
    if not f then
        return nil, err
    end
    f:write(content)
    f:close()
    return true
end

function M.append_file(path, content)
    local f, err = io.open(path, "a")
    if not f then
        return nil, err
    end
    f:write(content)
    f:close()
    return true
end

function M.cwd()
    local handle = io.popen("cd")
    if handle then
        local result = handle:read("*a")
        handle:close()
        return result:gsub("%s+$", "")
    end
    return nil
end

M.path_sep = "\\"

function M.path_join(...)
    local parts = {...}
    return table.concat(parts, "\\")
end

function M.path_dirname(path)
    return path:match("(.+)\\[^\\]+$") or "."
end

function M.path_basename(path)
    return path:match("[^\\]+$") or path
end

-- Stub: Windows process management would use CreateProcess/WaitForSingleObject
function M.spawn(argv, opts)
    return nil, "Windows process spawn not implemented in Phase 1"
end

function M.waitpid(pid, nohang)
    return nil, "Windows process management not implemented in Phase 1"
end

function M.kill(pid, sig)
    return false, "Windows process management not implemented in Phase 1"
end

function M.getpid()
    return 0 -- stub
end

function M.ephemeral_port()
    return nil, "Windows ephemeral port not implemented in Phase 1"
end

function M.poll_readable(fd, timeout_ms)
    return false
end

function M.poll_writable(fd, timeout_ms)
    return false
end

return M
