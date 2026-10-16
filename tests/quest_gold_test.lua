-- Regression tests for the quest gold: normal available ("!") and ready ("?")
-- quest waypoints use the classic WoW quest yellow #FFD100 for the marker
-- (frame, text, beam) and the bridge's tint-ready copies of Waypoint UI's
-- glyphs (Art/Icons/QuestAvailable, QuestComplete), so the tinted glyph is
-- full gold. Quest types, incomplete quests, services and the default icon
-- keep their colours; with Custom Colours off Waypoint UI's own icons are used.
-- Mocked APIs; not proof of in-game behaviour.
local H = dofile(ADDON_ROOT .. "/tests/harness.lua")
H.verbose = true
local check, advance, point, newStep, goto_ = H.check, H.advance, H.point, H.newStep, H.goto_
local quests, wui = H.quests, H.wui

Enum.QuestClassification = { Important = 0, Legendary = 1, Campaign = 2, Calling = 3, Meta = 4, Recurring = 5, Questline = 6, Normal = 7 }
local classification = {}
C_QuestInfoSystem = { GetQuestClassification = function(q) return classification[q] or Enum.QuestClassification.Normal end }
C_Map.GetBestMapForUnit = function() return 1421 end
C_Map.GetPlayerMapPosition = function() return { GetXY = function() return 0.5, 0.5 end } end
function GetPlayerFacing() return 0 end

local RXPW = H.load(ADDON_ROOT, { debug = true, strategy = "coordinates" })
local slash = H.slash
local Config = RXPW.Config
local OWN = "Interface\\AddOns\\RestedXPWaypoint\\Art\\Icons\\"
local WUI_ICON = "Interface\\AddOns\\WaypointUI\\Art\\Icons\\"

local function tintIs(r, g, b)
  local n = wui.nav
  return n and n.r and math.abs(n.r - r / 255) < 1e-6 and math.abs(n.g - g / 255) < 1e-6 and math.abs(n.b - b / 255) < 1e-6
end
local function gold() return tintIs(255, 209, 0) end
local function visit(index, dist, ...)
  local g = goto_(dist, 0)
  H.setActiveSteps(newStep(index, {}, g, ...)); point(g); advance(2)
end

----------------------------------------------------------------------------
-- 1. Available "!" and ready "?": gold marker, tint-ready glyph
visit(1, 20, H.header("Talk to Dalia"), H.accept(500, "Harvesting More"))
check("available quest: tint-ready ! icon", wui.nav.iconTexture == OWN .. "QuestAvailable", wui.nav.iconTexture)
check("available quest: quest gold #FFD100 (was Waypoint UI's pale 'Other')", gold())
check("available quest: label unchanged", wui.nav.name == "Accept Harvesting More", wui.nav.name)

quests[501] = { title = "Turn It In", ready = true, poi = 50 }
visit(2, 30, H.header("Talk to Rorian"), H.turnin(501, "Turn It In"))
check("ready quest: tint-ready ? icon", wui.nav.iconTexture == OWN .. "QuestComplete", wui.nav.iconTexture)
check("ready quest: quest gold #FFD100 (was #FFFF9C)", gold())
check("no tint request needed (r/g/b already recolours)", wui.nav.requestRecolor == nil)
local text = (function() local b = #H.chat; slash("status"); return table.concat(H.chat, "\n", b + 1) end)()
check("status names the colour and texture", text:find("colour: QuestGold", 1, true) ~= nil
  and text:find("Marker texture: " .. OWN .. "QuestComplete", 1, true) ~= nil, text)

----------------------------------------------------------------------------
-- 2. Everything else keeps its colours and Waypoint UI's icons
quests[502] = { title = "Still Working", ready = false, poi = 52, objectives = { { type = "monster", finished = false, numFulfilled = 0, numRequired = 5 } } }
visit(3, 40, H.header("Kill boars"), H.complete(502, 1))
check("incomplete quest unchanged: silver ? and #C8C8C8", wui.nav.iconTexture == WUI_ICON .. "IncompleteQuest" and tintIs(200, 200, 200))

classification[503] = Enum.QuestClassification.Campaign
quests[503] = { title = "Campaign Done", ready = true, poi = 53 }
visit(4, 50, H.header("Talk to the general"), H.turnin(503, "Campaign Done"))
check("campaign turn-in unchanged: Waypoint UI icon and #FFFF9C", wui.nav.iconTexture == WUI_ICON .. "CompleteCampaignQuest"
  and tintIs(255, 255, 156), wui.nav.iconTexture)

classification[504] = Enum.QuestClassification.Recurring
quests[504] = { title = "Daily Done", ready = true, poi = 54 }
visit(5, 60, H.header("Talk to the quartermaster"), H.turnin(504, "Daily Done"))
check("recurring turn-in unchanged: Waypoint UI icon and blue", wui.nav.iconTexture == WUI_ICON .. "CompleteRecurringQuest"
  and tintIs(158, 207, 245), wui.nav.iconTexture)

classification[505] = Enum.QuestClassification.Important
visit(6, 70, H.header("Talk to the herald"), H.accept(505, "Important Offer"))
check("important available unchanged: Waypoint UI icon, no colour", wui.nav.iconTexture == WUI_ICON .. "AvailableImportantQuest"
  and wui.nav.r == nil, wui.nav.iconTexture)

visit(7, 80, { tag = "fp", text = "Get the flight path" })
check("service unchanged: flight master green", wui.nav.iconTexture == OWN .. "FlightMaster" and tintIs(0x70, 0xD6, 0x5A))

----------------------------------------------------------------------------
-- 3. Appearance settings
visit(2, 30, H.header("Talk to Rorian"), H.turnin(501, "Turn It In"))
local writes = wui.writes
Config.Set("customColors", false); advance(3)
check("colours off: Waypoint UI's own ? (keeps its colours), no r/g/b, one silent update",
  wui.nav.iconTexture == WUI_ICON .. "CompleteQuest" and wui.nav.r == nil and wui.writes == writes + 1 and H.navAt(30))
Config.Set("customColors", true); advance(3)
check("colours on again: gold and the tint-ready ?", wui.nav.iconTexture == OWN .. "QuestComplete" and gold())
Config.Set("questIcons", false); advance(3)
check("quest icons off: Waypoint UI generic icon, gold marker", wui.nav.iconTexture == nil and gold())
Config.Set("questIcons", true); advance(3)

-- Native quest tracking is Waypoint UI's own marker: no bridge colour involved.
slash("mode hybrid"); advance(2)
check("hybrid turn-in goes native (Blizzard marker, untouched)", H.mode() == "native")
slash("mode coordinates"); advance(2)

----------------------------------------------------------------------------
-- 4. Preview and settings swatch
slash("preview available")
check("preview available: tint-ready ! in quest gold", wui.nav.iconTexture == OWN .. "QuestAvailable" and gold())
slash("preview complete")
check("preview complete: tint-ready ? in quest gold", wui.nav.iconTexture == OWN .. "QuestComplete" and gold())
local art, tint = RXPW.Preview.GetEntryArt("available")
check("swatch art: tint-ready ! with the gold", art == OWN .. "QuestAvailable" and tint and math.abs(tint.g - 209 / 255) < 1e-6)
Config.Set("customColors", false)
art = RXPW.Preview.GetEntryArt("available")
check("swatch art with colours off: Waypoint UI's own !", art == WUI_ICON .. "AvailableQuest", art)
Config.Set("customColors", true)
slash("preview off")

H.finish()
