-- Regression tests for v0.5.5: Waypoint UI quest icons on RestedXP coordinate
-- waypoints (native-first). The icon mirrors what Waypoint UI's native quest
-- marker shows (Waypoint_ContextIcon: <Available|Incomplete|Complete><Type>Quest).
-- Fixtures follow RestedXP-Skyborne.lua. Mocked APIs; not proof of in-game behaviour.
local H = dofile(ADDON_ROOT .. "/tests/harness.lua")
H.verbose = true
local check, advance, point, newStep, goto_ = H.check, H.advance, H.point, H.newStep, H.goto_
local quests, st, wui = H.quests, H.st, H.wui

-- Quest classification (Waypoint UI uses C_QuestInfoSystem.GetQuestClassification).
Enum.QuestClassification = { Important = 0, Legendary = 1, Campaign = 2, Calling = 3, Meta = 4, Recurring = 5, Questline = 6, Normal = 7 }
local classification = {}
C_QuestInfoSystem = { GetQuestClassification = function(q) return classification[q] or Enum.QuestClassification.Normal end }

local RXPW = H.load(ADDON_ROOT, { debug = true, strategy = "native-first" })
local slash = H.slash
local ICON = "Interface\\AddOns\\WaypointUI\\Art\\Icons\\"
local DEFAULT_ICON = "Interface\\AddOns\\RestedXPWaypoint\\Art\\Icons\\DefaultWaypoint"
local GOLD_OPEN = "Interface\\AddOns\\RestedXPWaypoint\\Art\\Icons\\QuestAvailable" -- tint-ready "!" for the quest gold
local GOLD_DONE = "Interface\\AddOns\\RestedXPWaypoint\\Art\\Icons\\QuestComplete"  -- tint-ready "?"

local function crystals() return H.header("|TInterface/cursor/crosshair/interact.blp:20|tClick on the |cRXP_PICK_Crystals|r") end

----------------------------------------------------------------------------
-- 1. The in-game case: Windstone Cluster collection route (no #loop) -> coordinates,
--    RestedXP's instruction kept, incomplete-quest icon instead of the default arrow.
--    step #completewith next / .goto 2521,43.82,25.41,20,0 ... (6) / >>Click on the Crystals / *warn / *warn / .complete 93552,1
quests[93552] = { title = "Harvesting Windstones", ready = false, poi = 300,
  objectives = { { type = "object", finished = false, numFulfilled = 9, numRequired = 15 } } }
local r = {}
for i, d in ipairs({ 20, 25, 30, 35, 40, 45 }) do r[i] = goto_(d, 0, { radius = 20 + i, hidePin = true }) end
local route = newStep(31, { completewith = "next", sticky = true }, r[1], r[2], r[3], r[4], r[5], r[6], crystals(),
  H.star("|cRXP_WARN_Expect to break about 10 stones, but you may need up to 15|r."),
  H.star("|cRXP_WARN_If the area is abnormally crowded, camp one spawn point or rotate between nearby stones|r."),
  H.complete(93552, 1))
H.setActiveSteps(route)
point(r[1]); advance(2)
check("Windstone route stays coordinates", H.mode() == "coordinates" and H.navAt(20))
check("RestedXP's instruction is kept", wui.nav.name == "Click on the Crystals", wui.nav.name)
check("incomplete quest icon (silver ?) instead of the default arrow", wui.nav.iconTexture == ICON .. "IncompleteQuest", wui.nav.iconTexture)
local function tintIs(r, g, b) return wui.nav and wui.nav.r and math.abs(wui.nav.r - r / 255) < 1e-6
  and math.abs(wui.nav.g - g / 255) < 1e-6 and math.abs(wui.nav.b - b / 255) < 1e-6 end
check("incomplete quest uses Waypoint UI's incomplete-quest colour (silver), not the gold 'Other'", tintIs(200, 200, 200))
check("icon decision logged", H.lastChat("icon IncompleteQuest %(quest 93552, step 31 objective%)") ~= nil)

-- Moving along the route keeps the icon; no extra writes beyond the new coordinates
local writes = wui.writes
r[1].skip = true; point(r[2]); advance(2)
check("next route point: one write, same icon", wui.writes == writes + 1 and wui.nav.iconTexture == ICON .. "IncompleteQuest" and H.navAt(25))

-- Objective finished while still on the route: the quest is ready -> gold ? (silent same-coordinate update)
quests[93552].objectives[1] = { type = "object", finished = true, numFulfilled = 15, numRequired = 15 }
quests[93552].ready = true
writes = wui.writes
H.fire("QUEST_LOG_UPDATE"); advance(2)
check("quest ready -> complete-quest icon via a silent same-coordinate update", wui.nav.iconTexture == GOLD_DONE
  and wui.writes == writes + 1 and H.navAt(25) and wui.nav.name == "Click on the Crystals")
check("icon-only refresh is logged as a same-destination update", H.lastChat("Label/icon changed") ~= nil)
check("ready quest uses the quest gold #FFD100", tintIs(255, 209, 0))

----------------------------------------------------------------------------
-- 2. Accept step that stays on coordinates: "!" (available) icon
--    step .goto 2521,43.37,23.99 / >>Talk to Dalia / .accept 93552 / .target
quests[93600] = nil
local accept = goto_(50, 0)
local acceptStep = newStep(40, {}, accept, H.header("Talk to |cRXP_FRIENDLY_Dalia the Collector::251363|r."),
  H.accept(93600, "Harvesting More"), { tag = "target", textOnly = true })
H.setActiveSteps(acceptStep)
point(accept); advance(2)
check("accept step uses the quest gold #FFD100 (not Waypoint UI's pale 'Other')", tintIs(255, 209, 0))
-- v0.5.6: the real instruction wins over the ">>" heading (as it always did in
-- game, where RestedXP marks headings completed when it draws them).
check("accept step: coordinates with the available-quest icon", H.mode() == "coordinates" and wui.nav.name == "Accept Harvesting More"
  and wui.nav.iconTexture == GOLD_OPEN, wui.nav.iconTexture)

-- Quest accepted while standing there (RestedXP has not moved on yet): incomplete icon
quests[93600] = { title = "Harvesting More", ready = false, poi = 900, objectives = { { type = "object", finished = false, numFulfilled = 0, numRequired = 5 } } }
H.fire("QUEST_ACCEPTED"); advance(2)
check("after accepting: incomplete icon", wui.nav.iconTexture == ICON .. "IncompleteQuest", wui.nav.iconTexture)
check("after accepting: incomplete colour", tintIs(200, 200, 200))

----------------------------------------------------------------------------
-- 3. Quest type follows Waypoint UI's classification (campaign / repeatable)
classification[93700] = Enum.QuestClassification.Campaign
quests[93700] = { title = "Campaign Step", ready = false, poi = 900 }
local camp = goto_(55, 0, { radius = 10, hidePin = true })
local campStep = newStep(50, { completewith = "next", sticky = true }, camp, goto_(57, 0), H.header("Talk to the general"), H.turnin(93700, "Campaign Step"))
H.setActiveSteps(campStep)
point(camp); advance(2)
check("campaign quest gets the campaign icon", wui.nav.iconTexture == ICON .. "IncompleteCampaignQuest", wui.nav.iconTexture)

classification[93701] = nil
quests[93701] = { title = "Daily Chore", ready = true, poi = 900 }
C_QuestLog.IsRepeatableQuest = function(q) return q == 93701 end
classification[93701] = -1 -- not Normal, not a named class
local rep = goto_(60, 0, { radius = 10, hidePin = true })
local repStep = newStep(51, { completewith = "next", sticky = true }, rep, goto_(62, 0), H.turnin(93701, "Daily Chore"))
H.setActiveSteps(repStep)
point(rep); advance(2)
check("repeatable quest ready -> complete repeatable icon", wui.nav.iconTexture == ICON .. "CompleteRepeatableQuest", wui.nav.iconTexture)
C_QuestLog.IsRepeatableQuest = nil

----------------------------------------------------------------------------
-- 4. Non-quest waypoints keep Waypoint UI's default icon
local travel = goto_(65, 0, { text = "Run to the bridge" })
local travelStep = newStep(60, { completewith = "next", sticky = true }, travel)
H.setActiveSteps(travelStep)
point(travel); advance(2)
check("travel step: the bridge's default icon, no r/g/b", wui.nav.name == "Run to the bridge"
  and wui.nav.iconTexture == DEFAULT_ICON and wui.nav.r == nil and wui.nav.g == nil and wui.nav.b == nil, wui.nav.iconTexture)

local vendor = goto_(70, 0)
local vendorStep = newStep(61, {}, vendor, H.header("Talk to Uualia"), { tag = "vendor", text = "Vendor trash" }, H.complete(93552, 1))
H.setActiveSteps(vendorStep)
point(vendor); advance(2)
check("step that starts with a non-quest action (.vendor): its service icon, not a quest icon",
  wui.nav.iconTexture == "Interface\\AddOns\\RestedXPWaypoint\\Art\\Icons\\Bags", wui.nav.iconTexture)

local unknown = goto_(75, 0)
local unknownStep = newStep(62, {}, unknown, H.complete(99999, 1)) -- quest not in the log
H.setActiveSteps(unknownStep)
point(unknown); advance(2)
check("objective of a quest not in the log: default icon", wui.nav.iconTexture == DEFAULT_ICON and wui.nav.r == nil, wui.nav.iconTexture)

----------------------------------------------------------------------------
-- 5. Native tracking is unchanged; presentation is the same in every strategy (v0.5.6)
quests[93800] = { title = "Native One", ready = true, poi = 81 }
local nat = goto_(80, 0)
local natStep = newStep(70, {}, nat, H.header("Talk to Rorian"), H.turnin(93800, "Native One"))
H.setActiveSteps(natStep)
point(nat); advance(2)
check("native turn-in still uses the native marker", H.mode() == "native" and select(2, H.mode()) == 93800)

H.setActiveSteps(route)
r[2].skip = nil; point(r[2]); advance(2)
local before = #H.chat
slash("status")
local text = table.concat(H.chat, "\n", before + 1)
check("status shows the coordinate marker icon", text:find("Marker icon: quest 93552 Complete | CompleteQuest", 1, true) ~= nil
  and text:find("Marker texture: " .. GOLD_DONE, 1, true) ~= nil
  and text:find("set by RestedXP Waypoint, custom icon") ~= nil, text)

local nativeFirstNav = { name = wui.nav.name, x = wui.nav.x, y = wui.nav.y }
slash("mode hybrid"); advance(2)
check("hybrid: same quest icon and colour", H.mode() == "coordinates" and wui.nav.iconTexture == GOLD_DONE
  and wui.nav.r ~= nil, wui.nav.iconTexture)
slash("mode coordinates"); advance(2)
check("coordinates: same quest icon", H.mode() == "coordinates" and wui.nav.iconTexture == GOLD_DONE, wui.nav.iconTexture)
check("strategies do not move the waypoint or change its label", wui.nav.name == nativeFirstNav.name
  and wui.nav.x == nativeFirstNav.x and wui.nav.y == nativeFirstNav.y)
slash("mode native-first"); advance(2)
check("back to native-first: icon returns", wui.nav.iconTexture == GOLD_DONE)

-- Unverified Waypoint UI version: no quest icon file, so the bridge's default icon
H.versions.WaypointUI = "1.8.0"
point(r[3]); advance(2)
check("unverified Waypoint UI version: the bridge's default icon, no r/g/b", wui.nav.iconTexture == DEFAULT_ICON and wui.nav.r == nil)
H.versions.WaypointUI = "1.7.3"

H.finish()
