-- Offline integration tests for the native-first strategy (run with: node tests/run.js).
-- Step structures mirror the installed Forever guides (Horde-01-14_Undead.lua,
-- RestedXP-Skyborne.lua). Mocked APIs; not proof of in-game behaviour.
local H = dofile(ADDON_ROOT .. "/tests/harness.lua")
H.verbose = true
local check, advance, point, newStep, goto_ = H.check, H.advance, H.point, H.newStep, H.goto_
local quests, st, wui = H.quests, H.st, H.wui

local function kill(numFulfilled, numRequired) return { type = "monster", finished = false, numFulfilled = numFulfilled, numRequired = numRequired } end
local function item(numFulfilled, numRequired) return { type = "item", finished = false, numFulfilled = numFulfilled, numRequired = numRequired } end
local function object(numFulfilled, numRequired) return { type = "object", finished = false, numFulfilled = numFulfilled, numRequired = numRequired } end

-- A previously saved strategy is preserved (nobody is switched to native-first).
local RXPW = H.load(ADDON_ROOT, { debug = true, strategy = "hybrid" })
local slash = H.slash
check("saved strategy preserved on load", RXPW.db.strategy == "hybrid")

----------------------------------------------------------------------------
-- Zombies: #loop step, lowPrio + radius patrol points, two objectives of one quest
--   #loop / .goto ...,0 / .goto ...,40,0 x3 / >>Kill Zombies / .complete 364,1 / .mob / .complete 364,2 / .mob
quests[364] = { title = "The Mindless Ones", ready = false, poi = 60, objectives = { kill(2, 8), kill(0, 8) } }
local z0, z1, z2, z3 = H.lowPrioPoint(55, 0), H.loopPoint(60, 0), H.loopPoint(62, 5), H.loopPoint(58, -5)
local stepZ = newStep(10, { loop = "" }, z0, z1, z2, z3, H.header("Kill |cRXP_ENEMY_Mindless Zombies|r and |cRXP_ENEMY_Wretched Zombies|r"),
  H.complete(364, 1), H.mob("+Mindless Zombie"), H.complete(364, 2), H.mob("+Wretched Zombie"))
point(z1); advance(1)
check("hybrid keeps a kill objective on coordinates (v0.4 behaviour)", H.mode() == "coordinates" and H.navAt(60) and st.setQuestCalls == 0)

slash("mode native-first")
check("strategy saved", RXPWDB.strategy == "native-first")
advance(1.5)
local m, q, kind = H.mode()
check("native-first: loop kill objective goes native", m == "native" and q == 364 and kind == "objective", m)
check("decision logged as kill objective", H.lastChat("quest objective detected: kill quest 364") ~= nil)
check("verification values logged", H.lastChat("Native target check: native 60.0 yd, RestedXP 60.0 yd") ~= nil)

-- RestedXP cycles the loop: no re-supertracking, no writes
local calls, writes = st.setQuestCalls, wui.writes
point(z2); advance(1); point(z3); advance(1); point(z0); advance(1)
check("cycling #loop points does not re-supertrack", st.setQuestCalls == calls and wui.writes == writes)

-- Kills: progress events update Waypoint UI natively, the bridge writes nothing
for i = 3, 7 do quests[364].objectives[1].numFulfilled = i; H.fire("QUEST_LOG_UPDATE"); advance(0.7) end
check("kill progress causes no navigation writes", st.setQuestCalls == calls and wui.writes == writes)
check("objective progress logged as an update", H.lastChat("Native objective updated: quest 364 %- obj 1 7/8, obj 2 0/8") ~= nil)

-- Objective 1 done (RestedXP marks the element complete); objective 2 remains
quests[364].objectives[1] = { type = "monster", finished = true, numFulfilled = 8, numRequired = 8 }
stepZ.elements[6].completed = true
H.fire("QUEST_LOG_UPDATE"); advance(1)
check("finishing one objective keeps native tracking", H.mode() == "native" and st.setQuestCalls == calls)

----------------------------------------------------------------------------
-- Quest complete -> RestedXP moves to a travel route (#completewith next chain, ".goto ...,2 >> Enter the crypt")
quests[364].objectives[2] = { type = "monster", finished = true, numFulfilled = 8, numRequired = 8 }
quests[364].ready = true
stepZ.elements[8].completed = true
local r1, r2 = goto_(20, 0, { radius = 8, hidePin = true }), goto_(25, 0, { radius = 8, hidePin = true })
local r3 = goto_(30, 0, { radius = 2, text = "Enter the crypt" })
newStep(11, {}, r1, r2, r3)
point(r1); advance(1)
check("native objective -> coordinates when the travel route starts", H.mode() == "coordinates" and H.navAt(20))
check("transition native -> coordinates recorded", H.transitionText() == "native quest 364 -> coordinates", H.transitionText())
r1.skip = true; point(r2); advance(1)
check("intermediate route point stays coordinates", H.mode() == "coordinates" and H.navAt(25))
r2.skip = true; point(r3); advance(1)
check("waypoint with its own travel text stays coordinates", H.mode() == "coordinates" and H.navAt(30)
  and H.lastChat("explicit travel instruction") ~= nil)

-- Turn-in step: .goto / >>Talk to / .turnin 364 -> native turn-in
quests[364].poi = 42
local t1 = goto_(40, 0); newStep(12, {}, t1, H.header("Talk to |cRXP_FRIENDLY_Executor Arren::1570|r"), H.turnin(364, "The Mindless Ones"), { tag = "target", textOnly = true })
point(t1); advance(2)
m, q, kind = H.mode()
check("coordinates -> native turn-in", m == "native" and q == 364 and kind == "turnin", m)
check("turn-in uses the turn-in tolerance", H.lastChat("limit 50 yd") ~= nil)

----------------------------------------------------------------------------
-- Windstone Clusters: "#completewith next / .goto 2521,43.53,23.83,7,0 / >>Click on the Crystals / .complete 93552,1"
quests[93552] = { title = "Harvesting Windstones", ready = false, poi = 52, objectives = { object(9, 15) } }
local w1 = goto_(50, 0, { radius = 7, hidePin = true })
newStep(20, { completewith = "next" }, w1, H.header("|TInterface/cursor/crosshair/interact.blp:20|tClick on the |cRXP_PICK_Crystals|r"), H.complete(93552, 1))
point(w1); advance(2)
m, q, kind = H.mode()
check("Windstone: radius objective waypoint goes native", m == "native" and q == 93552 and kind == "objective", m)
check("Windstone classified as interact", H.lastChat("quest objective detected: interact quest 93552") ~= nil)
local hybridView = RXPW.Nav.Decide(RXPW.RXP.GetTarget(), "hybrid")
check("hybrid analysis still rejects the radius waypoint", hybridView.mode == "coordinates" and hybridView.reason:find("pass%-through") ~= nil, hybridView.reason)
-- arriving inside the 7 yd radius marks the waypoint reached; navigation is kept
calls, writes = st.setQuestCalls, wui.writes
w1.skip = true; advance(1)
quests[93552].objectives[1].numFulfilled = 10; H.fire("QUEST_LOG_UPDATE"); advance(1)
check("reached objective waypoint keeps native tracking, no writes", H.mode() == "native" and st.setQuestCalls == calls and wui.writes == writes)

----------------------------------------------------------------------------
-- Route then objective in ONE step (no #loop): road, turn, cave mouth, kill
quests[800] = { title = "Cave Dwellers", ready = false, poi = 72, objectives = { kill(0, 6) } }
local c1, c2 = goto_(60, 0, { radius = 20, hidePin = true }), goto_(65, 0, { radius = 15, hidePin = true })
local c3 = goto_(70, 0)
newStep(30, {}, c1, c2, c3, H.header("Kill |cRXP_ENEMY_Cave Dwellers|r"), H.complete(800, 1), H.mob("Cave Dweller"))
calls = st.setQuestCalls
point(c1); advance(2)
check("road waypoint before the objective stays coordinates", H.mode() == "coordinates" and H.navAt(60) and st.setQuestCalls == calls)
check("reason: intermediate route waypoint", H.lastChat("intermediate route waypoint") ~= nil)
c1.skip = true; point(c2); advance(2)
check("turn waypoint stays coordinates", H.mode() == "coordinates" and H.navAt(65) and st.setQuestCalls == calls)
c2.skip = true; point(c3); advance(2)
check("objective waypoint goes native only at the end of the route", H.mode() == "native" and select(2, H.mode()) == 800)

----------------------------------------------------------------------------
-- Ambiguous and unsupported blocks stay on coordinates
quests[376] = { title = "Paws", ready = false, poi = 80, objectives = { item(1, 6) } }
quests[377] = { title = "Wings", ready = false, poi = 80, objectives = { item(1, 6) } }
local a1 = goto_(80, 0)
newStep(40, {}, a1, H.header("Kill Scavengers and Duskbats"), H.complete(376, 1), H.complete(377, 1))
point(a1); advance(2)
check("two quests in one block -> coordinates", H.mode() == "coordinates" and H.lastChat("multiple candidate quests %(376, 377%)") ~= nil)

quests[500] = { title = "Split Objectives", ready = false, poi = 82, objectives = { kill(0, 5), item(0, 3) } }
local a2 = goto_(82, 0)
newStep(41, {}, a2, H.complete(500, 1))
point(a2); advance(2)
check("quest with another unfinished objective elsewhere -> coordinates", H.mode() == "coordinates"
  and H.lastChat("another unfinished objective %(2%)") ~= nil)

local a3 = goto_(84, 0)
quests[501] = { title = "Mixed", ready = false, poi = 84, objectives = { kill(0, 5) } }
newStep(42, {}, a3, H.complete(501, 1), H.plusObjective("|cRXP_WARN_Loot 60 copper of vendor items|r"))
point(a3); advance(2)
check("block with a non-quest instruction -> coordinates", H.mode() == "coordinates" and H.lastChat("non%-quest instruction") ~= nil)

local a4 = goto_(86, 0)
newStep(43, {}, a4, H.accept(502, "Later"), H.complete(501, 1))
point(a4); advance(2)
check("first pending instruction is an accept -> coordinates", H.mode() == "coordinates" and H.lastChat("next instruction is %.accept") ~= nil)

local a5 = goto_(88, 0)
newStep(44, {}, a5, H.complete(503, 1))
point(a5); advance(2)
check("quest not in log -> coordinates", H.mode() == "coordinates" and H.lastChat("quest 503 is not in the quest log") ~= nil)

quests[504] = { title = "Done Already", ready = true, poi = 90, objectives = { { type = "monster", finished = true, numFulfilled = 5, numRequired = 5 } } }
local a6 = goto_(90, 0)
newStep(45, {}, a6, H.complete(504, 1))
point(a6); advance(2)
check("quest already complete while RestedXP lags -> coordinates", H.mode() == "coordinates" and H.lastChat("already complete") ~= nil)

H.noObjectivesAPI = true
quests[505] = { title = "No API", ready = false, poi = 92, objectives = { kill(0, 5) } }
local a7 = goto_(92, 0)
newStep(46, {}, a7, H.complete(505, 1))
point(a7); advance(2)
check("objectives API unavailable -> coordinates", H.mode() == "coordinates" and H.lastChat("objectives are unavailable") ~= nil)
H.noObjectivesAPI = false

----------------------------------------------------------------------------
-- Gotos placed AFTER the objectives (parent-linked): the block above them counts
quests[600] = { title = "Boars", ready = false, poi = 100, objectives = { kill(0, 8), item(0, 4) } }
local o1, o2 = H.complete(600, 1), H.complete(600, 2)
local p1 = goto_(100, 0, { radius = 30, hidePin = true, parent = o2 })
local p2 = goto_(105, 0, { radius = 30, hidePin = true, parent = o2 })
newStep(50, {}, H.header("Kill boars and loot tusks"), o1, H.mob("Boar"), o2, p1, p2)
point(p1); advance(2)
check("parent-linked objective waypoint goes native", H.mode() == "native" and select(2, H.mode()) == 600)
calls = st.setQuestCalls
point(p2); advance(1)
check("next parent-linked point keeps the same native quest", st.setQuestCalls == calls
    and H.mode() == "native" and select(2, H.mode()) == 600 and st.quest == 600 and not st.user)
check("parent-linked continuation creates no coordinate navigation", H.wui.nav == nil)

----------------------------------------------------------------------------
-- Verification failures fall back and are not retried
quests[700] = { title = "No Marker", ready = false, poi = nil, objectives = { kill(0, 5) } }
local v1 = goto_(110, 0); newStep(60, {}, v1, H.complete(700, 1))
point(v1); advance(2)
check("no native target -> coordinate fallback", H.mode() == "coordinates" and H.navAt(110) and H.failureText():find("no native navigation target") ~= nil)
calls = st.setQuestCalls
for i = 1, 4 do H.fire("QUEST_LOG_UPDATE"); advance(1) end
check("failed objective is not retried on quest events", st.setQuestCalls == calls)

-- Objective tolerance (100 yd) accepts an area marker 80 yd off; turn-in tolerance (50 yd) would not
quests[701] = { title = "Wide Area", ready = false, poi = 200, objectives = { kill(0, 5) } }
local v2 = goto_(120, 0); newStep(61, {}, v2, H.complete(701, 1))
point(v2); advance(2)
check("objective area marker within 100 yd is accepted", H.mode() == "native" and select(2, H.mode()) == 701)
quests[702] = { title = "Far Turn-in", ready = true, poi = 210 }
local v3 = goto_(130, 0); newStep(62, {}, v3, H.turnin(702, "Far Turn-in"))
point(v3); advance(2)
check("turn-in 80 yd off is rejected", H.mode() == "coordinates" and H.failureText():find("limit 50") ~= nil, H.failureText())
quests[703] = { title = "Other Region", ready = false, poi = 400, objectives = { kill(0, 5) } }
local v4 = goto_(140, 0); newStep(63, {}, v4, H.complete(703, 1))
point(v4); advance(2)
check("objective marker far away is rejected", H.mode() == "coordinates" and H.failureText():find("limit 100") ~= nil, H.failureText())

----------------------------------------------------------------------------
-- Same coordinates: native objective -> native turn-in at one NPC (kill, then turn in here)
quests[750] = { title = "Here And Now", ready = false, poi = 150, objectives = { kill(0, 3) } }
local s1 = goto_(150, 0); local o750 = H.complete(750, 1)
newStep(70, {}, s1, o750, H.turnin(750, "Here And Now"))
point(s1); advance(2)
check("objective first", H.mode() == "native" and select(3, H.mode()) == "objective")
calls = st.setQuestCalls
quests[750].objectives[1] = { type = "monster", finished = true, numFulfilled = 3, numRequired = 3 }; quests[750].ready = true
o750.completed = true
H.fire("QUEST_LOG_UPDATE"); advance(2)
m, q, kind = H.mode()
-- The same already-active native quest is now adopted and verified, so the
-- kind changes without an unnecessary SetSuperTrackedQuestID call.
check("same coordinates: objective -> turn-in for the same quest", m == "native" and q == 750 and kind == "turnin" and st.setQuestCalls == calls)
check("transition recorded", H.transitionText() == "native quest 750 -> native quest 750", H.transitionText())

----------------------------------------------------------------------------
-- Manual waypoint while a native objective is active
quests[900] = { title = "Patrol", ready = false, poi = 160, objectives = { kill(0, 10) } }
local l0, l1, l2 = H.lowPrioPoint(158, 0), H.loopPoint(160, 0), H.loopPoint(162, 4)
newStep(80, { loop = "" }, l0, l1, l2, H.complete(900, 1))
point(l1); advance(2)
check("patrol objective native", H.mode() == "native" and select(2, H.mode()) == 900)
H.setManualWaypoint("Repair Vendor"); advance(2)
calls, writes = st.setQuestCalls, wui.writes
point(l2); advance(1)
quests[900].objectives[1].numFulfilled = 4; H.fire("QUEST_LOG_UPDATE"); advance(1)
check("manual waypoint respected while RestedXP cycles the same objective", wui.nav.name == "Repair Vendor" and st.setQuestCalls == calls and wui.writes == writes)
check("outside change recorded", (RXPW.Sync.GetState().external or ""):find("another waypoint") ~= nil, RXPW.Sync.GetState().external)
local n1 = goto_(170, 0, { text = "Run to the bridge" }); newStep(81, {}, n1)
point(n1); advance(2)
check("new RestedXP destination keeps the active manual waypoint", wui.nav.name == "Repair Vendor")
WaypointUIAPI.Navigation.ClearUserNavigation(); advance(2)
check("bridge resumes at RestedXP's next destination", wui.nav.flags == "RestedXPWaypoint" and H.navAt(170))

----------------------------------------------------------------------------
-- Stale callbacks from an interrupted native transition
quests[950] = { title = "Interrupted", ready = false, poi = 180, objectives = { kill(0, 3) } }
local i1 = goto_(180, 0); newStep(90, {}, i1, H.complete(950, 1))
point(i1); advance(0.5)
local midPending = RXPW.Sync.GetState().pending
local i2 = goto_(185, 0, { text = "Leave the area" }); newStep(91, {}, i2)
point(i2); advance(2)
check("transition was in progress", midPending == true)
check("interrupted transition ends on coordinates with no stale quest", H.mode() == "coordinates" and H.navAt(185) and st.quest ~= 950)

----------------------------------------------------------------------------
-- Strategy switching re-evaluates immediately, in every direction
quests[960] = { title = "Switch", ready = false, poi = 190, objectives = { kill(0, 3) } }
local x1 = goto_(190, 0); newStep(95, {}, x1, H.complete(960, 1))
point(x1); advance(2)
check("native-first native before switching", H.mode() == "native")
slash("mode coordinates")
check("coordinates restores RestedXP's coordinates at once", H.mode() == "coordinates" and H.navAt(190) and st.quest == nil)
slash("mode hybrid")
check("hybrid keeps the objective on coordinates", H.mode() == "coordinates")
slash("mode native-first"); advance(2)
check("native-first goes native again", H.mode() == "native" and select(2, H.mode()) == 960)
check("strategy persisted", RXPWDB.strategy == "native-first")

-- No repeated writes when nothing changes
calls, writes = st.setQuestCalls, wui.writes
for i = 1, 6 do H.fire("QUEST_LOG_UPDATE"); H.fire("QUEST_ACCEPTED"); advance(0.3) end
advance(2)
check("repeated quest events with no change cause no API calls", st.setQuestCalls == calls and wui.writes == writes)

-- Status prints without errors
local before = #H.chat
slash("status")
local okStatus = true
for i = before + 1, #H.chat do if H.chat[i]:find("Internal error") then okStatus = false end end
check("status command runs", okStatus and H.lastChat("Native eligible %(native%-first analysis%)") ~= nil)

H.finish()
