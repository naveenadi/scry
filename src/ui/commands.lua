-- src/ui/commands.lua — parse command-mode input

local M = {}

function M.parse(text)
    local raw = (text or ""):match("^%s*(.-)%s*$")
    local command = raw:gsub("^:", "")
    if command == "q" or command == "quit" or command == "q!" then
        return "quit"
    elseif command == "reconnect" then
        return "reconnect"
    elseif command == "dismiss" then
        return "dismiss"
    elseif command == "help" then
        return "help"
    elseif command == "history" then
        return "history"
    elseif command:match("^connect%s+(.+)$") then
        local name = command:match("^connect%s+(.+)$")
        return "connect", name
    end
    return "unknown", command
end

return M
