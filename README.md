# scry

## Current UI behavior

- The SQL editor is always in insert mode. The status bar shows `[INSERT]` while editing.
- Press `:` or `Esc` to enter command mode; the status bar changes to `[COMMAND]`. Press `Esc` to return to insert mode.
- In command mode, type `q` or `:q` and press `Enter` to quit. A literal `q` typed in the editor is inserted into the SQL Buffer.
- Backspace accepts both common terminal encodings (`0x08` and `0x7f`).
- Result columns are sized to their headers and loaded values, padded, and separated with `|`. SQL `NULL` is shown as `NULL`; binary values are shown as `[binary]`.
