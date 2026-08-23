# Scry Makefile — builds the production binary
# See build/SOURCES.txt for pinned dependency versions

LUAJIT_DIR  = vendor/LuaJIT
LUAJIT_INC  = $(LUAJIT_DIR)/src
LUAJIT_LIB  = $(LUAJIT_DIR)/src/libluajit.a
LUASQL_DIR  = vendor/luasql/src
TERMBOX_H   = vendor/termbox2.h

CC         ?= cc
CFLAGS     ?= -O2
export MACOSX_DEPLOYMENT_TARGET = $(shell sw_vers -productVersion | cut -d. -f1-2)
SQLITE_CFLAGS = $(shell pkg-config --cflags sqlite3 2>/dev/null)
SQLITE_LIBS   = $(shell pkg-config --libs sqlite3 2>/dev/null)

# Lua source files
LUA_SRC = $(shell find src -name '*.lua' -not -path '*/platform/windows.lua')

.PHONY: all clean vendor test check

all: scry

# --- vendor fetch ---
vendor:
	mkdir -p vendor
	git clone --depth 1 --branch v2.1 https://github.com/LuaJIT/LuaJIT.git vendor/LuaJIT
	git clone --depth 1 https://github.com/lunarmodules/luasql.git vendor/luasql
	curl -fsSL 'https://raw.githubusercontent.com/termbox/termbox2/master/termbox2.h' -o vendor/termbox2.h

# --- LuaJIT ---
$(LUAJIT_LIB): $(LUAJIT_DIR)
	cd $(LUAJIT_DIR) && $(MAKE) -j$$(sysctl -n hw.ncpu)

# --- LuaSQL objects (patched to avoid luaL_setfuncs duplicate) ---
src/luasql.o: $(LUASQL_DIR)/luasql.c
	cp $< /tmp/luasql_fixed.c
	sed -i '' 's/LUASQL_VERSION_NUMBER/"2.8.0"/' /tmp/luasql_fixed.c
	python3 -c "import re; s=open('/tmp/luasql_fixed.c').read(); s=re.sub(r'#if !defined LUA_VERSION_NUM \|\| LUA_VERSION_NUM==501.*?#endif\n','/* luaL_setfuncs: provided by LuaJIT 2.1 */\n',s,count=1,flags=re.DOTALL); open('/tmp/luasql_fixed.c','w').write(s)"
	$(CC) $(CFLAGS) -fPIC -I$(LUAJIT_INC) -I$(LUASQL_DIR) $(SQLITE_CFLAGS) -c /tmp/luasql_fixed.c -o $@

src/ls_sqlite3.o: $(LUASQL_DIR)/ls_sqlite3.c
	$(CC) $(CFLAGS) -fPIC -I$(LUAJIT_INC) -I$(LUASQL_DIR) $(SQLITE_CFLAGS) -c $< -o $@

# --- termbox2 shared lib (macOS: needed for LuaJIT FFI) ---
libtermbox2.dylib: $(TERMBOX_H)
	echo '#define TB_IMPL\n#define TB_OPT_TRUECOLOR\n#include "termbox2.h"' > /tmp/termbox2_impl.c
	$(CC) $(CFLAGS) -shared -fPIC -dynamiclib -I vendor /tmp/termbox2_impl.c -o $@

# --- host binary ---
scry: src/main.c src/luasql.o src/ls_sqlite3.o $(LUAJIT_LIB) libtermbox2.dylib
	$(CC) $(CFLAGS) -o $@ -I$(LUAJIT_INC) src/main.c src/luasql.o src/ls_sqlite3.o \
	  $(LUAJIT_LIB) $(SQLITE_LIBS) -lm

# --- tests ---
test: scry
	@echo "Running tests..."
	@for f in tests/**/*_test.lua; do \
		echo "  $$f"; \
		./scry $$f || exit 1; \
	done
	@echo "All tests passed."

# --- check (lint + test) ---
check: test

clean:
	rm -f scry libtermbox2.dylib src/*.o
	rm -rf build/
