-- Regression for Al'Aketh Thugs: automatic tracking reasserted after the
-- acceptance window must not latch the manual override on Step 74.
local passes, fails = 0, 0
local function check(name, ok)
  if ok then passes = passes + 1; print("ok   " .. name)
  else fails = fails + 1; print("FAIL " .. name) end
end
local Q = 92544
local function setup(strategy)
  local H = dofile(ADDON_ROOT .. "/tests/harness.lua")
  local R = H.load(ADDON_ROOT, { strategy = strategy or "hybrid", debug = true })
  H.quests[Q] = { title = "Al'Aketh Thugs", ready = false, poi = 80, objectives = {
    { type = "monster", numFulfilled = 0, numRequired = 6 },
    { type = "monster", numFulfilled = 0, numRequired = 4 },
    { type = "monster", numFulfilled = 0, numRequired = 1 },
  } }
  local g = H.goto_(40, 0)
  local step = H.newStep(71, {}, g, H.accept(Q, "Al'Aketh Thugs"))
  H.setActiveSteps(step); H.point(g); H.advance(2)
  return H, R
end
local function route(H, index, dist, text)
  local g = H.goto_(dist, 0, { radius = 30, text = text })
  H.setActiveSteps(H.newStep(index, {}, g)); H.point(g)
  return g
end
local function objective(H)
  local a = H.complete(Q, 1, { text = "0/6 Al'Aketh Brute slain" })
  local b = H.complete(Q, 2)
  local sticky = H.newStep(72, { sticky = true, completewith = "next" }, a, b)
  local g = H.goto_(60, 0, { radius = 20, hidePin = true })
  local boss = H.newStep(73, { sticky = true }, g, H.complete(Q, 3))
  H.setActiveSteps(sticky, boss); H.point(g)
  return a
end
local function patrol(H)
  local g = H.loopPoint(90, 0)
  local step = H.newStep(77, { loop = "", hidewindow = true, sticky = true, completewith = "Grind6" },
    g, H.loopPoint(95, 0), H.placeholder())
  local grind = H.newStep(78, { label = "Grind6" }, { tag = "xp", text = "Grind to level 6" })
  H.setActiveSteps(step, grind); H.point(g)
  return g
end

for _, strategy in ipairs({ "coordinates", "hybrid", "native-first" }) do
  for _, ordering in ipairs({ "accept-first", "track-first", "late-track" }) do
    local H, R = setup(strategy)
    if ordering == "track-first" then H.setExternalQuest(Q, "RestedXP") end
    H.fire("QUEST_ACCEPTED", 1, Q)
    local progress = objective(H)
    if ordering == "late-track" then H.advance(2.5) end
    H.setExternalQuest(Q, "RestedXP"); H.advance(2)
    check(strategy .. " " .. ordering .. ": accepts guide quest without a persistent override", H.navAt(60)
      and not R.Sync.GetState().overrideActive)
    -- Installed .complete can reassert supertracking inside/after a WUI write.
    local create = WaypointUIAPI.Navigation.NewUserNavigation
    WaypointUIAPI.Navigation.NewUserNavigation = function(options)
      local result = create(options)
      H.setExternalQuest(Q, "RestedXP")
      return result
    end
    route(H, 74, 70, "Head to the upper level of the temple"); H.advance(2)
    check(strategy .. " " .. ordering .. ": travel point writes despite automatic tracking", H.navAt(70))
    WaypointUIAPI.Navigation.NewUserNavigation = create
    local writes = H.wui.writes
    for i = 1, 6 do
      progress.text = i .. "/6 Al'Aketh Brute slain"
      H.setExternalQuest(Q, "RestedXP"); H.fire("QUEST_LOG_UPDATE"); H.advance(.6)
    end
    check(strategy .. " " .. ordering .. ": no fight at unchanged coordinates", H.wui.writes == writes)
    for _, o in ipairs(H.quests[Q].objectives) do o.finished = true; o.numFulfilled = o.numRequired end
    H.quests[Q].ready = true
    H.fire("QUEST_LOG_UPDATE"); patrol(H); H.advance(2)
    check(strategy .. " " .. ordering .. ": completed quest to patrol follows fresh target", H.navAt(90)
      and R.Sync.GetState().bridgeActive and not R.Sync.GetState().overrideActive)
    check(strategy .. " " .. ordering .. ": step progression is visible in diagnostics",
      H.lastChat("Step 74 %-> Step 77") ~= nil)
    local audible = H.wui.audible or 0
    writes = H.wui.writes
    H.advance(5); H.fire("QUEST_LOG_UPDATE"); H.advance(1)
    check(strategy .. " " .. ordering .. ": no duplicate writes or sounds", H.wui.writes == writes
      and (H.wui.audible or 0) == audible)
  end
end

for _, source in ipairs({ "quest", "waypoint", "raw" }) do
  local H, R = setup()
  H.fire("QUEST_ACCEPTED", 1, Q); objective(H); H.setExternalQuest(Q, "Blizzard"); H.advance(2)
  if source == "quest" then H.setExternalQuest(999)
  elseif source == "waypoint" then H.setManualWaypoint("Player destination")
  else
    H.st.quest, H.st.user = nil, true
    H.st.waypoint = { uiMapID = 1421, position = { x = .8, y = .8 } }
    H.fire("USER_WAYPOINT_UPDATED")
  end
  local writes, marker, point = H.wui.writes, H.wui.nav, H.st.waypoint
  for i = 74, 76 do route(H, i, 70 + i, "Continue"); H.fire("QUEST_LOG_UPDATE"); H.advance(1) end
  patrol(H); H.advance(2)
  check(source .. ": real override protects navigation across several steps", H.wui.writes == writes
    and (H.wui.nav == marker or (source ~= "waypoint" and H.wui.nav == nil)) and H.st.waypoint == point)
  check(source .. ": latest step observed even while blocked", H.lastChat("Step 76 %-> Step 77") ~= nil)
  H.wui.nav, H.st.waypoint, H.st.quest, H.st.user = nil, nil, nil, false
  H.fire("USER_WAYPOINT_UPDATED"); H.fire("SUPER_TRACKING_CHANGED"); H.advance(.99)
  check(source .. ": resume delay preserved", H.wui.writes == writes)
  H.advance(.02)
  check(source .. ": resume uses latest patrol", H.navAt(90) and H.wui.writes == writes + 1
    and H.wui.nav.suppressAudio)
end

do
  local H = setup()
  H.fire("QUEST_ACCEPTED", 1, 999); H.setExternalQuest(999); objective(H); H.advance(3)
  check("accepting an unrelated quest never makes it guide-owned", H.st.quest == 999 and H.wui.writes == 1)
end
do
  local H, R = setup("coordinates")
  local e = route(H, 74, 70, "First instruction"); H.advance(2)
  local writes = H.wui.writes
  e.step.index = 77 -- same step/element tables and coordinates, reused in place
  e.text = "New instruction"
  H.advance(.6)
  check("in-place step index change is observed by cheap target polling", H.lastChat("Step 74 %-> Step 77") ~= nil)
  H.advance(2)
  check("same-coordinate instruction change updates presentation once", H.wui.nav.name == "New instruction"
    and H.wui.writes == writes + 1 and H.wui.nav.suppressAudio)
end

for _, strategy in ipairs({ "hybrid", "native-first" }) do
  local H, R = setup("coordinates")
  H.quests[101] = { title = "Previous native work", ready = true, poi = 40 }
  local g = H.goto_(40, 0)
  local oldStep = H.newStep(70, {}, g, H.turnin(101, "Previous native work"))
  H.setActiveSteps(oldStep); H.point(g); H.advance(1)
  H.slash("mode " .. strategy); H.advance(.08)
  H.fire("QUEST_ACCEPTED", 1, Q)
  H.quests[Q].ready, H.quests[Q].poi = true, 40
  local fresh = H.goto_(40, 0) -- same coordinates as the interrupted operation
  H.setActiveSteps(H.newStep(71, {}, fresh, H.turnin(Q, "Al'Aketh Thugs"))); H.point(fresh)
  H.setExternalQuest(Q, "RestedXP"); H.advance(2)
  check(strategy .. ": automatic guide tracking cannot leave a stale native hold", H.st.quest == Q
    and R.Sync.GetState().questID == Q and not R.Sync.GetState().pending)
end

do
  local H, R = setup("coordinates")
  local create = WaypointUIAPI.Navigation.NewUserNavigation
  WaypointUIAPI.Navigation.NewUserNavigation = function(options)
    local result = create(options)
    H.setManualWaypoint("Chosen inside the write")
    return result
  end
  route(H, 74, 70, "Continue"); H.advance(1)
  WaypointUIAPI.Navigation.NewUserNavigation = create
  local writes = H.wui.writes
  check("synchronous real external selection is observed after coordinate write", R.Sync.GetState().overrideActive
    and H.wui.nav.name == "Chosen inside the write")
  patrol(H); H.fire("QUEST_LOG_UPDATE"); H.advance(3)
  check("coordinate and presentation writes are blocked after synchronous takeover", H.wui.writes == writes
    and H.wui.nav.name == "Chosen inside the write")
end

do
  local H, R = setup()
  local malformed = { active = true, index = 72, elements = { false, "bad", { questId = Q, tag = false } } }
  RXPFrame.activeSteps = { false, malformed } -- malformed external data, bypass the fixture builder
  check("quest attribution validates external instruction fields", not R.Nav.HasActiveQuest({}, Q))
  check("quest attribution rejects malformed quest IDs", not R.Nav.HasActiveQuest({}, "92544"))
  RXPFrame.activeSteps = {}
  H.fire("QUEST_ACCEPTED", 1, {}); H.setExternalQuest(999); route(H, 74, 70, "Continue"); H.advance(2)
  check("malformed acceptance cannot grant guide ownership", H.st.quest == 999 and H.wui.writes == 1)
end
print(string.format("%d passed, %d failed", passes, fails))
assert(fails == 0, "quest progression regressions failed")
