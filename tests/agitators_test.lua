-- Regression tests for v0.5.1: native-first on RestedXP patrol steps.
-- Fixtures follow the installed Forever guide RestedXP-Skyborne.lua
-- (Alliance/!Shaman path around "Agitators", quest 92465). Mocked APIs; not
-- proof of in-game behaviour. Run with: node tests/run.js
local H = dofile(ADDON_ROOT .. "/tests/harness.lua")
H.verbose = true
local check, advance, point, newStep, goto_ = H.check, H.advance, H.point, H.newStep, H.goto_
local quests, st, wui = H.quests, H.st, H.wui

local function kill(n, r) return { type = "monster", finished = false, numFulfilled = n, numRequired = r } end
local function object(n, r) return { type = "object", finished = false, numFulfilled = n, numRequired = r } end
local function done(t, r) return { type = t, finished = true, numFulfilled = r, numRequired = r } end
local function patrolPoint(dist, radius) return goto_(dist, 0, { radius = radius, hidePin = true }) end

local ns = H.load(ADDON_ROOT, { debug = true, strategy = "native-first" })
local slash = H.slash

----------------------------------------------------------------------------
-- RestedXP-Skyborne.lua, Alliance/!Shaman:
--   step #hidewindow / #completewith Windstone Cluster / #loop
--        .goto 2521,46.85,17.68,30,0 ... (10 points, radius 30-50, optional) / +1
--   step #completewith next / >>Click on the Crystals / *warn / *warn / .complete 93552,1
--   step >>Kill Al'Aketh Convert and Roiling Winds. / *Prioritize Roiling Winds
--        .complete 92465,1 / .mob / .complete 92465,2 / .mob
local radii = { 30, 30, 50, 35, 35, 40, 30, 40, 30, 30 }
local patrol = {}
for i, r in ipairs(radii) do patrol[i] = patrolPoint(40 + i, r) end
local patrolElements = {}
for i, p in ipairs(patrol) do patrolElements[i] = p end
patrolElements[#patrolElements + 1] = H.placeholder()
local stepPatrol = newStep(27, { hidewindow = "", completewith = "Windstone Cluster", sticky = true, loop = "" },
  table.unpack(patrolElements))

local windstoneObjective = H.complete(93552, 1)
local stepWindstone = newStep(28, { completewith = "next", sticky = true },
  H.header("|TInterface/cursor/crosshair/interact.blp:20|tClick on the |cRXP_PICK_Crystals|r"),
  H.star("|cRXP_WARN_Expect to break about 10 stones, but you may need up to 15|r."),
  H.star("|cRXP_WARN_If the area is abnormally crowded, camp one spawn point or rotate between nearby stones|r."),
  windstoneObjective)

local agitators1, agitators2 = H.complete(92465, 1), H.complete(92465, 2)
local stepAgitators = newStep(29, {},
  H.header("Kill |cRXP_ENEMY_Al'Aketh Convert::251160|r and |cRXP_ENEMY_Roiling Winds::251143|r."),
  H.star("|cRXP_WARN_Prioritize |cRXP_ENEMY_Roiling Winds::251143|r|r"),
  agitators1, H.mob("+Al'Aketh Convert::251160"), agitators2, H.mob("+Roiling Winds::251143"))

quests[92465] = { title = "Agitators", ready = false, poi = 45, objectives = { kill(3, 7), kill(3, 6) } }
quests[93552] = { title = "Harvesting Windstones", ready = false, poi = 46, objectives = { object(9, 15) } }

-- Test D (v0.5.3): Windstone still running alongside Agitators -> both quests are
-- relevant to the shared patrol; Agitators wins (its step says "Prioritize ...").
H.setActiveSteps(stepPatrol, stepWindstone, stepAgitators)
point(patrol[3]); advance(1.5)
check("D: shared patrol with two quests selects one instead of falling back", H.mode() == "native" and select(2, H.mode()) == 92465)
check("D: both candidates are listed",
  H.lastChat("Candidate 92465 %(Agitators%) obj 1 3/7, obj 2 3/6 %- eligible %[selected%]") ~= nil
  and H.lastChat("Candidate 93552 %(Harvesting Windstones%) obj 1 9/15 %- eligible") ~= nil)
check("D: selection reason is RestedXP's explicit priority",
  H.lastChat("selected quest 92465: explicit RestedXP priority %(\"Prioritize Roiling Winds\"%)") ~= nil)
check("label for the patrol waypoint is not the \"+1\" placeholder", ns.RXP.GetTarget().label ~= "1", ns.RXP.GetTarget().label)
check("hybrid still sees an intermediate route point here",
  ns.Nav.Decide(ns.RXP.GetTarget(), "hybrid").reason:find("pass%-through") ~= nil)

-- Test E: Windstone objective finished but its sticky step not yet dropped (RestedXP lag) -> ignored
windstoneObjective.completed = true
quests[93552].objectives[1] = done("object", 15); quests[93552].ready = true
H.fire("QUEST_LOG_UPDATE"); advance(1.5)
local m, q, kind = H.mode()
check("E/A: completed Windstone ignored, Agitators stays native (no switch)", m == "native" and q == 92465 and kind == "objective", m)
check("A: classified as a kill objective with both objectives targeted",
  H.lastChat("quest objective detected: kill quest 92465 %(Agitators%) %- obj 1 3/7, obj 2 3/6") ~= nil)
check("A: decision reason shows the patrol association",
  H.lastChat("patrol step 27 serving step%(s%) 28, 29") ~= nil)
check("B: descriptive headings (>>Kill, *Prioritize) did not block the objectives", H.lastChat("next instruction is text") == nil)

-- RestedXP drops the finished sticky step
H.setActiveSteps(stepPatrol, stepAgitators)
local calls, writes = st.setQuestCalls, wui.writes
H.fire("QUEST_LOG_UPDATE"); advance(1.5)
check("dropping the finished sticky step changes nothing", H.mode() == "native" and st.setQuestCalls == calls and wui.writes == writes)

-- Progress + patrol cycling: no writes, no re-supertracking
for i = 4, 6 do quests[92465].objectives[1].numFulfilled = i; H.fire("QUEST_LOG_UPDATE"); advance(0.7) end
point(patrol[4]); advance(1); point(patrol[5]); advance(1)
check("G: kills and patrol cycling cause no navigation writes", st.setQuestCalls == calls and wui.writes == writes)

-- Objective 2 finished first (RestedXP marks it complete): objective 1 still targeted, still native
quests[92465].objectives[2] = done("monster", 6); agitators2.completed = true
H.fire("QUEST_LOG_UPDATE"); advance(1.5)
check("E: a finished objective does not change the selected quest", H.mode() == "native" and st.setQuestCalls == calls)

-- Quest complete -> RestedXP moves to the turn-in step (own .goto) -> native turn-in
quests[92465].objectives[1] = done("monster", 7); quests[92465].ready = true; agitators1.completed = true
local yala = goto_(60, 0)
local stepTurnIn = newStep(31, {}, yala, H.header("|Tinterface/worldmap/chatbubble_64grey.blp:20|tTalk to |cRXP_FRIENDLY_Yala Windwatcher::249363|r."),
  H.turnin(92465, "Agitators"), H.accept(92469, "Return to Rorian"), { tag = "target", textOnly = true })
quests[92465].poi = 61
H.setActiveSteps(stepTurnIn)
point(yala); advance(2)
m, q, kind = H.mode()
check("objective -> turn-in for Agitators", m == "native" and q == 92465 and kind == "turnin", m)

----------------------------------------------------------------------------
-- Test B (own step): goto + two descriptive headings + two objectives of one quest
quests[92470] = { title = "Headings", ready = false, poi = 70, objectives = { kill(0, 5), kill(0, 5) } }
local own = goto_(70, 0)
local stepOwn = newStep(40, {}, own, H.header("Kill |cRXP_ENEMY_A|r and |cRXP_ENEMY_B|r."), H.star("|cRXP_WARN_Prioritize |cRXP_ENEMY_B|r|r"),
  H.complete(92470, 1), H.mob("A"), H.complete(92470, 2), H.mob("B"))
H.setActiveSteps(stepOwn)
point(own); advance(2)
check("B: headings before objectives in the waypoint's own step -> native", H.mode() == "native" and select(2, H.mode()) == 92470)

----------------------------------------------------------------------------
-- Test C: genuine travel keeps coordinates
-- Alliance "#label UseRacialAbility": .goto ...,30,0 / .goto ...,30,0 / .goto 46.41,18.21 / >>Use [Read Ley Line] / *warn / .complete 92597,1 / .usespell
quests[92597] = { title = "Reading the Ley Lines", ready = false, poi = 84, objectives = { { type = "event", finished = false } } }
local u1, u2, u3 = goto_(80, 0, { radius = 30, hidePin = true }), goto_(82, 0, { radius = 30, hidePin = true }), goto_(84, 0)
local stepRift = newStep(30, {}, u1, u2, u3, H.header("Use |T236219:0|t[Read Ley Line] near the |cRXP_WARN_Blue Rift|r on the ground"),
  H.star("|cRXP_WARN_Found throughout the zone|r"), H.complete(92597, 1), H.usespell(1259705))
H.setActiveSteps(stepRift)
calls = st.setQuestCalls
point(u1); advance(2)
check("C: route point before the rift stays coordinates", H.mode() == "coordinates" and H.navAt(80) and st.setQuestCalls == calls
  and H.lastChat("intermediate route waypoint") ~= nil)
u1.skip = true; point(u2); advance(2)
check("C: second route point stays coordinates", H.mode() == "coordinates" and H.navAt(82))
u2.skip = true; point(u3); advance(2)
check("C: objective with a non-quest action (.usespell) stays coordinates", H.mode() == "coordinates"
  and H.lastChat("non%-quest instruction %(%.usespell%)") ~= nil)

-- A real "+text" instruction is never treated as a placeholder (Undead guide "#completewith Vendor" grind step)
local g1, g2 = goto_(90, 0, { radius = 40, hidePin = true }), goto_(92, 0, { radius = 40, hidePin = true })
local stepGrind = newStep(5, { completewith = "Vendor", sticky = true }, g1, g2,
  H.plusObjective("|cRXP_WARN_Kill |cRXP_ENEMY_Young Scavengers|r and |cRXP_ENEMY_Duskbats|r. Loot them until you have 60 copper worth of vendor items|r"))
local stepAfter = newStep(6, {}, H.complete(92470, 1))
H.setActiveSteps(stepGrind, stepAfter)
point(g2); advance(2)
check("C: a real +objective blocks native and is named in the reason", H.mode() == "coordinates"
  and H.lastChat("next instruction is %+objective \"Kill Young Scavengers") ~= nil)

-- Patrol step whose served step has its own waypoint -> coordinates
local pp = patrolPoint(100, 30)
local stepPatrol2 = newStep(50, { completewith = "next", sticky = true, loop = "" }, pp, H.placeholder())
quests[92480] = { title = "Own Waypoint", ready = false, poi = 101, objectives = { kill(0, 3) } }
local stepServedOwn = newStep(51, {}, goto_(105, 0), H.complete(92480, 1))
H.setActiveSteps(stepPatrol2, stepServedOwn)
point(pp); advance(2)
check("served step with its own waypoint -> coordinates", H.mode() == "coordinates" and H.lastChat("served step 51 has its own waypoint") ~= nil)

-- Non-sticky #loop with only a placeholder never delegates
local np = patrolPoint(110, 30)
local stepLoopOnly = newStep(52, { loop = "" }, np, H.placeholder())
local stepNext = newStep(53, {}, H.complete(92480, 1))
H.setActiveSteps(stepLoopOnly, stepNext)
point(np); advance(2)
check("non-sticky placeholder loop -> coordinates", H.mode() == "coordinates" and H.lastChat("not a sticky #loop patrol step") ~= nil)

----------------------------------------------------------------------------
-- Test D/F: Horde Shaman "#loop" variant: patrol points, descriptive lines, Agitators x2 + Signet of Akir (92466)
quests[92465] = { title = "Agitators", ready = false, poi = 121, objectives = { kill(1, 7), kill(0, 6) } }
quests[92466] = { title = "Call of Earth", ready = false, poi = 121, objectives = { { type = "item", finished = false, numFulfilled = 0, numRequired = 1 } } }
local s1, s2 = patrolPoint(120, 30), patrolPoint(122, 50)
local signet = H.complete(92466, 1)
local stepShaman = newStep(60, { loop = "" }, s1, s2,
  H.header("Kill |cRXP_ENEMY_Al'Aketh Convert::251160|r and |cRXP_ENEMY_Roiling Winds::251143|r."),
  H.star("Loot them for the |T1020384:0|t[Signet of Akir]"),
  H.star("|cRXP_WARN_Prioritize |cRXP_ENEMY_Roiling Winds::251143|r|r"),
  H.complete(92465, 1), H.mob("+Al'Aketh Convert::251160"), H.complete(92465, 2), H.mob("+Roiling Winds::251143"), signet)
H.setActiveSteps(stepShaman)
point(s1); advance(2)
-- v0.5.3: both quests share this #loop farming circuit. The priority line sits in
-- a step with two quests (so it is not quest-level), the step is current for
-- both, nothing is tracked yet -> RestedXP's line order picks Agitators.
check("D/F: loop with two quests selects by guide order", H.mode() == "native" and select(2, H.mode()) == 92465
  and H.lastChat("selected quest 92465: first in RestedXP's guide order %(step 60%)") ~= nil)
local callsDF = st.setQuestCalls
signet.completed = true; quests[92466].objectives[1].finished = true
H.fire("QUEST_LOG_UPDATE"); advance(2)
check("F: Signet finishing leaves Agitators tracked without re-supertracking",
  H.mode() == "native" and select(2, H.mode()) == 92465 and st.setQuestCalls == callsDF)

----------------------------------------------------------------------------
-- In-game log (v0.5.1): arrow on patrol point 1 at 161 yd while the player is
-- inside the area (other points 35-60 yd away) and Blizzard's marker is 22 yd
-- away. Comparing only against the arrow's point gave gap 139 > 100 and fell
-- back; the whole circuit must be the reference.
local farRadii = { 30, 30, 50, 35, 35, 40, 30, 40, 30, 30 }
local farDist = { 161, 120, 95, 60, 35, 40, 70, 110, 150, 175 }
local farPoints = {}
for i, d in ipairs(farDist) do farPoints[i] = patrolPoint(d, farRadii[i]) end
local farElements = {}
for i, p in ipairs(farPoints) do farElements[i] = p end
farElements[#farElements + 1] = H.placeholder()
local stepFarPatrol = newStep(127, { hidewindow = "", completewith = "Windstone Cluster", sticky = true, loop = "" }, table.unpack(farElements))
local stepFarServed = newStep(129, {}, H.header("Kill |cRXP_ENEMY_Al'Aketh Convert::251160|r and |cRXP_ENEMY_Roiling Winds::251143|r."),
  H.star("|cRXP_WARN_Prioritize |cRXP_ENEMY_Roiling Winds::251143|r|r"), H.complete(92465, 1), H.mob("+Al'Aketh Convert::251160"),
  H.complete(92465, 2), H.mob("+Roiling Winds::251143"))
quests[92465] = { title = "Agitators", ready = false, poi = 22, objectives = { kill(3, 7), kill(3, 6) } }
slash("mode coordinates") -- start from coordinates, as in the log
H.setActiveSteps(stepFarPatrol, stepFarServed)
point(farPoints[1]); advance(2)
slash("mode native-first"); advance(2)
check("log repro: native accepted against the nearest patrol point, not the arrow's far point",
  H.mode() == "native" and select(2, H.mode()) == 92465, H.failureText())
check("log repro: check reports the nearest of 10 patrol points",
  H.lastChat("Native target check: native 22.0 yd, RestedXP 35.0 yd %(nearest of 10 patrol points%), gap 13.0 yd, limit 100 yd") ~= nil)

-- A marker that is far from EVERY patrol point is still rejected
quests[92491] = { title = "Elsewhere", ready = false, poi = 400, objectives = { kill(0, 4) } }
local farPoints2 = {}
for i, d in ipairs(farDist) do farPoints2[i] = patrolPoint(d + 1, farRadii[i]) end
local farElements2 = {}
for i, p in ipairs(farPoints2) do farElements2[i] = p end
farElements2[#farElements2 + 1] = H.placeholder()
local stepFarPatrol2 = newStep(130, { completewith = "next", sticky = true, loop = "" }, table.unpack(farElements2))
local stepFarServed2 = newStep(131, {}, H.complete(92491, 1))
H.setActiveSteps(stepFarPatrol2, stepFarServed2)
point(farPoints2[1]); advance(2)
check("marker far from every patrol point is still rejected", H.mode() == "coordinates"
  and H.failureText():find("from every one of RestedXP's 10 patrol points %(limit 100%)") ~= nil, H.failureText())

----------------------------------------------------------------------------
-- Classification passes but native verification fails: reported separately
quests[92490] = { title = "No Marker", ready = false, poi = nil, objectives = { kill(0, 4) } }
local vp = patrolPoint(130, 30)
local stepPatrol3 = newStep(70, { completewith = "next", sticky = true, loop = "" }, vp, H.placeholder())
local stepServed3 = newStep(71, {}, H.header("Kill things"), H.complete(92490, 1))
H.setActiveSteps(stepPatrol3, stepServed3)
point(vp); advance(2)
local v = ns.Sync.GetState().lastVerification or {}
check("verification failure is distinct from classification", H.mode() == "coordinates" and v.questID == 92490 and v.ok == false
  and H.lastChat("Native verification failed after classification passed %(no native navigation target") ~= nil)

----------------------------------------------------------------------------
-- /rxpwb inspect on the Agitators patrol
H.setActiveSteps(stepPatrol, stepAgitators)
quests[92465] = { title = "Agitators", ready = false, poi = 45, objectives = { kill(3, 7), kill(3, 6) } }
agitators1.completed, agitators2.completed = nil, nil
point(patrol[2]); advance(2)
local before = #H.chat
slash("inspect")
local text = table.concat(H.chat, "\n", before + 1)
check("inspect lists the patrol step flags", text:find("Arrow step 27 %(#loop, #completewith Windstone Cluster, #hidewindow, active%)") ~= nil)
check("inspect marks the +1 placeholder", text:find("%+placeholder \"1\" | placeholder | pending") ~= nil)
check("inspect lists the served step and its objectives", text:find("Served step 29") ~= nil and text:find("%.complete | quest 92465 obj 2 | pending") ~= nil)
check("inspect shows quest state", text:find("Quest 92465 %(Agitators%): in log yes, ready no, objectives: 1 monster 3/7; 2 monster 3/6") ~= nil)
check("inspect shows the native-first analysis", text:find("Native%-first analysis: .-yes") ~= nil and text:find("Internal error") == nil)

-- Coordinates strategy comparison: original navigation unchanged
slash("mode coordinates")
check("coordinates strategy restores RestedXP's patrol coordinates", H.mode() == "coordinates" and H.navAt(42) and st.quest == nil)

H.finish()
