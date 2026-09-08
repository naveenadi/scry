-- src/ui/draw.lua — thin facade delegating to focused renderers

local editor_renderer = require("src.ui.draw.editor")
local grid_renderer = require("src.ui.draw.grid")
local status_renderer = require("src.ui.draw.status")
local sidebar_renderer = require("src.ui.draw.sidebar")
local modal_renderer = require("src.ui.draw.modal")

local M = {}

M.editor = editor_renderer.render
M.grid = grid_renderer.render
M.status = status_renderer.render
M.sidebar = sidebar_renderer.render
M.modal = modal_renderer.render

function M.too_small(term, terminal)
    term.clear()
    local message = "Terminal too small. Please resize to at least 80x24."
    term.text(math.floor((term.width() - #message) / 2), math.floor(term.height() / 2), message, terminal.RED, terminal.DEFAULT)
    term.present()
end

return M
