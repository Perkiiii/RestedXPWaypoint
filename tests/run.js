// Offline test runner for RestedXP Waypoint.
// Runs every tests/*_test.lua in fengari (a Lua VM in JavaScript) with
// ADDON_ROOT set to the repository root. These tests use mocked RestedXP,
// Waypoint UI and WoW APIs; they do not prove in-game compatibility.
//
// Setup once:  npm install --prefix tests
// Run:         node tests/run.js            (every suite)
//              node tests/run.js settings   (suites whose name contains "settings")
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
const tocPath = path.join(root, 'RestedXPWaypoint_Camelot.toc');
const toc = fs.readFileSync(tocPath, 'utf8');
const tocFiles = toc.split(/\r?\n/).filter((line) => line && !line.startsWith('#'));
const expectedTocFiles = [
    'Core.lua', 'LabelResolver.lua', 'RXPAdapter.lua', 'NavigationResolver.lua',
    'WaypointAdapter.lua', 'Sync.lua', 'Preview.lua', 'SettingsSchema.lua', 'WaypointSettingsAdapter.lua', 'SettingsWidgets.lua', 'SettingsTabs.lua', 'SettingsPanel.lua',
];
if (!/^## Interface: 16001$/m.test(toc)
    || !/^## Title: RestedXP Waypoint$/m.test(toc)
    || !/^## Notes: An unofficial companion addon that displays RestedXP navigation through Waypoint UI\.$/m.test(toc)
    || !/^## Version: (?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)$/m.test(toc)
    || !/^## OptionalDeps: RXPGuides, WaypointUI$/m.test(toc)
    || !/^## SavedVariables: RXPWDB$/m.test(toc)
    || /RXPWaypointBridge/.test(toc)
    || JSON.stringify(tocFiles) !== JSON.stringify(expectedTocFiles)) {
    console.error('Addon TOC metadata, dependencies, SavedVariables, or module order is incorrect.');
    process.exit(1);
}
console.log('== RestedXPWaypoint_Camelot.toc metadata and module order passed');
const addonVersion = toc.match(/^## Version: (.+)$/m)[1].trim();
const filter = process.argv[2];
const files = fs.readdirSync(__dirname).filter((f) => f.endsWith('_test.lua') && (!filter || f.includes(filter))).sort();
let failed = 0;

for (const file of files) {
    console.log(`== ${file}`);
    const L = lauxlib.luaL_newstate();
    lualib.luaL_openlibs(L);
    lua.lua_pushstring(L, to_luastring(root));
    lua.lua_setglobal(L, to_luastring('ADDON_ROOT'));
    lua.lua_pushstring(L, to_luastring(addonVersion));
    lua.lua_setglobal(L, to_luastring('ADDON_VERSION'));
    const testPath = path.join(__dirname, file).replace(/\\/g, '/');
    if (lauxlib.luaL_dofile(L, to_luastring(testPath)) !== 0) {
        console.log(`FAILED: ${lua.lua_tojsstring(L, -1)}`);
        failed++;
    }
}

console.log(failed === 0 ? 'All test files passed.' : `${failed} test file(s) failed.`);
process.exit(failed === 0 ? 0 : 1);
