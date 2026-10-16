-- Event-ordered regression for the Step 100 -> 110 incident. Stored marker,
-- native map pin, active quest and sync permission are deliberately independent.
local passes, fails = 0, 0
local function check(name, ok)
  if ok then passes = passes + 1; print("ok   " .. name)
  else fails = fails + 1; print("FAIL " .. name) end
end
local function fixture(noObserver)
  local H = dofile(ADDON_ROOT .. "/tests/harness.lua")
  if noObserver then hooksecurefunc = nil end
  local R = H.load(ADDON_ROOT, { strategy = "hybrid", debug = true })
  H.quests[92553] = { title = "Restocking the Larders", poi = 60, ready = false }
  H.quests[94411] = { title = "Meddlesome Mages", poi = 70, ready = false,
    objectives = { { type = "monster", numFulfilled = 0, numRequired = 6 } } }
  local g = H.goto_(40, 0, { zone = 2521, x = 43.85, y = 43.84 })
  local step = H.newStep(100, {}, g, H.accept(92553, "Restocking the Larders"))
  H.setActiveSteps(step); H.point(g); H.advance(2)
  return H, R, g
end
local function route(H, index)
  local g = H.loopPoint(70, 0)
  g.zone, g.x, g.y = 2521, 46.13, 39.79
  H.setActiveSteps(H.newStep(index, { loop = "" }, g,
    H.complete(94411, 1, { text = "0/6 High Order Apprentice defeated" })))
  H.point(g)
  return g
end
local function at110(H)
  return H.wui.nav and H.wui.nav.mapID == 2521
    and math.abs(H.wui.nav.x * 100 - 46.13) < .0001
    and H.wui.nav.name == "0/6 High Order Apprentice defeated"
end
for _, pathfinding in ipairs({ false, true }) do
  local H, R, old = fixture()
  H.wui.pathfinding = pathfinding
  local nativePin, writes, sounds = H.st.waypoint, H.wui.writes, H.wui.markerIntroEvents
  H.fire("QUEST_ACCEPTED", 1, 92553)
  H.setExternalQuest(92553, "Blizzard") -- unknown caller, not proof of automatic intent
  old.step.active = nil
  H.fire("QUEST_LOG_UPDATE"); H.advance(.6) -- RXP still points to the inactive step
  check("inactive old step retires only the stored marker (path " .. tostring(pathfinding) .. ")",
    H.wui.nav == nil and H.st.waypoint == nativePin and H.st.quest == 92553)
  check("cleanup preserves waypoint and suppresses callbacks/queue advance",
    H.wui.lastClear.preserveWaypoint == true and H.wui.lastClear.suppressAdvance == true)
  check("historical ownership does not grant active ownership or sync permission",
    not R.Sync.GetState().bridgeActive and R.Sync.GetState().overrideActive)
  for _, index in ipairs({ 102, 103, 106, 110 }) do route(H, index); H.advance(.6) end
  H.setExternalQuest(94411) -- same guide quest, deliberately selected manually
  H.advance(3)
  check("rapid progression cannot recreate Step 100 while a guide quest is manually selected",
    H.wui.nav == nil and H.wui.writes == writes and H.st.quest == 94411)
  local target = R.RXP.GetTarget()
  check("Step 110 retains Hybrid coordinate/loop behavior",
    R.Nav.Decide(target, "hybrid").mode == "coordinates" and target.stepIndex == 110
    and target.label == "0/6 High Order Apprentice defeated")
  check("cleanup creates no new navigation or intro sounds", H.wui.writes == writes
    and H.wui.markerIntroEvents == sounds)
  H.setExternalQuest(0); H.advance(.99)
  check("no navigation before full external resume delay", H.wui.nav == nil)
  H.advance(.02)
  check("resume uses fresh Step 110 exactly once with audio suppression", at110(H)
    and H.wui.writes == writes + 1 and H.wui.nav.suppressAudio)
  H.advance(4)
  check("old delayed evaluations remain inert", at110(H) and H.wui.writes == writes + 1)
end
for _, source in ipairs({ "Blizzard", "player", "OtherAddon" }) do
  local H, R = fixture()
  H.fire("QUEST_ACCEPTED", 1, 92553)
  H.setExternalQuest(92553, source); route(H, 110); H.advance(3)
  check(source .. ": acceptance plus association is not automatic attribution",
    H.st.quest == 92553 and H.wui.writes == 1 and R.Sync.GetState().overrideActive)
end
do
  local H, R = fixture()
  H.fire("QUEST_ACCEPTED", 1, 92553)
  H.setExternalQuest(92553, "RestedXP"); H.advance(2)
  check("observed RXP setter on acceptance work supplies attribution", not R.Sync.GetState().overrideActive
    and R.Sync.GetState().guideTrackingQuest == 92553)
  route(H, 110); H.advance(2)
  local writes = H.wui.writes
  for _ = 1, 4 do
    H.advance(3); H.setExternalQuest(92553, "RestedXP"); H.fire("QUEST_LOG_UPDATE"); H.advance(.6)
  end
  check("later automatic re-supertracking has no timeout and causes no fight",
    H.wui.writes == writes and not R.Sync.GetState().overrideActive)
  H.setExternalQuest(92553) -- exact same previously attributed ID
  H.advance(1)
  route(H, 111); H.point(H.goto_(90, 0)); H.advance(2)
  check("same-quest manual setter revokes retained guide attribution", H.st.quest == 92553
    and R.Sync.GetState().guideTrackingQuest == nil and R.Sync.GetState().overrideActive
    and H.wui.writes == writes)
  H.setExternalQuest(92553, "RestedXP"); H.advance(2)
  check("later RXP reassertion cannot erase a protected manual selection", H.st.quest == 92553
    and H.wui.writes == writes and R.Sync.GetState().overrideActive)
end
for _, callback in ipairs({ "event", "pin", "quest" }) do
  local H, R = fixture()
  H.setExternalQuest(999)
  local pin
  H.wui.onClear = function()
    if callback == "event" then H.fire("USER_WAYPOINT_UPDATED"); H.fire("SUPER_TRACKING_CHANGED")
    elseif callback == "pin" then H.setManualWaypoint("Selected during cleanup"); pin = H.st.waypoint
    else H.setExternalQuest(998) end
  end
  route(H, 110); H.advance(2)
  check("synchronous cleanup callback " .. callback .. " cannot reclaim navigation", H.wui.writes == 1
    and R.Sync.GetState().overrideActive)
  check("synchronous cleanup callback " .. callback .. " preserves external selection",
    callback == "pin" and H.st.waypoint == pin and H.wui.nav.name == "Selected during cleanup"
      or callback == "quest" and H.st.quest == 998 or callback == "event" and H.st.quest == 999)
end
do
  local H, R = fixture(true)
  H.fire("QUEST_ACCEPTED", 1, 92553); H.setExternalQuest(92553, "RestedXP")
  route(H, 110); H.advance(3)
  check("missing provenance API fails closed", H.st.quest == 92553 and H.wui.writes == 1
    and R.Sync.GetState().overrideActive)
end
do
  local H, R = fixture()
  H.setExternalQuest(999)
  WaypointUIAPI.Navigation.ClearUserNavigation = nil
  route(H, 110); H.advance(3)
  check("missing cleanup API retains marker without touching external tracking", H.wui.nav ~= nil
    and H.st.quest == 999 and H.wui.writes == 1)
  check("deferred cleanup explains the limitation", R.Sync.GetState().markerCleanup:find("API unavailable", 1, true))
end
-- Stack formats seen in WoW, and an unrelated immediate caller above an
-- RXP frame: attribution must never search the whole stack for any RXP frame.
for _, case in ipairs({
  { "[string \"@Interface/AddOns/RXPGuides/GuideWindow.lua\"]:790: in function 'SetStep'", true },
  { "Interface\\AddOns\\RXPGuides\\functions.lua:1850: in function '?'", true },
  { "[Interface/AddOns/OtherAddon/Click.lua]:20: in function 'Click'\n[Interface/AddOns/RXPGuides/functions.lua]:1850: in function '?'", false },
  { "[Interface/AddOns/RXPGuidesOther/functions.lua]:1850: in function '?'", false },
}) do
  local H, R = fixture()
  H.selectionStack = case[1]
  H.setExternalQuest(92553)
  H.selectionStack = nil
  H.advance(2)
  check("immediate caller attribution: " .. case[1], (not R.Sync.GetState().overrideActive) == case[2])
end
do
  local H, R = fixture()
  H.setExternalQuest(999)
  local old = H.wui.nav
  WaypointUIAPI.Navigation.IsUserNavigationFlagged = nil
  route(H, 110); H.advance(2)
  check("cleanup requires positive public ownership proof", H.wui.nav == old and H.st.quest == 999
    and R.Sync.GetState().markerCleanup:find("ownership API unavailable", 1, true))
end
print(string.format("%d passed, %d failed", passes, fails))
assert(fails == 0, "stale marker regressions failed")
