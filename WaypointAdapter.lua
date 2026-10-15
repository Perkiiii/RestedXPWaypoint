-- RXP Waypoint Bridge
-- WaypointAdapter: the only file that talks to Waypoint UI.
--
-- Only the documented WaypointUIAPI.Navigation surface (WaypointUI/API.lua)
-- is used. NewUserNavigation expects x/y as 0-100 percentages and returns
-- nil without erroring when it cannot place the destination.
-- GetUserNavigation returns x/y normalised to 0-1.

local _, ns = ...
local WUI = ns.WUI

local WUI_ADDON = "WaypointUI"

-- Tolerance in map percent when comparing Waypoint UI's stored navigation
-- (normalised, then scaled back) against a RestedXP target.
local MATCH_TOLERANCE = 0.001

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
    local loaded = ns.IsLoaded(WUI_ADDON)
    local api = GetNavigationAPI()
    return {
        loaded = loaded,
        version = loaded and ns.GetVersion(WUI_ADDON) or nil,
        apiAvailable = api ~= nil and type(api.NewUserNavigation) == "function",
    }
end

-- Returns the current Waypoint UI user navigation (x/y normalised 0-1), or nil.
function WUI.GetNavigation()
    local nav = SafeCall(GetNavigationAPI(), "GetUserNavigation")
    if type(nav) == "table" then return nav end
    return nil
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
    if not (nav and tracked and nav.flags == ns.OWNER_FLAG) then return false end
    if nav.mapID ~= target.mapID then return false end
    if not (ns.IsFiniteNumber(nav.x) and ns.IsFiniteNumber(nav.y)) then return false end
    return abs(nav.x * 100 - target.x) < MATCH_TOLERANCE and abs(nav.y * 100 - target.y) < MATCH_TOLERANCE
end

-- True when the bridge-owned navigation already shows this target's label
-- (and icon).
function WUI.HasTargetLabel(target)
    local nav = WUI.GetNavigation()
    return nav ~= nil and nav.flags == ns.OWNER_FLAG and nav.name == target.label
        and (nav.stripCoordinates == true) == (target.stripCoordinates == true)
        and nav.iconTexture == target.iconTexture
end

-- Quest icon for a custom waypoint that carries quest context (v0.5.4).
-- NewUserNavigation's documented iconTexture/iconType options are drawn as the
-- marker's context icon for a tracked custom navigation
-- (Waypoint_DataProvider.GetContextIconForPinData). Waypoint UI's own native
-- quest icons are files it ships in Art\Icons (CompleteQuest /
-- IncompleteQuest for normal quests, see Waypoint_ContextIcon.lua). Those file
-- names are an implementation detail, so they are only used with the Waypoint
-- UI version they were verified against (1.7.x); otherwise no icon is set and
-- Waypoint UI keeps its default custom-waypoint icon.
local VERIFIED_ICON_VERSION = "^1%.7%."
local QUEST_ICON_PATH = "Interface\\AddOns\\WaypointUI\\Art\\Icons\\"

function WUI.GetQuestIcon(ready)
    local version = ns.GetVersion(WUI_ADDON)
    if type(version) ~= "string" or not version:find(VERIFIED_ICON_VERSION) then return nil end
    return QUEST_ICON_PATH .. (ready and "CompleteQuest" or "IncompleteQuest")
end

-- True when Waypoint UI is following a bridge-owned custom navigation.
function WUI.IsOwnedNavigationTracked()
    local nav, tracked = GetTrackedNavigation()
    return nav ~= nil and tracked and nav.flags == ns.OWNER_FLAG
end

-- Removes the bridge's own custom navigation (never anyone else's).
-- ClearUserNavigation(false, true): also remove the native user waypoint
-- it created, and do not advance Waypoint UI's multi-pin queue.
-- Note: Waypoint UI reacts to the removed native waypoint with
-- C_SuperTrack.ClearAllSuperTracked() (MapPin.lua USER_WAYPOINT_UPDATED
-- handler) when the waypoint was supertracked, so callers must set any new
-- supertracking AFTER that has run, not before. Returns true if cleared.
function WUI.ClearOwnedNavigation()
    local api = GetNavigationAPI()
    if not api or type(api.ClearUserNavigation) ~= "function" then return false end
    local nav = WUI.GetNavigation()
    if not (nav and nav.flags == ns.OWNER_FLAG) then return false end
    local ok = pcall(api.ClearUserNavigation, false, true)
    return ok
end

-- Name of a tracked navigation that the bridge did not create, or nil.
function WUI.GetForeignNavigationName()
    local nav, tracked = GetTrackedNavigation()
    if nav and tracked and nav.flags ~= ns.OWNER_FLAG then
        return tostring(nav.name or "unnamed waypoint")
    end
    return nil
end

-- Describes what Waypoint UI is following when it is NOT the bridge's
-- navigation; returns nil while the bridge's navigation is being followed.
-- expectedQuestID: in native quest mode, that quest being supertracked counts
-- as the bridge's navigation, whoever set it (RestedXP sets it too).
function WUI.DescribeOutsideNavigation(expectedQuestID)
    if expectedQuestID and ns.Nav.IsNativeQuestActive(expectedQuestID) then
        return nil
    end

    local nav, tracked = GetTrackedNavigation()
    if nav and tracked then
        if nav.flags == ns.OWNER_FLAG then return nil end
        return format("another waypoint is tracked (%s)", tostring(nav.name or "unnamed"))
    end

    local questID = ns.Nav.GetSuperTrackedQuest()
    if questID then
        return format("quest %d is supertracked", questID)
    end
    if expectedQuestID then
        return "bridge quest is no longer supertracked (turned in or cleared)"
    end
    return "bridge waypoint is no longer tracked (cleared or arrived)"
end

-- Returns true on success, or false plus a reason.
-- Calling this again with the same coordinates only renames the navigation:
-- Waypoint UI skips C_Map.SetUserWaypoint when the native waypoint already
-- matches (MapPin.NewUserNavigation), so there is no new destination.
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
        flags = ns.OWNER_FLAG,
        suppressAudio = suppressAudio and true or false,
        stripCoordinates = target.stripCoordinates and true or false,
        iconTexture = target.iconTexture,
        iconType = target.iconTexture and "TEXTURE" or nil,
    })

    if not ok then
        return false, "Waypoint UI raised an error: " .. tostring(result)
    end
    if not result then
        return false, "Waypoint UI rejected the destination"
    end
    return true
end
