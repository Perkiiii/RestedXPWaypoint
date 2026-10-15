-- F1-F3: observable destinations and writer history across native callbacks.
-- Every fixture starts in coordinates, then schedules the real native path.
local passes, fails = 0, 0
local function check(name, ok)
  if ok then passes = passes + 1; print("ok   " .. name)
  else fails = fails + 1; print("FAIL " .. name) end
end

local function setup(strategy, poi)
  local H = dofile(ADDON_ROOT .. "/tests/harness.lua")
  C_Map.GetBestMapForUnit = function() return 1421 end
  C_Map.GetPlayerMapPosition = function() return { GetXY = function() return 0.5, 0.5 end } end
  GetPlayerFacing = function() return 0 end
  local RXPW = H.load(ADDON_ROOT, { strategy = "coordinates", debug = true })
  H.quests[101] = { title = "Current quest", ready = true, poi = poi }
  H.quests[202] = { title = "Other quest", ready = true, poi = 60 }
  local g = H.goto_(40, 0)
  local instruction = H.turnin(101, "Current quest")
  local step = H.newStep(1, {}, g, instruction)
  H.setActiveSteps(step); H.point(g); H.advance(1)
  H.slash("mode " .. (strategy or "hybrid"))
  return H, RXPW, g, step, instruction
end

local function writesAfter(H, index, kind, writer)
  local found = 0
  for i = index + 1, #H.operations do
    local op = H.operations[i]
    if (not kind or op.kind == kind) and (not writer or op.writer == writer) then found = found + 1 end
  end
  return found
end

-- F1: cancellation on either side of the native setter, for both strategies.
for _, strategy in ipairs({ "hybrid", "native-first" }) do
  for _, delay in ipairs({ 0.01, 0.08, 0.24, 0.26, 0.84 }) do
    local H, RXPW = setup(strategy) -- missing native POI would normally cause fallback
    H.advance(delay)
    H.slash("off")
    local marker, quest, waypoint, at = H.wui.nav, H.st.quest, H.st.waypoint, #H.operations
    H.advance(2)
    check("F1 " .. strategy .. " off at " .. delay .. ": destination unchanged",
      H.wui.nav == marker and H.st.quest == quest and H.st.waypoint == waypoint
      and not RXPW.Sync.GetState().pending and not RXPW.Sync.GetState().running
      and writesAfter(H, at, nil, "bridge") == 0)
  end
end

do
  local H, RXPW = setup("hybrid", 40)
  H.advance(0.08); H.slash("off"); H.slash("on"); H.advance(0.18)
  check("F1 restart: old SetQuest cannot run in the new session", H.st.quest == nil and not RXPW.Sync.GetState().pending)
  H.advance(1.5)
  check("F1 restart: new work succeeds", H.st.quest == 101 and H.st.setQuestCalls == 1
    and RXPW.Sync.GetState().mode == "native" and not RXPW.Sync.GetState().pending)
end

do
  local H = setup("hybrid", 40)
  H.advance(0.08); H.slash("off"); H.slash("sync"); H.slash("off"); H.advance(2)
  check("F1 explicit manual sync survives auto-sync off", H.st.quest == 101 and not H.st.user
    and H.mode() == "native" and not H.RXPW.Sync.GetState().pending)
  H.quests[101].poi = nil
  H.slash("sync"); H.advance(2)
  check("F1 manual sync off retains authorized coordinate fallback", H.navAt(40)
    and H.wui.nav.flags == "RestedXPWaypoint" and H.st.quest == nil and H.st.user)
end

do
  local H = setup("hybrid", 40)
  H.advance(2)
  local at = #H.operations
  H.slash("off"); H.advance(2)
  check("F1 stopping completed native navigation leaves it displayed", H.st.quest == 101
    and writesAfter(H, at, nil, "bridge") == 0)
  H.slash("mode coordinates"); H.slash("sync")
  local marker, waypoint = H.wui.nav, H.st.waypoint
  at = #H.operations
  H.slash("off"); H.advance(2)
  check("F1 stopping coordinates leaves the actual waypoint unchanged", H.wui.nav == marker
    and H.st.waypoint == waypoint and H.st.user and writesAfter(H, at, nil, "bridge") == 0)
end

-- A queued quest evaluation from the old automatic session must not execute
-- immediately after restart, before the new target has settled.
do
  local H, RXPW = setup("hybrid", 40)
  H.advance(2); H.slash("mode coordinates")
  H.fire("QUEST_LOG_UPDATE"); H.advance(0.1); H.slash("off")
  local b = H.goto_(60, 0, { text = "New destination" })
  H.newStep(2, {}, b); H.point(b)
  H.slash("on"); H.advance(0.41)
  check("F1 restart discards the old queued quest evaluation", H.navAt(40))
  H.advance(1)
  check("F1 restart settles and writes the new destination", H.navAt(60) and RXPW.Sync.GetState().bridgeActive)
end

-- F2: external selection at several offsets on both sides of SetQuest.
for _, strategy in ipairs({ "hybrid", "native-first" }) do
  for _, delay in ipairs({ 0.01, 0.08, 0.24, 0.26, 0.84 }) do
    for _, selection in ipairs({ "pin", "quest", "addon" }) do
      local H, RXPW = setup(strategy)
      H.advance(delay)
      if selection == "pin" then H.setManualWaypoint("Player destination")
      else H.setExternalQuest(202, selection == "addon" and "RestedXP" or "player") end
      local marker, waypoint, quest, user, at = H.wui.nav, H.st.waypoint, H.st.quest, H.st.user, #H.operations
      H.fire("QUEST_LOG_UPDATE"); H.advance(2)
      H.fire("QUEST_LOG_UPDATE"); H.advance(1)
      check("F2 " .. strategy .. " " .. selection .. " at " .. delay .. ": external writer keeps control",
        H.wui.nav == marker and H.st.waypoint == waypoint and H.st.quest == quest and H.st.user == user
        and not RXPW.Sync.GetState().pending and not RXPW.Sync.GetState().bridgeActive
        and writesAfter(H, at, nil, "bridge") == 0
        and H.operations[at].writer == (selection == "addon" and "RestedXP" or "player"))
    end
  end
end

do
  local H = setup("hybrid", 40)
  H.advance(0.3)
  H.setExternalQuest(202)
  -- Returning to the expected ID does not undo the already observed override.
  H.setExternalQuest(101, "RestedXP")
  local at = #H.operations
  H.fire("QUEST_LOG_UPDATE"); H.advance(2)
  check("F2 matching quest ID does not revive an interrupted transition", H.st.quest == 101
    and writesAfter(H, at, nil, "bridge") == 0 and not H.RXPW.Sync.GetState().pending)
end

do
  local H = setup("hybrid", 40)
  H.advance(0.3)
  -- A raw Blizzard pin can replace the native waypoint before WUI has
  -- replaced/cleared its stored session table.
  H.st.waypoint = { uiMapID = 1421, position = { x = 0.7, y = 0.7 } }
  H.st.user, H.st.quest = true, nil
  H.fire("USER_WAYPOINT_UPDATED")
  local waypoint, at = H.st.waypoint, #H.operations
  H.advance(2)
  check("F2 raw native pin is protected despite a stale WUI session", H.st.waypoint == waypoint
    and H.st.user and H.st.quest == nil and writesAfter(H, at, nil, "bridge") == 0)
end

-- Callbacks must also validate snapshots if no navigation event is delivered.
do
  local H = setup("hybrid", 40)
  H.advance(0.08)
  H.st.quest, H.st.user = 202, false
  local at = #H.operations
  H.advance(2)
  check("F2 changed native quest detected without an event", H.st.quest == 202
    and writesAfter(H, at, nil, "bridge") == 0)
end

do
  local H = setup("hybrid", 40)
  local setter = C_SuperTrack.SetSuperTrackedQuestID
  C_SuperTrack.SetSuperTrackedQuestID = function(q)
    setter(q)
    if q == 101 then H.setExternalQuest(202, "reacting addon") end
  end
  H.advance(2)
  check("F2 synchronous addon reaction to SetQuest is not adopted as bridge ownership",
    H.st.quest == 202 and H.wui.nav == nil and not H.st.user and not H.RXPW.Sync.GetState().pending)
  local at = #H.operations
  H.fire("QUEST_LOG_UPDATE"); H.advance(1)
  check("F2 synchronous override is held without fallback or reclaim", writesAfter(H, at, nil, "bridge") == 0)
end

do
  local H = setup("hybrid", 40)
  H.slash("mode coordinates") -- supersede the initial pending transition
  local clear = WaypointUIAPI.Navigation.ClearUserNavigation
  WaypointUIAPI.Navigation.ClearUserNavigation = function(...)
    clear(...)
    H.setManualWaypoint("Selected during clear", "reacting addon")
  end
  H.slash("mode hybrid"); H.advance(2)
  check("F2 synchronous addon reaction to ClearOwnedNavigation is preserved", H.wui.nav
    and H.wui.nav.name == "Selected during clear" and H.st.user and H.st.quest == nil
    and not H.RXPW.Sync.GetState().pending)
end

for _, delay in ipairs({ 0.01, 0.08, 0.3 }) do
  local H, RXPW = setup("native-first")
  H.advance(delay); H.slash("preview all far")
  local preview = H.wui.nav
  local at = #H.operations
  H.advance(2)
  check("F1/F2 preview at " .. delay .. ": old callbacks cannot replace it", H.wui.nav == preview
    and H.wui.nav.flags == "RestedXPWaypoint-Preview" and H.st.quest == nil and H.st.user
    and not RXPW.Sync.GetState().pending and writesAfter(H, at, nil, "bridge") == 0)
  H.advance(2.1)
  check("F1/F2 preview cycle continues independently", H.wui.nav.flags == "RestedXPWaypoint-Preview"
    and H.wui.nav.name == "Preview: Quest in progress")
  H.slash("preview off"); H.advance(2)
  check("F1 preview exit starts only current sync work", H.navAt(40)
    and H.wui.nav.flags == "RestedXPWaypoint" and H.st.quest == nil and RXPW.Sync.GetState().running)
end

do
  local H = setup("native-first")
  H.advance(0.08); H.slash("off"); H.slash("sync")
  H.slash("preview repair")
  local at = #H.operations
  H.advance(2)
  check("F2 preview also supersedes a pending explicit manual sync", H.wui.nav
    and H.wui.nav.name == "Preview: Repair" and H.st.user and H.st.quest == nil
    and writesAfter(H, at, nil, "bridge") == 0 and not H.RXPW.Sync.GetState().pending)
end

do
  local H = setup("native-first", 40)
  H.advance(0.08)
  local b = H.goto_(60, 0)
  H.newStep(2, {}, b, H.turnin(202, "Other quest")); H.point(b)
  local at = #H.operations
  H.slash("sync"); H.advance(2)
  local stale = false
  for i = at + 1, #H.operations do
    if H.operations[i].kind == "quest" and H.operations[i].value == 101 then stale = true end
  end
  check("F2 newer explicit native operation supersedes the delayed old setter", H.st.quest == 202
    and not H.st.user and H.mode() == "native" and not stale and not H.RXPW.Sync.GetState().pending)
end

-- F3: invalidate the target before SetQuest or Verify. No stale fallback,
-- quest release, or other navigation write is allowed while it is invalid.
local invalidators = {
  missing = function(H) H.point(nil) end,
  inactive = function(_, _, step) step.active = nil end,
  skipped = function(_, g) g.skip = true end,
  hidden = function(_, g) g.hidden = true end,
  map = function(_, g) g.zone = nil end,
  coordinates = function(_, g) g.x = nil end,
  unknown_map = function() C_Map.GetMapInfo = function() return nil end end,
  unsupported_map = function() C_Map.CanSetUserWaypointOnMap = function() return false end end,
}
for _, name in ipairs({ "missing", "inactive", "skipped", "hidden", "map", "coordinates", "unknown_map", "unsupported_map" }) do
  for _, delay in ipairs({ 0.08, 0.3 }) do
    local H, RXPW, g, step = setup("native-first")
    H.advance(delay); invalidators[name](H, g, step)
    local marker, waypoint, quest, at = H.wui.nav, H.st.waypoint, H.st.quest, #H.operations
    H.advance(2)
    check("F3 " .. name .. " at " .. delay .. ": no stale write", H.wui.nav == marker
      and H.st.waypoint == waypoint and H.st.quest == quest and not RXPW.Sync.GetState().pending
      and not RXPW.Sync.GetState().bridgeActive and writesAfter(H, at, nil, "bridge") == 0)
  end
end

for _, delay in ipairs({ 0.08, 0.3 }) do
  for _, activity in ipairs({ "travel", "quest" }) do
    local H, RXPW = setup("native-first")
    H.advance(delay)
    local b = H.goto_(60, 0, activity == "travel" and { text = "New destination" } or nil)
    local step = H.newStep(2, {}, b, activity == "quest" and H.turnin(202, "Other quest") or H.header("Continue"))
    H.setActiveSteps(step); H.point(b)
    local at = #H.operations
    H.advance(2)
    local stale = false
    for i = at + 1, #H.operations do
      local op = H.operations[i]
      if (op.kind == "quest" and op.value == 101)
        or (op.kind == "navigation" and op.value.x == 20) then stale = true end
    end
    check("F3 newer " .. activity .. " at " .. delay .. ": only the new target is applied",
      not stale and not RXPW.Sync.GetState().pending
      and (activity == "travel" and H.navAt(60) and H.st.user and H.st.quest == nil
        or activity == "quest" and H.st.quest == 202 and not H.st.user and H.mode() == "native"))
  end
end

do
  local H, RXPW, _, _, instruction = setup("native-first", 40)
  H.advance(0.3)
  instruction.questId = 202 -- same arrow and coordinates, different activity
  local at = #H.operations
  H.advance(0.6)
  check("F3 changed quest on the same arrow invalidates old verification", not RXPW.Sync.GetState().pending
    and not RXPW.Sync.GetState().bridgeActive and writesAfter(H, at, nil, "bridge") == 0)
  H.advance(2)
  check("F3 normal evaluation picks up the new quest activity", H.st.quest == 202 and H.mode() == "native")
end

for _, delay in ipairs({ 0.08, 0.3 }) do
  local H, RXPW = setup("hybrid")
  H.advance(delay); H.fire("PLAYER_LEAVING_WORLD")
  local marker, quest, at = H.wui.nav, H.st.quest, #H.operations
  H.advance(2)
  check("F3 loading at " .. delay .. ": no delayed writes", H.wui.nav == marker and H.st.quest == quest
    and not RXPW.Sync.GetState().pending and writesAfter(H, at, nil, "bridge") == 0)
  local b = H.goto_(60, 0, { text = "After loading" })
  H.newStep(2, {}, b); H.point(b); H.fire("PLAYER_ENTERING_WORLD"); H.advance(2)
  check("F3 zoning resumes with the current coordinates", H.navAt(60) and H.st.user and H.st.quest == nil)
end

do
  local H, RXPW = setup("hybrid")
  H.advance(0.3); H.fire("PLAYER_ENTERING_WORLD")
  H.point(nil)
  local quest, at = H.st.quest, #H.operations
  H.advance(2)
  check("F3 entering-world alone invalidates old verification", H.st.quest == quest
    and H.wui.nav == nil and not RXPW.Sync.GetState().pending and writesAfter(H, at, nil, "bridge") == 0)
end

-- Positive controls: the safety gates must not disable normal native paths,
-- coordinate fallback, next-candidate selection, or subsequent route changes.
for _, strategy in ipairs({ "hybrid", "native-first" }) do
  for _, available in ipairs({ true, false }) do
    local H, RXPW = setup(strategy, available and 40 or nil)
    H.advance(2)
    local at = #H.operations
    check(strategy .. (available and ": uninterrupted native succeeds" or ": current target falls back normally"),
      not RXPW.Sync.GetState().pending and (available and H.st.quest == 101 and not H.st.user and H.mode() == "native"
        or not available and H.navAt(40) and H.st.quest == nil and H.st.user and H.wui.nav.flags == "RestedXPWaypoint"))
    H.fire("QUEST_LOG_UPDATE"); H.advance(2)
    check(strategy .. ": stable result does not write again", writesAfter(H, at, nil, "bridge") == 0)
  end
end

do
  local H = setup("hybrid", 40)
  local setter = C_SuperTrack.SetSuperTrackedQuestID
  C_SuperTrack.SetSuperTrackedQuestID = function(q)
    if q == 101 then error("simulated unavailable native setter") end
    return setter(q)
  end
  H.advance(2)
  check("F3 setter error still falls back for a valid authorized target", H.navAt(40)
    and H.wui.nav.flags == "RestedXPWaypoint" and H.st.user and H.st.quest == nil
    and not H.RXPW.Sync.GetState().pending)
end

do
  local H = setup("hybrid", 40)
  H.advance(0.08); H.setExternalQuest(202)
  H.advance(1)
  local b = H.goto_(70, 0, { text = "Follow the new route" })
  H.newStep(2, {}, b); H.point(b); H.advance(2)
  check("F2 override hold ends at a genuinely new route destination", H.navAt(70)
    and H.st.user and H.st.quest == nil and H.wui.nav.flags == "RestedXPWaypoint")
end

print(string.format("%d passed, %d failed", passes, fails))
if fails > 0 then error(fails .. " transition regression(s) failed", 0) end
