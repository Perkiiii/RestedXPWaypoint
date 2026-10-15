-- Regression tests for v0.5.4: navigation and quest presentation continuity.
-- Fixtures follow the installed Forever guide RestedXP-Skyborne.lua:
--   step 34  #completewith next / #label Harvesting Windstones2
--            .goto 2521,43.89,22.27,40,0 / >>Talk to Dalia / *warn / .turnin 93552 / .target
--   step 35  #completewith Harvesting Windstones2 / #hidewindow / .goto 2521,43.37,23.98,60 >>1
--   step 36  #requires Harvesting Windstones2 / .goto 2521,43.37,23.98 / >>Talk to Dalia / *warn / .turnin 93552
-- and the druid helper "#completewith next / #hidewindow / .goto 2521,64.703,30.067,20 >>1"
-- before a #loop objective step. Mocked APIs; not proof of in-game behaviour.
local H = dofile(ADDON_ROOT .. "/tests/harness.lua")
H.verbose = true
local check, advance, point, newStep, goto_ = H.check, H.advance, H.point, H.newStep, H.goto_
local quests, st, wui = H.quests, H.st, H.wui

local ns = H.load(ADDON_ROOT, { debug = true, strategy = "native-first" })
local slash = H.slash
local QUEST_ICON_DONE = "Interface\\AddOns\\WaypointUI\\Art\\Icons\\CompleteQuest"
local QUEST_ICON_OPEN = "Interface\\AddOns\\WaypointUI\\Art\\Icons\\IncompleteQuest"

local function dalia() return H.header("|Tinterface/worldmap/chatbubble_64grey.blp:20|tTalk to |cRXP_FRIENDLY_Dalia the Collector::251363|r.") end
local function warn() return H.star("|cRXP_WARN_Choose between Mining, Herbalism, or Skinning|r.") end
local function target() return { tag = "target", textOnly = true } end

-- Distances from the player (yards): approach point 60, Dalia 90.
local function windstoneSteps(base)
  local approach = goto_(60, 0, { radius = 40, hidePin = true })
  local s34 = newStep(base, { completewith = "next", sticky = true, label = "Harvesting Windstones2" },
    approach, dalia(), warn(), H.turnin(93552, "Harvesting Windstones"), target())
  local helper = goto_(90, 0, { radius = 60, text = "1" })
  local s35 = newStep(base + 1, { completewith = "Harvesting Windstones2", sticky = true, hidewindow = "" }, helper)
  local final = goto_(90, 0)
  local turnin36 = H.turnin(93552, "Harvesting Windstones")
  local s36 = newStep(base + 2, { requires = "Harvesting Windstones2" }, final, dalia(), warn(), turnin36, target())
  return { s34 = s34, s35 = s35, s36 = s36, approach = approach, helper = helper, final = final, turnin36 = turnin36 }
end

quests[93552] = { title = "Harvesting Windstones", ready = true, poi = 91, objectives = { { type = "object", finished = true, numFulfilled = 15, numRequired = 15 } } }

----------------------------------------------------------------------------
-- A. Native turn-in -> hidden helper (same quest giver) -> same native turn-in: no transition
local w = windstoneSteps(34)
H.setActiveSteps(w.s34, w.s35)
point(w.approach); advance(2)
local m, q, kind = H.mode()
check("A: step 34 approach point -> native turn-in", m == "native" and q == 93552 and kind == "turnin", m)
local calls, writes, clears = st.setQuestCalls, wui.writes, wui.clears
local transition = H.transitionText()
w.approach.skip = true; point(w.helper); advance(2)
check("A: helper step 35 keeps the native marker", H.mode() == "native" and st.setQuestCalls == calls
  and wui.writes == writes and wui.clears == clears and H.transitionText() == transition)
check("A: preserved with a structural reason", H.lastChat("Preserving native quest 93552: native continuity: helper step 35 leads to the same turn%-in %(quest 93552, step 34%)") ~= nil)
w.helper.skip = true; H.setActiveSteps(w.s36); point(w.final); advance(2)
check("A: step 36 continues the same native session", H.mode() == "native" and st.setQuestCalls == calls
  and wui.writes == writes and H.transitionText() == transition)
local before = #H.chat
slash("inspect")
local text = table.concat(H.chat, "\n", before + 1)
check("A: inspect explains role and context", text:find("Waypoint role: turn%-in destination") ~= nil
  and text:find("Quest context: 93552 Harvesting Windstones %(turn%-in, ready%)") ~= nil)

----------------------------------------------------------------------------
-- A2. RestedXP supertracked a different quest meanwhile: no continuity, helper followed
quests[2010] = { title = "Other Quest", ready = false, poi = 300, objectives = { { type = "monster", finished = false, numFulfilled = 0, numRequired = 3 } } }
quests[93552] = { title = "Harvesting Windstones", ready = true, poi = 91 }
local wa = windstoneSteps(1034)
H.setActiveSteps(wa.s34, wa.s35)
point(wa.approach); advance(2)
check("A2: native turn-in first", H.mode() == "native" and select(2, H.mode()) == 93552)
C_SuperTrack.SetSuperTrackedQuestID(2010) -- RestedXP's own .complete handler
wa.approach.skip = true; point(wa.helper); advance(2)
check("A2: quest no longer supertracked -> helper followed with coordinates", H.mode() == "coordinates" and H.navAt(90)
  and H.lastChat("native continuity not applicable: quest 93552 is no longer supertracked") ~= nil)
check("A2: helper labelled with its quest", wui.nav.name == "Harvesting Windstones - Ready for turn-in")

----------------------------------------------------------------------------
-- C. Helper that is provably elsewhere (native NPC 91 yd, helper 30 yd): coordinates,
--    but with the quest's title, status and icon instead of "Step N"
local w2 = windstoneSteps(134)
H.setActiveSteps(w2.s134 or w2.s34, w2.s35)
point(w2.approach); advance(2)
check("C: native turn-in first", H.mode() == "native")
local farHelper = goto_(30, 0, { radius = 60, text = "1" })
w2.s35.elements[1] = farHelper; farHelper.step = w2.s35
w2.approach.skip = true; point(farHelper); advance(2)
check("C: inconsistent helper -> coordinates (route preserved)", H.mode() == "coordinates" and H.navAt(30))
check("C: rejection explained", H.lastChat("native continuity rejected: the native target is not consistent with the helper waypoint") ~= nil)
check("C: label uses quest context", wui.nav.name == "Harvesting Windstones - Ready for turn-in", wui.nav.name)
check("C: quest icon and no coordinate line", wui.nav.iconTexture == QUEST_ICON_DONE and wui.nav.stripCoordinates == true)
check("C: label source logged", H.lastChat("Coordinate waypoint label: Harvesting Windstones %- Ready for turn%-in %(quest context, icon: quest%)") ~= nil)

----------------------------------------------------------------------------
-- D. Turn-in completes: context cleared, next activity selected
w2.turnin36.completed = true
w2.s34.elements[4].completed = true
quests[93552] = nil; st.quest = nil
local s37 = newStep(137, {}, goto_(40, 0, { text = "Walk to the grove" }))
H.setActiveSteps(s37); H.fire("QUEST_TURNED_IN"); point(s37.elements[1]); advance(2)
check("D: next activity uses its own instruction", H.mode() == "coordinates" and wui.nav.name == "Walk to the grove" and wui.nav.iconTexture == nil)
check("D: stale context cleared", H.lastChat("Quest context cleared: quest 93552 %(quest turned in or removed%)") ~= nil)

----------------------------------------------------------------------------
-- E. A different quest: helper for quest B after a coordinate context for quest A
quests[2001] = { title = "Quest A", ready = true, poi = 500 }
quests[2002] = { title = "Quest B", ready = false, poi = 500, objectives = { { type = "monster", finished = false, numFulfilled = 1, numRequired = 4 } } }
local aSteps = newStep(200, { completewith = "next", sticky = true, label = "A" }, goto_(20, 0, { radius = 30, hidePin = true }), H.turnin(2001, "Quest A"))
local aHelper = goto_(22, 0, { radius = 40, text = "1" })
local aHelperStep = newStep(201, { completewith = "A", sticky = true, hidewindow = "" }, aHelper)
H.setActiveSteps(aSteps, aHelperStep)
aSteps.elements[1].skip = true; point(aHelper); advance(2)
check("E: helper for quest A labelled with quest A", H.mode() == "coordinates" and wui.nav.name == "Quest A - Ready for turn-in", wui.nav.name)
-- RestedXP moves on: druid-style helper before a #loop objective of quest B
local bHelper = goto_(24, 0, { radius = 20, text = "1" })
local bHelperStep = newStep(210, { completewith = "next", sticky = true, hidewindow = "" }, bHelper)
local bLoop = newStep(211, { loop = "" }, H.loopPoint(30, 0), H.loopPoint(32, 0),
  H.header("Click on the |cRXP_PICK_Druids|r"), H.complete(2002, 1), { tag = "target", textOnly = true })
H.setActiveSteps(bHelperStep, bLoop)
point(bHelper); advance(2)
check("E: objective helper stays coordinates (route between clusters)", H.mode() == "coordinates" and H.navAt(24))
check("E: label switched to quest B, no stale quest A", wui.nav.name == "Quest B" and wui.nav.iconTexture == QUEST_ICON_OPEN, wui.nav.name)
check("E: objectives never use continuity", H.lastChat("helper step 210 %(completes with step 211%): objective of quest 2002") ~= nil)

-- E2. Real druid case: native objective active for quest B, then the helper that moves the
--     player to the second cluster of the SAME objective -> coordinates (objectives never
--     keep native through helpers), labelled with quest B.
local c1 = H.loopPoint(30, 0)
local cluster1 = newStep(212, { loop = "" }, c1, H.loopPoint(31, 0), H.header("Click on the |cRXP_PICK_Druids|r"), H.complete(2002, 1))
quests[2002].poi = 31
H.setActiveSteps(cluster1)
point(c1); advance(2)
check("E2: first cluster native objective", H.mode() == "native" and select(2, H.mode()) == 2002 and select(3, H.mode()) == "objective")
local moveHelper = goto_(40, 0, { radius = 20, text = "1" })
local moveStep = newStep(213, { completewith = "next", sticky = true, hidewindow = "" }, moveHelper)
local cluster2 = newStep(214, { loop = "" }, H.loopPoint(45, 0), H.loopPoint(47, 0), H.header("Click on the |cRXP_PICK_Druids|r."), H.complete(2002, 1))
H.setActiveSteps(moveStep, cluster2)
point(moveHelper); advance(2)
check("E2: helper to the second cluster is followed with coordinates", H.mode() == "coordinates" and H.navAt(40)
  and wui.nav.name == "Quest B")

-- E3. Real instructions are never replaced by quest context
quests[2006] = { title = "Not Ready Yet", ready = false, poi = 52, objectives = { { type = "monster", finished = false, numFulfilled = 0, numRequired = 3 } } }
local ilsa = goto_(52, 0)
local ilsaStep = newStep(215, {}, ilsa, H.header("Talk to Ilsa"), H.turnin(2006, "Not Ready Yet"))
H.setActiveSteps(ilsaStep)
point(ilsa); advance(2)
check("E3: quest context exists but the RestedXP instruction stays", H.mode() == "coordinates" and wui.nav.name == "Talk to Ilsa"
  and wui.nav.iconTexture == nil and H.lastChat("Using quest context: Not Ready Yet") ~= nil, wui.nav.name)

----------------------------------------------------------------------------
-- F. Ambiguous: helper without an active anchor -> no quest name, existing fallback
local orphan = goto_(26, 0, { radius = 20, text = "1" })
local orphanStep = newStep(220, { completewith = "Nowhere", sticky = true, hidewindow = "" }, orphan)
H.setActiveSteps(orphanStep)
point(orphan); advance(2)
check("F: no anchor -> plain fallback label, no quest icon", H.mode() == "coordinates" and wui.nav.name == "Step 220"
  and wui.nav.iconTexture == nil, wui.nav.name)

----------------------------------------------------------------------------
-- G. Cave entrance keeps its instruction even when the step belongs to a quest activity
quests[2003] = { title = "Cave Quest", ready = false, poi = 60, objectives = { { type = "monster", finished = false, numFulfilled = 0, numRequired = 5 } } }
local caveEntrance = goto_(28, 0, { radius = 5, text = "Enter the cave" })
local caveStep = newStep(230, { completewith = "next", sticky = true }, caveEntrance)
local caveKill = newStep(231, {}, goto_(60, 0), H.header("Kill cave dwellers"), H.complete(2003, 1))
H.setActiveSteps(caveStep, caveKill)
point(caveEntrance); advance(2)
check("G: cave entrance stays coordinates with its instruction", H.mode() == "coordinates" and wui.nav.name == "Enter the cave"
  and wui.nav.iconTexture == nil and H.lastChat("explicit travel instruction") ~= nil)
check("G: route-critical role shown", (function()
  local b = #H.chat; slash("status"); return table.concat(H.chat, "\n", b + 1):find("Waypoint role: travel instruction | route%-critical: .-yes") ~= nil
end)())

----------------------------------------------------------------------------
-- B. Native turn-in -> required road waypoint -> native turn-in
quests[2004] = { title = "Road Quest", ready = true, poi = 81 }
local roadA = goto_(80, 0)
local turnStepA = newStep(240, {}, roadA, H.header("Talk to Greta"), H.turnin(2004, "Road Quest"))
H.setActiveSteps(turnStepA)
point(roadA); advance(2)
check("B: native turn-in", H.mode() == "native" and select(2, H.mode()) == 2004)
local road = goto_(50, 0, { radius = 15, text = "Follow the road around the ridge" })
local roadStep = newStep(239, { completewith = "next", sticky = true }, road)
H.setActiveSteps(roadStep, turnStepA)
point(road); advance(2)
check("B: required road waypoint -> coordinates with its instruction", H.mode() == "coordinates" and H.navAt(50)
  and wui.nav.name == "Follow the road around the ridge")
road.skip = true; H.setActiveSteps(turnStepA); point(roadA); advance(2)
check("B: native turn-in again after the road", H.mode() == "native" and select(2, H.mode()) == 2004)

----------------------------------------------------------------------------
-- H. Manual waypoint during the native turn-in: helper of the same quest does not reclaim it
quests[93552] = { title = "Harvesting Windstones", ready = true, poi = 91 }
local w3 = windstoneSteps(334)
H.setActiveSteps(w3.s34, w3.s35)
point(w3.approach); advance(2)
check("H: native turn-in before the manual waypoint", H.mode() == "native" and select(2, H.mode()) == 93552)
H.setManualWaypoint("Repair Vendor"); advance(2)
calls, writes = st.setQuestCalls, wui.writes
w3.approach.skip = true; point(w3.helper); advance(2)
check("H: helper of the same quest does not override the manual waypoint", wui.nav.name == "Repair Vendor"
  and st.setQuestCalls == calls and wui.writes == writes)
check("H: no quest information forced onto the manual waypoint", wui.nav.iconTexture == nil and wui.nav.flags == nil)
w3.helper.skip = true; H.setActiveSteps(w3.s36); point(w3.final); advance(2)
check("H: same native id at step 36 writes nothing", wui.nav.name == "Repair Vendor" and st.setQuestCalls == calls)

----------------------------------------------------------------------------
-- I. Rapid transitions: 34 -> 35 -> 36 faster than the settle time, plus an interrupted native start
slash("mode coordinates")
quests[2005] = { title = "Fresh Turn-in", ready = true, poi = 71 }
local fresh = goto_(70, 0)
local freshStep = newStep(434, {}, fresh, H.header("Talk to Ilsa"), H.turnin(2005, "Fresh Turn-in"))
H.setActiveSteps(freshStep)
point(fresh); advance(1)                 -- coordinates written under the coordinates strategy
slash("mode native-first")               -- native transition starts (clear + delayed supertrack)
local pending = ns.Sync.GetState().pending
local travel = goto_(15, 0, { text = "Leave town" })
local travelStep = newStep(400, {}, travel)
H.setActiveSteps(travelStep)
point(travel); advance(0.1); point(fresh); advance(0.1); point(travel); advance(2)
check("I: transition was pending when RestedXP moved on", pending == true)
check("I: final state is the last RestedXP target, no stale native restore", H.mode() == "coordinates" and H.navAt(15)
  and st.quest ~= 2005 and wui.nav.name == "Leave town")

----------------------------------------------------------------------------
-- Other strategies are unchanged
quests[93552] = { title = "Harvesting Windstones", ready = true, poi = 91 }
local w5 = windstoneSteps(534)
H.setActiveSteps(w5.s34, w5.s35)
w5.approach.skip = true
slash("mode hybrid"); point(w5.helper); advance(2)
check("hybrid: helper stays coordinates with its v0.4 label", H.mode() == "coordinates" and wui.nav.name == "Step 535"
  and wui.nav.iconTexture == nil, wui.nav.name)
slash("mode coordinates"); advance(2)
check("coordinates: no quest context label", H.mode() == "coordinates" and wui.nav.name == "Step 535" and wui.nav.iconTexture == nil, wui.nav.name)

-- Unverified Waypoint UI version: no quest icon (label still improved)
H.versions.WaypointUI = "2.0.0"
slash("mode native-first"); advance(2)
check("unknown Waypoint UI version: quest label without icon", wui.nav.name == "Harvesting Windstones - Ready for turn-in"
  and wui.nav.iconTexture == nil, wui.nav.name)
H.versions.WaypointUI = "1.7.3"

H.finish()
