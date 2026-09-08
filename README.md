# scry

> "See the future in your data."

A fast, Vim-inspired terminal SQL client. Connect to PostgreSQL, MySQL/MariaDB, and SQLite — edit queries, execute them, browse results, all without leaving your terminal.

## Prerequisites

- **LuaJIT 2.1** (pinned commit, built from source by Makefile)
- **SQLite3** development libraries (`libsqlite3-dev` / `sqlite-devel`)
- **PostgreSQL** client libraries (`libpq-dev` / `postgresql-devel`) — for Postgres adapter
- **MariaDB Connector/C** (`libmariadb-dev` / `mariadb-connector-c-devel`) — for MySQL adapter (stock MySQL's libmysqlclient does not provide async APIs)
- **pkg-config** — for locating system libraries
- **GNU Make** and a C compiler (gcc/clang/MSVC)

## Build

```bash
git clone https://github.com/naveenadi/scry.git
cd scry
make release       # production build
make debug         # debug build with symbols
```

The Makefile fetches pinned dependencies (LuaJIT, LuaSQL, termbox2) into `vendor/` and builds everything from source. See `build/SOURCES.txt` for exact dependency pins.

Binary size: ~661 KB. Startup: ~3 ms.

## Install

```bash
./install.sh                     # installs to /usr/local/bin
./install.sh --prefix ~/.local  # custom prefix
```

## Quick start

```bash
# Create a config file
cp examples/config.lua.example ~/.config/scry/config.lua

# Connect to a database
scry --connection local_dev

# Or use SQLite directly
scry --connection local_sqlite
```

## Configuration

Config files are loaded from:
- **Global**: `~/.config/scry/config.lua` (Unix) or `%APPDATA%\scry\config.lua` (Windows)
- **Project**: `.scry_config.lua` in the current directory (overrides global)

See `examples/config.lua.example` for a full annotated example.

### Connections

```lua
return {
  connections = {
    mydb = {
      type = "postgres",       -- "postgres" | "mysql" | "sqlite"
      host = "localhost",
      port = 5432,
      database = "mydb",
      username = "user",
      password = os.getenv("DB_PASSWORD"),
      read_only = false,       -- client-side read-only enforcement
    },
  },
}
```

### Read-only mode

Enable via config (`read_only = true`) or CLI flag (`--read-only`). Blocks `INSERT`, `UPDATE`, `DELETE`, `DROP`, `TRUNCATE`, `ALTER`, `CREATE`, `REPLACE`, `MERGE` — including inside CTEs. Client-side only; database permissions remain the authoritative safeguard.

## Keybindings

| Key | Action |
|-----|--------|
| `Ctrl+r` | Execute query |
| `Ctrl+c` | Cancel query |
| `Ctrl+p` | Previous history entry |
| `Ctrl+n` | Next history entry |
| `Tab` | Cycle focus (editor → grid → sidebar) |
| `Esc` | Focus sidebar (from editor) |
| `?` | Toggle help overlay |

### Editor

| Key | Action |
|-----|--------|
| Arrow keys | Move cursor |
| `Home`/`End` | Start/end of line |
| `Ctrl+a`/`Ctrl+e` | Start/end of line |
| `Ctrl+k` | Kill to end of line |
| `Ctrl+u` | Kill to start of line |
| `Ctrl+l` | Clear line |

### Grid

| Key | Action |
|-----|--------|
| `Ctrl+f` / `Ctrl+b` | Next / previous page |
| `gg` / `G` | First / last row |
| `j` / `k` | Move selection down / up |
| `h` / `l` | Scroll columns left / right | `/` | Filter rows |
| `Enter` | Sort by column / open cell |
| `Ctrl+e` | Export result as CSV |
| `Shift+E` | Export result as JSON |

### Sidebar

| Key | Action |
|-----|--------|
| `j` / `k` | Navigate tables |
| `Enter` | Select table (insert name into editor) |
| `Esc` | Close sidebar |

### Commands

| Command | Action |
|---------|--------|
| `:q` / `:quit` | Quit |
| `:connect NAME` | Switch connection |
| `:help` | Show help overlay |
| `:history` | Show query history |
| `:reconnect` | Reconnect after cancel |
| `:rollback` | Issue `ROLLBACK` |
| `:dismiss` | Dismiss reconnect prompt |

## Supported databases

| Database | Driver | Async | Status |
|----------|--------|-------|--------|
| SQLite 3 | luasql sqlite3 | prepare/step split | Phase 1 |
| PostgreSQL 12+ | luasql postgres (libpq) | full cooperative async | Phase 1 |
| MySQL 8+ / MariaDB 10.5+ | luasql mysql (MariaDB Connector/C) | query async, result blocks | Phase 1 |

## Tests

```bash
make test    # run all tests
```

Tests cover SQL parsing, config merge, editor/input, UI (commands, draw, grid, layout), query execution, database adapters, export (CSV, JSON, stream), SSH tunnel lifecycle, query history, and read-only enforcement.

## Project structure

```
src/
  app.lua              # application wiring
  cli.lua              # CLI argument parsing
  config/
    loader.lua         # config file loading
    merge.lua          # deep-merge semantics
    defaults.lua       # default config values
  core/
    event_loop.lua     # main event loop
    execution.lua      # multi-statement execution engine
    statement_cycle.lua  # statement scheduling
  db/
    adapter.lua        # adapter contract definition
    base.lua           # shared adapter base
    factory.lua        # adapter construction
    sqlite.lua         # SQLite adapter
    postgres.lua       # PostgreSQL adapter (libpq)
    mysql.lua          # MySQL/MariaDB adapter
  export/
    csv.lua            # CSV (RFC 4180) export
    json.lua           # JSON export
    stream.lua         # result-to-stream helpers
  history/
    store.lua          # query history persistence
  platform/
    init.lua           # platform module entry
    unix.lua           # Unix platform layer
    windows.lua        # Windows platform layer
  sql/
    parse.lua          # SQL parser (split + classify + highlight)
  ssh/
    tunnel.lua         # SSH tunnel lifecycle
  tui/
    terminal.lua       # termbox2 FFI wrapper
  ui/
    commands.lua       # command-mode parser
    draw.lua           # TUI renderers
    draw/
      editor.lua       # editor renderer
      grid.lua         # results grid renderer
      modal.lua        # modal renderer
      sidebar.lua      # sidebar renderer
      status.lua       # status bar renderer
    editor.lua         # text editor component
    grid.lua           # results grid controller
    keys.lua           # keyboard dispatch
    keys/
      command.lua      # command-mode key handling
      help.lua         # help overlay text
    layout.lua         # layout calculation
  utils/
    syntax.lua         # syntax highlighting tokenizer
    json.lua           # JSON helpers
main.c                 # C entry point
```

```
tests/
  config/              # config merge tests
  core/                # statement cycle tests
  db/                  # adapter base tests
  export/              # CSV, JSON, stream tests
  history/             # history store tests
  integration/         # execution engine + SQLite tests
  readonly/            # read-only enforcement tests
  sql/                 # parser unit tests
  ssh/                 # tunnel unit tests
  ui/                  # UI component tests
  editor_test.lua      # editor unit tests
  utils_json_test.lua  # JSON helper tests
  utils_syntax_test.lua  # syntax tokenizer tests
```

```
docs/
  adr/                 # architectural decision records
  research/            # research findings
examples/
  config.lua.example   # annotated config example
```

## License

MIT — see [LICENSE](LICENSE).
