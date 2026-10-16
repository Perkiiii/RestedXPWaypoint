-- Tests for /rxpw preview (in-game icon testing). Mocked APIs; not proof of
-- in-game behaviour. Run with: node tests/run.js
local H = dofile(ADDON_ROOT .. "/tests/harness.lua")
H.verbose = true
local check, advance, point, newStep, goto_ = H.check, H.advance, H.point, H.newStep, H.goto_
local wui = H.wui

-- Player on map 1421 at 50%, 50%, facing north (0 rad).
local facing = 0
C_Map.GetBestMapForUnit = function() return 1421 end
C_Map.GetPlayerMapPosition = function() return { GetXY = function() return 0.5, 0.5 end } end
function GetPlayerFacing() return facing end

local RXPW = H.load(ADDON_ROOT, { debug = true, strategy = "native-first" })
local slash = H.slash
local OWN = "Interface\\AddOns\\RestedXPWaypoint\\Art\\Icons\\"
local WUIICON = "Interface\\AddOns\\WaypointUI\\Art\\Icons\\"

-- A normal RestedXP coordinate waypoint first
local g = goto_(40, 0, { text = "Run to the bridge" })
H.setActiveSteps(newStep(1, {}, g)); point(g); advance(2)
check("bridge waypoint before the preview", wui.nav.flags == "RestedXPWaypoint" and wui.nav.name == "Run to the bridge")

slash("preview")
check("usage lists the names", H.lastChat("names: available, incomplete, complete, flightmaster") ~= nil)

slash("preview flightmaster")
check("preview marker placed with the flight master icon", wui.nav.flags == "RestedXPWaypoint-Preview"
  and wui.nav.iconTexture == OWN .. "FlightMaster" and wui.nav.name == "Preview: Flight master" and wui.nav.stripCoordinates == true)
check("preview uses the service colour (Discovery Green)", wui.nav.r and math.abs(wui.nav.r - 0x70 / 255) < 1e-6
  and math.abs(wui.nav.g - 0xD6 / 255) < 1e-6 and math.abs(wui.nav.b - 0x5A / 255) < 1e-6)
check("placed ahead of the player (north = smaller y)", math.abs(wui.nav.x - 0.5) < 1e-6 and wui.nav.y < 0.5 and wui.nav.y > 0.49)
check("automatic sync paused", RXPW.Sync.GetState().running == false and RXPWDB.autoSync == true)

-- RestedXP moving on does not replace the preview while it is shown
local g2 = goto_(60, 0, { text = "Somewhere else" })
H.setActiveSteps(newStep(2, {}, g2)); point(g2); advance(2)
check("preview not replaced by RestedXP", wui.nav.flags == "RestedXPWaypoint-Preview")

facing = math.pi / 2 -- west
slash("preview incomplete")
check("quest preview: incomplete icon with the quest colour", wui.nav.iconTexture == WUIICON .. "IncompleteQuest"
  and wui.nav.r and math.abs(wui.nav.r - 200 / 255) < 1e-6)
check("placed ahead when facing west (smaller x)", wui.nav.x < 0.5 and math.abs(wui.nav.y - 0.5) < 1e-6)

slash("preview next")
check("next: complete quest icon", wui.nav.iconTexture == OWN .. "QuestComplete")

slash("preview all")
check("cycle starts at the first icon", wui.nav.iconTexture == OWN .. "QuestAvailable")
local seen = { [wui.nav.iconTexture or "none"] = true }
for i = 1, 14 do advance(4); seen[wui.nav.iconTexture or "none"] = true end
check("cycle shows every service icon", seen[OWN .. "Grind"] and seen[OWN .. "Bags"] and seen[OWN .. "Innkeeper"]
  and seen[OWN .. "StableMaster"] and seen[OWN .. "Repair"] and seen[OWN .. "DefaultWaypoint"] and not seen["none"])
check("cycle ends", H.lastChat("Preview cycle finished") ~= nil)

-- Close vs far: far is 300% further away (4x the close distance)
facing = 0
slash("preview all close")
local closeY = wui.nav.y
check("preview all close: first icon, close by", wui.nav.iconTexture == OWN .. "QuestAvailable" and math.abs(closeY - (0.5 - 0.008)) < 1e-6, closeY)
slash("preview all far")
local farY = wui.nav.y
check("preview all far: first icon, 4x as far", wui.nav.iconTexture == OWN .. "QuestAvailable" and math.abs(farY - (0.5 - 0.032)) < 1e-6, farY)
check("far cycle keeps the far distance", (function() advance(4); return math.abs(wui.nav.y - (0.5 - 0.032)) < 1e-6 and wui.nav.iconTexture == WUIICON .. "IncompleteQuest" end)())
check("cycle messages show the distance", H.lastChat("Preview 2/14 %(far%): Quest in progress") ~= nil)
slash("preview next")
check("next keeps the last distance (far)", math.abs(wui.nav.y - (0.5 - 0.032)) < 1e-6 and wui.nav.iconTexture == OWN .. "QuestComplete")
slash("preview grind close")
check("single icon close", wui.nav.iconTexture:find("Grind$") and math.abs(wui.nav.y - (0.5 - 0.008)) < 1e-6)
slash("preview far grind")
check("word order does not matter", wui.nav.iconTexture:find("Grind$") and math.abs(wui.nav.y - (0.5 - 0.032)) < 1e-6)
slash("preview all far extra")
check("extra words are explained", H.lastChat("Unexpected \"extra\"") ~= nil)

slash("preview bogus")
check("unknown name explained", H.lastChat("Unknown preview \"bogus\"") ~= nil)

slash("preview off")
check("preview off removes the marker and resumes sync", H.lastChat("automatic sync resumed") ~= nil and RXPW.Sync.GetState().running == true)
advance(2)
check("bridge navigation restored for RestedXP's current waypoint", wui.nav and wui.nav.flags == "RestedXPWaypoint"
  and wui.nav.name == "Somewhere else", wui.nav and wui.nav.name)

-- Preview with automatic sync off: stays off afterwards
slash("off")
slash("preview repair")
check("preview works with auto sync off", wui.nav.iconTexture == OWN .. "Repair")
slash("preview off")
check("auto sync stays off", RXPW.Sync.GetState().running == false and H.lastChat("Preview removed%.") ~= nil)

-- No position (instance): explained, nothing written
C_Map.GetBestMapForUnit = function() return nil end
local writes = wui.writes
slash("preview grind")
check("no position: explained, no write", wui.writes == writes and H.lastChat("needs your position") ~= nil)

H.finish()
