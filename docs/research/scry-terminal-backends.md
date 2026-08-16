# Research: Scry terminal backends

Ticket: [#2 Research Scry terminal backends](https://github.com/naveenadi/scry/issues/2)

## Question

Which maintained, permissively licensed terminal backend can Scry call through a small LuaJIT FFI wrapper while providing termbox-compatible primitives on Linux, macOS, and Windows?

## Recommendation

**Use termbox2 as the primary backend on Unix (Linux + macOS), behind a thin `src/ui/tui.lua` FFI wrapper.**

- Ship `termbox2.h` as a single-file implementation compiled into the host (`#define TB_IMPL` in one C translation unit), matching the project's "small wrapper so the rest of the UI doesn't depend on the backend" requirement.
- Treat **Windows as a separate backend path** until termbox2's Windows support lands. Prefer a small Win32 Console / VT-sequence backend implementing the same wrapper API, not a second high-level TUI framework.
- Keep the wrapper surface minimal: init/shutdown, size, clear/present, set cell/print, cursor, poll/peek event, optional mouse.

## Why termbox2

| Criterion | Finding | Source |
|---|---|---|
| Licence | MIT | [termbox2 LICENSE / repo](https://github.com/termbox/termbox2) |
| Deps | libc only; no ncurses | [README](https://github.com/termbox/termbox2/blob/master/README.md) |
| Shape | Single-file header or static/shared lib | same |
| API fit | termbox-compatible `tb_*` primitives (init, cells, present, events) | same + [termbox2.h](https://github.com/termbox/termbox2/blob/master/termbox2.h) |
| Maintenance | Active (pushed 2026) | GitHub repo metadata |
| FFI | C ABI; demo directory shows FFI/ABI bindings in several languages | [README language bindings](https://github.com/termbox/termbox2/blob/master/README.md) |
| Size/startup | Small surface, no multimedia/terminfo runtime dep → best fit for <3 MB / <50 ms targets among real options | inferred from deps + single-header design; measure in prototype |

## Windows status (hard limit)

Windows support is **not merged**. Open PR [#123 Add experimental Windows support via `windows.sh`](https://github.com/termbox/termbox2/pull/123) (state: open, not merged as of research date). Earlier attempts: [#66](https://github.com/termbox/termbox2/pull/66), [#58](https://github.com/termbox/termbox2/pull/58).

**Plan implication:** do not block the Unix MVP path on upstream Windows. Implement the wrapper interface twice if needed (termbox2 Unix; Win32/VT Windows) and document the Windows backend as Scry-owned until upstream merges.

## Alternatives rejected

### notcurses
- Rich modern TUI library; depends on terminfo (ncurses ecosystem) and is far larger / feature-heavier than Scry needs.
- Licence metadata on GitHub is non-asserted/`NOASSERTION` without a simple MIT pin from the quick check — extra compliance work.
- API is not termbox-shaped; wrapper would be thick.
- Source: [notcurses repo](https://github.com/dankamongmen/notcurses), [notcurses(3)](https://notcurses.com/notcurses.3.html)

### Original termbox
- Superseded by termbox2; termbox2 is the maintained continuation with stricter errors and no deps beyond libc.
- Source: [termbox2 README comparison](https://github.com/termbox/termbox2/blob/master/README.md)

### ncurses / pdcurses
- Ubiquitous but heavier, terminfo-coupled, and not termbox-compatible without a large shim. Conflicts with "slim alternative to ncurses" intent of the stack.

## FFI boundary sketch

```text
src/main.c          -- embed LuaJIT, TB_IMPL or link termbox2, register opens
src/ui/tui.lua      -- only module that ffi.cdef's tb_* / Win32 backend
src/ui/*.lua        -- call tui.* only
```

LuaJIT FFI can call exported C symbols from the host executable on POSIX when linked appropriately; on Windows, either export from the exe/dll carefully or keep the backend in the host and expose a tiny Lua/C API if FFI load rules get awkward ([LuaJIT install/embed docs](https://luajit.org/install.html), [FFI API](https://luajit.org/ext_ffi_api.html)).

## Size / startup implications

- termbox2 adds little beyond a few tens of KB when compiled in; dominant binary cost will be LuaJIT + DB client libs, not the TUI backend.
- Cold start should stay dominated by LuaJIT init + config load, not termbox2 init (`tb_init` opens the tty).
- **Still measure** on the build host in [Prototype Scry runtime baseline](https://github.com/naveenadi/scry/issues/5); do not claim <3 MB / <50 ms until measured with LuaJIT linked.

## Unknowns left for the prototype

1. Exact stripped size delta of embedding termbox2 vs host-only.
2. Mouse and truecolor compile flags (`TB_OPT_*`) needed for Scry's dark/light themes and optional mouse.
3. Concrete Win32/VT backend effort if PR #123 stays unmerged.
4. Whether macOS Terminal / iTerm key sequences need any termbox2 workarounds for the Scry key table.

## Sources

- https://github.com/termbox/termbox2
- https://github.com/termbox/termbox2/blob/master/README.md
- https://github.com/termbox/termbox2/blob/master/termbox2.h
- https://github.com/termbox/termbox2/pull/123
- https://github.com/dankamongmen/notcurses
- https://luajit.org/install.html
- https://luajit.org/ext_ffi_api.html
