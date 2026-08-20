-- src/config/loader.lua — load and merge global + project configuration

local merge = require("src.config.merge")
local defaults = require("src.config.defaults")

local M = {}

-- Detect platform for path resolution
local jit = require("jit")
local is_windows = jit.os == "Windows"

-- Get the global config path.
function M.global_config_path()
    if is_windows then
        local appdata = os.getenv("APPDATA")
        if appdata then
            return appdata .. "\\scry\\config.lua"
        end
        return os.getenv("USERPROFILE") .. "\\AppData\\Roaming\\scry\\config.lua"
    else
        local xdg = os.getenv("XDG_CONFIG_HOME")
        if xdg then
            return xdg .. "/scry/config.lua"
        end
        return (os.getenv("HOME") or "/tmp") .. "/.config/scry/config.lua"
    end
end

-- Find the project config by walking cwd to parents, stopping at repo root.
-- Returns the path to .scry_config.lua, or nil if not found.
function M.find_project_config()
    local cwd
    if is_windows then
        local handle = io.popen("cd")
        if handle then
            cwd = handle:read("*a"):gsub("%s+$", "")
            handle:close()
        end
    else
        local handle = io.popen("pwd")
        if handle then
            cwd = handle:read("*a"):gsub("%s+$", "")
            handle:close()
        end
    end
    if not cwd then return nil end

    local sep = is_windows and "\\" or "/"
    local dir = cwd

    while dir do
        local candidate = dir .. sep .. ".scry_config.lua"
        local f = io.open(candidate, "r")
        if f then
            f:close()
            return candidate
        end

        -- Check for .git directory (repo root indicator)
        local git_dir = dir .. sep .. ".git"
        local gf = io.open(git_dir, "r")
        if gf then
            gf:close()
            -- At repo root, stop searching
            return nil
        end

        -- Move to parent
        local parent = dir:match("(.+)" .. sep .. "[^" .. sep .. "]+$")
        if parent == dir then break end -- reached filesystem root
        dir = parent
    end

    return nil
end

-- Load a Lua config file. Returns the table, or nil + error.
function M.load_file(path)
    local fn, err = loadfile(path)
    if not fn then
        return nil, err
    end
    local ok, result = pcall(fn)
    if not ok then
        return nil, "error executing " .. path .. ": " .. tostring(result)
    end
    if type(result) ~= "table" then
        return nil, path .. " must return a table"
    end
    return result
end

-- Load the full merged configuration.
-- Returns the merged config table.
function M.load()
    local config = merge.merge_config(defaults, {})

    -- Load global config
    local global_path = M.global_config_path()
    local global_config, err = M.load_file(global_path)
    if global_config then
        config = merge.merge_config(config, global_config)
    end

    -- Load project config
    local project_path = M.find_project_config()
    if project_path then
        local project_config, err = M.load_file(project_path)
        if project_config then
            config = merge.merge_config(config, project_config)
        end
    end

    return config
end

return M
