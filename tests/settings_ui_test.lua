-- Settings page interaction, through the harness's geometry and hit-testing:
-- clicks are delivered to whichever frame is on top at the clicked point, so
-- a covered, clipped or unlaid-out control fails here. Offline evidence only:
-- fonts are approximated and nothing is drawn; in-game acceptance remains.
local passes, fails = 0, 0
local function check(name, ok, detail)
  if ok then passes = passes + 1; print("ok   " .. name)
  else fails = fails + 1; print("FAIL " .. name .. (detail ~= nil and (" -- " .. tostring(detail)) or "")) end
end

local function load(saved, setup)
  local H = dofile(ADDON_ROOT .. "/tests/harness.lua")
  C_Map.GetBestMapForUnit = function() return 1421 end
  C_Map.GetPlayerMapPosition = function() return { GetXY = function() return 0.5, 0.5 end } end
  GetPlayerFacing = function() return 0 end
  if setup then setup(H) end
  local R = H.load(ADDON_ROOT, saved or { strategy = "hybrid" })
  R.SettingsPanel.Open()
  return H, R, R.SettingsPanel
end

local function near(a, b) return math.abs(a - b) < 0.01 end
local function rectText(r) return r and string.format("%.1f,%.1f,%.1f,%.1f", r[1], r[2], r[3], r[4]) or "nil" end
local function inside(inner, outer)
  return inner and outer and inner[1] >= outer[1] - 0.01 and inner[3] <= outer[3] + 0.01
    and inner[2] >= outer[2] - 0.01 and inner[4] <= outer[4] + 0.01
end
-- Scrolls the active page so a row's control is fully in view (instantly).
local function reveal(H, P, control)
  local page = P.GetPage()
  local view, r = H.ui.rect(page.scroll), H.ui.rect(control)
  if r[2] < view[2] + 20 or r[4] > view[4] - 20 then
    page.scrollbar:ScrollTo(page.scroll:GetVerticalScroll() + (view[4] - r[4]) - 40, true)
  end
end
local function visiblePages(P)
  local list = {}
  for _, name in ipairs(P.tabs) do if P.pages[name].frame:IsVisible() then list[#list + 1] = name end end
  return table.concat(list, ",")
end
-- Rows of a page's containers whose control is currently inside the viewport.
local function controlsInView(H, P, name)
  local result = {}
  for _, block in ipairs(P.pages[name].blocks) do
    for _, row in ipairs(block.rows or {}) do
      if row.control and row.control.mouse and row.frame:IsVisible() and H.ui.rendered(row.control) then
        local r, v = H.ui.rect(row.control), H.ui.visibleRect(row.control)
        if near(r[2], v[2]) and near(r[4], v[4]) then result[#result + 1] = row end
      end
    end
  end
  return result
end

--------------------------------------------------------------------------------
-- Frame placement: Waypoint UI's offsets around Blizzard's settings canvas.
do
  local H, R, P = load()
  local canvas, root = H.ui.rect(P.canvas), H.ui.rect(P.root)
  check("root frame sits 16 px left, 10 up, 6 below like Waypoint UI", near(root[1], canvas[1] - 16)
    and near(root[3], canvas[3]) and near(root[4], canvas[4] + 10) and near(root[2], canvas[2] + 6), rectText(root))
  local divider = H.ui.rect(P.divider)
  check("2 px divider at the sidebar's right edge, full height", near(divider[1], root[1] + 210)
    and near(divider[3], root[1] + 212) and near(divider[4], root[4]) and near(divider[2], root[2]), rectText(divider))
  local content = H.ui.rect(P.contentArea)
  check("content area right of the sidebar, 17.5 px inset", near(content[1], root[1] + 229.5)
    and near(content[3], root[3] - 17.5), rectText(content))
  local previousBottom
  for i, name in ipairs({ "General", "Waypoint", "Appearance", "Map", "Audio" }) do
    local r = H.ui.rect(P.tabButtons[name])
    local ok = near(r[1], root[1] + 22.5) and near(r[3], root[1] + 189.5) and near(r[4] - r[2], 35)
      and near(r[4], root[4] - 22.5 - (i - 1) * 38)
    if previousBottom then ok = ok and near(previousBottom - r[4], 3) end
    check(name .. " tab: 167 x 35, 3 px spacing", ok, rectText(r))
    previousBottom = r[2]
  end
  local about = H.ui.rect(P.tabButtons.About)
  check("About anchored 22.5 px above the sidebar bottom", near(about[2], root[2] + 22.5)
    and near(about[4] - about[2], 35), rectText(about))
  local page = H.ui.rect(P.GetPage("General").scroll)
  check("page scroll frame leaves 22 px for the scroll bar", near(page[3], content[3] - 22), rectText(page))
end

--------------------------------------------------------------------------------
-- Tab switching with real clicks.
do
  local H, R, P = load()
  check("General is shown first, alone", P.activeTab == "General" and visiblePages(P) == "General")
  for _, name in ipairs({ "Waypoint", "Appearance", "Map", "Audio", "About", "General" }) do
    local button = P.tabButtons[name]
    local got = H.ui.click(button)
    check(name .. ": the click reaches the tab button", got == button)
    check(name .. ": only its page is visible", P.activeTab == name and visiblePages(P) == name, visiblePages(P))
    local looks = true
    for other, b in pairs(P.tabButtons) do
      if other == name then
        looks = looks and b.selected and b.background.artName == "TabSelectedHighlighted" and b.text:GetAlpha() == 1
      else
        looks = looks and not b.selected and b.background:IsShown() == false and b.text:GetAlpha() == 0.5
      end
    end
    check(name .. ": selected look on it only (gold art, white text; others transparent, faded)", looks)
    local inView = controlsInView(H, P, name)
    local reachable = #inView > 0 or name == "About"
    for _, row in ipairs(inView) do
      local x, y = H.ui.pointOf(row.control)
      local target = H.ui.hit(x, y)
      local owner = target
      while owner and owner ~= row.control do owner = owner.parent end
      if not owner then reachable = false; print("       covered: " .. tostring(row.label)) end
    end
    check(name .. ": every control in view takes the mouse (" .. #inView .. ")", reachable)
    local hidden = true
    for other, page in pairs(P.pages) do
      if other ~= name then
        for _, block in ipairs(page.blocks) do
          for _, row in ipairs(block.rows or {}) do
            if row.control and H.ui.rendered(row.control) then hidden = false end
          end
        end
      end
    end
    check(name .. ": controls of other tabs are neither drawn nor clickable", hidden)
  end
  -- Hover and press states of an unselected tab.
  local map = P.tabButtons.Map
  H.ui.moveTo(H.ui.pointOf(map))
  check("hovering an unselected tab: grey highlight, full-opacity text", map.background.artName == "TabHighlighted"
    and map.text:GetAlpha() == 1)
  map:GetScript("OnMouseDown")(map)
  check("pressing it: pushed art, 0.75 text", map.background.artName == "TabPushed" and map.text:GetAlpha() == 0.75)
  map:GetScript("OnMouseUp")(map)
  H.ui.moveTo(H.ui.pointOf(P.GetPage("General").scroll))
  check("leaving it: transparent again", not map.background:IsShown() and map.text:GetAlpha() == 0.5)

  -- Values survive tab changes, and controls stay interactive.
  local c = P.controls
  H.ui.click(c.autoSync)
  check("General checkbox clicked through the page", RXPWDB.autoSync == false and not c.autoSync:GetChecked())
  H.ui.click(P.tabButtons.Appearance); H.ui.click(P.tabButtons.General)
  check("returning to General keeps the value", not c.autoSync:GetChecked())
  H.ui.click(c.autoSync)
  check("and the checkbox still works", RXPWDB.autoSync == true and c.autoSync:GetChecked())

  -- A failing refresh can never block navigation.
  local original = R.SettingsTabs.Refresh
  R.SettingsTabs.Refresh = function() error("simulated provider failure") end
  local ok = pcall(H.ui.click, P.tabButtons.Audio)
  check("a refresh error still switches the page", ok and P.activeTab == "Audio" and visiblePages(P) == "Audio")
  R.SettingsTabs.Refresh = original
  H.ui.click(P.tabButtons.General)
end

--------------------------------------------------------------------------------
-- Containers, rows and branding.
do
  local H, R, P = load()
  local page = P.GetPage("General")
  check("General starts with the logo header, then Synchronization and Connection Status",
    page.blocks[1].kind == "header" and page.blocks[2].title == "Synchronization"
    and page.blocks[3].title == "Connection Status")
  check("logo header drawn on General", H.ui.rendered(P.header.logo) and H.ui.rendered(P.header.name))
  local sync = page.blocks[2]
  local main = H.ui.rect(sync.frame.main)
  local inOne = #sync.rows == 3
  for _, row in ipairs(sync.rows) do inOne = inOne and inside(H.ui.rect(row.frame), main) end
  check("the three synchronization settings share one container", inOne)
  check("container uses Waypoint UI's rounded container art, 3.5 px outset",
    sync.frame.background.artName == "Container" and sync.frame.background.texture:find("Widget%-Container")
    and near(H.ui.rect(sync.frame.background)[1], main[1] - 3.5))
  local first, second = H.ui.rect(sync.rows[1].frame), H.ui.rect(sync.rows[2].frame)
  check("rows inset 12.5 px, 10 px apart", near(first[1], main[1] + 12.5) and near(first[4], main[4] - 12.5)
    and near(first[2] - second[4], 10))
  local title = H.ui.rect(sync.frame.title)
  check("gold 14 pt title centred in a 32 px strip, 15 px in", near(title[1], H.ui.rect(sync.frame)[1] + 15)
    and sync.frame.title.textColor[1] == 1 and math.abs(sync.frame.title.textColor[2] - 0.82) < 0.01)
  local row = sync.rows[1]
  check("label white 12 pt, description faded 11 pt", row.frame.label.font.fontSize == 12
    and row.frame.desc.font.fontSize == 11 and row.frame.desc.textColor[4] == 0.5)
  H.ui.moveTo(H.ui.pointOf(row.frame.label))
  check("hovering a row shows Waypoint UI's widget highlight", row.frame.hover:IsShown()
    and row.frame.hover.artName == "Widget")
  H.ui.moveTo(H.ui.pointOf(P.controls.autoSync))
  check("the highlight stays while over the row's control", row.frame.hover:IsShown())
  H.ui.click(P.tabButtons.About)
  check("About shows the faint large logo title, General's header is hidden", H.ui.rendered(P.title.icon)
    and P.title.icon:GetAlpha() < 0.1 and not H.ui.rendered(P.header.logo))
end

--------------------------------------------------------------------------------
-- Navigation Strategy dropdown.
do
  local H, R, P = load({ strategy = "hybrid" })
  local dd = P.controls.strategy
  local labels = {}
  for i, option in ipairs(dd.options) do labels[i] = option.value .. "=" .. option.label end
  check("strategy options in the agreed order", table.concat(labels, "|")
    == "hybrid=Hybrid (Recommended)|coordinates=RestedXP Coordinates|native-first=Blizzard Waypoints")
  local fits = true
  for _, option in ipairs(dd.options) do
    dd.text:SetText(option.label)
    if dd.text:GetStringWidth() > H.ui.rect(dd.text)[3] - H.ui.rect(dd.text)[1] + 0.5 then fits = false end
  end
  dd:SetValue(dd.value)
  check("every option fits the button without truncation", fits and dd:GetWidth() >= 125, dd:GetWidth())
  local label = H.ui.rect(P.strategyRow.frame.label)
  check("dropdown never overlaps its label", label[3] <= H.ui.rect(dd)[1])
  check("description follows the selection (Hybrid)", P.strategyRow.description:find("^Uses Blizzard quest waypoints"))
  check("click reaches the dropdown", H.ui.click(dd) == dd and dd.list:IsShown())
  local list = H.ui.rect(dd.list)
  check("menu opens 6 px below, at least 175 px wide, rows 28 px", near(list[4], H.ui.rect(dd)[2] - 6)
    and list[3] - list[1] >= 175 and near(H.ui.rect(dd.list.rows[1])[4] - H.ui.rect(dd.list.rows[1])[2], 28))
  local row = dd.list.rows[2]
  check("menu rows are on top and take the click", H.ui.click(row) == row)
  check("choosing RestedXP Coordinates saves the id and closes the menu", RXPWDB.strategy == "coordinates"
    and not dd.list:IsShown() and dd.text:GetText() == "RestedXP Coordinates")
  check("description follows the selection (Coordinates)",
    P.strategyRow.description == "Always follows RestedXP's coordinates for navigation.")
  H.ui.click(dd); H.ui.click(dd.list.rows[3])
  check("Blizzard Waypoints maps to native-first", RXPWDB.strategy == "native-first"
    and P.strategyRow.description:find("^Prioritizes Blizzard's native quest navigation"))
  H.ui.click(dd)
  H.ui.click(P.controls.autoSync)
  check("clicking elsewhere closes the menu", not dd.list:IsShown())
  H.ui.click(P.controls.autoSync)
end

--------------------------------------------------------------------------------
-- Scrolling: each page scrolls on its own; the sidebar never moves.
do
  local H, R, P = load()
  WaypointUIAPI.Settings = dofile(ADDON_ROOT .. "/tests/settings_provider.lua")(R) -- shared rows make it long
  P.Refresh()
  H.ui.click(P.tabButtons.Appearance)
  local page = P.GetPage("Appearance")
  local before = H.ui.rect(P.tabButtons.General)
  check("long page shows its scroll bar", page.scrollbar:IsShown() and page.scrollbar:GetRange() > 0)
  local firstRow = page.blocks[1].rows[1]
  H.ui.wheel(page.scroll, -1); H.ui.update(2)
  local offset = page.scroll:GetVerticalScroll()
  check("mouse wheel scrolls 150 px, interpolated", near(offset, 150), offset)
  check("scroll bar follows", near(page.scrollbar:GetValue(), offset))
  check("sidebar does not move", rectText(before) == rectText(H.ui.rect(P.tabButtons.General)))
  local hiddenRow = firstRow.control
  local r = H.ui.rect(hiddenRow)
  local view = H.ui.rect(page.scroll)
  check("content scrolled out of view is clipped and not clickable", r[2] > view[4] and not H.ui.rendered(hiddenRow))
  H.ui.click(P.tabButtons.General)
  check("General keeps its own position", P.GetPage("General").scroll:GetVerticalScroll() == 0)
  H.ui.click(P.tabButtons.Appearance)
  check("Appearance keeps its scroll position", near(page.scroll:GetVerticalScroll(), offset))
  for _ = 1, 20 do H.ui.wheel(page.scroll, -1) end
  H.ui.update(3)
  check("scrolling stops at the end", near(page.scroll:GetVerticalScroll(), page.scrollbar:GetRange()))
  WaypointUIAPI.Settings = nil
  local general = P.GetPage("General")
  P.canvas.width, P.canvas.height = 680, 600 -- about the in-game canvas at UI scale 1
  H.ui.click(P.tabButtons.General)
  check("General fits a typical canvas: no scroll bar", not general.scrollbar:IsShown(), general.height)
end

--------------------------------------------------------------------------------
-- Waypoint UI-owned controls with the public provider: sliders, steppers,
-- dropdowns, inputs, conditional rows, value text.
do
  local H, R, P = load({ strategy = "hybrid" })
  local provider = dofile(ADDON_ROOT .. "/tests/settings_provider.lua")(R)
  WaypointUIAPI.Settings = provider
  P.Refresh()
  H.ui.click(P.tabButtons.Waypoint)
  local c = P.controls
  local slider = c.DistanceThresholdPinpoint
  check("slider is Waypoint UI's 188 x 19 range with value text", near(slider:GetWidth(), 188)
    and near(slider:GetHeight(), 19) and slider.text:GetText() == "1 units")
  local writes = provider.writes
  reveal(H, P, slider)
  check("forward stepper takes the click", H.ui.click(slider.forward) == slider.forward)
  check("stepper moves one step and writes once", math.abs(provider.Get("DistanceThresholdPinpoint") - 1.1) < 1e-6
    and provider.writes == writes + 1 and slider.text:GetText():find("^1%.1"))
  H.ui.click(slider.backward)
  check("backward stepper returns", math.abs(provider.Get("DistanceThresholdPinpoint") - 1) < 1e-6)
  local mode = c.WaypointSystemType
  reveal(H, P, mode)
  H.ui.click(mode); H.ui.click(mode.list.rows[2])
  check("shared dropdown writes the provider", provider.Get("WaypointSystemType") == 2 and mode.text:GetText() == "Second")
  local child = c.PinpointInfoExtended
  local parentRow = c.PinpointInfo:GetParent()
  check("indented child row is 15 px further in (Waypoint UI indent)",
    near(H.ui.rect(child:GetParent().label)[1] - H.ui.rect(parentRow.label)[1], 15))
  provider.descriptors.PinpointInfoExtended.visible = false
  reveal(H, P, c.PinpointInfo)
  H.ui.click(c.PinpointInfo)
  check("conditional row hides and the layout closes the gap", not child:GetParent():IsShown()
    and provider.Get("PinpointInfo") == false)
  provider.descriptors.PinpointInfoExtended.visible = true
  reveal(H, P, c.PinpointInfo)
  H.ui.click(c.PinpointInfo)
  check("and returns", child:GetParent():IsShown())
  H.ui.click(P.tabButtons.Audio)
  local input = c.AudioProximitySound
  check("sound input is 188 x 32 with Waypoint UI's input art", near(input:GetWidth(), 188)
    and input.texture.artName == "Input")
  provider.descriptors.AudioGlobal.enabled = false
  P.Refresh()
  check("disabled control uses the disabled art", c.AudioGlobal.texture.artName == "CheckedDisabled"
    and not c.AudioGlobal:IsEnabled())
end

--------------------------------------------------------------------------------
-- Waypoint UI-owned settings without the public Settings API: no disabled
-- rows, one button per tab; with the API the real controls replace it.
do
  local H, R, P = load()
  local opened = 0
  WaypointUIAPI.OpenSettingsUI = function() opened = opened + 1 end
  P.Refresh()
  local expected = { Waypoint = "openWaypoint", Appearance = "openAppearance", Map = "openMap", Audio = "openAudio" }
  for tab, id in pairs(expected) do
    H.ui.click(P.tabButtons[tab])
    local page = P.GetPage(tab)
    local buttons, sharedShown = 0, false
    for _, block in ipairs(page.blocks) do
      for _, row in ipairs(block.rows or {}) do
        if row.frame:IsVisible() and row.button then buttons = buttons + 1 end
        if row.frame:IsVisible() and row.id and R.WaypointSettings.Describe and P.controls[row.id] and row.control
          and not row.button and (row.control.slider or row.control.list or row.control.checked ~= nil)
          and not ({ questIcons = 1, serviceIcons = 1, customColors = 1, stepSound = 1 })[row.id] then sharedShown = true end
      end
    end
    local button = P.controls[id]
    check(tab .. ": exactly one Waypoint UI button and no shared rows", buttons == 1 and not sharedShown)
    check(tab .. ": button text names the tab and is not truncated", button.text:GetText():find(tab .. " Settings", 1, true)
      and button:GetWidth() >= button.text:GetStringWidth() + 31)
    local before = opened
    check(tab .. ": the click opens Waypoint UI's settings", H.ui.click(button) == button and opened == before + 1)
  end
  H.ui.click(P.tabButtons.Appearance)
  check("RestedXP Waypoint's own appearance settings stay usable", H.ui.click(P.controls.questIcons) == P.controls.questIcons
    and RXPWDB.questIcons == false)
  H.ui.click(P.controls.questIcons)
  H.ui.click(P.tabButtons.Audio)
  check("RestedXP Waypoint's own audio setting stays usable", H.ui.rendered(P.controls.stepSound))
  WaypointUIAPI.Settings = dofile(ADDON_ROOT .. "/tests/settings_provider.lua")(R)
  P.Refresh()
  check("with the public API: real controls, no fallback button", P.controls.AudioGlobal:GetParent():IsVisible()
    and not P.controls.openAudio:IsVisible())
  WaypointUIAPI.OpenSettingsUI = nil
  WaypointUIAPI.Settings = nil
  P.Refresh()
  check("fallback button disabled when Waypoint UI cannot open its settings", P.controls.openAudio:IsVisible()
    and not P.controls.openAudio:IsEnabled())
end

--------------------------------------------------------------------------------
-- Layout at other canvas sizes (UI scale / resolution).
for _, case in ipairs({ { 560, 420 }, { 640, 520 }, { 980, 760 }, { 560, 420, true }, { 680, 600, true } }) do
  local size = case
  local H, R, P = load()
  if case[3] then WaypointUIAPI.Settings = dofile(ADDON_ROOT .. "/tests/settings_provider.lua")(R) end
  P.canvas.width, P.canvas.height = size[1], size[2]
  local ok = true
  for _, name in ipairs(P.tabs) do
    P.SelectTab(name)
    local page = P.GetPage(name)
    local view = H.ui.rect(page.scroll)
    for _, block in ipairs(page.blocks) do
      if block.frame:IsShown() and block.rows then
        local main = H.ui.rect(block.frame.main)
        for _, row in ipairs(block.rows) do
          if row.frame:IsShown() then
            local label = H.ui.rect(row.frame.label)
            if not inside(H.ui.rect(row.frame), main) or label[1] < main[1] then ok = false end
            if row.control then
              local control = H.ui.rect(row.control)
              local text = row.frame.desc:IsShown() and H.ui.rect(row.frame.desc) or label
              local clash = row.stacked and control[4] > text[2] + 0.5 or not row.stacked and label[3] > control[1] + 0.5
              if clash or control[3] > main[3] + 0.5 or not inside(control, H.ui.rect(row.frame)) then
                ok = false; print("       overlap: " .. name .. " / " .. tostring(row.label))
              end
            end
            if main[3] > view[3] + 0.5 then ok = false end
          end
        end
      end
    end
  end
  check(string.format("%dx%d%s: rows inside containers, no label/control overlap", size[1], size[2],
    case[3] and " with shared controls" or ""), ok)
end

--------------------------------------------------------------------------------
-- Connection status.
do
  local H, R, P = load({ strategy = "hybrid" })
  local c = P.controls
  local function shows(item, state, text)
    local style = P.STATUS_STYLES[state]
    return item.state == state and item.value.text:GetText() == text
      and item.frame.icon:GetTexture():find(style.icon == "check" and "StatusCheck" or style.icon == "cross" and "StatusCross"
        or style.icon == "pause" and "StatusPause" or "StatusWarning")
      and item.value.text.textColor[1] == style.color[1] and item.frame.icon.vertex[2] == style.color[2]
  end
  check("dependencies connected (green check)", shows(c.statusRXP, "connected", "Connected")
    and shows(c.statusWUI, "connected", "Connected"))
  check("synchronization active (green check)", shows(c.statusSync, "active", "Active"))
  local icon, label, value = H.ui.rect(c.statusSync.frame.icon), H.ui.rect(c.statusSync.frame.label), H.ui.rect(c.statusSync.value)
  check("icon and label left, status text right-aligned", icon[3] < label[1] and label[3] < value[1]
    and near(value[3], H.ui.rect(c.statusSync.frame)[3] - 2))
  H.ui.click(c.autoSync)
  check("auto-sync off: grey pause, Disabled", shows(c.statusSync, "disabled", "Disabled"))
  H.ui.click(c.autoSync)
  H.setManualWaypoint("Player pin"); H.advance(1)
  check("manual navigation: amber pause, Paused (from the sync status listener)",
    shows(c.statusSync, "paused", "Paused"))
end
do
  local H, R, P = load({ strategy = "hybrid" })
  local g = H.goto_(40, 0); H.setActiveSteps(H.newStep(1, {}, g)); H.point(g); H.advance(2)
  H.slash("preview flightmaster")
  check("development preview: amber Paused, reason on hover", R.Preview.IsActive()
    and P.controls.statusSync.state == "paused" and P.controls.statusSync.tooltip:find("preview"))
  H.slash("preview off"); H.advance(1)
  check("preview off: Active again", P.controls.statusSync.state == "active")
end
do
  local H, R, P = load(nil, function()
    C_AddOns.IsAddOnLoaded = function(name) return name ~= "WaypointUI" and name ~= "ElvUI" end
    WaypointUIAPI = nil
  end)
  check("Waypoint UI missing: red cross Disconnected", P.controls.statusWUI.state == "disconnected"
    and P.controls.statusWUI.value.text:GetText() == "Disconnected")
  check("sync then shows an error (red warning)", P.controls.statusSync.state == "error"
    and P.controls.statusSync.frame.icon:GetTexture():find("StatusWarning"))
  check("without verified Waypoint UI art the page uses flat colours", P.tabButtons.General.background.texture == nil
    and P.tabButtons.General.background.color ~= nil)
  local ok = pcall(H.ui.click, P.tabButtons.Map)
  check("and still switches tabs", ok and P.activeTab == "Map")
end
do
  local H, R, P = load(nil, function() RXPG_ARROW = nil end)
  check("RestedXP loaded without its arrow: red warning", P.controls.statusRXP.state == "error"
    and P.controls.statusRXP.value.text:GetText() == "Arrow Unavailable")
end

print(string.format("%d passed, %d failed", passes, fails))
if fails > 0 then error(fails .. " test(s) failed", 0) end
