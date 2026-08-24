-- src/cli.lua — command-line argument parsing and text

local M = {}

function M.parse_args(args)
    local result = {
        connection = nil,
        read_only = false,
        debug = false,
        version = false,
        help = false,
    }

    local i = 1
    while i <= #args do
        local arg = args[i]
        if arg == "--connection" and i + 1 <= #args then
            result.connection = args[i + 1]
            i = i + 2
        elseif arg:sub(1, 13) == "--connection=" then
            result.connection = arg:sub(14)
            i = i + 1
        elseif arg == "--read-only" then
            result.read_only = true
            i = i + 1
        elseif arg == "--debug" then
            result.debug = true
            i = i + 1
        elseif arg == "--version" then
            result.version = true
            i = i + 1
        elseif arg == "--help" or arg == "-h" then
            result.help = true
            i = i + 1
        else
            i = i + 1
        end
    end

    return result
end

function M.help_text()
    return table.concat({
        "scry — terminal SQL client",
        "",
        "Usage: scry [OPTIONS]",
        "",
        "Options:",
        "  --connection NAME  Connect to a named connection profile",
        "  --read-only        Enable read-only mode",
        "  --debug            Enable debug logging",
        "  --version          Show version",
        "  --help, -h         Show this help",
    }, "\n")
end

function M.version_text()
    return "scry 0.1.0"
end

return M
