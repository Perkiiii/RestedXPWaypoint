const fs = require('fs');
const path = require('path');
const { lua, lauxlib, lualib, to_luastring } = require('fengari');
const source = process.argv[2];
if (!source) throw new Error('Usage: node tests/run-waypoint-api.js <separate Waypoint UI development checkout>');
const root = path.resolve(source).replace(/\\/g, '/');
const preload = fs.readFileSync(path.join(root, 'Preload.lua'), 'utf8');
const enumSource = preload.slice(preload.indexOf('local Enum ='), preload.indexOf('local Config ='));
const defaultSource = preload.slice(preload.indexOf('local DB_GLOBAL_DEFAULTS ='), preload.indexOf('local DB_GLOBAL_PERSISTENT_DEFAULTS ='));
const L = lauxlib.luaL_newstate(); lualib.luaL_openlibs(L);
for (const [key, value] of Object.entries({ SOURCE_ROOT: root, ADDON_ROOT: path.resolve(__dirname, '..').replace(/\\/g, '/'),
    ENUM_SOURCE: enumSource, DEFAULT_SOURCE: defaultSource })) {
    lua.lua_pushstring(L, to_luastring(value)); lua.lua_setglobal(L, to_luastring(key));
}
if (lauxlib.luaL_dofile(L, to_luastring(path.join(__dirname, 'waypoint_api_source_check.lua').replace(/\\/g, '/'))) !== 0) {
    console.error(lua.lua_tojsstring(L, -1)); process.exit(1);
}
