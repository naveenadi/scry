-- src/config/defaults.lua — default configuration values

return {
    general = {
        default_page_size = 100,
        max_result_rows = 100000,
        sidebar_width = 30,
        mouse_enabled = true,
        theme = "dark",
        connect_timeout_seconds = 10,
    },
    connections = {},
    query_editor = {
        syntax_highlighting = true,
        history_limit = 1000,
        history_max_entry_bytes = 1024 * 1024, -- 1 MB
    },
    keybindings = {
        quit = "q",
        run_query = "Ctrl-r",
        page_forward = "Ctrl-f",
        page_backward = "Ctrl-b",
        first_row = "gg",
        last_row = "G",
        sort_column = "Enter",
        filter_rows = "/",
        scroll_left = "H",
        scroll_right = "L",
        export_csv = "Ctrl-e",
        export_json = "Ctrl-Shift-e",
        history_prev = "Ctrl-p",
        history_next = "Ctrl-n",
        cancel = "Ctrl-c",
        help = "?",
        tab_next = "Tab",
        tab_prev = "Shift-Tab",
        focus_sidebar = "Esc",
        command_mode = ":",
    },
}
