-- Stage 4 (v0.5.9): F7 activity observation, F8 native area re-verification,
-- orphaned preview recovery after /reload and same-destination presentation
-- updates. Every fixture uses a fresh harness and checks the actual final
-- navigation (WoW supertracking, Waypoint UI's destination, flags, labels).
-- Mocked APIs and deterministic timers; not proof of in-game behaviour, and the
-- Waypoint UI pathfinding model is counters only (no rendering or FPS).
local passes, fails = 0, 0
local current

local function check(name, ok, detail)
  if ok then passes = passes + 1; print("ok   " .. name)
  else
    fails = fails + 1
    print("FAIL " .. name .. (detail ~= nil and (" -- " .. tostring(detail)) or ""))
    if current then for i = math.max(1, #current.chat - 8), #current.chat do print("       | " .. current.chat[i]) end end
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

local function start(strategy, saved)
  local H = fresh()
  saved = saved or {}
  saved.strategy = saved.strategy or strategy
  saved.debug = true
  return H, H.load(ADDON_ROOT, saved)
end

-- Pre-v0.5.9 modules have no counters; zeros keep a pre-fix run going.
local function counters(R)
  local c = R.Sync.GetState().counters or {}
  return setmetatable({}, { __index = function(_, k) return c[k] or 0 end })
end
local function kill(n, r) return { type = "monster", finished = n >= r, numFulfilled = n, numRequired = r } end

-- Navigation writes (quest, waypoint, clear) by a writer since operation index.
local function opsAfter(H, index, writer)
  local found = 0
  for i = index + 1, #H.operations do
    if not writer or H.operations[i].writer == writer then found = found + 1 end
  end
  return found
end

local function native(H, questID, kind)
  local mode, q, k = H.mode()
  return mode == "native" and q == questID and (kind == nil or k == kind) and H.st.quest == questID
    and not H.RXPW.Sync.GetState().pending
end

-- Advances in small steps until a native operation is pending (max 5 s).
local function untilPending(H)
  for _ = 1, 100 do
    if H.RXPW.Sync.GetState().pending then return true end
    H.advance(0.05)
  end
  return false
end

-- RestedXP-Skyborne patrol shape: #hidewindow / #completewith / #loop / 7 points / +1.
local function patrolFixture(H)
  local points, elements = {}, {}
  for i, d in ipairs({ 30, 34, 38, 42, 46, 50, 54 }) do
    points[i] = H.goto_(d, 0, { radius = 40, hidePin = true })
    elements[i] = points[i]
  end
  elements[#elements + 1] = H.placeholder()
  local patrol = H.newStep(4, { hidewindow = "", completewith = "Juvenile Vuldren", sticky = true, loop = "" },
    table.unpack(elements))
  return patrol, points
end

--------------------------------------------------------------------------------
-- F7: RestedXP activity changes while the arrow stays on the same waypoint
--------------------------------------------------------------------------------

-- F7.1 patrol unchanged, served quest changes A -> B (step skipped, no quest event)
do
  local H, R = start("native-first")
  local patrol, points = patrolFixture(H)
  local A, B = 92461, 92462
  H.quests[A] = { title = "Harmony in Balance", poi = 40, objectives = { kill(1, 8) } }
  H.quests[B] = { title = "Infestation Investigation", poi = 44, objectives = { kill(2, 8) } }
  local s5 = H.newStep(5, { completewith = "next", sticky = true }, H.header("Kill |cRXP_ENEMY_Juvenile Vuldren|r"),
    H.complete(A, 1), H.mob("Juvenile Vuldren"))
  local s6 = H.newStep(6, {}, H.header("Kill |cRXP_ENEMY_Pesky Cirrusfly|r"), H.star("|cRXP_WARN_Prioritize them|r"),
    H.complete(B, 1), H.mob("Pesky Cirrusfly"))
  local s7 = H.newStep(7, { label = "Juvenile Vuldren" }, H.header("Kill |cRXP_ENEMY_Juvenile Vuldren|r"), H.complete(A, 1))
  H.setActiveSteps(patrol, s5, s6); H.point(points[1]); H.advance(3)
  check("F7.1 setup: prioritized quest B tracked natively", native(H, B, "objective"))

  local calls, writes = H.st.setQuestCalls, H.wui.writes
  H.setActiveSteps(patrol, s7) -- the player skips step 6; s5 completes with it
  H.advance(3)
  local fresh = R.Nav.Decide(R.RXP.GetTarget(), "native-first", R.Sync.GetDecisionContext())
  check("F7.1 served quest change at the same patrol point switches to A", native(H, A, "objective")
    and fresh.questID == A and H.st.setQuestCalls == calls + 1 and H.wui.writes == writes
    and H.transitionText() == "native quest 92462 -> native quest 92461", H.transitionText())

  -- F7.9 a stable signature causes no further evaluation or write
  local c = counters(R)
  local evaluations, checks = c.evaluations, c.activityChecks
  calls, writes = H.st.setQuestCalls, H.wui.writes
  local at = #H.operations
  H.advance(30)
  c = counters(R)
  check("F7.9 unchanged activity: no evaluation, write or supertrack for 30 s", c.evaluations == evaluations
    and H.st.setQuestCalls == calls and H.wui.writes == writes and opsAfter(H, at) == 0 and native(H, A))
  check("F7.9 activity is compared about once a second", c.activityChecks and checks
    and c.activityChecks - checks >= 28 and c.activityChecks - checks <= 31, c.activityChecks)
end

-- F7.2 an instruction of the arrow's own #loop step is ticked off (no quest event)
do
  local H = start("native-first")
  local C = 700
  H.quests[C] = { title = "Strange Chest", poi = 45, objectives = { kill(0, 6) } }
  local lp = H.lowPrioPoint(40, 0)
  local loot = H.plusObjective("Loot the |cRXP_PICK_Strange Chest|r")
  local s = H.newStep(10, { loop = "" }, lp, H.loopPoint(44, 0), H.loopPoint(48, 0), H.header("Kill Boars"),
    H.complete(C, 1, { text = "Boars slain: 0/6" }), loot)
  H.setActiveSteps(s); H.point(lp); H.advance(3)
  check("F7.2 setup: pending +objective keeps coordinates", H.mode() == "coordinates" and H.navAt(40)
    and H.wui.nav.name == "Boars slain: 0/6")
  loot.completed = true; loot.skip = true -- ActiveStepElementPostClick: skip, no message
  H.advance(3)
  check("F7.2 skipped instruction at an unchanged arrow -> native objective", native(H, C, "objective")
    and H.wui.nav == nil)
end

-- F7.3 sticky step becoming active, then inactive again; F7.6 redraws
do
  local H, R = start("native-first")
  local patrol, points = patrolFixture(H)
  local D, E = 801, 802
  H.quests[D] = { title = "Spider Work", poi = 41, objectives = { kill(0, 6) } }
  H.quests[E] = { title = "Wolf Work", poi = 43, objectives = { kill(0, 6) } }
  local sD = H.newStep(11, { completewith = "Wolves", sticky = true }, H.header("Kill Spiders"),
    H.star("Prioritize them"), H.complete(D, 1))
  local sE = H.newStep(12, { label = "Wolves" }, H.header("Kill Wolves"), H.complete(E, 1), H.mob("Wolf"))
  H.setActiveSteps(patrol, sE); H.point(points[1]); H.advance(3)
  check("F7.3 setup: only the current step's quest", native(H, E))
  H.setActiveSteps(patrol, sD, sE); H.advance(3)
  check("F7.3 sticky step becomes active -> its prioritized quest", native(H, D))
  H.setActiveSteps(patrol, sE); H.advance(3)
  check("F7.3 sticky step inactive again -> current step's quest", native(H, E))

  local c = counters(R)
  local evaluations, changes = c.evaluations, c.activityChanges
  local calls, writes, at = H.st.setQuestCalls, H.wui.writes, #H.operations
  for i = 1, 10 do
    -- RestedXP's guide window redraw: completed toggles on headings, helpers
    -- and every .goto (GuideWindow.lua ~1316); activeSteps refilled.
    for _, s in ipairs({ patrol, sE }) do
      for _, e in ipairs(s.elements) do
        if e.textOnly or not e.text then e.completed = (i % 2 == 0) or nil end
      end
    end
    RXPFrame.activeSteps = { patrol, sE }
    H.advance(1)
  end
  c = counters(R)
  check("F7.6 redraws and rebuilt activeSteps: no evaluation, write or supertrack", c.evaluations == evaluations
    and c.activityChanges == changes and H.st.setQuestCalls == calls and H.wui.writes == writes
    and opsAfter(H, at) == 0 and native(H, E))
end

-- F7.4 prioritization changes without arrow movement; F7.8 manual protection
do
  local H, R = start("native-first")
  local patrol, points = patrolFixture(H)
  local F, G = 901, 902
  H.quests[F] = { title = "Feather Work", poi = 42, objectives = { kill(0, 6) } }
  H.quests[G] = { title = "Gem Work", poi = 44, objectives = { kill(0, 6) } }
  local sS = H.newStep(21, { completewith = "Done", sticky = true }, H.header("Kill anything"),
    H.complete(F, 1), H.complete(G, 1))
  local sC1 = H.newStep(22, {}, H.header("Kill Gem Golems"), H.complete(G, 1))
  local sC2 = H.newStep(23, {}, H.header("Kill Harpies"), H.complete(F, 1))
  H.setActiveSteps(patrol, sS, sC1); H.point(points[1]); H.advance(3)
  check("F7.4 setup: current step 22 selects G", native(H, G))
  local calls = H.st.setQuestCalls
  H.setActiveSteps(patrol, sS, sC2); H.advance(3)
  local decision = R.Sync.GetState().mode and R.Nav.Decide(R.RXP.GetTarget(), "native-first", R.Sync.GetDecisionContext())
  check("F7.4 new current step at the same point selects F", native(H, F) and H.st.setQuestCalls == calls + 1
    and decision.questID == F and decision.selection == "RestedXP's current step 23", decision.selection)

  H.setManualWaypoint("Player pin")
  local marker, at = H.wui.nav, #H.operations
  H.setActiveSteps(patrol, sS, sC1); H.advance(5)
  H.fire("QUEST_LOG_UPDATE"); H.advance(3)
  check("F7.8 activity change while a manual pin is tracked: pin kept, no bridge write",
    H.wui.nav == marker and H.st.user and H.st.quest == nil and opsAfter(H, at, "bridge") == 0)
end

-- F7.5 activity changes during a pending native transition
do
  local H = start("native-first")
  local patrol, points = patrolFixture(H)
  local E, F = 802, 803
  H.quests[E] = { title = "Wolf Work", poi = 43, objectives = { kill(0, 6) } }
  H.quests[F] = { title = "Bear Work", poi = 42, objectives = { kill(0, 6) } }
  local feathers = H.plusObjective("Collect 5 feathers")
  local sE = H.newStep(12, {}, H.header("Kill Wolves"), H.complete(E, 1), feathers)
  local sF = H.newStep(13, {}, H.header("Kill Bears"), H.complete(F, 1))
  H.setActiveSteps(patrol, sE); H.point(points[1]); H.advance(3)
  check("F7.5 setup: coordinates while a non-quest instruction is pending", H.mode() == "coordinates" and H.navAt(30))
  feathers.completed = true; feathers.skip = true
  local pending = untilPending(H)
  H.setActiveSteps(patrol, sF) -- RestedXP moves on before the transition finishes
  H.advance(4)
  local v = H.RXPW.Sync.GetState().lastVerification
  check("F7.5 pending transition superseded: final native target is the new activity's quest", pending
    and native(H, F) and v and v.questID == F and v.ok and H.wui.nav == nil)
end

-- F7.7 coordinates strategy: exact RestedXP coordinates, bounded work
do
  local H, R = start("coordinates")
  local patrol, points = patrolFixture(H)
  local F, G = 901, 902
  H.quests[F] = { title = "Feather Work", poi = 42, objectives = { kill(0, 6) } }
  H.quests[G] = { title = "Gem Work", poi = 44, objectives = { kill(0, 6) } }
  local sS = H.newStep(21, { completewith = "Done", sticky = true }, H.header("Kill anything"),
    H.complete(F, 1), H.complete(G, 1))
  local sC1 = H.newStep(22, {}, H.header("Kill Gem Golems"), H.complete(G, 1))
  local sC2 = H.newStep(23, {}, H.header("Kill Harpies"), H.complete(F, 1))
  H.setActiveSteps(patrol, sS, sC1); H.point(points[1]); H.advance(3)
  check("F7.7 setup: coordinates at RestedXP's point", H.mode() == "coordinates" and H.navAt(30))
  local c = counters(R)
  local evaluations, writes = c.evaluations, H.wui.writes
  H.advance(20)
  check("F7.7 idle coordinates: no evaluation or write", counters(R).evaluations == evaluations
    and H.wui.writes == writes)

  points[7].skip = true -- a real but irrelevant change in the arrow's step
  H.advance(3)
  check("F7.7 irrelevant real change: one evaluation, no write", counters(R).evaluations == evaluations + 1
    and H.wui.writes == writes and H.navAt(30))

  H.setActiveSteps(patrol, sS, sC2); H.advance(4)
  local t = R.RXP.GetTarget(); R.Sync.PrepareTarget(t, R.Nav.Decide(t, "coordinates"))
  check("F7.7 activity change: coordinates unchanged, presentation follows, no supertracking",
    H.mode() == "coordinates" and H.navAt(30) and H.wui.nav.flags == "RestedXPWaypoint"
    and H.wui.nav.name == t.label and H.wui.nav.iconTexture == t.iconTexture
    and H.st.setQuestCalls == 0 and H.wui.writes <= writes + 1, H.wui.nav.name)
end

--------------------------------------------------------------------------------
-- F8: the same native quest, a different RestedXP activity area
--------------------------------------------------------------------------------

local Q = 5000
-- One step per activity: objectives, then parent-linked waypoints (dist in yd).
local function areaStep(H, index, objectives, ...)
  local elements, parent = { H.header("Click on the |cRXP_PICK_Crystals|r") }, nil
  for _, obj in ipairs(objectives) do
    parent = H.complete(Q, obj)
    elements[#elements + 1] = parent
  end
  local points = {}
  for i, d in ipairs({ ... }) do
    points[i] = H.goto_(d, 0, { parent = parent })
    elements[#elements + 1] = points[i]
  end
  return H.newStep(index, {}, table.unpack(elements)), points
end

local function areaSetup(strategy)
  local H, R = start(strategy)
  H.quests[Q] = { title = "Windstone Cluster", poi = 40, objectives = { kill(0, 15), kill(0, 3) } }
  local s10, p10 = areaStep(H, 10, { 1, 2 }, 40, 43)
  H.setActiveSteps(s10); H.point(p10[1]); H.advance(3)
  return H, R, p10
end

do
  local H, R, p10 = areaSetup("native-first")
  check("F8 setup: native objective", native(H, Q, "objective") and H.st.setQuestCalls == 1)
  local calls, verified = H.st.setQuestCalls, R.Sync.GetState().lastVerification.time

  -- F8.1 same activity: progress events and a parent-linked point 3 yd away
  for n = 1, 3 do
    H.quests[Q].objectives[1] = kill(n, 15); H.fire("QUEST_LOG_UPDATE"); H.advance(1)
  end
  p10[1].skip = true; H.point(p10[2]); H.advance(2)
  check("F8.1 same quest, same area: no re-verification or supertrack", native(H, Q)
    and counters(R).reverifications == 0 and H.st.setQuestCalls == calls
    and R.Sync.GetState().lastVerification.time == verified)

  -- F8.2/F8.3 objective 2 done, RestedXP moves to a new step for objective 1
  -- nearby: re-verified and kept without re-supertracking.
  H.quests[Q].objectives[2] = kill(3, 3)
  local s11, p11 = areaStep(H, 11, { 1 }, 45)
  H.setActiveSteps(s11); H.point(p11[1]); H.fire("QUEST_LOG_UPDATE"); H.advance(3)
  local v = R.Sync.GetState().lastVerification
  check("F8.2 different objective association is re-verified", counters(R).reverifications == 1
    and v.time > verified and v.ok, counters(R).reverifications)
  check("F8.3 equivalent destination keeps native tracking without a write", native(H, Q, "objective")
    and H.st.setQuestCalls == calls and H.wui.writes == 0)

  -- F8.4 RestedXP leads 190 yd away while Blizzard still points at the old area
  local s12, p12 = areaStep(H, 12, { 1 }, 190)
  H.setActiveSteps(s12); H.point(p12[1]); H.advance(3)
  check("F8.4 substantially different destination: native rejected, RestedXP coordinates used",
    H.mode() == "coordinates" and H.navAt(190) and H.wui.nav.flags == "RestedXPWaypoint" and H.st.quest == nil
    and H.st.setQuestCalls == calls and H.failureText():find("native quest 5000", 1, true) ~= nil, H.failureText())
  local writes = H.wui.writes
  H.fire("QUEST_LOG_UPDATE"); H.advance(5)
  check("F8.4 failed area is not retried for the same activity", H.mode() == "coordinates"
    and H.st.setQuestCalls == calls and H.wui.writes == writes)

  -- A genuinely new activity may use native navigation again.
  H.quests[Q].poi = 60
  local s13, p13 = areaStep(H, 13, { 1 }, 60)
  H.setActiveSteps(s13); H.point(p13[1]); H.advance(3)
  check("F8 new activity after a failure is reconsidered", native(H, Q, "objective")
    and H.st.setQuestCalls == calls + 1)

  -- F8.6 the objective is done; RestedXP routes to the turn-in
  H.quests[Q].objectives = { kill(15, 15), kill(3, 3) }; H.quests[Q].ready = true; H.quests[Q].poi = 62
  local npc = H.goto_(62, 0)
  local s14 = H.newStep(14, {}, npc, H.header("Talk to |cRXP_FRIENDLY_Elatrell|r"), H.turnin(Q, "Windstone Cluster"))
  H.setActiveSteps(s14); H.point(npc); H.fire("QUEST_TURNED_IN"); H.advance(3)
  check("F8.6 turn-in replaces objective navigation", native(H, Q, "turnin")
    and R.Sync.GetState().lastVerification.ok)
end

-- F8.5 #loop circuit: cycling points never re-verifies or re-supertracks
do
  local H, R = start("native-first")
  H.quests[Q] = { title = "Windstone Cluster", poi = 44, objectives = { kill(0, 15) } }
  local points, elements = {}, {}
  for i, d in ipairs({ 40, 44, 48, 52, 56, 60, 64 }) do
    points[i] = i == 1 and H.lowPrioPoint(d, 0) or H.loopPoint(d, 0)
    elements[i] = points[i]
  end
  elements[#elements + 1] = H.header("Click on the Crystals")
  elements[#elements + 1] = H.complete(Q, 1)
  local s = H.newStep(30, { loop = "" }, table.unpack(elements))
  H.setActiveSteps(s); H.point(points[1]); H.advance(3)
  check("F8.5 setup: native loop circuit", native(H, Q))
  for _ = 1, 2 do
    for i = 2, 7 do H.point(points[i]); H.advance(0.6) end
  end
  check("F8.5 patrol cycling: no re-verification or supertrack", native(H, Q)
    and counters(R).reverifications == 0 and H.st.setQuestCalls == 1)
end

-- F8.7 a pending re-verification superseded by a new activity
do
  local H, R = areaSetup("native-first")
  H.quests[Q].objectives[2] = kill(3, 3)
  local s11, p11 = areaStep(H, 11, { 1 }, 45)
  local s12, p12 = areaStep(H, 12, { 1 }, 190)
  H.setActiveSteps(s11); H.point(p11[1])
  local pending = untilPending(H)
  H.setActiveSteps(s12); H.point(p12[1]); H.advance(4)
  check("F8.7 superseded check verifies the newest activity (rejected far area)", pending
    and H.mode() == "coordinates" and H.navAt(190) and H.st.quest == nil and H.st.setQuestCalls == 1)
end

-- F8.8 manual waypoint chosen during re-verification
do
  local H, R = areaSetup("native-first")
  H.quests[Q].objectives[2] = kill(3, 3)
  local s12, p12 = areaStep(H, 12, { 1 }, 190)
  H.setActiveSteps(s12); H.point(p12[1])
  local pending = untilPending(H)
  H.setManualWaypoint("Player pin")
  local marker, at = H.wui.nav, #H.operations
  H.advance(5); H.fire("QUEST_LOG_UPDATE"); H.advance(3)
  check("F8.8 manual pin during the area check: kept, no release, no fallback", pending
    and H.wui.nav == marker and H.st.user and opsAfter(H, at, "bridge") == 0
    and not R.Sync.GetState().pending)
end

-- F8.9 RestedXP's target becomes unusable during re-verification
do
  local H, R = areaSetup("native-first")
  H.quests[Q].objectives[2] = kill(3, 3)
  local s11, p11 = areaStep(H, 11, { 1 }, 45)
  H.setActiveSteps(s11); H.point(p11[1])
  local pending = untilPending(H)
  H.slash("status")
  check("F8.9 status reports the area check, not a transition", R.Sync.GetState().areaCheck == true
    and H.lastChat("re%-checking the native target") ~= nil)
  p11[1].hidden = true
  local at = #H.operations
  H.advance(3)
  check("F8.9 hidden target during the check: native kept, nothing written", pending
    and H.st.quest == Q and H.mode() == "native" and opsAfter(H, at, "bridge") == 0
    and not R.Sync.GetState().pending)
  p11[1].hidden = nil
  H.advance(3)
  local v = R.Sync.GetState().lastVerification
  check("F8.9 target usable again: re-verified, never re-supertracked", native(H, Q)
    and H.st.setQuestCalls == 1 and v.ok and opsAfter(H, at, "bridge") == 0)
end

-- F8.10 coordinates strategy follows RestedXP's exact waypoints
do
  local H = areaSetup("coordinates")
  local ok = H.mode() == "coordinates" and H.navAt(40)
  H.quests[Q].objectives[2] = kill(3, 3)
  for i, d in ipairs({ 45, 190, 60 }) do
    local s, p = areaStep(H, 10 + i, { 1 }, d)
    H.setActiveSteps(s); H.point(p[1]); H.advance(3)
    ok = ok and H.mode() == "coordinates" and H.navAt(d) and H.wui.nav.mapID == 1421
  end
  check("F8.10 coordinates strategy: exact RestedXP waypoints, no supertracking", ok and H.st.setQuestCalls == 0)
end

--------------------------------------------------------------------------------
-- Preview recovery after /reload
--------------------------------------------------------------------------------

local PREVIEW = "RestedXPWaypoint-Preview"
local OWN_ICON = "Interface\\AddOns\\RestedXPWaypoint\\Art\\Icons\\FlightMaster"
local function previewSession(tracked)
  return { name = "Preview: Flight master", flags = PREVIEW, x = 0.5, y = 0.492, iconTexture = OWN_ICON,
           r = 0x70 / 255, g = 0xD6 / 255, b = 0x5A / 255, stripCoordinates = true }, tracked
end
local function rxpTarget(H)
  local g = H.goto_(40, 0, { text = "Run to the bridge" })
  H.setActiveSteps(H.newStep(1, {}, g)); H.point(g)
end
local function clearsOf(H, flag)
  local n = 0
  for _, op in ipairs(H.operations) do if op.kind == "clear" and op.value == flag then n = n + 1 end end
  return n
end

-- P1/P8 normal preview entry and exit, then sync resumes
do
  local H = start("coordinates")
  rxpTarget(H); H.advance(2)
  H.slash("preview flightmaster")
  local entered = H.wui.nav.flags == PREVIEW and not H.RXPW.Sync.GetState().running
  H.slash("preview off"); H.advance(2)
  check("P1 preview entry and exit", entered and H.lastChat("automatic sync resumed") ~= nil)
  check("P8 automatic sync resumes at RestedXP's destination", H.navAt(40)
    and H.wui.nav.flags == "RestedXPWaypoint" and H.RXPW.Sync.GetState().running)
end

-- P2 preview restored after /reload with lost session state, sync on
for _, tracked in ipairs({ false, true }) do
  local H = fresh()
  H.restoreSession(previewSession(tracked))
  rxpTarget(H)
  local R = H.load(ADDON_ROOT, { strategy = "coordinates", debug = true })
  H.advance(3)
  check("P2 restored preview (" .. (tracked and "tracked" or "not tracked") .. ") removed, sync resumes",
    clearsOf(H, PREVIEW) == 1 and H.navAt(40) and H.wui.nav.flags == "RestedXPWaypoint"
    and H.lastChat("leftover preview marker") ~= nil and counters(R).orphanedPreviews == 1
    and R.Sync.GetState().external == nil)
end

-- P3 /rxpw preview off removes a confirmed orphan while automatic sync is off
do
  local H = fresh()
  H.restoreSession(previewSession(true))
  rxpTarget(H)
  H.load(ADDON_ROOT, { strategy = "coordinates", autoSync = false, debug = true })
  H.advance(2)
  local kept = H.wui.nav and H.wui.nav.flags == PREVIEW
  H.slash("preview off"); H.advance(1)
  check("P3 preview off removes the orphaned preview marker", kept and H.wui.nav == nil
    and clearsOf(H, PREVIEW) == 1 and H.lastChat("leftover preview marker") ~= nil
    and not H.RXPW.Sync.GetState().running)
end

-- P4/P5 manual and other-addon navigation are never treated as a preview
for _, case in ipairs({ { name = "Player pin", flags = nil, label = "P4 manual waypoint" },
                        { name = "Quest helper", flags = "SomeOtherAddon", label = "P5 another addon's navigation" } }) do
  for _, auto in ipairs({ true, false }) do
    local H = fresh()
    H.restoreSession({ name = case.name, flags = case.flags }, true)
    rxpTarget(H)
    local R = H.load(ADDON_ROOT, { strategy = "coordinates", autoSync = auto, debug = true })
    H.advance(2)
    local marker = H.wui.nav
    H.slash("preview off"); H.advance(2)
    check(case.label .. " untouched (auto sync " .. tostring(auto) .. ")", H.wui.nav == marker
      and H.wui.nav.name == case.name and H.wui.clears == 0 and H.wui.writes == 0
      and H.lastChat("No preview is shown") ~= nil and (counters(R).orphanedPreviews or 0) == 0)
  end
end

-- P6 native quest tracking survives orphan removal and preview off
do
  local H = fresh()
  H.restoreSession(previewSession(false))
  H.st.quest = 4242 -- the player tracks a quest natively; the preview pin is not supertracked
  H.quests[4242] = { title = "Tracked", poi = 80 }
  rxpTarget(H)
  H.load(ADDON_ROOT, { strategy = "coordinates", autoSync = false, debug = true })
  H.slash("preview off"); H.advance(2)
  check("P6 orphan removed, native quest tracking kept", H.wui.nav == nil and H.st.quest == 4242
    and H.st.releaseCalls == nil)
  H.slash("preview off"); H.advance(1)
  check("P6 preview off with only a native quest: nothing cleared", H.st.quest == 4242 and H.wui.clears == 1
    and H.lastChat("No preview is shown") ~= nil)
end

-- P7 preview starting while a native transition is pending
do
  local H = start("coordinates")
  H.quests[101] = { title = "Current quest", ready = true, poi = 40 }
  local g = H.goto_(40, 0)
  H.setActiveSteps(H.newStep(1, {}, g, H.turnin(101, "Current quest"))); H.point(g); H.advance(2)
  H.slash("mode native-first")
  local pending = H.RXPW.Sync.GetState().pending
  H.slash("preview flightmaster")
  local at = #H.operations
  H.advance(3)
  check("P7 preview supersedes a pending transition", pending and H.wui.nav.flags == PREVIEW
    and opsAfter(H, at, "bridge") == 0 and H.st.quest == nil and not H.RXPW.Sync.GetState().pending)
  H.slash("preview off"); H.advance(3)
  check("P7 after preview off the transition is decided again", native(H, 101, "turnin"))
end

-- P9 no preview: no extra writes or clears
do
  local H = fresh()
  rxpTarget(H)
  local R = H.load(ADDON_ROOT, { strategy = "coordinates", debug = true })
  H.advance(3)
  local writes = H.wui.writes
  H.slash("preview off"); H.advance(3)
  check("P9 no preview: one normal write, no clear", writes == 1 and H.wui.writes == 1 and H.wui.clears == 0
    and (counters(R).orphanedPreviews or 0) == 0 and H.lastChat("No preview is shown") ~= nil)
end

--------------------------------------------------------------------------------
-- Same-destination presentation updates (Waypoint UI rename side effects)
--------------------------------------------------------------------------------

local W = 98100
local function progressSetup(pathfinding)
  local H, R = start("coordinates")
  H.wui.pathfinding = pathfinding
  H.quests[W] = { title = "Windstone Cluster", poi = 40, objectives = { kill(1, 15) } }
  local obj = H.complete(W, 1, { text = "1/15 Windstone Cluster" })
  local g = H.goto_(40, 0)
  H.setActiveSteps(H.newStep(1, {}, g, obj)); H.point(g); H.advance(4)
  return H, R, obj
end
local function shown(H, label) return H.navAt(40) and H.wui.nav.name == label and H.wui.nav.flags == "RestedXPWaypoint" end

for _, pathfinding in ipairs({ false, true }) do
  local tag = pathfinding and "pathfinding on" or "pathfinding off"
  local H, R, obj = progressSetup(pathfinding)
  check("T setup (" .. tag .. ")", shown(H, "1/15 Windstone Cluster") and H.RXPW.Sync.GetState().bridgeActive)

  local writes, builds = H.wui.writes, H.wui.pathBuilds
  obj.text = "2/15 Windstone Cluster"; H.fire("QUEST_LOG_UPDATE"); H.advance(2)
  check("T1 label change at unchanged coordinates (" .. tag .. ")", shown(H, obj.text)
    and H.wui.writes == writes + 1 and H.wui.pathBuilds == builds + (pathfinding and 1 or 0))

  writes = H.wui.writes
  for _ = 1, 10 do H.fire("QUEST_LOG_UPDATE"); H.advance(0.3) end
  H.advance(3)
  check("T2 repeated identical progress events: no write (" .. tag .. ")", H.wui.writes == writes)

  writes, builds = H.wui.writes, H.wui.pathBuilds
  local resets = H.wui.markerResets
  for n = 3, 9 do obj.text = n .. "/15 Windstone Cluster"; H.fire("QUEST_LOG_UPDATE"); H.advance(0.6) end
  local burst = H.wui.writes - writes
  H.advance(3)
  check("T3 rapid progress: bounded renames (" .. tag .. ")", burst <= 3 and H.wui.writes - writes <= 4,
    H.wui.writes - writes)
  check("T7 no stale presentation after coalescing (" .. tag .. ")", shown(H, "9/15 Windstone Cluster")
    and H.wui.markerResets - resets == H.wui.writes - writes
    and H.wui.pathBuilds - builds == (pathfinding and H.wui.writes - writes or 0))

  H.quests[W].ready = true; H.quests[W].objectives[1] = kill(15, 15)
  writes = H.wui.writes
  H.fire("QUEST_LOG_UPDATE"); H.advance(3)
  check("T4 icon-only change at unchanged coordinates (" .. tag .. ")", H.navAt(40) and H.wui.writes == writes + 1
    and H.wui.nav.iconTexture == "Interface\\AddOns\\RestedXPWaypoint\\Art\\Icons\\QuestComplete")

  H.wui.rejects = 1; obj.text = "Turn in soon"; H.fire("QUEST_LOG_UPDATE"); H.advance(3)
  local rejected = H.wui.nav.name ~= obj.text
  H.advance(8)
  check("T5 rejected rename recovers later (" .. tag .. ")", rejected and shown(H, obj.text))

  H.setManualWaypoint("Player pin")
  local marker = H.wui.nav
  writes = H.wui.writes
  obj.text = "Something new"; H.fire("QUEST_LOG_UPDATE"); H.advance(8)
  check("T8 manual pin protected from presentation updates (" .. tag .. ")", H.wui.nav == marker
    and H.wui.writes == writes)
end

print(string.format("%d passed, %d failed", passes, fails))
if fails > 0 then error(fails .. " test(s) failed", 0) end
