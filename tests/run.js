// Offline test runner for RXP Waypoint Bridge.
// Runs every tests/*_test.lua in fengari (a Lua VM in JavaScript) with
// ADDON_ROOT set to the repository root. These tests use mocked RestedXP,
// Waypoint UI and WoW APIs; they do not prove in-game compatibility.
//
// Setup once:  npm install --prefix tests
// Run:         node tests/run.js
const fs = require('fs');
const path = require('path');

let fengari;
try {
    fengari = require('fengari');
} catch (e) {
    console.error('fengari is not installed. Run: npm install --prefix tests');
    process.exit(2);
}
const { lua, lauxlib, lualib, to_luastring } = fengari;

const root = path.resolve(__dirname, '..').replace(/\\/g, '/');
const files = fs.readdirSync(__dirname).filter((f) => f.endsWith('_test.lua')).sort();
let failed = 0;

for (const file of files) {
    console.log(`== ${file}`);
    const L = lauxlib.luaL_newstate();
    lualib.luaL_openlibs(L);
    lua.lua_pushstring(L, to_luastring(root));
    lua.lua_setglobal(L, to_luastring('ADDON_ROOT'));
    const testPath = path.join(__dirname, file).replace(/\\/g, '/');
    if (lauxlib.luaL_dofile(L, to_luastring(testPath)) !== 0) {
        console.log(`FAILED: ${lua.lua_tojsstring(L, -1)}`);
        failed++;
    }
}

console.log(failed === 0 ? 'All test files passed.' : `${failed} test file(s) failed.`);
process.exit(failed === 0 ? 0 : 1);
