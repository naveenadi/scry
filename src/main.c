/*
 * Scry — embeds LuaJIT, registers built-in LuaSQL drivers, loads src.app
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

extern int luaopen_luasql_sqlite3(lua_State *L);
#if !defined(SCRY_SQLITE_ONLY)
#ifndef SCRY_NO_POSTGRES
extern int luaopen_luasql_postgres(lua_State *L);
#endif
#ifndef SCRY_NO_MYSQL
extern int luaopen_luasql_mysql(lua_State *L);
#endif
#endif

static void preload_luasql(lua_State *L) {
    lua_getglobal(L, "package");
    lua_getfield(L, -1, "preload");
    lua_pushcfunction(L, luaopen_luasql_sqlite3);
    lua_setfield(L, -2, "luasql.sqlite3");
#ifndef SCRY_SQLITE_ONLY
#ifndef SCRY_NO_POSTGRES
    lua_pushcfunction(L, luaopen_luasql_postgres);
    lua_setfield(L, -2, "luasql.postgres");
#endif
#ifndef SCRY_NO_MYSQL
    lua_pushcfunction(L, luaopen_luasql_mysql);
    lua_setfield(L, -2, "luasql.mysql");
#endif
#endif
    lua_pop(L, 2);
}

int main(int argc, char **argv) {
    lua_State *L;

    if (argc >= 3 && strcmp(argv[1], "--run") == 0) {
        L = luaL_newstate();
        if (!L) { fprintf(stderr, "error: failed to create Lua state\n"); return 1; }
        luaL_openlibs(L);
        preload_luasql(L);

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
    preload_luasql(L);

    lua_newtable(L);
    for (int i = 0; i < argc; i++) {
        lua_pushstring(L, argv[i]);
        lua_rawseti(L, -2, i);
    }
    lua_setglobal(L, "arg");

    lua_getglobal(L, "package");
    lua_pushstring(L, "src/?.lua;?.lua;?/init.lua");
    lua_setfield(L, -2, "path");
    lua_pop(L, 1);

    lua_getglobal(L, "require");
    lua_pushstring(L, "src.app");
    if (lua_pcall(L, 1, 1, 0) != 0) {
        fprintf(stderr, "error: %s\n", lua_tostring(L, -1));
        lua_close(L);
        return 1;
    }

    lua_getfield(L, -1, "run");
    lua_getglobal(L, "arg");
    if (lua_pcall(L, 1, 1, 0) != 0) {
        fprintf(stderr, "error: %s\n", lua_tostring(L, -1));
        lua_close(L);
        return 1;
    }

    int rc = 0;
    if (lua_isnumber(L, -1)) {
        rc = (int)lua_tonumber(L, -1);
    }
    lua_close(L);
    return rc;
}
