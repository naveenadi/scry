package.path = "src/?.lua;" .. package.path

local editor = require("src.ui.editor").new()
editor:insert_char("SELECT")
editor:insert_char(" ")
editor:insert_char("*")
editor:insert_char(" ")
editor:insert_char("FROM")
editor:insert_char(" ")
editor:insert_char("users")
assert(editor:get_text() == "SELECT * FROM users", editor:get_text())

editor:move_home()
editor:insert_char("X")
assert(editor:get_text() == "XSELECT * FROM users", editor:get_text())
editor:backspace()
assert(editor:get_text() == "SELECT * FROM users", editor:get_text())

-- Both terminal backspace encodings must produce the same edit operation.
editor:move_end()
editor:backspace()
assert(editor:get_text() == "SELECT * FROM user", editor:get_text())
editor:insert_char("s")
assert(editor:get_text() == "SELECT * FROM users", editor:get_text())

editor:move_end()
editor:insert_newline()
editor:insert_char("WHERE id = 1")
assert(editor:get_text() == "SELECT * FROM users\nWHERE id = 1", editor:get_text())

-- Vim-like buffer navigation
editor:move_buffer_start()
assert(editor.cursor_y == 0 and editor.cursor_x == 0)
editor:move_buffer_end()
assert(editor.cursor_y == 1 and editor.cursor_x == #"WHERE id = 1")

print("editor test passed")
