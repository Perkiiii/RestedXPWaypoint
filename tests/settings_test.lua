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
-- Registration and construction
--------------------------------------------------------------------------------
do
  local H, R = start()
  local P = R.SettingsPanel
  check("exactly one Settings category, named RestedXP Waypoint", #H.settings.categories == 1
    and H.settings.categories[1].name == "RestedXP Waypoint" and #H.settings.addOnCategories == 1
    and H.settings.addOnCategories[1] == H.settings.categories[1] and H.settings.categories[1].frame == P.canvas)
  P.Initialize(); P.Initialize()
  check("initialization is idempotent: no duplicate registration", #H.settings.categories == 1
    and #H.settings.addOnCategories == 1)
  check("the page is not built before it is first shown", P.controls.autoSync == nil and not P.canvas:IsShown())

  H.slash("config")
  check("/rxpw config opens the category by its generated ID", H.settings.opened[1] == H.settings.categories[1]:GetID()
    and P.canvas:IsShown())
  local c = P.controls
  local ids = { "autoSync", "strategy", "hideArrow", "questIcons", "serviceIcons", "customColors", "openWaypointUI",
    "previewIconDropdown", "previewIcon", "previewDistance", "previewShow", "previewNext", "previewAll",
    "previewStop", "debug", "status", "inspect", "restore" }
  local missing = {}
  for _, id in ipairs(ids) do if not c[id] then missing[#missing + 1] = id end end
  check("every control is constructed", #missing == 0, table.concat(missing, ", "))
  local titles = {}
  for _, s in ipairs(P.GetSections()) do titles[#titles + 1] = s end
  check("one page with sections General, Navigation, Waypoint Appearance, Waypoint Preview, Advanced",
    table.concat(titles, "|") == "General|Navigation|Waypoint Appearance|Waypoint Preview|Advanced",
    table.concat(titles, "|"))
  check("header shows name, subtitle, version and dependency status", P.header.title:GetText() == "RestedXP Waypoint"
    and P.header.subtitle:GetText() == "RestedXP navigation, powered by Waypoint UI."
    and P.header.version:GetText() == "v" .. ADDON_VERSION and P.header.status[1].label:GetText() == "RestedXP: detected"
    and P.header.status[2].label:GetText() == "Waypoint UI: detected" and P.header.status[3].label:GetText() == "Sync: running")
  local logo, version = P.header.logo, P.header.version
  local vp, lp = version.points[1] or {}, logo.points[1] or {}
  check("logo top-right at 80x80, version centred under it",
    logo:GetTexture() == "Interface\\AddOns\\RestedXPWaypoint\\Art\\Logo"
    and logo:GetWidth() == 80 and logo:GetHeight() == 80 and lp[1] == "TOPRIGHT" and lp[3] == "TOPRIGHT"
    and vp[1] == "TOP" and vp[2] == logo and vp[3] == "BOTTOM")
  check("content is laid out for one vertical page", P.GetContentHeight() > 600)
  H.versions.RestedXPWaypoint = "98.76.54"
  P.canvas:Hide()
  H.slash("config")
  check("reopening settings reads the installed version instead of a fixed label",
    P.header.version:GetText() == "v98.76.54")
  H.versions.RestedXPWaypoint = ADDON_VERSION
  P.canvas:Hide()
  H.slash("config")
  check("settings restores the TOC version from addon metadata",
    P.header.version:GetText() == "v" .. ADDON_VERSION)
  local content = c.autoSync:GetParent():GetParent()
  check("one uniform background: no section cards or row hover shading", #content.regions == 0
    and c.autoSync:GetParent().highlight == nil and c.questIcons:GetParent().highlight == nil)

  -- Scrolling: the wheel moves the single page and is clamped to its height.
  local scrollFrame = c.autoSync:GetParent():GetParent():GetParent()
  P.Scroll(-1)
  local down = scrollFrame:GetVerticalScroll()
  for _ = 1, 100 do P.Scroll(-1) end
  local _, range = P.GetScrollRange()
  check("mouse wheel scrolls the page and stops at the end", down > 0 and scrollFrame:GetVerticalScroll() == range
    and range > 0)
  for _ = 1, 100 do P.Scroll(1) end
  check("scrolling back stops at the top", scrollFrame:GetVerticalScroll() == 0)

  -- Clicking the dropdown again closes it (GLOBAL_MOUSE_DOWN precedes OnClick).
  c.strategy:Click()
  local open = c.strategy.list:IsShown()
  c.strategy.mouseOver = true
  H.fire("GLOBAL_MOUSE_DOWN")
  c.strategy:Click()
  c.strategy.mouseOver = false
  local closed = not c.strategy.list:IsShown()
  c.strategy:Click(); H.fire("GLOBAL_MOUSE_DOWN")
  check("dropdown toggles on its button and closes on an outside click", open and closed
    and not c.strategy.list:IsShown())

  H.inCombat = true
  local opened = #H.settings.opened
  H.slash("settings")
  check("opening during combat is refused with a message", #H.settings.opened == opened
    and H.lastChat("cannot be opened during combat") ~= nil)
  H.inCombat = false
end

-- Missing dependencies: the page still builds; dependent actions disabled.
do
  local H = fresh()
  WaypointUIAPI = nil
  RXPG_ARROW = nil
  H.aceAddons.RXPGuides = nil
  C_AddOns.IsAddOnLoaded = function(name) return name == "RestedXPWaypoint" end
  local R = H.load(ADDON_ROOT, { strategy = "coordinates" })
  local P = R.SettingsPanel
  local ok, err = pcall(P.Open)
  local c = P.controls
  check("page builds without RestedXP and Waypoint UI", ok and c.autoSync ~= nil, err)
  check("missing dependencies are shown and preview/Waypoint UI actions disabled",
    P.header.status[1].label:GetText() == "RestedXP: not loaded"
    and P.header.status[2].label:GetText() == "Waypoint UI: not loaded"
    and not c.previewShow:IsEnabled() and not c.previewAll:IsEnabled() and not c.openWaypointUI:IsEnabled()
    and not c.hideArrow:IsEnabled() and P.arrowRow.frame.desc:GetText():find("Unavailable", 1, true) ~= nil
    and P.previewStatus.frame.text:GetText():find("needs Waypoint UI", 1, true) ~= nil)
  c.autoSync:Click()
  check("settings still save without dependencies", RXPWDB.autoSync == false and not c.autoSync:GetChecked())
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
        hybrid = "Hybrid (Recommended)", ["native-first"] = "Native First" })[value]
      and P.strategyRow.frame.desc:GetText():find(value == "hybrid" and "eligible turn-ins"
        or value == "native-first" and "Prefer native" or "exact waypoint", 1, true) ~= nil)
    H.slash("status")
    check("/rxpw status reflects the panel's " .. value, H.lastChat("strategy: " .. value:gsub("%-", "%%-")) ~= nil)
  end
  H.slash("mode native-first")
  check("/rxpw mode updates the open dropdown", c.strategy.value == "native-first"
    and c.strategy.text:GetText() == "Native First")
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
  c.previewShow:Click()
  marker, at = H.wui.nav, #H.operations
  c.customColors:Click(); H.advance(4)
  check("appearance changes keep an active preview", H.wui.nav == marker and opsAfter(H, at) == 0
    and H.wui.nav.flags == "RestedXPWaypoint-Preview")
  c.previewStop:Click(); H.advance(3)
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
-- Waypoint Preview
--------------------------------------------------------------------------------
do
  local H, R = start()
  local g = rxpQuestStep(H)
  H.advance(3)
  local P = R.SettingsPanel
  P.Open()
  local c = P.controls
  check("preview defaults: Flight Master, close, nothing shown", c.previewIconDropdown.value == "flightmaster"
    and c.previewIcon.swatch:GetTexture() == OWN_ICONS .. "FlightMaster" and c.previewDistance.value == "close"
    and P.previewStatus.frame.text:GetText() == "No preview is shown." and not c.previewStop:IsEnabled())
  check("preview list offers all 14 markers with their icons", #c.previewIconDropdown.list.rows == 14
    and c.previewIconDropdown.options[1].label == "Available Quest"
    and c.previewIconDropdown.options[14].label == "Default Waypoint"
    and c.previewIconDropdown.options[14].icon == OWN_ICONS .. "DefaultWaypoint" and c.previewIconDropdown.options[14].tint == nil)
  choose(c.previewIconDropdown, "repair")
  check("selected icon shown beside the dropdown", c.previewIcon.swatch:GetTexture() == OWN_ICONS .. "Repair"
    and c.previewIcon.swatch:IsShown() and c.previewIconDropdown.text:GetText() == "Repair")
  choose(c.previewIconDropdown, "default")
  check("default waypoint: its icon in the swatch, uncoloured", c.previewIcon.swatch:IsShown()
    and c.previewIcon.swatch:GetTexture() == OWN_ICONS .. "DefaultWaypoint")
  local writes = H.wui.writes
  choose(c.previewIconDropdown, "repair"); c.previewDistance.buttons[2]:Click()
  check("selecting icon and distance writes nothing", H.wui.writes == writes and c.previewDistance.value == "far")

  c.previewShow:Click()
  check("Show Preview places the selected marker far away", H.wui.nav.flags == "RestedXPWaypoint-Preview"
    and H.wui.nav.name == "Preview: Repair" and math.abs(H.wui.nav.y - (0.5 - 0.032)) < 1e-6
    and not R.Sync.GetState().running and c.previewStop:IsEnabled()
    and P.previewStatus.frame.text:GetText():find("Preview active", 1, true) ~= nil)
  c.previewNext:Click()
  check("Next Icon advances and the dropdown follows", H.wui.nav.name == "Preview: Innkeeper"
    and c.previewIconDropdown.value == "innkeeper")
  c.previewAll:Click()
  check("Preview All cycles from the first marker", H.wui.nav.name == "Preview: Accept quest"
    and P.previewStatus.frame.text:GetText():find("cycling", 1, true) ~= nil)
  H.advance(4)
  check("the cycle advances and the page shows it", H.wui.nav.name == "Preview: Quest in progress"
    and c.previewIconDropdown.value == "incomplete")
  c.previewStop:Click(); H.advance(3)
  check("Stop Preview resumes RestedXP navigation", H.navAt(40) and H.wui.nav.flags == "RestedXPWaypoint"
    and R.Sync.GetState().running and P.previewStatus.frame.text:GetText() == "No preview is shown.")

  R.db.questIcons = false
  choose(c.previewIconDropdown, "incomplete"); c.previewShow:Click()
  check("preview follows the appearance settings", H.wui.nav.iconTexture == nil
    and H.lastChat("icon turned off in the appearance settings") ~= nil)
  R.db.questIcons = true
  c.previewStop:Click(); H.advance(2)

  P.canvas:Hide()
  c.previewShow:Click()
  P.canvas:Show()
  P.canvas:Hide()
  check("closing the page leaves the preview controllable", R.Preview.IsActive() and not c.strategy.list:IsShown())
  H.slash("preview off"); H.advance(2)

  H.setManualWaypoint("Player pin")
  local marker, at = H.wui.nav, #H.operations
  P.canvas:Show()
  c.previewStop:Click(); H.advance(2)
  check("Stop Preview without a preview leaves a manual pin alone", H.wui.nav == marker and opsAfter(H, at) == 0)
end

-- Orphaned preview after /reload, removed through the panel's Stop button.
do
  local H = fresh()
  H.restoreSession({ name = "Preview: Repair", flags = "RestedXPWaypoint-Preview" }, true)
  local R = H.load(ADDON_ROOT, { autoSync = false, strategy = "coordinates" })
  R.SettingsPanel.Open()
  local offered = R.SettingsPanel.controls.previewStop:IsEnabled()
    and R.SettingsPanel.previewStatus.frame.text:GetText():find("leftover", 1, true) ~= nil
  R.SettingsPanel.controls.previewStop:Click()
  check("orphaned preview recovery still works from the panel", offered and H.wui.nav == nil
    and H.lastChat("leftover preview marker") ~= nil)
end

--------------------------------------------------------------------------------
-- Advanced
--------------------------------------------------------------------------------
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
