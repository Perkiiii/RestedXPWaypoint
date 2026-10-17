-- RestedXP Waypoint
-- WaypointAdapter: the only file that talks to Waypoint UI.
--
-- Only the documented WaypointUIAPI.Navigation surface (WaypointUI/API.lua)
-- is used. NewUserNavigation expects x/y as 0-100 percentages and returns
-- nil without erroring when it cannot place the destination.
-- GetUserNavigation returns x/y normalised to 0-1.

local addonName, RXPW = ...
local WUI = RXPW.WUI

local WUI_ADDON = "WaypointUI"

-- Tolerance in map percent when comparing Waypoint UI's stored navigation
-- (normalised, then scaled back) against a RestedXP target.
local MATCH_TOLERANCE = 0.001

local RequestsRecolor -- defined with the default icon below

local format = string.format
local type = type
local tostring = tostring
local pcall = pcall
local abs = math.abs

local function GetNavigationAPI()
    local api = type(_G.WaypointUIAPI) == "table" and _G.WaypointUIAPI.Navigation
    if type(api) ~= "table" then return nil end
    return api
end

-- Calls an optional API function safely; returns its first result or nil.
local function SafeCall(api, name, ...)
    local fn = api and api[name]
    if type(fn) ~= "function" then return nil end
    local ok, result = pcall(fn, ...)
    if ok then return result end
    return nil
end

function WUI.GetStatus()
    local loaded = RXPW.IsLoaded(WUI_ADDON)
    local api = GetNavigationAPI()
    return {
        loaded = loaded,
        version = loaded and RXPW.GetVersion(WUI_ADDON) or nil,
        apiAvailable = api ~= nil and type(api.NewUserNavigation) == "function",
    }
end

-- Waypoint UI's own settings page, through its documented
-- WaypointUIAPI.OpenSettingsUI() (API.lua header). Used by the settings panel.
function WUI.CanOpenSettings()
    local api = _G.WaypointUIAPI
    return type(api) == "table" and type(api.OpenSettingsUI) == "function"
end

function WUI.OpenSettings()
    if not WUI.CanOpenSettings() then return false end
    return (pcall(_G.WaypointUIAPI.OpenSettingsUI))
end

-- Returns the current Waypoint UI user navigation (x/y normalised 0-1), or nil.
function WUI.GetNavigation()
    local nav = SafeCall(GetNavigationAPI(), "GetUserNavigation")
    if type(nav) == "table" then return nav end
    return nil
end

-- Value snapshot: session tables can be mutated in place by their owner.
-- Include the native waypoint too, so a raw map pin replacing a stored WUI
-- navigation is observable even before WUI processes its validation event.
function WUI.GetNavigationIdentity()
    local nav = WUI.GetNavigation()
    local session = nav and format("%s|%s|%s|%s|%s|%s", tostring(nav.flags), tostring(nav.name),
        tostring(nav.mapID), tostring(nav.x), tostring(nav.y), tostring(nav.superTracked))
    local ok, mapID, x, y = pcall(function()
        local point = C_Map and C_Map.GetUserWaypoint and C_Map.GetUserWaypoint()
        if point and point.position then return point.uiMapID, point.position.x, point.position.y end
    end)
    local waypoint = ok and mapID and RXPW.IsFiniteNumber(x) and RXPW.IsFiniteNumber(y)
        and format("%s|%s|%s", tostring(mapID), tostring(x), tostring(y)) or nil
    if not session and not waypoint then return nil end
    return tostring(session) .. ";" .. tostring(waypoint), waypoint
end

-- Returns nav, tracked: the user navigation and whether Waypoint UI is
-- actually navigating to it (directly or through a pathfinding step).
local function GetTrackedNavigation()
    local api = GetNavigationAPI()
    local nav = WUI.GetNavigation()
    if not nav then return nil, false end
    local tracked = SafeCall(api, "IsUserNavigationTracked") or SafeCall(api, "IsPathStepWaypointTracked")
    return nav, tracked and true or false
end

-- True when Waypoint UI is already navigating to this target's coordinates
-- via a bridge-owned navigation (the label may still differ).
function WUI.IsShowingTarget(target)
    local nav, tracked = GetTrackedNavigation()
    if not (nav and tracked and nav.flags == RXPW.OWNER_FLAG) then return false end
    if nav.mapID ~= target.mapID then return false end
    if not (RXPW.IsFiniteNumber(nav.x) and RXPW.IsFiniteNumber(nav.y)) then return false end
    return abs(nav.x * 100 - target.x) < MATCH_TOLERANCE and abs(nav.y * 100 - target.y) < MATCH_TOLERANCE
end

-- True when the bridge-owned navigation already shows this target's label
-- (and icon).
function WUI.HasTargetLabel(target)
    local nav = WUI.GetNavigation()
    return nav ~= nil and nav.flags == RXPW.OWNER_FLAG and nav.name == target.label
        and (nav.stripCoordinates == true) == (target.stripCoordinates == true)
        and nav.iconTexture == target.iconTexture
        and nav.iconType == (target.iconTexture and "TEXTURE" or nil)
        and nav.r == (target.tint and target.tint.r) and nav.g == (target.tint and target.tint.g)
        and nav.b == (target.tint and target.tint.b)
        and nav.requestRecolor == RequestsRecolor(target.iconTexture)
end

-- Quest icon for a custom waypoint that carries quest context (v0.5.4).
-- NewUserNavigation's documented iconTexture/iconType options are drawn as the
-- marker's context icon for a tracked custom navigation
-- (Waypoint_DataProvider.GetContextIconForPinData). Waypoint UI's own native
-- quest icons are files it ships in Art\Icons (CompleteQuest /
-- IncompleteQuest for normal quests, see Waypoint_ContextIcon.lua). Those file
-- names are an implementation detail, so they are only used with the Waypoint
-- UI version they were verified against (1.7.x); otherwise no quest icon is
-- set and the bridge's default icon is shown (WUI.ResolveAppearance).
local VERIFIED_ICON_VERSION = "^1%.7%."
local QUEST_ICON_PATH = "Interface\\AddOns\\WaypointUI\\Art\\Icons\\"

-- status: "Available" | "Incomplete" | "Complete" (Waypoint UI's state prefix);
-- iconType: "" or one of the shipped quest types (Campaign, Repeatable, ...),
-- see Nav.GetQuestIconType. Mirrors Waypoint_ContextIcon's "<State><Type>Quest".
local ICON_STATES = { Available = true, Incomplete = true, Complete = true }

-- Waypoint UI's default marker colours (Preload.lua Enum.ColorRGB01, 1.7.x);
-- normal available/ready quests use the quest gold instead (QUEST_GOLD below).
-- A custom navigation with r/g/b is tinted with that colour (frame, text,
-- beam) instead of the "Other" gold (Waypoint.GetTintColorInfo). Waypoint UI
-- then also desaturates and tints the icon (recolor is forced on for custom
-- colours), so the "?" picks up the tint slightly; native quest markers keep
-- the icon's own colours. Custom colours chosen in Waypoint UI's settings are
-- private settings and are not mirrored.
local QUEST_TINTS = {
    IncompleteQuest = { r = 200 / 255, g = 200 / 255, b = 200 / 255 },
    NormalQuest     = { r = 255 / 255, g = 255 / 255, b = 156 / 255 },
    RepeatableQuest = { r = 158 / 255, g = 207 / 255, b = 245 / 255 },
    ImportantQuest  = { r = 249 / 255, g = 196 / 255, b = 255 / 255 },
}

function WUI.GetQuestTint(tintKey)
    local version = RXPW.GetVersion(WUI_ADDON)
    if type(version) ~= "string" or not version:find(VERIFIED_ICON_VERSION) then return nil end
    return QUEST_TINTS[tintKey]
end

-- The bridge's own service icons (Art/Icons, built by tools/build_icons.py in
-- Waypoint UI's glyph style and BLP format). Shipped with this addon, so no
-- Waypoint UI version check is needed.
-- Service colour palette (design spec). Only `primary` reaches the screen:
-- a custom navigation's r/g/b tints Waypoint UI's diamond frame, label and
-- distance text, close-range pinpoint, navigator arrow AND beam
-- (Waypoint.GetTintColorInfo: beamColor = color), and it forces the icon to be
-- desaturated and tinted (recolor = requestRecolor or true; the icons in
-- Art/Icons are stored brightness-only for that, see tools/build_icons.py).
-- `beam`, `highlight` and `shadow` are kept as the reference palette; Waypoint
-- UI's public API has no separate beam colour or highlight/shadow inputs.
local SERVICE_PALETTE = {
    FlightMaster      = { name = "Discovery Green", primary = "70D65A", beam = "7DE968", highlight = "C4FFB2", shadow = "245E37" },
    ClassTrainer      = { name = "Arcane Purple",   primary = "AB79F4", beam = "B58CFA", highlight = "E3C7FF", shadow = "50327A" },
    ProfessionTrainer = { name = "Artisan Copper",  primary = "C57A55", beam = "D78C68", highlight = "F3BC98", shadow = "61362B" },
    FoodAndDrink      = { name = "Tavern Gold",     primary = "F3C24F", beam = "F5D16F", highlight = "FFF0B8", shadow = "78551B" },
    Repair            = { name = "Steel Silver",    primary = "B9C9D5", beam = "D0DDE6", highlight = "FFFFFF", shadow = "425565" },
    Innkeeper         = { name = "Hearth Teal",     primary = "48BECF", beam = "5BD4E1", highlight = "C2F4F9", shadow = "165869" },
    StableMaster      = { name = "Saddle Brown",    primary = "997B59", beam = "B39A76", highlight = "E0CDA9", shadow = "473627" },
    Vendor            = { name = "Merchant Blue",   primary = "4B95E4", beam = "65ADFA", highlight = "B5DDFF", shadow = "214B7B" },
    Grind             = { name = "Combat Red",      primary = "D95451", beam = "ED665E", highlight = "FFB0A5", shadow = "701E29" },
}
SERVICE_PALETTE.Banker = SERVICE_PALETTE.Vendor -- shares the bags icon and Merchant Blue

local function HexColor(hex)
    return {
        r = tonumber(hex:sub(1, 2), 16) / 255,
        g = tonumber(hex:sub(3, 4), 16) / 255,
        b = tonumber(hex:sub(5, 6), 16) / 255,
    }
end

-- Quest gold: the classic WoW quest-marker yellow (NORMAL_FONT_COLOR, #FFD100)
-- for normal available ("!") and ready ("?") quests, instead of Waypoint UI's
-- pale defaults ("Other" #FFF1B4 / NormalQuest #FFFF9C). The colour forces
-- Waypoint UI to desaturate and tint the icon, which turns its own full-colour
-- glyphs a dull mustard, so these two use the bridge's tint-ready copies of
-- those glyphs (Art/Icons/QuestAvailable, QuestComplete: same alpha, brightness
-- only, tools/build_icons.py) and come out full gold, like the service icons.
-- With customColors off no colour is sent, so Waypoint UI's original icons
-- are used and keep their own colours. Quest types (campaign, repeatable, ...)
-- and incomplete quests keep their existing icons and colours.
local QUEST_GOLD = "FFD100"
local QUEST_GOLD_ICONS = { Available = "QuestAvailable", Complete = "QuestComplete" }

local function GoldQuestIcon(status, iconType)
    if RXPW.db and RXPW.db.customColors == false then return nil end
    if iconType ~= nil and iconType ~= "" then return nil end
    return QUEST_GOLD_ICONS[status]
end

-- Marker colour (r/g/b, 0-1) for a service, or nil.
function WUI.GetServiceTint(service)
    local palette = SERVICE_PALETTE[service]
    return palette and HexColor(palette.primary) or nil
end

-- Marker colour and its name for a Nav.GetPresentation result: the service
-- palette's primary, the quest gold, or Waypoint UI's quest colour
-- (GetQuestTint). nil = keep Waypoint UI's default ("Other") colour.
function WUI.GetPresentationTint(presentation)
    if not presentation then return nil end
    if presentation.service then
        local palette = SERVICE_PALETTE[presentation.service]
        if palette then return HexColor(palette.primary), palette.name end
        return nil
    end
    if GoldQuestIcon(presentation.status, presentation.iconType) then return HexColor(QUEST_GOLD), "QuestGold" end
    local tint = presentation.tintKey and WUI.GetQuestTint(presentation.tintKey)
    return tint, tint and presentation.tintKey or nil
end

-- Palette entry (name and hex values) for diagnostics, or nil.
function WUI.GetServicePalette(service)
    return SERVICE_PALETTE[service]
end

-- service -> icon file (the general vendor and the banker share the bags icon)
local SERVICE_ICONS = {
    FlightMaster = "FlightMaster", ClassTrainer = "ClassTrainer", ProfessionTrainer = "ProfessionTrainer",
    FoodAndDrink = "FoodAndDrink", Repair = "Repair", Innkeeper = "Innkeeper", StableMaster = "StableMaster",
    Vendor = "Bags", Banker = "Bags", Grind = "Grind",
}

local OWN_ICON_PATH = "Interface\\AddOns\\" .. addonName .. "\\Art\\Icons\\"

function WUI.GetServiceIcon(service)
    local file = SERVICE_ICONS[service]
    if not file then return nil end
    return OWN_ICON_PATH .. file
end

-- The bridge's own default marker icon (the logo's arrow), for a RestedXP
-- coordinate waypoint without a quest or service icon. Stored brightness-only
-- like the service icons, and sent without r/g/b but with the documented
-- requestRecolor option: Waypoint UI then desaturates it and colours it with
-- its own custom-waypoint colour ("Other", or the player's choice in Waypoint
-- UI), the same colour as the marker frame, text and beam
-- (Waypoint.GetTintColorInfo, MapPinFrame GetTintColor), exactly as it does
-- for its own generic navigation icon.
local DEFAULT_ICON = "DefaultWaypoint"

function WUI.GetDefaultIcon()
    return OWN_ICON_PATH .. DEFAULT_ICON
end

-- requestRecolor for an icon: only the default icon asks for it. (Coloured
-- icons are recoloured anyway; quest icons without a colour keep theirs.)
function RequestsRecolor(iconTexture)
    if iconTexture ~= nil and iconTexture == WUI.GetDefaultIcon() then return true end
    return nil
end

-- Icon path and display name for a Nav.GetPresentation result (quest or service).
function WUI.GetPresentationIcon(presentation)
    if not presentation then return nil end
    if presentation.service then
        local icon = WUI.GetServiceIcon(presentation.service)
        return icon, icon and presentation.service or nil
    end
    local icon = WUI.GetQuestIcon(presentation.status, presentation.iconType)
    return icon, icon and (presentation.status .. (presentation.iconType or "") .. "Quest") or nil
end

-- What the bridge supplies for a presentation, after the appearance settings
-- (v0.6.0). Returns iconTexture, iconName, tint, tintName (any may be nil).
--   no quest or service icon (travel and other steps, or a quest icon this
--     Waypoint UI version cannot show): the bridge's DefaultWaypoint icon, no
--     r/g/b; SetNavigation adds requestRecolor, so Waypoint UI tints it with
--     the marker's own colour. No setting turns it off; the settings below
--     only concern recognised quest and service destinations.
--   questIcons / serviceIcons off: no iconTexture, so Waypoint UI draws its own
--     generic custom-navigation icon (Art\Icons\Navigation, recoloured with
--     the marker colour; Waypoint_DataProvider.GetContextIconTextureForOtherPinType).
--   customColors off: no r/g/b, so Waypoint UI uses its "Other" colour (or the
--     player's own Waypoint UI colour settings) for frame, text and beam, and
--     a supplied icon keeps its own colours.
-- The colour still belongs only to recognised destinations that have a
-- shippable icon (as since v0.5.5), whether or not that icon is shown.
function WUI.ResolveAppearance(presentation)
    local db = RXPW.db
    local icon, iconName = WUI.GetPresentationIcon(presentation)
    if not icon then return WUI.GetDefaultIcon(), DEFAULT_ICON, nil, nil end
    local tint, tintName
    if db.customColors ~= false then
        tint, tintName = WUI.GetPresentationTint(presentation)
    end
    local allowed
    if presentation.service then allowed = db.serviceIcons ~= false else allowed = db.questIcons ~= false end
    if not allowed then icon, iconName = nil, nil end
    return icon, iconName, tint, tintName
end

-- The settings page draws Waypoint UI 1.7.x's own settings artwork, read from
-- the installed addon by file path (never bundled); other versions get the
-- page's flat colours, since the texture layout may differ.
function WUI.HasVerifiedArt()
    local version = RXPW.GetVersion(WUI_ADDON)
    return RXPW.IsLoaded(WUI_ADDON) and type(version) == "string" and version:find(VERIFIED_ICON_VERSION) ~= nil
end

function WUI.GetQuestIcon(status, iconType)
    local version = RXPW.GetVersion(WUI_ADDON)
    if type(version) ~= "string" or not version:find(VERIFIED_ICON_VERSION) then return nil end
    if not ICON_STATES[status] then return nil end
    local gold = GoldQuestIcon(status, iconType)
    if gold then return OWN_ICON_PATH .. gold end
    return QUEST_ICON_PATH .. status .. (type(iconType) == "string" and iconType or "") .. "Quest"
end

-- True when Waypoint UI is following a bridge-owned custom navigation.
function WUI.IsOwnedNavigationTracked()
    local nav, tracked = GetTrackedNavigation()
    return nav ~= nil and tracked and nav.flags == RXPW.OWNER_FLAG
end

-- Removes the bridge's own custom navigation (never anyone else's).
-- ClearUserNavigation(false, true): also remove the native user waypoint
-- it created, and do not advance Waypoint UI's multi-pin queue.
-- Note: Waypoint UI reacts to the removed native waypoint with
-- C_SuperTrack.ClearAllSuperTracked() (MapPin.lua USER_WAYPOINT_UPDATED
-- handler) when the waypoint was supertracked, so callers must set any new
-- supertracking AFTER that has run, not before. Returns true if cleared.
function WUI.ClearOwnedNavigation()
    return WUI.ClearNavigationWithFlag(RXPW.OWNER_FLAG)
end

-- True when Waypoint UI's current custom navigation carries exactly this flag,
-- tracked or not. Waypoint UI saves its navigation (flags included) per
-- character and restores it on load without re-applying it, so this also
-- recognises a navigation created before /reload. Uses the documented
-- IsUserNavigationFlagged and requires the stored table to agree.
function WUI.HasNavigationWithFlag(flag)
    if type(flag) ~= "string" then return false end
    local api = GetNavigationAPI()
    local nav = WUI.GetNavigation()
    if not (nav and nav.flags == flag) then return false end
    if type(api.IsUserNavigationFlagged) == "function" then
        return SafeCall(api, "IsUserNavigationFlagged", flag) == true
    end
    return true
end

-- Removes the current custom navigation only if it carries this flag
-- (e.g. the preview marker). Returns true if cleared.
function WUI.ClearNavigationWithFlag(flag)
    local api = GetNavigationAPI()
    if not api or type(api.ClearUserNavigation) ~= "function" then return false end
    if not WUI.HasNavigationWithFlag(flag) then return false end
    local ok = pcall(api.ClearUserNavigation, false, true)
    return ok
end

-- Retire only an inactive owned session. Preserve the native waypoint even
-- when it happens to share coordinates: historical marker ownership is not
-- permission to delete a raw Blizzard pin. suppressAdvance also prevents WUI's
-- path destination-clear callback (verified in 1.7.3), not just queue advance.
function WUI.RetireInactiveNavigation(expected)
    local api = GetNavigationAPI()
    if not api or type(api.ClearUserNavigation) ~= "function" then return false, "cleanup API unavailable" end
    if type(api.IsUserNavigationFlagged) ~= "function" then return false, "ownership API unavailable" end
    if not WUI.HasNavigationWithFlag(RXPW.OWNER_FLAG) then return false, "marker ownership changed" end
    if WUI.GetNavigation() ~= expected then return false, "stored marker changed" end
    if WUI.IsOwnedNavigationTracked() then return false, "bridge marker is actively followed" end
    local ok = pcall(api.ClearUserNavigation, true, true)
    if not ok then return false, "cleanup API failed" end
    if WUI.GetNavigation() == expected then return false, "marker retained by Waypoint UI" end
    return true, "stored marker removed; native waypoint and external tracking preserved"
end

-- Name of a tracked navigation that the bridge did not create, or nil.
function WUI.GetForeignNavigationName()
    local nav, tracked = GetTrackedNavigation()
    if nav and tracked and nav.flags ~= RXPW.OWNER_FLAG then
        return tostring(nav.name or "unnamed waypoint")
    end
    -- A raw Blizzard pin can replace WUI's native waypoint while its stored
    -- session still belongs to us. Ownership of that stale session is not
    -- ownership of the currently tracked pin. Path steps above remain owned.
    local _, priority = RXPW.Nav.GetTrackingState()
    local userType = Enum and Enum.SuperTrackingType and Enum.SuperTrackingType.UserWaypoint
    if userType ~= nil and priority == userType and not (nav and tracked) then
        local _, waypoint = WUI.GetNavigationIdentity()
        if waypoint then return "user waypoint" end
    end
    return nil
end

-- Describes what Waypoint UI is following when it is NOT the bridge's
-- navigation; returns nil while the bridge's navigation is being followed.
-- expectedQuestID: in native quest mode, that quest being supertracked counts
-- as the bridge's navigation, whoever set it (RestedXP sets it too).
function WUI.DescribeOutsideNavigation(expectedQuestID)
    if expectedQuestID and RXPW.Nav.IsNativeQuestActive(expectedQuestID) then
        return nil
    end

    local nav, tracked = GetTrackedNavigation()
    if nav and tracked then
        if nav.flags == RXPW.OWNER_FLAG then return nil end
        return format("another waypoint is tracked (%s)", tostring(nav.name or "unnamed"))
    end

    local questID = RXPW.Nav.GetSuperTrackedQuest()
    if questID then
        return format("quest %d is supertracked", questID)
    end
    if expectedQuestID then
        return "bridge quest is no longer supertracked (turned in or cleared)"
    end
    return "bridge waypoint is no longer tracked (cleared or arrived)"
end

-- Returns true on success, or false plus a reason.
-- Calling this again with the same coordinates keeps the destination:
-- Waypoint UI skips C_Map.SetUserWaypoint when the native waypoint already
-- matches (MapPin.NewUserNavigation). It is still a new navigation to Waypoint
-- UI (1.7.3, verified in source): MapPin.NewUserNavigation always fires, the
-- Waypoint_Director resets and replays the marker's intro (and show sound),
-- and with pathfinding enabled the path is rebuilt and its step waypoint
-- recreated. There is no public rename API, so Sync limits how often a
-- same-destination presentation update is sent (PRESENTATION_MIN_INTERVAL).
-- suppressAudio controls only MapPin's new-navigation sound, not those intros.
-- stripCoordinates (documented option) hides the coordinate line under the name.
function WUI.SetNavigation(target, suppressAudio)
    local api = GetNavigationAPI()
    if not api or type(api.NewUserNavigation) ~= "function" then
        return false, "WaypointUIAPI.Navigation.NewUserNavigation is unavailable"
    end

    local ok, result = pcall(api.NewUserNavigation, {
        name = target.label or "RestedXP",
        mapID = target.mapID,
        x = target.x,
        y = target.y,
        flags = target.flags or RXPW.OWNER_FLAG, -- target.flags: preview marker
        suppressAudio = suppressAudio and true or false,
        stripCoordinates = target.stripCoordinates and true or false,
        iconTexture = target.iconTexture,
        iconType = target.iconTexture and "TEXTURE" or nil,
        requestRecolor = RequestsRecolor(target.iconTexture),
        r = target.tint and target.tint.r or nil,
        g = target.tint and target.tint.g or nil,
        b = target.tint and target.tint.b or nil,
    })

    if not ok then
        return false, "Waypoint UI raised an error: " .. tostring(result)
    end
    if not result then
        return false, "Waypoint UI rejected the destination"
    end
    return true
end
