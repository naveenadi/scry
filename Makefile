# Scry production build. Dependency pins live in build/SOURCES.txt.

LUAJIT_COMMIT  = 1ee778a4e37122d8ca7d5733c590a47dafd6b15c
LUASQL_COMMIT  = 491fea76b9d9ee613fcd7de6b8a1c902e3668d11
TERMBOX_COMMIT = 9b5a5da862c06c554148c14fd38d2f796be22d57

LUAJIT_DIR = vendor/LuaJIT
LUAJIT_INC = $(LUAJIT_DIR)/src
LUAJIT_LIB = $(LUAJIT_INC)/libluajit.a
LUASQL_DIR = vendor/luasql/src
TERMBOX_H  = vendor/termbox2.h
LUAJIT_BIN = $(LUAJIT_DIR)/src/luajit
VENDOR_STAMP = vendor/.scry-pinned

CC ?= cc
CFLAGS ?= -O2
CPPFLAGS ?=
LDFLAGS ?=
MACOSX_DEPLOYMENT_TARGET ?= 10.15
SQLITE_CFLAGS = $(shell pkg-config --cflags sqlite3 2>/dev/null)
SQLITE_LIBS   = $(shell pkg-config --libs sqlite3 2>/dev/null || printf '%s' '-lsqlite3')

UNAME_S := $(shell uname -s 2>/dev/null)
ifeq ($(UNAME_S),Darwin)
  TERMBOX_LIB = libtermbox2.dylib
  TERMBOX_BUILD_FLAGS = -dynamiclib
  TERMBOX_RUNTIME_FLAGS = -Wl,-rpath,@loader_path
else ifeq ($(OS),Windows_NT)
  TERMBOX_LIB = termbox2.dll
  TERMBOX_BUILD_FLAGS = -shared
  TERMBOX_RUNTIME_FLAGS =
else
  TERMBOX_LIB = libtermbox2.so
  TERMBOX_BUILD_FLAGS = -shared
  TERMBOX_RUNTIME_FLAGS = -Wl,-rpath,'$$ORIGIN'
endif

.PHONY: all debug release clean vendor sources test check

all: release

# Fetch by commit, never by a moving branch. Existing vendor clones are reused.
$(VENDOR_STAMP): Makefile
	@mkdir -p vendor
	@if test -d $(LUAJIT_DIR)/.git; then git -C $(LUAJIT_DIR) fetch --depth 1 origin $(LUAJIT_COMMIT); else git clone --filter=blob:none https://github.com/LuaJIT/LuaJIT.git $(LUAJIT_DIR); fi
	@git -C $(LUAJIT_DIR) checkout --detach $(LUAJIT_COMMIT)
	@if test -d vendor/luasql/.git; then git -C vendor/luasql fetch --depth 1 origin $(LUASQL_COMMIT); else git clone --filter=blob:none https://github.com/lunarmodules/luasql.git vendor/luasql; fi
	@git -C vendor/luasql checkout --detach $(LUASQL_COMMIT)
	@curl -fsSL https://raw.githubusercontent.com/termbox/termbox2/$(TERMBOX_COMMIT)/termbox2.h -o $(TERMBOX_H)
	@touch $@

vendor: $(VENDOR_STAMP)

# LuaJIT's own Makefile is the portable build entry point.
$(LUAJIT_LIB): $(VENDOR_STAMP)
	$(MAKE) -C $(LUAJIT_DIR) MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) -j$$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)

# LuaSQL carries a Lua 5.1 compatibility definition of luaL_setfuncs. LuaJIT
# provides it already, so compile a patched copy without changing vendor/.
LUASQL_VERSION = 2.8.1
LUASQL_PATCHED = build/luasql.c
$(LUASQL_PATCHED): $(LUASQL_DIR)/luasql.c $(VENDOR_STAMP)
	@mkdir -p build
	@python3 -c "import re; p=open('$<').read(); p,n=re.subn(r'#if !defined LUA_VERSION_NUM \\|\\| LUA_VERSION_NUM==501.*?#endif', '/* luaL_setfuncs is provided by LuaJIT 2.1 */', p, count=1, flags=re.S); assert n == 1; open('$@','w').write(p)"

src/luasql.o: $(LUASQL_PATCHED) $(VENDOR_STAMP)
	$(CC) $(CPPFLAGS) $(CFLAGS) -fPIC -I$(LUAJIT_INC) -I$(LUASQL_DIR) $(SQLITE_CFLAGS) -DLUASQL_VERSION_NUMBER=\"$(LUASQL_VERSION)\" -c $(LUASQL_PATCHED) -o $@

src/ls_sqlite3.o: $(LUASQL_DIR)/ls_sqlite3.c $(VENDOR_STAMP)
	$(CC) $(CPPFLAGS) $(CFLAGS) -fPIC -I$(LUAJIT_INC) -I$(LUASQL_DIR) $(SQLITE_CFLAGS) -c $< -o $@

$(TERMBOX_LIB): $(TERMBOX_H) $(VENDOR_STAMP)
	@printf '%s\n' '#define TB_IMPL' '#define TB_OPT_TRUECOLOR' '#include "termbox2.h"' > build/termbox2_impl.c
	$(CC) $(CPPFLAGS) $(CFLAGS) -fPIC $(TERMBOX_BUILD_FLAGS) -Ivendor build/termbox2_impl.c -o $@

scry: src/main.c src/luasql.o src/ls_sqlite3.o $(LUAJIT_LIB) $(TERMBOX_LIB) build/SOURCES.txt
	$(CC) $(CPPFLAGS) $(CFLAGS) $(LDFLAGS) -o $@ -I$(LUAJIT_INC) src/main.c src/luasql.o src/ls_sqlite3.o \
	  $(LUAJIT_LIB) $(SQLITE_LIBS) -lm $(TERMBOX_RUNTIME_FLAGS)

build/SOURCES.txt: Makefile $(VENDOR_STAMP)
	@mkdir -p build
	@printf '%s\n' \
	  'Scry reproducible dependency pins' \
	  '' \
	  'LuaJIT:' \
	  '  repository = https://github.com/LuaJIT/LuaJIT' \
	  '  branch     = v2.1' \
	  '  commit     = $(LUAJIT_COMMIT)' \
	  '' \
	  'LuaSQL:' \
	  '  repository = https://github.com/lunarmodules/luasql' \
	  '  branch     = master' \
	  '  commit     = $(LUASQL_COMMIT) (contains async I/O PR #201)' \
	  '' \
	  'MariaDB Connector/C:' \
	  '  repository = https://github.com/mariadb-corporation/mariadb-connector-c' \
	  '  version/commit = v3.4.8 / 46880b003653a000e9588bd73c8b1dd65088c6862 (required by MySQL target)' \
	  '' \
	  'libpq:' \
	  '  distribution = system package (required by PostgreSQL target)' \
	  '  version = recorded by the PostgreSQL build environment' \
	  '' \
	  'libsqlite3:' \
	  '  distribution = system package' \
	  '  version = recorded by pkg-config on the build host' \
	  '' \
	  'Terminal backend:' \
	  '  name = termbox2' \
	  '  repository = https://github.com/termbox/termbox2' \
	  '  version/commit = v2.5.0 / $(TERMBOX_COMMIT)' > $@

sources: build/SOURCES.txt

# Always rebuild when switching configurations; objects otherwise retain the
# flags from the previous mode.
debug: clean
	$(MAKE) CFLAGS='-O0 -g' scry

release: clean
	$(MAKE) CFLAGS='-O2' scry

test: scry $(LUAJIT_BIN)
	@echo 'Running tests...'
	@for f in $$(find tests -type f -name '*_test.lua' | sort); do \
		echo "  $$f"; \
		case "$$f" in \
			tests/integration/*) ./scry --run "$$f" || exit 1 ;; \
			*) $(LUAJIT_BIN) "$$f" || exit 1 ;; \
		esac; \
	done
	@echo 'All tests passed.'

check: test

clean:
	rm -f scry libtermbox2.dylib libtermbox2.so termbox2.dll src/*.o build/luasql.c build/termbox2_impl.c
