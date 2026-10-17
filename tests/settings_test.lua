-- Stage 5 (v0.6.0): the single-page settings panel, the shared configuration
-- layer and the appearance settings. Mocked widgets and Settings API: these
-- tests prove wiring, state and navigation effects, NOT how the page looks.
local passes, fails = 0, 0
local current

local function check(name, ok, detail)
  if ok then passes = passes + 1; print("ok   " .. name)
  else
    fails = fails + 1
    print("FAIL " .. name .. (detail ~= nil and (" -- " .. tostring(detail)) or ""))
    if current then for i = math.max(1, #current.chat - 6), #current.chat do print("       | " .. current.chat[i]) end end
  end
end

local function fresh()
  local H = dofile(ADDON_ROOT .. "/tests/harness.lua")
  current = H
  C_Map.GetBestMapForUnit = function() return 1421 end
  C_Map.GetPlayerMapPosition = function() return { GetXY = function() return 0.5, 0.5 end } end
  GetPlayerFacing = function() return 0 end
  return H
end

local function start(saved)
  local H = fresh()
  saved = saved or {}
  saved.strategy = saved.strategy or "coordinates"
  local R = H.load(ADDON_ROOT, saved)
  return H, R
end

local function opsAfter(H, index, writer)
  local n = 0
  for i = index + 1, #H.operations do if not writer or H.operations[i].writer == writer then n = n + 1 end end
  return n
end

local function listRow(dropdown, value)
  for _, row in ipairs(dropdown.list.rows) do if row.value == value then return row end end
end

-- Choose a dropdown entry the way a player does: open, then click the row.
local function choose(dropdown, value)
  dropdown:Click()
  local opened = dropdown.list:IsShown()
  local row = listRow(dropdown, value)
  if row then row:Click() end
  return opened and row ~= nil and not dropdown.list:IsShown()
end

local function rxpQuestStep(H)
  local q = 98001
  H.quests[q] = { title = "Crystals", poi = 40, ready = false,
    objectives = { { type = "object", numFulfilled = 1, numRequired = 15, finished = false } } }
  local obj = H.complete(q, 1, { text = "1/15 Crystals" })
  local g = H.goto_(40, 0)
  H.setActiveSteps(H.newStep(1, {}, g, obj)); H.point(g)
  return g, obj, q
end

local WUI_ICONS = "Interface\\AddOns\\WaypointUI\\Art\\Icons\\"
local OWN_ICONS = "Interface\\AddOns\\RestedXPWaypoint\\Art\\Icons\\"

--------------------------------------------------------------------------------
-- Registration, six-tab construction and released-provider fallback.
do
  local H, R = start()
  local P = R.SettingsPanel
  check("one lazy category", #H.settings.categories == 1 and P.controls.autoSync == nil)
  P.Initialize(); P.Initialize()
  check("registration is idempotent", #H.settings.categories == 1)
  H.slash("config")
  local c = P.controls
  check("category opens", P.canvas:IsShown() and H.settings.opened[1] == P.category:GetID())
  check("six tabs in order", table.concat(P.tabs, "|") == "General|Waypoint|Appearance|Map|Audio|About")
  check("all owned controls exist", c.autoSync and c.strategy and c.hideArrow and c.questIcons
    and c.serviceIcons and c.customColors and c.stepSound and c.debug and c.restore and c.inspect)
  check("preview controls removed", c.previewShow == nil and c.previewIcon == nil and c.previewStop == nil)
  check("released API: no disabled shared rows, they are not shown at all", c.WaypointScale:GetParent() ~= nil
    and P.controls.WaypointScale and not P.integration.visible and P.fallbacks[1].visible
    and (function() P.SelectTab("Appearance"); local hidden = not c.WaypointScale:GetParent():IsVisible()
      P.SelectTab("General"); return hidden end)())
  check("released API: one Waypoint UI button per shared tab, explaining the tab limitation", #P.fallbacks == 4
    and c.openWaypoint.text:GetText():find("Waypoint Settings", 1, true)
    and P.fallbacks[1].description:find("cannot be asked to open a particular tab", 1, true))
  check("General header has logo, name and version", P.header.logo:GetTexture() == "Interface\\AddOns\\RestedXPWaypoint\\Art\\Logo"
    and P.header.name:GetText() == "RestedXP Waypoint"
    and P.header.version:GetText():find("Version " .. ADDON_VERSION, 1, true) == 1)
  P.SelectTab("About")
  check("About title has version and logo", P.title.subtitle:GetText() == "Version " .. ADDON_VERSION
    and P.title.icon:GetTexture() == "Interface\\AddOns\\RestedXPWaypoint\\Art\\Logo")
  WaypointUIAPI.Settings = dofile(ADDON_ROOT .. "/tests/settings_provider.lua")(R) -- shared rows make it long
  P.Refresh()
  P.SelectTab("Appearance"); P.Scroll(-1, true)
  local scroll = P.GetPage("Appearance").scroll
  local position = scroll:GetVerticalScroll()
  P.SelectTab("General"); P.SelectTab("Appearance")
  check("tab scroll position restored", position > 0 and scroll:GetVerticalScroll() == position)
  P.SelectTab("General")
  c.strategy:Click(); H.fire("GLOBAL_MOUSE_DOWN")
  check("outside click closes dropdown", not c.strategy.list:IsShown())
  H.inCombat = true
  local count = #H.settings.opened
  H.slash("config")
  check("combat opening refused", #H.settings.opened == count and H.lastChat("cannot be opened during combat"))
  H.inCombat = false
  for i = 1, 10 do P.canvas:Hide(); P.Open() end
  check("repeated open has one category", #H.settings.categories == 1)
end

do
  local H = fresh()
  WaypointUIAPI = nil; RXPG_ARROW = nil; H.aceAddons.RXPGuides = nil
  local R = H.load(ADDON_ROOT, {})
  local ok, err = pcall(R.SettingsPanel.Open)
  check("build without dependencies", ok, err)
  check("arrow and shared actions disabled", not R.SettingsPanel.controls.hideArrow:IsEnabled()
    and not R.SettingsPanel.controls.AudioGlobal:IsEnabled())
end

-- No Settings API at all: no crash, /rxpw config explains.
do
  local H = fresh()
  Settings = nil
  local R = H.load(ADDON_ROOT, {})
  H.slash("config")
  check("no settings API: graceful message", R.SettingsPanel.registered == false
    and H.lastChat("settings page is not available") ~= nil)
end

--------------------------------------------------------------------------------
-- General and Navigation
--------------------------------------------------------------------------------
do
  local H, R = start()
  local g = rxpQuestStep(H)
  H.advance(2)
  local P = R.SettingsPanel
  P.Open()
  local c = P.controls
  check("auto-sync checkbox reflects the saved setting", c.autoSync:GetChecked() == true)
  local marker, at = H.wui.nav, #H.operations
  c.autoSync:Click()
  check("auto-sync off from the panel: saved, sync stopped, waypoint left in place", RXPWDB.autoSync == false
    and not R.Sync.GetState().running and H.wui.nav == marker and opsAfter(H, at) == 0
    and not c.autoSync:GetChecked() and H.lastChat("Automatic sync disabled") ~= nil)
  H.slash("on")
  check("/rxpw on updates the open panel", c.autoSync:GetChecked() == true and R.Sync.GetState().running)
  H.slash("off")
  check("/rxpw off updates the open panel", c.autoSync:GetChecked() == false)
  c.autoSync:Click()
  check("auto-sync on from the panel restarts sync", RXPWDB.autoSync == true and R.Sync.GetState().running)

  for _, value in ipairs({ "hybrid", "native-first", "coordinates" }) do
    local picked = choose(c.strategy, value)
    check("strategy dropdown selects " .. value, picked and RXPWDB.strategy == value
      and c.strategy.value == value and c.strategy.text:GetText() == ({ coordinates = "RestedXP Coordinates",
        hybrid = "Hybrid (Recommended)", ["native-first"] = "Blizzard Waypoints" })[value])
    H.slash("status")
    check("/rxpw status reflects the panel's " .. value, H.lastChat("strategy: " .. value:gsub("%-", "%%-")) ~= nil)
  end
  H.slash("mode native-first")
  check("/rxpw mode updates the open dropdown", c.strategy.value == "native-first"
    and c.strategy.text:GetText() == "Blizzard Waypoints")
  P.canvas:Hide(); H.slash("mode hybrid"); P.canvas:Show()
  check("reopening the page never shows an outdated strategy", c.strategy.value == "hybrid")
  H.slash("mode coordinates"); H.advance(2)

  H.setManualWaypoint("Player pin")
  marker, at = H.wui.nav, #H.operations
  choose(c.strategy, "native-first"); H.advance(3)
  choose(c.strategy, "hybrid"); H.advance(3)
  check("strategy changes from the panel keep a manual pin", H.wui.nav == marker and opsAfter(H, at, "bridge") == 0)
end

--------------------------------------------------------------------------------
-- Hide RestedXP Arrow: RestedXP's own option, mirrored live
--------------------------------------------------------------------------------
do
  local H, R = start()
  local g = rxpQuestStep(H)
  H.advance(2)
  local P = R.SettingsPanel
  P.Open()
  local c = P.controls
  local profile = H.aceAddons.RXPGuides.settings.profile
  check("arrow tickbox shows RestedXP's current option", c.hideArrow:IsEnabled() and c.hideArrow:GetChecked() == false)
  c.hideArrow:Click()
  check("ticking hides the arrow through RestedXP's option", profile.disableArrow == true
    and c.hideArrow:GetChecked() and not RXPG_ARROW:IsShown() and H.rxp.drawArrow == 1
    and H.rxp.updateMap == 1 and H.rxp.lastUpdateReset == nil and H.lastChat("arrow is now hidden") ~= nil)
  check("the option is RestedXP's, not a copy in RXPWDB", RXPWDB.disableArrow == nil and RXPWDB.hideArrow == nil)
  local b = H.goto_(60, 0)
  H.setActiveSteps(H.newStep(2, {}, b)); H.point(b); H.advance(2)
  check("synchronization continues while RestedXP's arrow is hidden", H.navAt(60)
    and H.wui.nav.flags == "RestedXPWaypoint")
  c.hideArrow:Click()
  check("unticking shows it again and asks RestedXP to refresh", profile.disableArrow == false
    and not c.hideArrow:GetChecked() and H.rxp.updateMap == 2 and H.lastChat("arrow is now shown") ~= nil)
  profile.disableArrow = true -- changed in RestedXP's own settings page
  P.canvas:Hide(); P.canvas:Show()
  check("a change made in RestedXP's settings shows on reopening", c.hideArrow:GetChecked() == true)
  c.hideArrow:Click()
  c.restore:Click(); H.acceptPopup("RESTEDXPWAYPOINT_RESTORE_DEFAULTS")
  check("Restore Defaults enables Hide RestedXP Arrow", profile.disableArrow == true and c.hideArrow:GetChecked())
end

--------------------------------------------------------------------------------
-- Waypoint Appearance
--------------------------------------------------------------------------------
do
  local H, R = start()
  local g, obj, q = rxpQuestStep(H)
  H.advance(3)
  local P = R.SettingsPanel
  P.Open()
  local c = P.controls
  local function questShown(icon, colour)
    local n = H.wui.nav
    return H.navAt(40) and n.flags == "RestedXPWaypoint" and n.name == "1/15 Crystals"
      and n.iconTexture == (icon and WUI_ICONS .. "IncompleteQuest" or nil)
      and n.r == (colour and 200 / 255 or nil) and n.b == (colour and 200 / 255 or nil)
  end
  check("appearance defaults: quest icon and colour", questShown(true, true)
    and c.questIcons:GetChecked() and c.serviceIcons:GetChecked() and c.customColors:GetChecked())

  local writes = H.wui.writes
  c.questIcons:Click(); H.advance(3)
  check("quest icons off: generic icon, colour, label and coordinates kept, one write", RXPWDB.questIcons == false
    and questShown(false, true) and H.wui.writes == writes + 1)
  c.questIcons:Click(); H.advance(3)
  check("quest icons on again", questShown(true, true))
  c.customColors:Click(); H.advance(3)
  check("custom colours off: no r/g/b, icon kept", RXPWDB.customColors == false and questShown(true, false))
  c.customColors:Click(); H.advance(3)
  check("custom colours on again", questShown(true, true))

  writes = H.wui.writes
  c.questIcons:Click(); c.questIcons:Click(); H.advance(3)
  check("toggling off and on before the update causes no write", H.wui.writes == writes and questShown(true, true))

  -- Service destination
  local fp = H.goto_(60, 0)
  H.setActiveSteps(H.newStep(2, {}, fp, { tag = "fp", text = "Get the flight path" })); H.point(fp); H.advance(3)
  local green = 0x70 / 255
  check("service icon and palette by default", H.wui.nav.iconTexture == OWN_ICONS .. "FlightMaster"
    and math.abs(H.wui.nav.r - green) < 1e-6)
  c.serviceIcons:Click(); H.advance(3)
  check("service icons off: generic icon, palette, label and coordinates kept", RXPWDB.serviceIcons == false
    and H.wui.nav.iconTexture == nil and math.abs(H.wui.nav.r - green) < 1e-6 and H.navAt(60)
    and H.wui.nav.name == "Get the flight path")
  H.setActiveSteps(g.step); H.point(g); H.advance(3)
  check("service icons off does not affect quest icons", questShown(true, true))
  c.serviceIcons:Click(); H.advance(1)

  -- Manual pin and preview are never rewritten by appearance changes.
  H.setManualWaypoint("Player pin")
  local marker, at = H.wui.nav, #H.operations
  c.questIcons:Click(); c.customColors:Click(); H.advance(4)
  check("appearance changes keep a manual pin", H.wui.nav == marker and opsAfter(H, at, "bridge") == 0)
  c.questIcons:Click(); c.customColors:Click(); H.advance(1)
  H.slash("sync"); H.advance(2)
  H.slash("preview flightmaster")
  marker, at = H.wui.nav, #H.operations
  c.customColors:Click(); H.advance(4)
  check("appearance changes keep an active preview", H.wui.nav == marker and opsAfter(H, at) == 0
    and H.wui.nav.flags == "RestedXPWaypoint-Preview")
  H.slash("preview off"); H.advance(3)
  check("after the preview the bridge destination uses the new appearance", questShown(true, false))
  c.customColors:Click(); H.advance(3)

  -- Native quest markers are Waypoint UI's own: nothing to write.
  H.quests[q].ready = true
  local npc = H.goto_(70, 0)
  H.quests[q].poi = 70
  H.setActiveSteps(H.newStep(3, {}, npc, H.turnin(q, "Crystals"))); H.point(npc)
  choose(c.strategy, "native-first"); H.advance(3)
  local calls = H.st.setQuestCalls
  at = #H.operations
  c.questIcons:Click(); c.customColors:Click(); c.serviceIcons:Click(); H.advance(4)
  check("native quest tracking is not touched by appearance settings", H.mode() == "native"
    and H.st.quest == q and H.st.setQuestCalls == calls and opsAfter(H, at) == 0)
end

-- Persistence through a simulated /reload.
do
  local H, R = start()
  R.SettingsPanel.Open()
  R.SettingsPanel.controls.questIcons:Click()
  R.SettingsPanel.controls.customColors:Click()
  local saved = RXPWDB
  local H2 = fresh()
  local g = rxpQuestStep(H2)
  local R2 = H2.load(ADDON_ROOT, saved)
  H2.advance(3)
  check("appearance settings persist through /reload and apply to the first write",
    R2.db.questIcons == false and R2.db.customColors == false and R2.db.serviceIcons == true
    and H2.wui.nav.iconTexture == nil and H2.wui.nav.r == nil and H2.navAt(40))
end

--------------------------------------------------------------------------------
-- Preview remains a developer slash-command feature, independent of panel visibility.
do
  local H, R = start()
  rxpQuestStep(H); H.advance(2)
  R.SettingsPanel.Open()
  H.slash("preview all far")
  check("preview slash commands retained", R.Preview.GetState().active and not R.Sync.GetState().running)
  R.SettingsPanel.canvas:Hide(); R.SettingsPanel.Open()
  check("opening settings leaves preview state intact", R.Preview.GetState().active)
  H.slash("preview off"); H.advance(2)
  check("slash off resumes synchronization", not R.Preview.GetState().active and R.Sync.GetState().running)
end

do
  local H, R = start()
  rxpQuestStep(H); H.advance(2)
  local P = R.SettingsPanel
  P.Open()
  local c = P.controls
  c.debug:Click()
  check("debug checkbox toggles the shared setting", RXPWDB.debug == true and c.debug:GetChecked()
    and H.lastChat("Debug messages") ~= nil)
  H.slash("debug")
  check("/rxpw debug updates the panel", RXPWDB.debug == false and not c.debug:GetChecked())
  local before = #H.chat
  c.status:Click()
  local versionPattern = ADDON_VERSION:gsub("%.", "%%.")
  check("Print Status runs the status report", #H.chat > before and H.lastChat("status %(v" .. versionPattern .. "%)") ~= nil)
  c.inspect:Click()
  check("Inspect Current Step runs the inspection", H.lastChat("inspect %(strategy coordinates%)") ~= nil)

  RXPWDB.unrelated = "keep me"
  H.slash("mode hybrid"); c.questIcons:Click(); c.customColors:Click(); c.serviceIcons:Click(); c.debug:Click()
  H.setManualWaypoint("Player pin")
  local marker, at = H.wui.nav, #H.operations
  c.restore:Click()
  check("Restore Defaults asks for confirmation first", H.popups[#H.popups] == "RESTEDXPWAYPOINT_RESTORE_DEFAULTS"
    and RXPWDB.strategy == "hybrid" and RXPWDB.debug == true)
  H.acceptPopup("RESTEDXPWAYPOINT_RESTORE_DEFAULTS"); H.advance(3)
  check("Restore Defaults resets menu settings and preserves unrelated saved data", RXPWDB.strategy == "hybrid"
    and RXPWDB.debug == false and RXPWDB.questIcons and RXPWDB.serviceIcons and RXPWDB.customColors
    and RXPWDB.autoSync and RXPWDB.unrelated == "keep me")
  check("controls show the restored values", c.strategy.value == "hybrid" and not c.debug:GetChecked()
    and c.questIcons:GetChecked() and c.customColors:GetChecked())
  check("Restore Defaults keeps the manual pin", H.wui.nav == marker and opsAfter(H, at, "bridge") == 0)
end

-- Confirmation without StaticPopup: a second click is required.
do
  local H = fresh()
  StaticPopup_Show = nil
  local R = H.load(ADDON_ROOT, { strategy = "coordinates" })
  R.SettingsPanel.Open()
  local b = R.SettingsPanel.controls.restore
  b:Click()
  local waited = RXPWDB.strategy == "coordinates" and b.text:GetText() == "Click again to confirm"
  b:Click()
  check("fallback confirmation needs a second click", waited and RXPWDB.strategy == "hybrid")
end

--------------------------------------------------------------------------------
-- Saved settings compatibility
--------------------------------------------------------------------------------
do
  local H = fresh()
  local R = H.load(ADDON_ROOT)
  R.SettingsPanel.Open()
  local strategy = R.SettingsPanel.controls.strategy
  check("new installations default to recommended Hybrid", RXPWDB.strategy == "hybrid"
    and R.Config.GetDefault("strategy") == "hybrid" and strategy.value == "hybrid"
    and strategy.text:GetText() == "Hybrid (Recommended)")
  local c = R.SettingsPanel.controls
  check("new installations have debug off and every other checkbox on",
    not c.debug:GetChecked() and c.autoSync:GetChecked() and c.hideArrow:GetChecked()
    and c.questIcons:GetChecked() and c.serviceIcons:GetChecked() and c.customColors:GetChecked()
    and RXPWDB.arrowDefaultPending == nil)
  R.RXP.SetArrowHidden(false)
  local saved = RXPWDB
  local returning = fresh()
  local loaded = returning.load(ADDON_ROOT, saved)
  check("returning installations keep their visible RestedXP arrow", loaded.RXP.IsArrowHidden() == false
    and returning.rxp.updateMap == 0)
  for _, value in ipairs({ "coordinates", "hybrid", "native-first" }) do
    local savedH = fresh()
    savedH.load(ADDON_ROOT, { strategy = value })
    check("existing " .. value .. " choice survives the Hybrid default", RXPWDB.strategy == value)
  end
end

do
  local H = fresh()
  H.aceAddons.RXPGuides = nil
  local R = H.load(ADDON_ROOT)
  check("missing RestedXP defers the new-install arrow default safely",
    R.RXP.IsArrowHidden() == nil and RXPWDB.arrowDefaultPending == true)
  local saved = RXPWDB
  local nextLogin = fresh()
  local loaded = nextLogin.load(ADDON_ROOT, saved)
  check("deferred arrow default applies once RestedXP is available",
    loaded.RXP.IsArrowHidden() == true and RXPWDB.arrowDefaultPending == nil)
end

do
  local saved = { autoSync = false, debug = true, strategy = "hybrid", unrelated = 7 }
  local H, R = start(saved)
  check("v0.5.9 settings kept; new fields default on; same table", RXPWDB == saved and saved.autoSync == false
    and saved.debug == true and saved.strategy == "hybrid" and saved.unrelated == 7
    and saved.questIcons == true and saved.serviceIcons == true and saved.customColors == true)
  local bad = { strategy = "warp", questIcons = "yes", customColors = 0 }
  start(bad)
  check("invalid saved values fall back to defaults", bad.strategy == "hybrid" and bad.questIcons == true
    and bad.customColors == true)
  local H3, R3 = start({ strategy = "hybrid" })
  check("Config rejects invalid values without touching the store", R3.Config.Set("strategy", "warp") == false
    and R3.Config.Set("questIcons", "no") == false and R3.Config.Set("bogus", true) == false
    and RXPWDB.strategy == "hybrid" and RXPWDB.questIcons == true and RXPWDB.bogus == nil)
end

print(string.format("%d passed, %d failed", passes, fails))
if fails > 0 then error(fails .. " test(s) failed", 0) end
