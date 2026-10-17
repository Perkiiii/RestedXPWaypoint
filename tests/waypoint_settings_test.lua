local H = dofile(ADDON_ROOT .. "/tests/harness.lua")
local R = H.load(ADDON_ROOT, { autoSync = false, strategy = "coordinates", questIcons = false, stepSound = false })
local check = H.check
local A, Panel = R.WaypointSettings, R.SettingsPanel
check("released API unavailable", not A.Connect() and A.Get("AudioGlobal") == nil)
check("unavailable write rejected", not A.Set("AudioGlobal", false))
local P = dofile(ADDON_ROOT .. "/tests/settings_provider.lua")(R)
WaypointUIAPI.Settings = P
check("public provider discovered", A.Connect())
local notifications = 0
A.RegisterListener(function() notifications = notifications + 1 end)
Panel.Open()
for _, tab in ipairs(Panel.tabs) do
    check(tab .. " is selectable", Panel.SelectTab(tab) and Panel.activeTab == tab)
end
for tab, specs in pairs(R.SettingsSchema) do
    Panel.SelectTab(tab)
    for _, spec in ipairs(specs) do
        local key, d, c = spec.key, P.Describe(spec.key), Panel.controls[spec.key]
        local original = P.Get(key)
        local value = d.type == "boolean" and not original or d.type == "select" and 2
            or d.type == "sound" and 12345 or 1.5
        -- false must remain false, rather than fall through Lua's and/or idiom.
        if d.type == "boolean" then value = not original end
        local before, writes = notifications, P.writes
        check(key .. ": adapter writes authoritative state", A.Set(key, value) and P.Get(key) == value)
        check(key .. ": one callback and write", notifications == before + 1 and P.writes == writes + 1)
        check(key .. ": identical write deduplicated", A.Set(key, value) and P.writes == writes + 1)
        P.Set(key, original)
        local shown = d.type == "boolean" and c:GetChecked() == original or d.type == "select" and c.value == original
            or d.type == "number" and c.slider:GetValue() == original or d.type == "sound" and c:GetText() == tostring(original)
        check(key .. ": other menu updates open control", shown)
        check(key .. ": no mirror in RXPWDB", RXPWDB[key] == nil)
        local count = P.writes
        if d.type == "boolean" then c:Click()
        elseif d.type == "select" then c:Click(); c.list.rows[2]:Click()
        elseif d.type == "sound" then c:SetText(tostring(value)); c:GetScript("OnEnterPressed")(c)
        else c.slider:SetValue(value) end
        local effective = P.Get(key)
        check(key .. ": widget commits once", P.writes == count + 1 and
            (d.type == "number" and math.abs(effective - value) < 0.00001 or effective == value))
        P.Set(key, original)
    end
end
check("owned saved settings preserved", not R.db.autoSync and not R.db.questIcons and not R.db.stepSound)
check("invalid bool rejected", not A.Set("AudioGlobal", 1))
check("unknown key rejected", not A.Set("arbitrary", true))
for _, value in ipairs({ -1, 0.11, 3, math.huge, -math.huge, "1" }) do
    check("invalid slider " .. tostring(value), not A.Set("WaypointScale", value))
end
check("NaN rejected", not A.Set("WaypointScale", 0/0))
check("slider minimum", A.Set("WaypointScale", 0.1))
check("slider maximum", A.Set("WaypointScale", 2))
check("invalid selection", not A.Set("WaypointSystemType", 3) and not A.Set("WaypointSystemType", 1.5))
check("sound blank mutes", A.Set("AudioCustomShowWaypoint", ""))
check("invalid sound", not A.Set("AudioCustomShowWaypoint", "abc") and not A.Set("AudioCustomShowWaypoint", -1))
P.descriptors.PinpointInfoExtended.visible = false
P.Set("PinpointInfo", false)
Panel.SelectTab("Waypoint")
check("conditional child hidden", not Panel.controls.PinpointInfoExtended:GetParent():IsShown())
check("hidden control write rejected", not A.Set("PinpointInfoExtended", false))
P.descriptors.PinpointInfoExtended.visible = true; P.Set("PinpointInfo", true)
check("conditional child returns", Panel.controls.PinpointInfoExtended:GetParent():IsShown())
P.descriptors.WaypointScale.min = "invalid"
check("invalid provider descriptor safe", A.Describe("WaypointScale") == nil)
Panel.Refresh()
check("invalid range disabled", not Panel.controls.WaypointScale.slider:IsEnabled())
P.descriptors.WaypointScale.min = 0.1
P.descriptors.WaypointScale.type = "boolean"
check("wrong provider type rejected", A.Describe("WaypointScale") == nil)
P.descriptors.WaypointScale.type = "number"
local writes = P.writes
for i = 1, 20 do Panel.canvas:Hide(); Panel.Open(); Panel.SelectTab(i % 2 == 0 and "General" or "About") end
check("reopen no writes or listener growth", P.writes == writes and P.subscriptions == 1 and P.listenerCount() == 1)
Panel.SelectTab("About")
Panel.controls.restore:Click(); H.acceptPopup("RESTEDXPWAYPOINT_RESTORE_DEFAULTS")
check("restore only owned settings", P.writes == writes and R.db.questIcons and R.db.stepSound)
Panel.canvas:Hide(); P.Set("AudioGlobal", false)
Panel.Open()
check("reopen reads fresh external state", not Panel.controls.AudioGlobal:GetChecked())
local second = dofile(ADDON_ROOT .. "/tests/settings_provider.lua")(R)
WaypointUIAPI.Settings = second; A.Connect()
check("provider replacement unsubscribes", P.listenerCount() == 0 and second.listenerCount() == 1)
second.Set = function() error("unavailable") end
check("throwing setter handled", not A.Set("AudioGlobal", false))
WaypointUIAPI.Settings = { version = 99 }
check("incompatible version rejected", not A.Connect() and second.listenerCount() == 0)
WaypointUIAPI.Settings = P; A.Connect()
P.OnChange = function() error("bad subscription") end
WaypointUIAPI.Settings = nil; A.Connect(); WaypointUIAPI.Settings = P
check("throwing subscription rejected", not A.Connect())

-- One-time new-install map default, with reliable explicitness only.
for _, case in ipairs({ "unset", "false", "true", "existing", "unknown" }) do
    local HH = dofile(ADDON_ROOT .. "/tests/harness.lua")
    local RR = HH.load(ADDON_ROOT, case == "existing" and {} or nil)
    local PP = dofile(ADDON_ROOT .. "/tests/settings_provider.lua")(RR)
    if case == "false" then PP.explicit.CustomMapPinsEnabled = true end
    if case == "true" then PP.explicit.CustomMapPinsEnabled = true; PP.values.CustomMapPinsEnabled = true end
    if case == "unknown" then PP.IsExplicit = nil end
    WaypointUIAPI.Settings = PP
    RR.WaypointSettings.ApplyFirstRunDefault()
    local expected = case == "unset" or case == "true"
    check(case .. ": correct map preference", PP.Get("CustomMapPinsEnabled") == expected)
    local count = PP.writes
    RR.WaypointSettings.ApplyFirstRunDefault(); RR.SettingsPanel.Open(); RR.SettingsPanel.canvas:Hide(); RR.SettingsPanel.Open()
    check(case .. ": never repeats initialization", PP.writes == count)
    if case == "unset" then
        PP.Set("CustomMapPinsEnabled", false); RR.WaypointSettings.ApplyFirstRunDefault()
        check("explicit later opt-out preserved", PP.Get("CustomMapPinsEnabled") == false)
    end
end
print(string.format("%d passed, %d failed", H.passes, H.fails))
if H.fails > 0 then error(H.fails .. " settings integration test(s) failed", 0) end
