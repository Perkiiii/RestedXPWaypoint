-- Event/ticker races and native marker reuse; no renderer is simulated.
local passes, fails = 0, 0
local function check(name, ok, detail)
  if ok then passes = passes + 1; print("ok   " .. name)
  else fails = fails + 1; print("FAIL " .. name .. " -- " .. tostring(detail)) end
end
local function setup(strategy)
  local H = dofile(ADDON_ROOT .. "/tests/harness.lua")
  C_Map.GetBestMapForUnit = function() return 1421 end
  C_Map.GetPlayerMapPosition = function() return { GetXY = function() return 0.5, 0.5 end } end
  GetPlayerFacing = function() return 0 end
  local R = H.load(ADDON_ROOT, { strategy = strategy, debug = true })
  local old = H.goto_(20, 0, { text = "Previous destination" })
  H.newStep(53, {}, old); H.point(old); H.advance(2)
  H.quests[92473] = { title = "Aggressive Encroachment", ready = true, poi = 80,
    objectives = { { type = "item", numFulfilled = 0, numRequired = 6 } } }
  return H, R
end
local function point(H, dist, index, native)
  local g = H.goto_(dist, 0, native and {} or { radius = 30 })
  local s
  if native then s = H.newStep(index, {}, g, H.turnin(92473, "Aggressive Encroachment"))
  else
    s = H.newStep(index, {}, g, H.goto_(dist + 5, 0, { radius = 30 }), H.complete(92473, 1))
  end
  H.setActiveSteps(s); H.point(g)
  return g
end
local function operations(H, start)
  local nav, quest, intermediate, first = 0, 0, 0
  for i = start + 1, #H.operations do
    local op = H.operations[i]
    if op.writer == "bridge" then
      if op.kind == "navigation" then
        nav = nav + 1; first = first or op.time
        if op.value.x ~= 40 then intermediate = intermediate + 1 end
      elseif op.kind == "quest" then quest = quest + 1 end
    end
  end
  return nav, quest, intermediate, first
end

for _, strategy in ipairs({ "coordinates", "hybrid", "native-first" }) do
  local H = setup(strategy)
  local start, at = #H.operations, GetTime()
  H.fire("QUEST_ACCEPTED", 92473)
  H.setExternalQuest(92473, "RestedXP")
  -- An external marker exists before any bridge write; the bridge cannot hide it.
  check(strategy .. " external quest marker is independent", H.st.quest == 92473 and operations(H, start) == 0)
  H.advance(0.26); point(H, 45, 54)
  H.advance(0.10); point(H, 55, 55)
  H.advance(0.10); point(H, 65, 56)
  H.advance(0.10); point(H, 80, 58)
  H.advance(1.2)
  local n, q, interim, first = operations(H, start)
  check(strategy .. " rapid steps apply only the final route point", H.navAt(80) and n == 1 and interim == 0, n)
  check(strategy .. " no bridge native supertracking", q == 0, q)
  check(strategy .. " final route point within 1 second of last change", first and first - at <= 1.56, first and first - at)
  print(string.format("measure %s: final %.3fs, writes %d, quest setters %d, intermediate %d", strategy, first - at, n, q, interim))
end

-- A change just before the old quest timer must not bypass the target quiet time.
do
  local H = setup("coordinates")
  local start = #H.operations
  H.fire("QUEST_ACCEPTED", 92473)
  H.advance(0.46); point(H, 60, 54)
  H.advance(0.10); point(H, 80, 58)
  H.advance(1)
  local n, _, interim = operations(H, start)
  check("quest timer cannot publish a target still resolving", H.navAt(80) and n == 1 and interim == 0, n)
end

for _, strategy in ipairs({ "hybrid", "native-first" }) do
  local H, R = setup(strategy)
  local start, at = #H.operations, GetTime()
  H.fire("QUEST_ACCEPTED", 92473); H.setExternalQuest(92473, "RestedXP")
  H.advance(0.26); point(H, 60, 54)
  H.advance(0.20); point(H, 80, 58, true)
  H.advance(1.6)
  local n, q = operations(H, start)
  check(strategy .. " final eligible native marker is retained", H.st.quest == 92473 and not H.st.user
    and R.Sync.GetState().mode == "native" and not R.Sync.GetState().pending)
  check(strategy .. " adoption has no coordinate writes or quest setters", n == 0 and q == 0, n .. "/" .. q)
  check(strategy .. " adoption leaves inactive bridge session intact", H.wui.clears == 0)
  check(strategy .. " adoption still verifies", R.Sync.GetState().lastVerification and R.Sync.GetState().lastVerification.ok)
  print(string.format("measure %s native: externally visible throughout, verified by %.3fs; writes %d, setters %d", strategy,
    R.Sync.GetState().lastVerification.time - at, n, q))
end

do
  local H, R = setup("native-first")
  local start = #H.operations
  H.quests[92473].ready = false
  H.fire("QUEST_ACCEPTED", 92473); H.setExternalQuest(92473, "RestedXP")
  local g = H.goto_(80, 0)
  local s = H.newStep(58, {}, g, H.complete(92473, 1))
  H.setActiveSteps(s); H.point(g); H.advance(1.5)
  local n, q = operations(H, start)
  check("eligible native-first objective is adopted too", R.Sync.GetState().kind == "objective"
    and H.st.quest == 92473 and n == 0 and q == 0)
end

for _, action in ipairs({ "bad-distance", "manual", "changed-target" }) do
  local H, R = setup("hybrid")
  H.fire("QUEST_ACCEPTED", 92473); H.setExternalQuest(92473, "RestedXP")
  point(H, 80, 58, true); H.advance(0.55)
  check(action .. " starts native adoption pending verification", R.Sync.GetState().pending)
  local start = #H.operations
  if action == "bad-distance" then H.quests[92473].poi = 500
  elseif action == "manual" then H.setManualWaypoint("During verification")
  else point(H, 90, 59) end
  H.advance(1.5)
  if action == "bad-distance" then
    check("adopted native still falls back when verification fails", H.navAt(80) and H.st.user and H.failureText() ~= "")
  elseif action == "manual" then
    check("adoption verification cannot reclaim a manual pin", H.wui.nav.name == "During verification" and operations(H, start) == 0)
  else
    check("adoption cannot restore captured coordinates", H.navAt(90))
  end
end

do
  local H = setup("coordinates")
  local start = #H.operations
  H.fire("QUEST_ACCEPTED", 92473)
  H.advance(0.10); point(H, 80, 58)
  H.advance(0.42)
  local n = operations(H, start)
  check("stable acceptance destination is applied promptly", H.navAt(80) and n == 1)
  for _ = 1, 10 do H.fire("QUEST_LOG_UPDATE"); H.advance(0.1) end
  H.advance(1)
  check("repeated quest events do not rewrite the final marker", operations(H, start) == 1)
end

for _, action in ipairs({ "manual", "raw", "preview", "off", "sync", "world" }) do
  local H, R = setup("coordinates")
  H.fire("QUEST_ACCEPTED", 92473)
  H.advance(0.26); point(H, 60, 54)
  H.advance(0.05)
  if action == "manual" then H.setManualWaypoint("Chosen while settling")
  elseif action == "raw" then
    H.st.user, H.st.quest = true, nil
    H.st.waypoint = { uiMapID = 1421, position = { x = 0.7, y = 0.7 } }
    H.fire("USER_WAYPOINT_UPDATED")
  elseif action == "preview" then H.slash("preview vendor")
  elseif action == "off" then H.slash("off")
  elseif action == "world" then H.fire("PLAYER_LEAVING_WORLD")
  else H.slash("sync") end
  local start, nav, waypoint = #H.operations, H.wui.nav, H.st.waypoint
  if action ~= "sync" then point(H, 80, 58) end
  H.advance(1.5)
  check(action .. " supersedes deferred automatic work", H.wui.nav == nav and H.st.waypoint == waypoint
    and operations(H, start) == 0)
  if action == "sync" then check("explicit sync is immediate", H.navAt(60)) end
  if action == "manual" then
    point(H, 90, 59); H.advance(0.6)
    check("a later real destination resumes after the deferred pin hold", H.navAt(90))
  end
end

do
  local H = setup("coordinates")
  local start = #H.operations
  H.fire("QUEST_ACCEPTED", 92473)
  -- A continuing burst must reach current data at the bounded deadline.
  for i = 1, 6 do H.advance(0.16); point(H, 40 + i * 5, 60 + i); H.fire("QUEST_LOG_UPDATE") end
  H.advance(0.12)
  local n, _, _, first = operations(H, start)
  check("continuous transitions have a bounded wait", n >= 1 and first <= 3.001, first)
  point(H, 80, 70); H.advance(0.6)
  check("newest activity wins after the deadline", H.navAt(80))
end

for _, event in ipairs({ "QUEST_TURNED_IN", "QUEST_LOG_UPDATE" }) do
  local H = setup("coordinates")
  local start = #H.operations
  H.fire(event, 92473)
  H.advance(0.46); point(H, 60, 54)
  H.advance(0.10); point(H, 80, 58)
  H.advance(1)
  local n, _, interim = operations(H, start)
  check(event .. " uses current settled data", H.navAt(80) and n == 1 and interim == 0)
end

do
  local H = setup("coordinates")
  local start, at = #H.operations, GetTime()
  point(H, 80, 58); H.advance(0.51)
  local n, _, _, first = operations(H, start)
  check("ordinary navigation retains its existing polling latency", H.navAt(80) and n == 1 and first - at <= 0.5)
  point(H, 90, 59); H.advance(0.5)
  check("next legitimate route point is preserved", H.navAt(90))
end

print(string.format("%d passed, %d failed", passes, fails))
if fails > 0 then error(fails .. " test(s) failed", 0) end
