/*
 * Scry prototype — embeds LuaJIT, registers built-in LuaSQL, loads scry.lua
 *
 * Build (macOS arm64):
 *   cc -O2 -o scry src/main.c src/luasql.o src/ls_sqlite3.o \
 *     -I vendor/LuaJIT/src \
 *     vendor/LuaJIT/src/libluajit.a \
 *     $(pkg-config --cflags --libs sqlite3) \
 *     -lm
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

/* Built-in LuaSQL SQLite3 driver */
extern int luaopen_luasql_sqlite3(lua_State *L);

static void preload_sqlite3(lua_State *L) {
    lua_getglobal(L, "package");
    lua_getfield(L, -1, "preload");
    lua_pushcfunction(L, luaopen_luasql_sqlite3);
    lua_setfield(L, -2, "luasql.sqlite3");
    lua_pop(L, 2);
}

int main(int argc, char **argv) {
    lua_State *L;

    if (argc > 1 && (strcmp(argv[1], "--help") == 0 || strcmp(argv[1], "-h") == 0)) {
        printf("scry — terminal SQL client (prototype)\n");
        printf("Usage: scry [--read-only] [--debug] [--help]\n");
        printf("       scry --version\n");
        return 0;
    }

    if (argc > 1 && strcmp(argv[1], "--version") == 0) {
        printf("scry 0.1.0-prototype\n");
        return 0;
    }

    L = luaL_newstate();
    if (!L) {
        fprintf(stderr, "error: failed to create Lua state\n");
        return 1;
    }
    luaL_openlibs(L);

    /* Register built-in modules */
    preload_sqlite3(L);

    /* Push argv */
    lua_newtable(L);
    for (int i = 0; i < argc; i++) {
        lua_pushstring(L, argv[i]);
        lua_rawseti(L, -2, i);
    }
    lua_setglobal(L, "arg");

    /* Run scry.lua from CWD */
    if (luaL_dofile(L, "scry.lua") != 0) {
        fprintf(stderr, "error: %s\n", lua_tostring(L, -1));
        lua_close(L);
        return 1;
    }

    lua_close(L);
    return 0;
}
