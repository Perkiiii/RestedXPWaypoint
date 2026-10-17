-- Temporary external waypoint ownership and fresh, one-time automatic resume.
local passes, fails = 0, 0
local function check(name, ok)
  if ok then passes = passes + 1; print("ok   " .. name)
  else fails = fails + 1; print("FAIL " .. name) end
end
local function setup(strategy)
  local H = dofile(ADDON_ROOT .. "/tests/harness.lua")
  C_Map.GetBestMapForUnit = function() return 1421 end
  C_Map.GetPlayerMapPosition = function() return { GetXY = function() return .5, .5 end } end
  GetPlayerFacing = function() return 0 end
  local R = H.load(ADDON_ROOT, { strategy = strategy or "coordinates", debug = true })
  local g = H.goto_(40, 0, { text = "Original route" })
  H.setActiveSteps(H.newStep(1, {}, g)); H.point(g); H.advance(2)
  return H, R, g
end
local function clear(H, events)
  H.wui.nav, H.st.waypoint, H.st.quest, H.st.user = nil, nil, nil, false
  if events ~= false then H.fire("USER_WAYPOINT_UPDATED"); H.fire("SUPER_TRACKING_CHANGED") end
end
local function raw(H)
  -- Keep the old owned WUI session to exercise ownership of a raw replacement.
  H.st.user, H.st.quest = true, nil
  H.st.waypoint = { uiMapID = 1421, position = { x = .7, y = .8 } }
  H.fire("USER_WAYPOINT_UPDATED"); H.fire("SUPER_TRACKING_CHANGED")
end

for _, kind in ipairs({ "manual", "arrival", "raw", "guard", "foreign-addon", "pathfinding" }) do
  local H, R, g = setup()
  H.wui.pathfinding = kind == "pathfinding"
  if kind == "raw" then raw(H)
  else
    H.setManualWaypoint("Outside destination")
    if kind == "guard" then H.wui.nav.flags = "GuidePin"
    elseif kind == "foreign-addon" then H.wui.nav.flags = "OtherAddon" end
  end
  H.advance(1)
  local writes, resets, paths = H.wui.writes, H.wui.markerResets, H.wui.pathBuilds
  g.text = "Fresh route label"
  if kind == "arrival" then clear(H, false) -- polling, no arrival event
  elseif kind == "manual" then WaypointUIAPI.Navigation.ClearUserNavigation()
  elseif kind == "raw" then
    -- Blizzard clears the pin; WUI may retain its stale owned session.
    H.st.waypoint, H.st.user = nil, false
    H.fire("USER_WAYPOINT_UPDATED"); H.fire("SUPER_TRACKING_CHANGED")
  else clear(H) end
  H.advance(.1)
  check(kind .. ": clearance settles before any write", H.wui.writes == writes)
  H.advance(2)
  check(kind .. ": unchanged RXP destination restored with fresh label", H.navAt(40)
    and H.wui.nav.name == "Fresh route label" and R.Sync.GetState().bridgeActive)
  check(kind .. ": exactly one silent resume", H.wui.writes == writes + 1 and H.wui.nav.suppressAudio
    and H.wui.markerResets == resets + 1 and H.wui.pathBuilds == paths + (kind == "pathfinding" and 1 or 0))
  H.advance(8); H.fire("QUEST_LOG_UPDATE"); H.advance(2)
  check(kind .. ": no repeated resume", H.wui.writes == writes + 1)
  clear(H); H.advance(2)
  check(kind .. ": later clearing our own waypoint stays cleared", H.wui.writes == writes + 1)
end

do
  local H = setup()
  H.setManualWaypoint("A"); H.advance(.1); clear(H); H.advance(.15)
  H.setManualWaypoint("B")
  local marker, writes = H.wui.nav, H.wui.writes
  H.advance(2)
  check("A to B during settle never reclaims", H.wui.nav == marker and H.wui.writes == writes)
  local g = H.goto_(80, 0, { text = "New route" })
  H.setActiveSteps(H.newStep(2, {}, g)); H.point(g); H.advance(2)
  check("new RXP destination leaves active B alone", H.wui.nav == marker and H.wui.writes == writes)
  clear(H); H.advance(2)
  check("B clearance restores current RXP destination", H.navAt(80) and H.wui.writes == writes + 1)
end

for _, selection in ipairs({ "quest", "other-type", "unknown-tracking" }) do
  local H = setup()
  H.setManualWaypoint("Manual"); H.advance(1); clear(H); H.advance(.1)
  if selection == "quest" then H.setExternalQuest(999)
  elseif selection == "other-type" then
    C_SuperTrack.GetHighestPrioritySuperTrackingType = function() return 7 end
    H.fire("SUPER_TRACKING_CHANGED")
  else
    C_SuperTrack.IsSuperTrackingAnything = function() return true end
    H.fire("SUPER_TRACKING_CHANGED")
  end
  local writes = H.wui.writes
  H.fire("QUEST_LOG_UPDATE"); H.advance(3)
  check(selection .. ": another active destination blocks resume", H.wui.writes == writes)
end

for _, strategy in ipairs({ "hybrid", "native-first" }) do
  local H, R = setup(strategy)
  H.quests[101] = { title = "Turn in", ready = true, poi = 60 }
  H.setManualWaypoint("Manual"); H.advance(1)
  local g = H.goto_(60, 0)
  H.setActiveSteps(H.newStep(2, {}, g, H.turnin(101, "Turn in"))); H.point(g)
  H.advance(1); local writes = H.wui.writes
  check(strategy .. ": no native switch while manual pin active", H.st.setQuestCalls == 0)
  clear(H); H.advance(2)
  check(strategy .. ": resume uses fresh native decision", H.st.quest == 101 and H.st.setQuestCalls == 1
    and R.Sync.GetState().mode == "native" and not R.Sync.GetState().pending and H.wui.writes == writes)

  -- A selection during the native callback wait leaves a nativeHold. Its
  -- later clearance must permit the same activity to start again.
  H.setManualWaypoint("Second manual"); H.advance(1); clear(H); H.advance(1.05)
  H.setManualWaypoint("During verification"); H.advance(1)
  check(strategy .. ": resumed native work cancels on another selection", not R.Sync.GetState().pending
    and H.wui.nav.name == "During verification")
  clear(H); H.advance(2)
  check(strategy .. ": native hold does not block later resume", H.st.quest == 101 and not R.Sync.GetState().pending)

  H.setManualWaypoint("Last manual"); H.advance(1)
  local travel = H.goto_(75, 0, { text = "Leave town" })
  H.setActiveSteps(H.newStep(3, {}, travel)); H.point(travel); H.advance(1)
  clear(H); H.advance(2)
  check(strategy .. ": previous native quest is not cached on resume", H.navAt(75)
    and H.st.quest == nil and R.Sync.GetState().mode == "coordinates")
end

for _, action in ipairs({ "off", "preview", "loading", "restart" }) do
  local H, R = setup()
  H.setManualWaypoint("Manual"); H.advance(1); clear(H); H.advance(.1)
  if action == "off" then H.slash("off")
  elseif action == "preview" then H.slash("preview vendor")
  elseif action == "loading" then H.fire("PLAYER_LEAVING_WORLD")
  else
    H.slash("off"); H.slash("on"); H.setManualWaypoint("New session manual")
  end
  local writes, marker = H.wui.writes, H.wui.nav
  H.advance(2)
  check(action .. ": stale resume callback cannot write", H.wui.writes == writes and H.wui.nav == marker)
  if action == "loading" then
    H.fire("PLAYER_ENTERING_WORLD"); H.advance(2)
    check("loading: retained override rechecks and resumes after entry", H.navAt(40) and H.wui.writes == writes + 1)
  end
end

do
  local H, R = setup("native-first")
  H.setManualWaypoint("Manual"); H.advance(1)
  H.quests[202] = { title = "Fresh objective", poi = 40,
    objectives = { { type = "monster", finished = false, numFulfilled = 0, numRequired = 5 } } }
  local g = H.goto_(40, 0)
  H.setActiveSteps(H.newStep(2, {}, g, H.complete(202, 1))); H.point(g)
  clear(H); H.advance(2)
  check("native-first uses fresh objective at unchanged coordinates", H.st.quest == 202
    and R.Sync.GetState().kind == "objective" and H.wui.writes == 1)
end
for _, strategy in ipairs({ "hybrid", "native-first" }) do
  local H = setup(strategy)
  H.setManualWaypoint("Manual"); H.advance(1)
  H.quests[101] = { title = "No native POI", ready = true }
  local g = H.goto_(40, 0)
  H.setActiveSteps(H.newStep(2, {}, g, H.turnin(101, "No native POI"))); H.point(g)
  clear(H); H.advance(2)
  check(strategy .. ": failed native resume falls back silently once", H.navAt(40)
    and H.wui.writes == 2 and H.wui.nav.suppressAudio == true)
  H.advance(5)
  check(strategy .. ": failed native resume does not loop", H.wui.writes == 2)
end

do
  local H, R, g = setup()
  H.setManualWaypoint("Manual"); H.advance(1); g.skip = true
  clear(H); H.advance(3)
  check("invalid current RXP target never restored", H.wui.nav == nil and H.wui.writes == 1)
  g.skip = nil; H.advance(2)
  check("later valid RXP target may resume once", H.navAt(40) and H.wui.writes == 2)
end
do
  local H = setup()
  clear(H); H.fire("QUEST_LOG_UPDATE"); H.advance(4)
  check("own waypoint cleared without override is never reclaimed", H.wui.nav == nil and H.wui.writes == 1)
end
do
  local H = setup()
  H.setManualWaypoint("Manual"); H.advance(1)
  -- An independently restored owned navigation consumes the override.
  H.slash("sync"); local writes = H.wui.writes
  clear(H); H.advance(3)
  check("explicit sync consumes temporary override", H.wui.nav == nil and H.wui.writes == writes)
end
-- Quest overrides use the same idle deadline, including when the inactive WUI
-- session and raw waypoint from the original bridge navigation still exist.
for _, strategy in ipairs({ "coordinates", "hybrid", "native-first" }) do
  for _, source in ipairs({ "waypoint", "quest" }) do
    local H, R = setup(strategy)
    if source == "quest" then H.setExternalQuest(999) else H.setManualWaypoint("Manual") end
    local writes = H.wui.writes
    H.advance(2)
    check(strategy .. " " .. source .. ": active override never written over", H.wui.writes == writes)
    if source == "quest" then H.setExternalQuest(0) else clear(H) end
    H.fire("QUEST_LOG_UPDATE"); H.advance(.55)
    local latest = H.goto_(80, 0, { text = "Latest route" })
    H.setActiveSteps(H.newStep(2, {}, latest)); H.point(latest)
    H.advance(.44)
    check(strategy .. " " .. source .. ": full second stays idle despite RXP change",
      H.wui.writes == writes and not H.st.user and H.st.quest == nil)
    H.advance(.02)
    check(strategy .. " " .. source .. ": latest target restored after one second",
      H.navAt(80) and H.wui.writes == writes + 1 and H.wui.nav.suppressAudio)
    H.advance(4)
    check(strategy .. " " .. source .. ": one resume only", H.wui.writes == writes + 1)
  end
end

for _, initial in ipairs({ "waypoint", "quest" }) do
  for _, replacement in ipairs({ "waypoint", "quest", "raw", "silent-quest" }) do
    local H = setup()
    if initial == "quest" then H.setExternalQuest(998) else H.setManualWaypoint("First") end
    H.advance(1); clear(H); H.advance(.8)
    local writes = H.wui.writes
    if replacement == "waypoint" then H.setManualWaypoint("Replacement")
    elseif replacement == "raw" then raw(H)
    elseif replacement == "silent-quest" then H.st.quest, H.st.user = 999, false
    else H.setExternalQuest(999) end
    H.advance(.3)
    check(initial .. " to " .. replacement .. ": stale deadline cannot write", H.wui.writes == writes)
    H.advance(2)
    check(initial .. " to " .. replacement .. ": replacement keeps control", H.wui.writes == writes)
    clear(H); H.advance(.99)
    check(initial .. " to " .. replacement .. ": clearance starts a new full delay", H.wui.writes == writes)
    H.advance(.02)
    check(initial .. " to " .. replacement .. ": replacement clearance resumes once", H.wui.writes == writes + 1)
  end
end

for _, pair in ipairs({ { "quest", "quest" }, { "quest", "waypoint" }, { "waypoint", "quest" } }) do
  local H = setup()
  if pair[1] == "quest" then H.setExternalQuest(998) else H.setManualWaypoint("First") end
  H.advance(1)
  if pair[2] == "quest" then H.setExternalQuest(999) else H.setManualWaypoint("Second") end
  local writes = H.wui.writes
  H.advance(2)
  check(pair[1] .. " directly to " .. pair[2] .. ": no intermediate reclaim", H.wui.writes == writes)
  clear(H); H.advance(1.1)
  check(pair[1] .. " directly to " .. pair[2] .. ": resumes after final clearance", H.wui.writes == writes + 1)
end

for _, strategy in ipairs({ "hybrid", "native-first" }) do
  local H, R = setup(strategy)
  H.quests[101] = { title = "Native turn-in", ready = true, poi = 40 }
  local g = H.goto_(40, 0)
  H.setActiveSteps(H.newStep(2, {}, g, H.turnin(101, "Native turn-in"))); H.point(g); H.advance(2)
  local setters, writes = H.st.setQuestCalls, H.wui.writes
  H.fire("SUPER_TRACKING_CHANGED"); H.advance(2)
  check(strategy .. ": maintained bridge native quest is never an override", H.st.quest == 101
    and H.st.setQuestCalls == setters and H.wui.writes == writes)
  H.setExternalQuest(999); H.advance(2)
  check(strategy .. ": different active quest holds native navigation", H.st.quest == 999
    and H.st.setQuestCalls == setters + 1 and H.wui.writes == writes)
  H.setExternalQuest(0); setters = H.st.setQuestCalls; H.advance(.99)
  check(strategy .. ": native restoration waits one second", H.st.quest == nil and H.st.setQuestCalls == setters)
  H.advance(.02)
  check(strategy .. ": native restoration starts through pipeline after deadline", H.st.quest == 101
    and R.Sync.GetState().pending and H.st.setQuestCalls == setters + 1)
  H.advance(1)
  check(strategy .. ": resumed native quest verifies without coordinate write", not R.Sync.GetState().pending
    and R.Sync.GetState().lastVerification.ok and H.wui.writes == writes)
  H.setExternalQuest(0); setters = H.st.setQuestCalls; H.advance(3)
  check(strategy .. ": clearing own native quest alone never resumes", H.st.quest == nil
    and H.st.setQuestCalls == setters and H.wui.writes == writes)
end

for _, action in ipairs({ "off", "preview", "loading", "restart", "missing" }) do
  local H, R, g = setup()
  H.setExternalQuest(999); H.advance(1); H.setExternalQuest(0); H.advance(.8)
  if action == "off" then H.slash("off")
  elseif action == "preview" then H.slash("preview vendor")
  elseif action == "loading" then H.fire("PLAYER_LEAVING_WORLD")
  elseif action == "restart" then H.slash("off"); H.slash("on"); H.setExternalQuest(998)
  else g.skip = true end
  local writes, setters = H.wui.writes, H.st.setQuestCalls
  H.advance(2)
  check("quest " .. action .. ": delayed callback cannot reclaim", H.wui.writes == writes and H.st.setQuestCalls == setters)
  if action == "loading" then
    H.fire("PLAYER_ENTERING_WORLD"); H.advance(.99)
    check("quest loading: old deadline is discarded", H.wui.writes == writes)
    H.advance(1)
    check("quest loading: fresh post-entry idle deadline resumes", H.wui.writes == writes + 1)
  end
end

do
  local H = setup()
  H.setManualWaypoint("Removed asynchronously"); H.advance(1)
  local writes = H.wui.writes
  H.wui.nav, H.st.waypoint = nil, nil
  H.fire("USER_WAYPOINT_UPDATED") -- priority is still UserWaypoint
  H.advance(.8)
  check("delayed cleanup: no deadline while tracking is still active", H.wui.writes == writes)
  C_SuperTrack.ClearAllSuperTracked(); H.advance(.99)
  check("delayed cleanup: full delay starts at confirmed idle", H.wui.writes == writes)
  H.advance(.02)
  check("delayed cleanup: one resume after confirmed idle", H.wui.writes == writes + 1)
end

do
  local H = setup("coordinates")
  H.fire("QUEST_ACCEPTED"); H.setExternalQuest(999)
  local g = H.goto_(80, 0, { text = "New route" })
  H.setActiveSteps(H.newStep(2, {}, g)); H.point(g); H.advance(2)
  check("unrelated quest in RXP transition remains protected", H.st.quest == 999 and H.wui.writes == 1)
  H.setExternalQuest(0); H.advance(1.1)
  check("unrelated transition quest clearance resumes latest route", H.navAt(80) and H.wui.writes == 2)
end

for _, strategy in ipairs({ "hybrid", "native-first" }) do
  for _, offset in ipairs({ .08, .3 }) do
    local H, R = setup("coordinates")
    H.quests[101] = { title = "Native work", ready = true, poi = 40 }
    local g = H.goto_(40, 0)
    H.setActiveSteps(H.newStep(2, {}, g, H.turnin(101, "Native work"))); H.point(g); H.advance(1)
    H.slash("mode " .. strategy); H.advance(offset)
    H.setExternalQuest(999); H.advance(.1); H.setExternalQuest(0)
    local setters, writes = H.st.setQuestCalls, H.wui.writes
    H.advance(.99)
    check(strategy .. " quest interrupts pending native at " .. offset .. ": old callback stays inert",
      H.st.setQuestCalls == setters and H.wui.writes == writes and H.st.quest == nil)
    H.advance(.8)
    check(strategy .. " quest interrupts pending native at " .. offset .. ": resumes fresh after deadline",
      H.st.quest == 101 and H.st.setQuestCalls == setters + 1 and not R.Sync.GetState().pending)
  end
end

do
  local H = setup()
  H.quests[101] = { title = "Fresh strategy", ready = true, poi = 40 }
  H.setExternalQuest(999); H.advance(1); H.setExternalQuest(0); H.advance(.5)
  local g = H.goto_(40, 0)
  H.setActiveSteps(H.newStep(2, {}, g, H.turnin(101, "Fresh strategy"))); H.point(g)
  H.slash("mode hybrid"); H.advance(.49)
  check("strategy change during delay cannot start native early", H.st.quest == nil and H.wui.writes == 1)
  H.advance(1)
  check("resume uses strategy selected during delay", H.st.quest == 101 and H.wui.writes == 1)
end

do
  local H = setup("hybrid")
  H.quests[101] = { title = "Linked quest", ready = true, poi = 40 }
  H.setManualWaypoint("Manual"); H.fire("QUEST_ACCEPTED")
  local g = H.goto_(40, 0)
  H.setActiveSteps(H.newStep(2, {}, g, H.turnin(101, "Linked quest"))); H.point(g)
  H.setExternalQuest(101); H.advance(2)
  check("waypoint to linked quest during transition remains external", H.st.quest == 101 and H.st.setQuestCalls == 1
    and not H.RXPW.Sync.GetState().pending and H.wui.writes == 1)
end
do
  local H = setup()
  local R = H.RXPW
  local provider = dofile(ADDON_ROOT .. "/tests/settings_provider.lua")(R)
  WaypointUIAPI.Settings = provider
  R.SettingsPanel.Open(); R.SettingsPanel.SelectTab("Waypoint")
  provider.Set("RightClickToClear", false)
  R.SettingsPanel.controls.RightClickToClear:Click()
  local writes = H.wui.writes
  -- Right-click calls ClearDestination: user navigation plus native tracking.
  WaypointUIAPI.Navigation.ClearUserNavigation()
  C_SuperTrack.ClearAllSuperTracked()
  H.fire("QUEST_LOG_UPDATE"); H.advance(5)
  R.SettingsPanel.canvas:Hide(); R.SettingsPanel.Open(); H.advance(2)
  check("right-click clear shared setting does not recreate bridge marker", H.wui.nav == nil and H.wui.writes == writes)
end
print(string.format("%d passed, %d failed", passes, fails))
assert(fails == 0, "manual resume regressions failed")
