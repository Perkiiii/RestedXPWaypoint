-- Creation audio and marker intros are separate in Waypoint UI 1.7.3.
local passes, fails = 0, 0
local function check(name, ok)
  if ok then passes = passes + 1; print("ok   " .. name)
  else fails = fails + 1; print("FAIL " .. name) end
end
local function setup(strategy, restored)
  local H = dofile(ADDON_ROOT .. "/tests/harness.lua")
  local addon = H.aceAddons.RXPGuides
  addon.currentGuide = { key = "Guide A", steps = {} }
  addon.GetGuideProgress = function() return addon.progress end
  function H.step(index, distance, opts, instruction)
    local g = H.goto_(distance, 20)
    local s = H.newStep(index, opts or {}, g, instruction or { text = "Travel" })
    addon.currentGuide.steps[index] = s
    addon.progress = index
    H.setActiveSteps(s); H.point(g)
    return g, s
  end
  H.step(1, 40)
  if restored then H.restoreSession({ name = "Travel", x = .2, y = .2, flags = "RestedXPWaypoint" }, restored == "tracked") end
  local R = H.load(ADDON_ROOT, { strategy = strategy or "coordinates" })
  H.advance(2)
  return H, R, addon
end
local function audible(H) return H.wui.audible or 0 end

for _, strategy in ipairs({ "coordinates", "hybrid", "native-first" }) do
  local H, R, addon = setup(strategy)
  check(strategy .. ": initial login quiet", audible(H) == 0 and H.navAt(40) and H.wui.audioOptions[1] == true)
  local g, s = H.step(2, 60)
  H.advance(1)
  check(strategy .. ": genuine new step audible", audible(H) == 1 and H.navAt(60) and H.wui.nav.suppressAudio == false)
  for i = 1, 5 do
    local nextPoint = H.goto_(60 + i * 2, 20); nextPoint.step = s
    nextPoint.parent = s.elements[2]
    table.insert(s.elements, nextPoint); H.point(nextPoint); H.advance(1)
  end
  check(strategy .. ": five gotos remain quiet", audible(H) == 1 and H.navAt(70) and H.wui.nav.suppressAudio == true)
  for i = 1, 10 do
    RXPG_ARROW.element.x = 35 + i; H.fire("QUEST_LOG_UPDATE"); H.advance(1)
  end
  check(strategy .. ": ten collection moves quiet", audible(H) == 1 and H.navAt(90))
  local resets, writes = H.wui.markerIntroEvents, H.wui.writes
  RXPG_ARROW.element.title = "Collected 10/10"; H.advance(3)
  check(strategy .. ": progress presentation suppresses creation only", audible(H) == 1
    and H.wui.writes == writes + 1 and H.wui.markerIntroEvents == resets + 1 and H.wui.nav.suppressAudio == true)
  H.step(3, 90); H.advance(3)
  local count = H.wui.writes
  check(strategy .. ": same-position next step quiet", audible(H) == 1 and H.navAt(90))
  RXPG_ARROW.element.x = 46; H.advance(1)
  check(strategy .. ": adoption consumed opportunity", audible(H) == 1 and H.wui.writes == count + 1)
  H.step(4, 100); H.advance(1)
  check(strategy .. ": next destination step audible once", audible(H) == 2 and H.navAt(100))
  local sameWrites = H.wui.writes
  H.step(5, 100); H.advance(2)
  check(strategy .. ": identical destination and presentation need no write", audible(H) == 2 and H.wui.writes == sameWrites)
  R.Sync.Stop(); R.Sync.Start(); H.advance(2)
  R.Config.Set("strategy", strategy == "coordinates" and "hybrid" or "coordinates"); H.advance(2)
  RXPG_ARROW.element.x = 51; H.advance(1)
  check(strategy .. ": off/on and strategy recovery quiet", audible(H) == 2 and H.navAt(102))
  C_Map.GetBestMapForUnit = function() return 1421 end
  C_Map.GetPlayerMapPosition = function() return { GetXY = function() return .5, .5 end } end
  GetPlayerFacing = function() return 0 end
  R.Preview.Show("complete")
  check(strategy .. ": preview owns temporary destination", H.wui.nav.flags == "RestedXPWaypoint-Preview")
  R.Preview.Off(); local sounds = audible(H); H.advance(2)
  check(strategy .. ": preview recovery quiet", audible(H) == sounds and H.navAt(102))
  addon.currentGuide = { key = "Guide B", steps = {} }; H.step(1, 110); H.advance(1)
  check(strategy .. ": guide switch audible", audible(H) == sounds + 1 and H.navAt(110))
  R.Sync.Stop()
end

do
  local H, R, addon = setup()
  local _, main = H.step(2, 60); H.advance(1)
  local patrol = H.newStep(1, { sticky = true, hidewindow = true, loop = "" }, H.loopPoint(70, 20), { text = "1" })
  addon.currentGuide.steps[1] = patrol
  for i = 1, 8 do
    H.setActiveSteps(patrol, main)
    H.point(i % 2 == 0 and main.elements[1] or patrol.elements[1]); H.advance(1)
  end
  check("sticky/helper and patrol source switching stays quiet", audible(H) == 1 and H.navAt(60))
  local g, nextStep = H.step(3, 80)
  H.setActiveSteps(patrol, nextStep); H.point(patrol.elements[1]); H.advance(2)
  check("progression under a persistent patrol announces once", audible(H) == 2 and H.navAt(70))
  -- Same logical guide reprocessed/renumbered: no invented progression.
  addon.currentGuide = { key = "Guide A", steps = {} }; H.step(30, 84); H.advance(1)
  check("guide revision baseline is quiet", audible(H) == 2 and H.navAt(84))
  addon.GetGuideProgress = function() error("not ready") end
  H.step(31, 86); H.advance(1)
  check("ambiguous source stays quiet", audible(H) == 2 and H.navAt(86))
  R.Sync.Stop()
end
do
  local H, R, addon = setup()
  local _, s = H.step(2, 60, { stepId = "stable-step" }); H.advance(1)
  addon.currentGuide.steps[2] = nil; addon.currentGuide.steps[20] = s
  s.index = 20; addon.progress = 20; s.elements[1].x = 31; H.advance(1)
  check("stable stepId survives index change", audible(H) == 1 and H.navAt(62))
  H.step(21, 80); H.fire("QUEST_ACCEPTED"); H.advance(.1)
  H.step(22, 90); H.advance(2)
  check("settling publishes only final new-step destination", audible(H) == 2 and H.navAt(90)
    and H.wui.audioOptions[#H.wui.audioOptions] == false)
  local n = audible(H)
  WaypointUIAPI.Navigation.NewUserNavigation({ mapID = 1421, x = 50, y = 50, name = "Player", suppressAudio = false })
  check("direct manual API retains ordinary audio", audible(H) == n + 1 and H.wui.nav.name == "Player")
  R.Sync.Stop()
end
for _, strategy in ipairs({ "hybrid", "native-first" }) do
  local H, R = setup(strategy)
  H.quests[101] = { title = "Turn in", ready = true, poi = 0 }
  H.step(2, 60, {}, H.turnin(101, "Turn in")); H.advance(3)
  check(strategy .. ": verified failure fallback announces final coordinate once", audible(H) == 1
    and H.navAt(60) and H.st.user and H.st.quest == nil)
  H.fire("QUEST_LOG_UPDATE"); H.advance(2)
  check(strategy .. ": fallback reevaluation quiet", audible(H) == 1 and H.navAt(60))
  R.Sync.Stop()
end
do
  local H, R = setup()
  H.wui.rejects = 1; H.step(2, 60); H.advance(1)
  check("failed write has no sound", audible(H) == 0 and H.navAt(40) and H.wui.audioOptions[2] == false)
  R.Sync.SyncNow()
  check("successful retry preserves opportunity", audible(H) == 1 and H.navAt(60))
  R.Sync.SyncNow()
  check("repeated manual sync quiet", audible(H) == 1 and H.wui.nav.suppressAudio == true)
  H.wui.rejects = 1; H.step(3, 80); H.advance(1)
  -- The already active marker as Sync would have shown it (label and icon).
  local target = R.RXP.GetTarget(); R.Sync.PrepareTarget(target); R.WUI.SetNavigation(target, true)
  local writes = H.wui.writes; H.fire("PLAYER_ENTERING_WORLD"); H.advance(2)
  check("retry of already active destination quiet", audible(H) == 1 and H.navAt(80) and H.wui.writes == writes)
  R.Sync.Stop()
end
for _, restored in ipairs({ "tracked", "untracked" }) do
  local H, R = setup("coordinates", restored)
  check("reload " .. restored .. " quiet", audible(H) == 0 and H.navAt(40))
  R.Sync.Stop()
end
for _, strategy in ipairs({ "hybrid", "native-first" }) do
  for _, cancel in ipairs({ false, true }) do
    local H, R = setup(strategy)
    H.quests[101] = { title = "Turn in", ready = true, poi = 60 }
    H.step(2, 60, {}, H.turnin(101, "Turn in"))
    H.fire("QUEST_TURNED_IN")
    for _ = 1, 20 do H.advance(.05); if R.Sync.GetState().pending then break end end
    check(strategy .. ": delayed native transition has no creation audio", R.Sync.GetState().pending and audible(H) == 0)
    if cancel then H.setManualWaypoint("Manual") end
    local writes = H.wui.writes; H.advance(2)
    check(strategy .. ": native completion/cancellation preserves navigation", audible(H) == 0 and H.wui.writes == writes
      and (cancel and H.wui.nav.name == "Manual" and H.st.user or not cancel and H.st.quest == 101))
    R.Sync.Stop()
  end
end
do
  local H, R = setup()
  H.step(2, 60); H.fire("QUEST_ACCEPTED"); H.setManualWaypoint("Selected during settle")
  H.advance(2)
  check("manual waypoint during settled step change protected", audible(H) == 0 and H.wui.nav.name == "Selected during settle" and H.st.user)
  H.step(3, 80); H.advance(1)
  check("later real step keeps the active manual waypoint", audible(H) == 0 and H.wui.nav.name == "Selected during settle")
  WaypointUIAPI.Navigation.ClearUserNavigation(); H.advance(1.5)
  check("cleared manual waypoint resumes the fresh step silently", audible(H) == 0 and H.navAt(80))
  R.Sync.Stop()
end
do
  local H, R = setup()
  local writes = H.wui.writes
  R.Config.Set("stepSound", false)
  check("sound toggle itself adds no write", H.wui.writes == writes)
  H.step(2, 60); H.advance(2)
  check("disabled new-step creation sound stays quiet", audible(H) == 0 and H.navAt(60))
  R.Config.Set("stepSound", true); H.advance(2)
  check("reenabling never replays consumed sound", audible(H) == 0)
  H.step(3, 80); H.advance(2)
  check("future genuine step sounds once after reenable", audible(H) == 1 and H.navAt(80))
  R.Sync.Stop()
end
print(string.format("%d passed, %d failed", passes, fails))
assert(fails == 0, "audio regressions failed")
