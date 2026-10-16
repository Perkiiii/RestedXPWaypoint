-- Startup quest state has no caller/intent evidence. Do not turn an inherited
-- quest into a permanent override merely because the RXP arrow is a vendor.
local passes, fails = 0, 0
local function check(name, ok)
  if ok then passes = passes + 1; print("ok   " .. name)
  else fails = fails + 1; print("FAIL " .. name) end
end
local function fixture(strategy, quest, navigation, delayed, autoSync)
  local H = dofile(ADDON_ROOT .. "/tests/harness.lua")
  C_Map.GetBestMapForUnit = function() return 2521 end
  C_Map.GetPlayerMapPosition = function() return { GetXY = function() return .5, .5 end } end
  GetPlayerFacing = function() return 0 end
  H.quests[92472] = { title = "The Next Step", ready = true, poi = 80 }
  local vendor = H.goto_(80, 0, { radius = 10, hidePin = true })
  vendor.zone, vendor.x, vendor.y = 2521, 44.67, 45.19
  local nextPin = H.goto_(82, 0); nextPin.zone, nextPin.x, nextPin.y = 2521, 44.78, 45.05
  local step = H.newStep(84, { sticky = true, completewith = "The Next Step" }, vendor, nextPin,
    { tag = "vendor", text = "Vendor trash." })
  local hidden = H.newStep(82, { sticky = true, hidewindow = true, completewith = "VendorStep" },
    H.turnin(92472, "The Next Step"))
  local collect = H.newStep(83, { sticky = true }, { tag = "collect", text = "Collect Strider Meat and Small Eggs" })
  local function point()
    H.setActiveSteps(hidden, collect, step); H.point(vendor)
  end
  if not delayed then point() end
  if navigation == "wui" then H.restoreSession({ name = "Player pin", flags = "OtherAddon" }, true)
  elseif navigation == "raw" then
    H.st.waypoint = { uiMapID = 2521, position = { x = .2, y = .3 } }; H.st.user = true
  else H.st.quest = quest end
  local R = H.load(ADDON_ROOT, { strategy = strategy or "coordinates", debug = true, autoSync = autoSync })
  return H, R, vendor, point
end
local function atVendor(H)
  local n = H.wui.nav
  return n and n.mapID == 2521 and math.abs(n.x * 100 - 44.67) < .001
    and math.abs(n.y * 100 - 45.19) < .001 and H.st.user
end
local function route(H, dist, index)
  local g = H.goto_(dist, 0, { text = "Continue the guide" })
  H.setActiveSteps(H.newStep(index, {}, g)); H.point(g)
end
local function clear(H)
  H.wui.nav, H.st.waypoint, H.st.quest, H.st.user = nil, nil, nil, false
  H.fire("USER_WAYPOINT_UPDATED"); H.fire("SUPER_TRACKING_CHANGED")
end

for _, strategy in ipairs({ "coordinates", "hybrid", "native-first" }) do
  for _, quest in ipairs({ 92472, 77777 }) do
    local H, R, vendor = fixture(strategy, quest)
    H.advance(2)
    check(strategy .. " inherited " .. quest .. ": vendor receives navigation", atVendor(H)
      and H.wui.writes == 1 and not R.Sync.GetState().overrideActive)
    check(strategy .. " inherited " .. quest .. ": service appearance preserved", H.wui.nav
      and H.wui.nav.iconTexture == "Interface\\AddOns\\RestedXPWaypoint\\Art\\Icons\\Bags")
    check(strategy .. " inherited " .. quest .. ": no automatic attribution claimed",
      R.Sync.GetState().guideTrackingQuest == nil)
    H.setExternalQuest(quest, "RestedXP") -- reassert the inherited identity
    local writes = H.wui.writes
    H.advance(2)
    check(strategy .. " inherited " .. quest .. ": no fight at unchanged destination", H.wui.writes == writes)
    route(H, 100, 85); H.advance(2)
    check(strategy .. " inherited " .. quest .. ": guide advances despite baseline tracking", H.navAt(100)
      and H.wui.writes == writes + 1 and not R.Sync.GetState().overrideActive)
    writes = H.wui.writes; H.advance(4)
    check(strategy .. " inherited " .. quest .. ": no repeated writes", H.wui.writes == writes)
  end
end

for _, source in ipairs({ "quest", "wui", "raw" }) do
  local H, R = fixture("coordinates", 92472)
  H.advance(2)
  if source == "quest" then H.setExternalQuest(999)
  elseif source == "wui" then H.setManualWaypoint("Player destination")
  else
    H.st.quest, H.st.user = nil, true
    H.st.waypoint = { uiMapID = 2521, position = { x = .2, y = .3 } }
    H.fire("USER_WAYPOINT_UPDATED")
  end
  local writes, marker, pin = H.wui.writes, H.wui.nav, H.st.waypoint
  route(H, 100, 85); H.advance(1); route(H, 110, 86); H.advance(1)
  check(source .. ": post-startup selection protects multiple guide steps", H.wui.writes == writes
    and (H.wui.nav == marker or (source ~= "wui" and H.wui.nav == nil))
    and H.st.waypoint == pin and R.Sync.GetState().overrideActive)
  clear(H); H.advance(.99)
  check(source .. ": full resume delay preserved", H.wui.writes == writes)
  H.advance(.02)
  check(source .. ": latest route resumes silently", H.navAt(110) and H.wui.writes == writes + 1
    and H.wui.nav.suppressAudio)
end

for _, navigation in ipairs({ "wui", "raw" }) do
  local H, R = fixture("coordinates", nil, navigation)
  H.advance(2)
  check("reload inherited " .. navigation .. ": waypoint protection is unchanged", H.wui.writes == 0
    and R.Sync.GetState().overrideActive)
  clear(H); H.advance(.99)
  check("reload inherited " .. navigation .. ": delay remains", H.wui.writes == 0)
  H.advance(.02)
  check("reload inherited " .. navigation .. ": resumes current vendor", atVendor(H) and H.wui.writes == 1)
end

do
  -- A fresh VM models both login and /reload: no persisted manual-intent flag
  -- exists for a quest selected in the preceding session.
  for _, priorOrigin in ipairs({ "automatic", "manual" }) do
    local H = fixture("coordinates", 92472)
    H.advance(2)
    check("reload " .. priorOrigin .. " quest: inherited intent is not invented", atVendor(H))
  end
end

do
  local H, R, vendor, point = fixture("coordinates", nil, nil, true)
  H.setExternalQuest(92472, "RestedXP"); H.advance(2)
  check("delayed startup target: no write until RXP is valid", H.wui.writes == 0)
  point(); H.advance(2)
  check("delayed startup target: initial quest cannot latch an override", atVendor(H)
    and not R.Sync.GetState().overrideActive)
end

do
  local H, R, vendor, point = fixture("coordinates", 92472, nil, true)
  H.setExternalQuest(999) -- a second, different selection is not inherited
  point(); H.advance(2)
  check("different selection before first RXP destination is still protected", H.st.quest == 999
    and H.wui.writes == 0 and R.Sync.GetState().overrideActive)
end

do
  local H, R = fixture("coordinates", 92472)
  H.advance(2); H.slash("off"); H.setExternalQuest(999); H.slash("on"); H.advance(2)
  check("sync restart does not reopen startup attribution", H.st.quest == 999
    and H.wui.writes == 1 and R.Sync.GetState().overrideActive)
end

for _, selection in ipairs({ 92472, 999 }) do
  local H, R = fixture("coordinates", 77777)
  H.advance(2)
  local writes = H.wui.writes
  H.setExternalQuest(selection); H.advance(1); route(H, 100, 85); H.advance(2)
  check("new quest " .. selection .. ": guide association never overrides an observed new selection",
    H.st.quest == selection and H.wui.writes == writes and R.Sync.GetState().overrideActive
    and R.Sync.GetState().inheritedQuest == nil)
end

do
  local H, R = fixture("coordinates", 92472)
  H.advance(2); H.setExternalQuest(92472, "RestedXP")
  H.setExternalQuest(0) -- actual idle clearance, not a side effect of our writer
  H.setExternalQuest(92472)
  local writes = H.wui.writes
  route(H, 100, 85); H.advance(2)
  check("clearing then reselecting the inherited quest is a new protected selection", H.st.quest == 92472
    and H.wui.writes == writes and R.Sync.GetState().overrideActive and R.Sync.GetState().inheritedQuest == nil)
end

for _, replacement in ipairs({ 92472, 999 }) do
  local H, R = fixture("coordinates", 92472)
  local create = WaypointUIAPI.Navigation.NewUserNavigation
  WaypointUIAPI.Navigation.NewUserNavigation = function(options)
    local result = create(options)
    H.setExternalQuest(replacement, "OtherAddon")
    return result
  end
  H.advance(2)
  WaypointUIAPI.Navigation.NewUserNavigation = create
  local writes = H.wui.writes
  route(H, 100, 85); H.advance(2)
  if replacement == 92472 then
    check("observed unknown setter supersedes inherited startup baseline", H.st.quest == replacement
      and H.wui.writes == writes and R.Sync.GetState().overrideActive)
  else
    check("synchronous different quest retains protection", H.st.quest == 999 and H.wui.writes == writes
      and R.Sync.GetState().overrideActive)
  end
end

do
  local H, R = fixture("coordinates", 92472, nil, false, false)
  H.advance(2)
  check("disabled startup never writes or acquires an inherited quest", H.wui.writes == 0
    and R.Sync.GetState().inheritedQuest == nil)
  H.slash("on"); H.advance(2)
  check("later enabling sync preserves existing quest protection", H.st.quest == 92472
    and H.wui.writes == 0 and R.Sync.GetState().overrideActive)
end

do
  local H, R, vendor, point = fixture("coordinates", 92472, nil, true)
  H.advance(1)
  H.fire("QUEST_ACCEPTED", 1, 92472)
  point(); H.advance(2)
  check("acceptance alone does not invent setter attribution for a startup baseline", atVendor(H)
    and not R.Sync.GetState().overrideActive and R.Sync.GetState().guideTrackingQuest == nil)
end

for _, action in ipairs({ "preview", "loading", "off" }) do
  local H, R = fixture("coordinates", 92472)
  H.advance(2); H.setExternalQuest(999); H.advance(.5); clear(H); H.advance(.8)
  if action == "preview" then H.slash("preview vendor")
  elseif action == "loading" then H.fire("PLAYER_LEAVING_WORLD")
  else H.slash("off") end
  local writes, marker = H.wui.writes, H.wui.nav
  H.advance(2)
  check("startup then " .. action .. ": stale resume callbacks remain inert", H.wui.writes == writes and H.wui.nav == marker)
end

print(string.format("%d passed, %d failed", passes, fails))
assert(fails == 0, "startup tracking regressions failed")
