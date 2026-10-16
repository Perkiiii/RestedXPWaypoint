-- Regression tests for the DefaultWaypoint marker icon: RestedXP coordinate
-- waypoints without quest or service context show the bridge's own icon
-- (Art/Icons/DefaultWaypoint, brightness-only) instead of Waypoint UI's generic
-- custom-navigation icon. It is sent without r/g/b and with requestRecolor, so
-- Waypoint UI tints it with the marker's own colour, like its generic icon. Quest and service
-- icons keep priority; the appearance settings keep their meaning; navigation,
-- labels, writes and audio are unchanged. Mocked APIs; not proof of in-game behaviour.
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
local Config = RXPW.Config
local OWN = "Interface\\AddOns\\RestedXPWaypoint\\Art\\Icons\\"
local DEFAULT_ICON = OWN .. "DefaultWaypoint"
local WUI_ICON = "Interface\\AddOns\\WaypointUI\\Art\\Icons\\"

local function uncoloured() return wui.nav.r == nil and wui.nav.g == nil and wui.nav.b == nil end
-- The default icon's contract: no r/g/b of its own, tinted by Waypoint UI.
local function markerTinted() return uncoloured() and wui.nav.requestRecolor == true end
local function statusText()
  local before = #H.chat
  slash("status")
  return table.concat(H.chat, "\n", before + 1)
end

check("same path convention as the service icons", RXPW.WUI.GetDefaultIcon() == DEFAULT_ICON
  and RXPW.WUI.GetServiceIcon("FlightMaster") == OWN .. "FlightMaster")

----------------------------------------------------------------------------
-- 1. Travel waypoint: default icon, no colour, RestedXP's label, one quiet write
local travel = goto_(40, 0, { text = "Run to the bridge" })
H.setActiveSteps(newStep(10, {}, travel))
point(travel); advance(2)
check("travel waypoint: DefaultWaypoint icon", H.mode() == "coordinates" and wui.nav.flags == "RestedXPWaypoint"
  and wui.nav.iconTexture == DEFAULT_ICON and wui.nav.iconType == "TEXTURE", wui.nav.iconTexture)
check("travel waypoint: no r/g/b, requestRecolor (tinted with the marker colour)", markerTinted())
check("travel waypoint: label and coordinates unchanged", wui.nav.name == "Run to the bridge" and H.navAt(40))
check("travel waypoint: one quiet write", wui.writes == 1 and wui.nav.suppressAudio == true)
check("default icon logged", H.lastChat("icon DefaultWaypoint %(no quest or service context%)") ~= nil)

local text = statusText()
check("status: default category and texture, no Lua error", text:find("Marker icon: default (travel or other) | DefaultWaypoint", 1, true) ~= nil
  and text:find("Marker texture: " .. DEFAULT_ICON, 1, true) ~= nil and text:find("set by RestedXP Waypoint, custom icon", 1, true) ~= nil, text)

-- Re-evaluation of the unchanged destination writes nothing
local writes = wui.writes
H.fire("QUEST_LOG_UPDATE"); advance(2)
RXPW.Sync.SyncNow(); advance(1)
check("unchanged default destination is not rewritten", wui.writes == writes + 1 and wui.nav.iconTexture == DEFAULT_ICON)
writes = wui.writes
H.fire("QUEST_LOG_UPDATE"); advance(2)
check("no further writes after a manual sync", wui.writes == writes)

----------------------------------------------------------------------------
-- 2. Quest and service icons keep priority
quests[700] = { title = "Crystals", ready = false, poi = 70,
  objectives = { { type = "object", finished = false, numFulfilled = 1, numRequired = 15 } } }
local q = goto_(50, 0)
H.setActiveSteps(newStep(11, {}, q, H.header("Click on the Crystals"), H.complete(700, 1)))
point(q); advance(2)
check("quest step: quest icon, not the default icon", wui.nav.iconTexture == WUI_ICON .. "IncompleteQuest" and wui.nav.r ~= nil
  and wui.nav.requestRecolor == nil, wui.nav.iconTexture)

local fp = goto_(60, 0)
H.setActiveSteps(newStep(12, {}, fp, { tag = "fp", text = "Get the flight path" }))
point(fp); advance(2)
check("service step: service icon, not the default icon", wui.nav.iconTexture == OWN .. "FlightMaster" and wui.nav.r ~= nil
  and wui.nav.requestRecolor == nil, wui.nav.iconTexture)

----------------------------------------------------------------------------
-- 3. Appearance settings keep their meaning
-- Quest / service icons off: those destinations get Waypoint UI's generic icon
-- (as documented), not the default icon.
Config.Set("serviceIcons", false); advance(3)
check("service icons off: Waypoint UI generic icon, palette kept", wui.nav.iconTexture == nil and wui.nav.r ~= nil
  and wui.nav.requestRecolor == nil)
Config.Set("serviceIcons", true); advance(3)
H.setActiveSteps(newStep(11, {}, q, H.header("Click on the Crystals"), H.complete(700, 1)))
point(q); advance(3)
Config.Set("questIcons", false); advance(3)
check("quest icons off: Waypoint UI generic icon, quest colour kept", wui.nav.iconTexture == nil and wui.nav.r ~= nil)

-- The default icon itself is not affected by any of the three settings.
H.setActiveSteps(newStep(10, {}, travel)); point(travel); advance(3)
check("quest icons off: travel still has the default icon", wui.nav.iconTexture == DEFAULT_ICON and markerTinted())
Config.Set("serviceIcons", false); Config.Set("customColors", false); advance(3)
check("all appearance settings off: travel still has the default icon, tinted by Waypoint UI",
  wui.nav.iconTexture == DEFAULT_ICON and markerTinted())
writes = wui.writes
Config.Set("customColors", true); advance(3)
check("colours on again: no write for the default destination (its colour is Waypoint UI's)", wui.writes == writes)
Config.RestoreDefaults(); advance(3)
check("defaults restored: default icon unchanged", wui.nav.iconTexture == DEFAULT_ICON and markerTinted())
Config.Set("debug", true) -- Restore Defaults also turned debug messages off

----------------------------------------------------------------------------
-- 4. Session from an older version (no icon): one silent same-destination update
local before = H.countChat("Label/icon changed")
wui.nav.iconTexture, wui.nav.iconType = nil, nil
writes = wui.writes
H.fire("QUEST_LOG_UPDATE"); advance(3)
check("restored marker without icon: one silent icon update in place", wui.writes == writes + 1
  and wui.nav.iconTexture == DEFAULT_ICON and markerTinted() and H.navAt(40) and wui.nav.suppressAudio == true
  and H.countChat("Label/icon changed") == before + 1)
-- The first DefaultWaypoint build sent the icon without requestRecolor.
wui.nav.requestRecolor = nil
writes = wui.writes
H.fire("QUEST_LOG_UPDATE"); advance(3)
check("marker from the untinted build: one silent update adds the tint request", wui.writes == writes + 1
  and markerTinted() and H.navAt(40) and wui.nav.suppressAudio == true)
writes = wui.writes
H.fire("QUEST_LOG_UPDATE"); advance(3)
check("then stable: no further writes", wui.writes == writes)

----------------------------------------------------------------------------
-- 5. Player-created and other addons' navigation are never given the icon
H.setManualWaypoint("Player pin")
local other = goto_(70, 0, { text = "Next stop" })
H.setActiveSteps(newStep(13, {}, other)); point(other); advance(3)
check("manual waypoint kept, no icon or tint request added", wui.nav.name == "Player pin" and wui.nav.flags == nil
  and wui.nav.iconTexture == nil and wui.nav.requestRecolor == nil)

----------------------------------------------------------------------------
-- 6. Preview: "default" shows the default icon, uncoloured, with the preview flag
slash("preview default")
check("preview default: DefaultWaypoint icon", wui.nav.flags == "RestedXPWaypoint-Preview"
  and wui.nav.iconTexture == DEFAULT_ICON and markerTinted() and wui.nav.name == "Preview: Default waypoint", wui.nav.iconTexture)
local art, tint = RXPW.Preview.GetEntryArt("default")
check("preview art for the settings swatch: default icon, no colour", art == DEFAULT_ICON and tint == nil)
check("preview of a service still uses its own art", RXPW.Preview.GetEntryArt("innkeeper") == OWN .. "Innkeeper")
H.versions.WaypointUI = "1.8.0"
slash("preview incomplete")
check("preview of a quest icon this Waypoint UI cannot show: default icon, with a note",
  wui.nav.iconTexture == DEFAULT_ICON and H.lastChat("icon unavailable") ~= nil, wui.nav.iconTexture)
H.versions.WaypointUI = "1.7.3"
slash("preview off")

H.finish()
