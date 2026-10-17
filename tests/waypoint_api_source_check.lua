-- Runs only through run-waypoint-api.js with an explicit external checkout.
-- Executes the real schema, defaults, enums, saved-variable handler, callback
-- registry and patched API. Frame rendering and gameplay remain mocked.
local modules = {}
local env = { modules = {} }
function env.modules:New(name) modules[name] = {}; return modules[name] end
function env.modules:Import(name) modules[name] = modules[name] or {}; return modules[name] end
env.modules.Await = env.modules.Import
local function source(file) return assert(loadfile(SOURCE_ROOT .. "/" .. file))("WaypointUI", env) end
SOUNDKIT = { UI_RUNECARVING_OPEN_MAIN_WINDOW = 1, UI_RUNECARVING_CLOSE_MAIN_WINDOW = 2 }
C_AddOns = { IsAddOnLoaded = function() return false end }
BreakUpLargeNumbers = tostring
assert(load(ENUM_SOURCE .. "\nreturn env", "enum", "t", setmetatable({env=env, Path={Root="WaypointUI"}}, {__index=_G})))()
env.Config = {}
local defaults = assert(load(DEFAULT_SOURCE .. "\nreturn DB_GLOBAL_DEFAULTS", "defaults", "t",
    setmetatable({ Enum=env.Enum, WoWClient={IS_FOREVER=true} }, {__index=_G})))()
source("packages/callback-registry/index.lua")
source("packages/saved-variables/src/enum.lua")
source("packages/saved-variables/src/handler.lua")
modules["packages\\saved-variables"] = modules["packages\\saved-variables\\handler"]
local Saved = modules["packages\\saved-variables"]
local db = Saved.RegisterDatabase("WaypointDB_Global").defaults(defaults)
env.Config.DBGlobal = db
source("Code/Waypoint/Waypoint_Enum.lua")
source("Code/Settings/Settings_Enum.lua")
source("Code/SharedUtil.lua")
modules["@\\Settings\\Define"] = { Descriptor=function(t) return t end, TitleInfo=function(t) return t end }
modules["@\\Settings\\Preload"] = { FRAME_NAME="WUISettingFrame" }
WUISettingFrame = { Prompt={} }
env.L = setmetatable({}, {__index=function(_, key) return key end})
source("Code/Settings/Settings_Schema.lua")
source("API.lua")
local API = assert(WaypointUIAPI.Settings, "Development API missing")
local R = {}; assert(loadfile(ADDON_ROOT .. "/SettingsSchema.lua"))("RestedXPWaypoint", R)
local passed = 0
local function check(name, condition) assert(condition, name); passed = passed + 1 end
local changes, runtime, refreshes = 0, 0, 0
local cancel = API.OnChange("*", function() changes = changes + 1 end)
Saved.OnChange("WaypointDB_Global", "WaypointScale", function() runtime = runtime + 1 end)
modules["packages\\callback-registry"].Add("Setting.Refresh", function() refreshes = refreshes + 1 end)
for _, specs in pairs(R.SettingsSchema) do
    for _, spec in ipairs(specs) do
        local d, errorText = API.Describe(spec.key)
        check(spec.key .. ": real schema descriptor " .. tostring(errorText), d and d.type == spec.type)
        check(spec.key .. ": real default", API.Get(spec.key) == d.default)
        check(spec.key .. ": unset distinguished", API.IsExplicit(spec.key) == false)
        if d.type == "number" then
            check(spec.key .. ": lower/upper bounds", API.Set(spec.key, d.min) and API.Set(spec.key, d.max))
            check(spec.key .. ": outside bounds", not API.Set(spec.key, d.min - d.step) and not API.Set(spec.key, d.max + d.step))
            check(spec.key .. ": off step", not API.Set(spec.key, d.min + d.step * 0.25))
        elseif d.type == "select" then
            for _, option in ipairs(d.options) do check(spec.key .. ": selection", API.Set(spec.key, option.value)) end
            check(spec.key .. ": invalid selection", not API.Set(spec.key, #d.options + 1))
        elseif d.type == "sound" then
            check(spec.key .. ": sound and mute", API.Set(spec.key, 12345) and API.Set(spec.key, ""))
        else check(spec.key .. ": boolean", API.Set(spec.key, not d.default)) end
        check(spec.key .. ": restore", API.Set(spec.key, d.default))
    end
end
check("unknown key closed", not API.Set("lastLoadedVersion", 7) and API.Get("lastLoadedVersion") == nil)
check("nonfinite rejected", not API.Set("WaypointScale", 0/0) and not API.Set("WaypointScale", math.huge))
local before = changes
check("API write uses real runtime callback", API.Set("WaypointScale", 1.5) and runtime > 0)
check("API notifies once", changes == before + 1)
before = changes; local uiBefore = refreshes
API.Set("WaypointScale", 1.5)
check("API duplicate has no callback or UI refresh", changes == before and refreshes == uiBefore)
db:SetVariable("WaypointScale", 1.6)
check("native settings writer notifies API", changes == before + 1 and API.Get("WaypointScale") == 1.6)
API.Set("CustomMapPinsEnabled", false)
-- Set equal to default is intentionally a no-op; a real UI write stores false.
db:SetVariable("CustomMapPinsEnabled", false)
check("explicit false distinguishable", API.IsExplicit("CustomMapPinsEnabled") == true and API.Get("CustomMapPinsEnabled") == false)
API.Set("WaypointSystemType", 3)
check("waypoint mode hides waypoint appearance", API.Describe("WaypointScale").visible == false)
check("pinpoint mode hides transition threshold", API.Describe("DistanceThresholdPinpoint").visible == false)
API.Set("WaypointSystemType", 1); API.Set("PinpointInfo", false)
check("parent hides extended info", API.Describe("PinpointInfoExtended").visible == false)
API.Set("WaypointUseWorldScale", false)
check("world scale dependency", API.Describe("WaypointScaleMin").visible == false)
API.Set("WaypointBeam", false)
check("beam dependency", API.Describe("WaypointBeamAlpha").visible == false)
API.Set("NavigatorShow", false)
check("navigator dependency", API.Describe("NavigatorScale").visible == false)
API.Set("AudioGlobal", false)
check("global audio dependency", API.Describe("AudioProximityDistance").visible == false)
API.Set("AudioGlobal", true); API.Set("AudioProximity", false)
check("proximity dependency", API.Describe("AudioProximityDistance").visible == false)
API.Set("AudioCustom", false)
check("custom audio dependency", API.Describe("AudioCustomShowWaypoint").visible == false)
API.Set("AutoTrackPlacedPinEnabled", true)
check("auto track link dependency", API.Describe("AutoTrackChatLinkPinEnabled").visible == false)
API.Set("PrefMetric", true)
local distance = API.Describe("DistanceThresholdPinpoint")
check("metric schema range", distance.min == 46 and distance.max == 458 and distance.step == 5)
check("metric source formatting", API.Format("DistanceThresholdPinpoint", 100) == "92 m")
cancel(); before = changes; API.Set("PrefMetric", false)
check("unsubscribe", before == changes)
local bad = API.OnChange("unknown", function() end)
check("unknown subscription rejected", bad == nil)
print(passed .. " real-source API assertions passed (offline; no rendered UI or live client).")
