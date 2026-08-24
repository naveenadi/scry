-- src/ui/commands.lua — parse command-mode input

local M = {}

function M.parse(text)
    local command = (text or ""):match("^%s*(.-)%s*$")
    command = command:gsub("^:", "")
    if command == "q" or command == "quit" or command == "q!" then
        return "quit"
    elseif command == "reconnect" then
        return "reconnect"
    elseif command == "dismiss" then
        return "dismiss"
    elseif command == "help" then
        return "help"
    end
    return "unknown", command
end

return M
