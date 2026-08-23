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

    /* --run <file>: execute a Lua file directly (for testing with built-in modules) */
    if (argc >= 3 && strcmp(argv[1], "--run") == 0) {
        L = luaL_newstate();
        if (!L) { fprintf(stderr, "error: failed to create Lua state\n"); return 1; }
        luaL_openlibs(L);
        preload_sqlite3(L);

        /* Push argv (skip --run and the filename) */
        lua_newtable(L);
        for (int i = 2; i < argc; i++) {
            lua_pushstring(L, argv[i]);
            lua_rawseti(L, -2, i - 2);
        }
        lua_setglobal(L, "arg");

        lua_getglobal(L, "package");
        lua_pushstring(L, "src/?.lua;?.lua;?/init.lua");
        lua_setfield(L, -2, "path");
        lua_pop(L, 1);

        if (luaL_dofile(L, argv[2]) != 0) {
            fprintf(stderr, "error: %s\n", lua_tostring(L, -1));
            lua_close(L);
            return 1;
        }
        lua_close(L);
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

    /* Set up package path to find src/ modules */
    lua_getglobal(L, "package");
    lua_pushstring(L, "src/?.lua;?.lua;?/init.lua");
    lua_setfield(L, -2, "path");
    lua_pop(L, 1);

    /* Run src/app.lua */
    lua_getglobal(L, "require");
    lua_pushstring(L, "src.app");
    if (lua_pcall(L, 1, 1, 0) != 0) {
        fprintf(stderr, "error: %s\n", lua_tostring(L, -1));
        lua_close(L);
        return 1;
    }

    /* Call app.run(arg) */
    lua_getfield(L, -1, "run");
    lua_getglobal(L, "arg");
    if (lua_pcall(L, 1, 1, 0) != 0) {
        fprintf(stderr, "error: %s\n", lua_tostring(L, -1));
        lua_close(L);
        return 1;
    }

    /* Get return code */
    int rc = 0;
    if (lua_isnumber(L, -1)) {
        rc = (int)lua_tonumber(L, -1);
    }
    lua_close(L);
    return rc;
}
