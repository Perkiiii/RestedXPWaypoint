-- Regression tests for v0.5.3: quest prioritization inside a shared farming
-- circuit. Fixtures follow the installed Forever guide RestedXP-Skyborne.lua:
--   step  #hidewindow / #completewith Juvenile Vuldren / #loop / .goto 2521,44.23,26,40,0 ... (7) / +1
--   step  #completewith next / >>Kill Juvenile Vuldren / .complete 92461,1 / .mob   (Harmony in Balance)
--   step  >>Kill Pesky Cirrusfly / *Prioritize them / .complete 92462,1 / .mob       (Infestation Investigation)
--   step  #label Juvenile Vuldren / >>Kill Juvenile Vuldren / .complete 92461,1 / .mob
-- Mocked APIs; not proof of in-game behaviour. Run with: node tests/run.js
local H = dofile(ADDON_ROOT .. "/tests/harness.lua")
H.verbose = true
local check, advance, point, newStep, goto_ = H.check, H.advance, H.point, H.newStep, H.goto_
local quests, st, wui = H.quests, H.st, H.wui

local function kill(n, r) return { type = "monster", finished = n >= r, numFulfilled = n, numRequired = r } end
local function patrolPoint(dist) return goto_(dist, 0, { radius = 40, hidePin = true }) end

local ns = H.load(ADDON_ROOT, { debug = true, strategy = "native-first" })
local slash = H.slash

local patrol = {}
for i, d in ipairs({ 30, 34, 38, 42, 46, 50, 54 }) do patrol[i] = patrolPoint(d) end
local function patrolStep(index)
  local elements = {}
  for i, p in ipairs(patrol) do elements[i] = p end
  elements[#elements + 1] = H.placeholder()
  return newStep(index, { hidewindow = "", completewith = "Juvenile Vuldren", sticky = true, loop = "" }, table.unpack(elements))
end
local stepPatrol = patrolStep(4)
local vuldren5 = H.complete(92461, 1)
local step5 = newStep(5, { completewith = "next", sticky = true },
  H.header("Kill |cRXP_ENEMY_Juvenile Vuldren::250873|r."), vuldren5, H.mob("Juvenile Vuldren::250873"))
local cirrus = H.complete(92462, 1)
local step6 = newStep(6, {},
  H.header("Kill |cRXP_ENEMY_Pesky Cirrusfly::251169|r."), H.star("|cRXP_WARN_Prioritize them|r"),
  cirrus, H.mob("Pesky Cirrusfly::251169"))
local vuldren7 = H.complete(92461, 1)
local step7 = newStep(7, { label = "Juvenile Vuldren" },
  H.header("Kill |cRXP_ENEMY_Juvenile Vuldren::250873|r."), vuldren7, H.mob("Juvenile Vuldren::250873"))

quests[92461] = { title = "Harmony in Balance", ready = false, poi = 40, objectives = { kill(1, 8) } }
quests[92462] = { title = "Infestation Investigation", ready = false, poi = 44, objectives = { kill(2, 8) } }

----------------------------------------------------------------------------
-- 1. Both unfinished: Infestation Investigation (explicit "Prioritize them")
H.setActiveSteps(stepPatrol, step5, step6)
point(patrol[1]); advance(2)
local m, q = H.mode()
check("both quests eligible -> native, not a coordinate fallback", m == "native" and q == 92462, m)
check("selection: explicit RestedXP priority", H.lastChat("selected quest 92462: explicit RestedXP priority %(\"Prioritize them\"%)") ~= nil)
check("both candidates logged",
  H.lastChat("Candidate 92461 %(Harmony in Balance%) obj 1 1/8 %- eligible$") ~= nil
  and H.lastChat("Candidate 92462 %(Infestation Investigation%) obj 1 2/8 %- eligible %[selected%]") ~= nil)
check("verified against the patrol circuit", H.lastChat("nearest of 7 patrol points") ~= nil)

-- 2. Stability: patrol cycling, kills on BOTH quests, repeated quest events
local calls, writes = st.setQuestCalls, wui.writes
for i = 2, 7 do point(patrol[i]); advance(0.6) end
quests[92461].objectives[1] = kill(3, 8); H.fire("QUEST_LOG_UPDATE"); advance(0.7)
quests[92462].objectives[1] = kill(5, 8); H.fire("QUEST_LOG_UPDATE"); advance(0.7)
for i = 1, 5 do H.fire("QUEST_LOG_UPDATE"); H.fire("QUEST_ACCEPTED"); advance(0.2) end
advance(1)
check("no switching or writes from patrol cycling and unrelated progress", st.setQuestCalls == calls and wui.writes == writes
  and select(2, H.mode()) == 92462)

-- 3. Cirrusflies done -> switch to Harmony in Balance (no premature turn-in)
quests[92462].objectives[1] = kill(8, 8); quests[92462].ready = true
cirrus.completed = true
H.fire("QUEST_LOG_UPDATE"); advance(2)
m, q = H.mode()
local _, _, kind = H.mode()
check("completed objective -> next quest in the circuit", m == "native" and q == 92461 and kind == "objective", q)
check("switch is native -> native", H.transitionText() == "native quest 92462 -> native quest 92461", H.transitionText())
check("exactly one supertrack call for the switch", st.setQuestCalls == calls + 1)
check("no turn-in navigation while circuit work remains", kind ~= "turnin")

-- RestedXP advances: step 6 completes, step 5 (#completewith next) is dropped, step 7 current
calls = st.setQuestCalls
H.setActiveSteps(stepPatrol, step7)
H.fire("QUEST_LOG_UPDATE"); point(patrol[2]); advance(2)
check("RestedXP advancing to step 7 keeps Harmony in Balance", select(2, H.mode()) == 92461 and st.setQuestCalls == calls)

-- 4. Both done -> RestedXP routes to the turn-in (own .goto) -> native turn-in
quests[92461].objectives[1] = kill(8, 8); quests[92461].ready = true
vuldren7.completed = true
quests[92462].poi = 70
local elatrell = goto_(70, 0)
local step8 = newStep(8, {}, elatrell, H.header("|Tinterface/worldmap/chatbubble_64grey.blp:20|tTalk to |cRXP_FRIENDLY_Elatrell Featherlight::251368|r."),
  H.turnin(92462, "Infestation Investigation"), H.accept(92463, "The Cirrusfly Queen"), { tag = "target", textOnly = true })
H.setActiveSteps(step8)
point(elatrell); advance(2)
m, q, kind = H.mode()
check("after the circuit, RestedXP's turn-in is followed", m == "native" and q == 92462 and kind == "turnin", m)

----------------------------------------------------------------------------
-- 5. Current step decides when there is no priority text
quests[1001] = { title = "Sticky Work", ready = false, poi = 40, objectives = { kill(0, 5) } }
quests[1002] = { title = "Current Work", ready = false, poi = 42, objectives = { kill(0, 5) } }
local p2 = patrolStep(20)
local sA = newStep(21, { completewith = "next", sticky = true }, H.header("Kill A"), H.complete(1001, 1))
local sB = newStep(22, {}, H.header("Kill B"), H.complete(1002, 1))
H.setActiveSteps(p2, sA, sB)
point(patrol[1]); advance(2)
check("no priority text: RestedXP's current step wins", select(2, H.mode()) == 1002
  and H.lastChat("selected quest 1002: RestedXP's current step 22") ~= nil)

----------------------------------------------------------------------------
-- 6. Keep a suitable quest the player already tracks when RestedXP gives no order
quests[1003] = { title = "First Listed", ready = false, poi = 40, objectives = { kill(0, 5) } }
quests[1004] = { title = "Player Picked", ready = false, poi = 41, objectives = { kill(0, 5) } }
slash("mode coordinates")
local p3 = patrolStep(30)
local sBoth = newStep(31, {}, H.header("Kill both"), H.complete(1003, 1), H.complete(1004, 1))
H.setActiveSteps(p3, sBoth)
point(patrol[1]); advance(2)
st.quest = 1004; st.user = false -- the player picked quest 1004 in the quest tracker
slash("mode native-first"); advance(2)
check("already supertracked candidate is kept", select(2, H.mode()) == 1004 and H.lastChat("selected quest 1004: already supertracked") ~= nil)
-- without that, guide order
slash("mode coordinates"); st.quest = nil
slash("mode native-first"); advance(2)
check("otherwise guide order decides", select(2, H.mode()) == 1003 and H.lastChat("selected quest 1003: first in RestedXP's guide order %(step 31%)") ~= nil)
-- hysteresis: progress on the other quest does not switch
calls = st.setQuestCalls
quests[1004].objectives[1] = kill(2, 5); H.fire("QUEST_LOG_UPDATE"); advance(2)
check("progress on the other candidate does not switch", select(2, H.mode()) == 1003 and st.setQuestCalls == calls)

----------------------------------------------------------------------------
-- 7. Selected quest's native target fails -> next candidate; retry after meaningful change
quests[1005] = { title = "No Marker Yet", ready = false, poi = nil, objectives = { kill(0, 5) } }
quests[1006] = { title = "Backup", ready = false, poi = 43, objectives = { kill(0, 5) } }
slash("mode coordinates")
local p4 = patrolStep(40)
local sFail = newStep(41, { completewith = "next", sticky = true }, H.header("Kill backup"), H.complete(1006, 1))
local sPrio = newStep(42, {}, H.header("Kill those"), H.star("|cRXP_WARN_Prioritize them|r"), H.complete(1005, 1))
H.setActiveSteps(p4, sFail, sPrio)
point(patrol[1]); advance(2)
slash("mode native-first"); advance(3)
check("failed priority quest -> next eligible candidate instead of coordinates", select(2, H.mode()) == 1006,
  H.mode())
check("failure recorded for the priority quest", H.failureText():find("native quest 1005: no native navigation target") ~= nil)
check("debug explains the next-candidate attempt", H.lastChat("Native verification failed for quest 1005 %(no native navigation target for the quest%); trying the next candidate, quest 1006") ~= nil)
-- no rapid retry: events without meaningful change keep the backup
calls = st.setQuestCalls
for i = 1, 4 do H.fire("QUEST_LOG_UPDATE"); advance(1) end
check("no retry without a meaningful change", select(2, H.mode()) == 1006 and st.setQuestCalls == calls)
-- progress changed but too soon (< 10 s since the failure): still blocked
quests[1005].objectives[1] = kill(1, 5); H.fire("QUEST_LOG_UPDATE"); advance(1)
check("progress change within 10 s does not retry", select(2, H.mode()) == 1006)
-- marker available now, progress changed, > 10 s: retried and selected again (it has priority)
quests[1005].poi = 44
advance(8); quests[1005].objectives[1] = kill(2, 5); H.fire("QUEST_LOG_UPDATE"); advance(2)
check("after a meaningful change the priority quest is retried", select(2, H.mode()) == 1005, H.mode())

----------------------------------------------------------------------------
-- 8. Mandatory travel before the farming area stays on coordinates
quests[92461] = { title = "Harmony in Balance", ready = false, poi = 40, objectives = { kill(1, 8) } }
quests[92462] = { title = "Infestation Investigation", ready = false, poi = 44, objectives = { kill(2, 8) } }
cirrus.completed, vuldren5.completed = nil, nil
local road1 = goto_(10, 0, { radius = 15, hidePin = true })
local road2 = goto_(15, 0, { radius = 15, hidePin = true })
local cave = goto_(20, 0, { radius = 5, text = "Enter the cave" })
local travel = newStep(3, { completewith = "next", sticky = true }, road1, road2, cave)
local stepPatrolB = patrolStep(50)
local s5b = newStep(51, { completewith = "next", sticky = true }, H.header("Kill Juvenile Vuldren"), H.complete(92461, 1))
local s6b = newStep(52, {}, H.header("Kill Pesky Cirrusfly"), H.star("|cRXP_WARN_Prioritize them|r"), H.complete(92462, 1))
H.setActiveSteps(travel, stepPatrolB, s5b, s6b)
point(road1); advance(2)
check("road waypoint stays coordinates despite two eligible quests nearby", H.mode() == "coordinates" and H.navAt(10)
  and H.lastChat("intermediate route waypoint") ~= nil)
road1.skip = true; point(road2); advance(2)
check("second road waypoint stays coordinates", H.mode() == "coordinates" and H.navAt(15))
road2.skip = true; point(cave); advance(2)
check("cave entrance with travel text stays coordinates", H.mode() == "coordinates" and H.navAt(20)
  and H.lastChat("explicit travel instruction") ~= nil)
cave.skip = true; H.setActiveSteps(stepPatrolB, s5b, s6b)
point(patrol[1]); advance(2)
check("inside the farming area: native with priority", H.mode() == "native" and select(2, H.mode()) == 92462)

----------------------------------------------------------------------------
-- 9. Manual waypoint: an objective finishing does not reclaim navigation
H.setManualWaypoint("Repair Vendor"); advance(2)
calls, writes = st.setQuestCalls, wui.writes
s6b.elements[3].completed = true
quests[92462].objectives[1] = kill(8, 8); quests[92462].ready = true
H.fire("QUEST_LOG_UPDATE"); point(patrol[3]); advance(2)
check("native -> native switch held while a manual waypoint is tracked", wui.nav and wui.nav.name == "Repair Vendor"
  and st.setQuestCalls == calls and wui.writes == writes)
check("hold is logged", H.lastChat("Mode change held: another waypoint is tracked %(Repair Vendor%)") ~= nil)
-- player clears the manual waypoint -> next evaluation switches to the remaining quest
wui.nav = nil; st.user = false
H.fire("USER_WAYPOINT_UPDATED"); H.fire("QUEST_LOG_UPDATE"); advance(2)
check("after the manual waypoint is gone, the remaining quest is tracked", select(2, H.mode()) == 92461 and st.quest == 92461)

----------------------------------------------------------------------------
-- 10. Status and inspect show the multi-quest decision
quests[92462] = { title = "Infestation Investigation", ready = false, poi = 44, objectives = { kill(2, 8) } }
s6b.elements[3].completed = nil
H.fire("QUEST_LOG_UPDATE"); advance(2)
local before = #H.chat
slash("status")
local text = table.concat(H.chat, "\n", before + 1)
check("status lists candidates and the selection", text:find("Candidate 92461: Harmony in Balance %- obj 1 1/8 %- eligible") ~= nil
  and text:find("Selected 92462: explicit RestedXP priority") ~= nil and text:find("Internal error") == nil)
before = #H.chat
slash("inspect")
text = table.concat(H.chat, "\n", before + 1)
check("inspect shows served steps and the selection", text:find("Served step 52") ~= nil
  and text:find("Selected 92462: explicit RestedXP priority") ~= nil and text:find("Internal error") == nil)

-- 11. Hybrid and coordinates strategies are unchanged here
slash("mode hybrid")
check("hybrid stays on coordinates for the patrol", H.mode() == "coordinates")
slash("mode coordinates")
check("coordinates strategy follows RestedXP's patrol point", H.mode() == "coordinates" and st.quest == nil)

H.finish()
