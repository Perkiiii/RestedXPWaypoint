-- Regression tests for v0.5.6: quest context and icon for intermediate
-- (route-critical) waypoints, and live objective progress in the label.
-- RestedXP's guide window marks every text-only / text-less element completed
-- when it draws the step (harness newStep simulates it), which used to hide
-- the quest context and freeze "0/15 Windstone Cluster".
-- Fixture: RestedXP-Skyborne.lua, Harvesting Windstones. Mocked APIs; not proof
-- of in-game behaviour.
local H = dofile(ADDON_ROOT .. "/tests/harness.lua")
H.verbose = true
local check, advance, point, newStep, goto_ = H.check, H.advance, H.point, H.newStep, H.goto_
local quests, wui = H.quests, H.wui

-- Player position for /rxpw preview.
C_Map.GetBestMapForUnit = function() return 1421 end
C_Map.GetPlayerMapPosition = function() return { GetXY = function() return 0.5, 0.5 end } end
function GetPlayerFacing() return 0 end

local RXPW = H.load(ADDON_ROOT, { debug = true, strategy = "coordinates" })
local slash = H.slash
local ICON = "Interface\\AddOns\\WaypointUI\\Art\\Icons\\"
local OWN = "Interface\\AddOns\\RestedXPWaypoint\\Art\\Icons\\"

local function tintIs(r, g, b)
  local n = wui.nav
  return n and n.r and math.abs(n.r - r / 255) < 1e-6 and math.abs(n.g - g / 255) < 1e-6 and math.abs(n.b - b / 255) < 1e-6
end
local function statusText()
  local before = #H.chat
  slash("status")
  return table.concat(H.chat, "\n", before + 1)
end

quests[93552] = { title = "Harvesting Windstones", ready = false, poi = 300,
  objectives = { { type = "object", finished = false, numFulfilled = 0, numRequired = 15 } } }

-- step #completewith next / #sticky: six route points (radius 20, optional),
-- >>Click on the Crystals, two warnings, .complete 93552,1
local r = {}
for i, d in ipairs({ 20, 25, 30, 35, 40, 45 }) do r[i] = goto_(d, 0, { radius = 20, hidePin = true }) end
local comp = H.complete(93552, 1, { text = "0/15 Windstone Cluster" })
local step = newStep(33, { completewith = "next", sticky = true }, r[1], r[2], r[3], r[4], r[5], r[6],
  H.header("|TInterface/cursor/crosshair/interact.blp:20|tClick on the |cRXP_PICK_Crystals|r"),
  H.star("|cRXP_WARN_Expect to break about 10 stones, but you may need up to 15|r."),
  H.star("|cRXP_WARN_If the area is abnormally crowded, camp one spawn point or rotate between nearby stones|r."),
  comp)
check("fixture: RestedXP's render flags are set", r[2].completed == true and step.elements[7].completed == true
  and comp.completed == nil)
H.setActiveSteps(step)
r[1].skip = true

----------------------------------------------------------------------------
-- 1. Route-critical point: RestedXP's coordinates, the quest's icon and colour, live label, every strategy
for _, strategy in ipairs({ "coordinates", "hybrid", "native-first" }) do
  slash("mode " .. strategy); point(r[2]); advance(2)
  check(strategy .. ": RestedXP's coordinates kept", H.mode() == "coordinates" and H.navAt(25))
  check(strategy .. ": incomplete quest icon (silver ?)", wui.nav.iconTexture == ICON .. "IncompleteQuest", wui.nav.iconTexture)
  check(strategy .. ": IncompleteQuest colour #C8C8C8", tintIs(200, 200, 200))
  check(strategy .. ": label is RestedXP's objective with live progress", wui.nav.name == "0/15 Windstone Cluster", wui.nav.name)
end
check("native-first: still a route waypoint (navigation decision unchanged)",
  RXPW.Sync.GetState().mode == "coordinates" and H.lastChat("intermediate route waypoint") ~= nil)

local text = statusText()
check("status: navigation role and coordinates", text:find("Navigation: coordinates | role: route point | route-critical: ", 1, true) ~= nil
  and text:find("map 1421 @ 12.50, 0.00", 1, true) ~= nil, text)
check("status: quest context with quest ID", text:find("Quest context: quest 93552 Harvesting Windstones | objective, incomplete | from step 33 objective", 1, true) ~= nil, text)
check("status: icon category and actual texture", text:find("Marker icon: quest 93552 Incomplete | IncompleteQuest", 1, true) ~= nil
  and text:find("colour: IncompleteQuest", 1, true) ~= nil
  and text:find("Marker texture: " .. ICON .. "IncompleteQuest", 1, true) ~= nil)
check("status: label is current", text:find('displayed "0/15 Windstone Cluster" | stale: ', 1, true) ~= nil
  and text:find("stale: |cffff4040no|r", 1, true) ~= nil)

----------------------------------------------------------------------------
-- 2. Progress 0/15 -> 1/15: one silent rename, nothing recreated
slash("mode coordinates"); advance(2)
local writes, clears, audible = wui.writes, wui.clears, wui.audible or 0
comp.text = "1/15 Windstone Cluster"
text = statusText()
check("status before the refresh: stale label detected", text:find('RestedXP "1/15 Windstone Cluster"', 1, true) ~= nil
  and text:find('displayed "0/15 Windstone Cluster" | stale: |cff00ff00yes|r', 1, true) ~= nil, text)
H.fire("QUEST_LOG_UPDATE"); H.fire("QUEST_LOG_UPDATE"); H.fire("QUEST_LOG_UPDATE")
advance(2)
check("progress: label updated to 1/15", wui.nav.name == "1/15 Windstone Cluster", wui.nav.name)
check("progress: one write for a burst of quest events (coalesced)", wui.writes == writes + 1, wui.writes - writes)
check("progress: no clear, no sound, same coordinates and icon", wui.clears == clears and (wui.audible or 0) == audible
  and H.navAt(25) and wui.nav.iconTexture == ICON .. "IncompleteQuest")

-- RestedXP updating its text without a quest event the bridge sees
writes = wui.writes
comp.text = "2/15 Windstone Cluster"
advance(2)
check("progress without a quest event: label check picks it up", wui.nav.name == "2/15 Windstone Cluster" and wui.writes == writes + 1,
  wui.nav.name)
advance(5)
check("unchanged progress: no further writes", wui.writes == writes + 1, wui.writes - writes)

-- Every strategy refreshes it
local count = 2
for _, strategy in ipairs({ "hybrid", "native-first" }) do
  slash("mode " .. strategy); advance(2)
  writes = wui.writes
  count = count + 1
  quests[93552].objectives[1].numFulfilled = count
  comp.text = count .. "/15 Windstone Cluster"
  H.fire("QUEST_LOG_UPDATE"); advance(2)
  check(strategy .. ": progress refreshed in place", wui.nav.name == comp.text and wui.writes == writes + 1 and H.navAt(25),
    wui.nav.name)
end
slash("mode coordinates"); advance(2)

----------------------------------------------------------------------------
-- 3. Manual override is respected
H.setManualWaypoint("My own pin"); advance(1)
writes = wui.writes
comp.text = "9/15 Windstone Cluster"
H.fire("QUEST_LOG_UPDATE"); advance(3)
check("manual override: progress does not replace the player's waypoint", wui.nav.name == "My own pin" and wui.writes == writes)
text = statusText()
check("manual override: status does not call it stale", text:find("Objective label:", 1, true) == nil)
-- RestedXP moves on: the bridge resumes
r[2].skip = true; point(r[3]); advance(2)
check("next RestedXP point: bridge resumes with live label and icon", H.navAt(30) and wui.nav.name == "9/15 Windstone Cluster"
  and wui.nav.iconTexture == ICON .. "IncompleteQuest", wui.nav.name)

----------------------------------------------------------------------------
-- 4. Quest ready (before RestedXP moves on): icon and colour follow the quest state at the same point
quests[93552].ready = true; quests[93552].objectives[1].finished = true
comp.text = "15/15 Windstone Cluster"
H.fire("QUEST_LOG_UPDATE"); advance(2)
check("quest ready: label shows the final progress", wui.nav.name == "15/15 Windstone Cluster" and H.navAt(30), wui.nav.name)
check("quest ready: complete quest icon and normal quest colour", wui.nav.iconTexture == ICON .. "CompleteQuest" and tintIs(255, 255, 156),
  wui.nav.iconTexture)

----------------------------------------------------------------------------
-- 5. Travel waypoints keep the default icon; service icons unaffected
local travel = goto_(65, 0, { text = "Run to the bridge" })
local travelStep = newStep(60, { completewith = "next", sticky = true }, travel)
H.setActiveSteps(travelStep)
point(travel); advance(2)
check("travel waypoint: default icon and colour", wui.nav.name == "Run to the bridge" and wui.nav.iconTexture == nil and wui.nav.r == nil)

local fp = goto_(70, 0)
local fpStep = newStep(61, {}, fp, H.header("Talk to |cRXP_FRIENDLY_Karos|r"), { tag = "fp", text = "Get the Sepulcher flight path" },
  { tag = "fly", text = "Fly to the Undercity" }, { tag = "target", textOnly = true })
H.setActiveSteps(fpStep)
point(fp); advance(2)
check("service waypoint: flight master icon and colour", wui.nav.iconTexture == OWN .. "FlightMaster"
  and tintIs(0x70, 0xD6, 0x5A), wui.nav.iconTexture)

----------------------------------------------------------------------------
-- 6. Preview still works and pauses label refreshes
H.setActiveSteps(step)
r[3].skip = nil; point(r[3]); advance(2)
slash("preview incomplete")
check("preview shown", wui.nav.flags == "RestedXPWaypoint-Preview")
writes = wui.writes
comp.text = "10/15 Windstone Cluster"
H.fire("QUEST_LOG_UPDATE"); advance(3)
check("preview not replaced by a progress update", wui.nav.flags == "RestedXPWaypoint-Preview" and wui.writes == writes)
slash("preview off"); advance(2)
check("preview off: bridge waypoint back with the live label", wui.nav.flags == "RestedXPWaypoint"
  and wui.nav.name == "10/15 Windstone Cluster", wui.nav.name)

H.finish()
