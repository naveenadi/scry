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
| `Ctrl+f` | Next page |
| `Ctrl+b` | Previous page |

### Sidebar

| Key | Action |
|-----|--------|
| `j`/`k` | Navigate tables |
| `Enter` | Select table (insert name into editor) |

### Commands

| Command | Action |
|---------|--------|
| `:q` / `:quit` | Quit |
| `:connect NAME` | Switch connection |
| `:help` | Show help overlay |
| `:history` | Show query history |
| `:reconnect` | Reconnect after cancel |
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

Tests include: SQL parser (48 tests), config merge (9 tests), UI commands (3 tests), UI draw (1 test), UI layout (3 tests), execution engine (10 tests).

## Project structure

```
src/
  app.lua              # application wiring
  cli.lua              # CLI argument parsing
  core/
    event_loop.lua     # main event loop
    execution.lua      # multi-statement execution engine
  db/
    adapter.lua        # adapter contract definition
    sqlite.lua         # SQLite adapter
    postgres.lua       # PostgreSQL adapter
    mysql.lua          # MySQL/MariaDB adapter
  sql/
    parse.lua          # SQL parser (split + classify + highlight)
  ui/
    commands.lua       # command-mode parser
    draw.lua           # renderers (editor, grid, sidebar, status, modal)
    editor.lua         # text editor component
    keys.lua           # keyboard dispatch
    layout.lua         # layout calculation
  config/
    loader.lua         # config file loading
    merge.lua          # deep-merge semantics
    defaults.lua       # default config values
  tui/
    terminal.lua       # termbox2 FFI wrapper
  platform/
    unix.lua           # Unix platform layer
    windows.lua        # Windows platform layer
  utils/
    syntax.lua         # syntax highlighting tokenizer
tests/
  sql/                 # parser unit tests
  config/              # config merge tests
  ui/                  # UI component tests
  integration/         # execution engine tests
docs/
  adr/                 # architectural decision records
  research/            # research findings
examples/
  config.lua.example   # annotated config example
```

## License

MIT — see [LICENSE](LICENSE).
