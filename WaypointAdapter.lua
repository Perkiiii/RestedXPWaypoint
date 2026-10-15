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

local C_SuperTrack = C_SuperTrack
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

-- True when Waypoint UI is already navigating to this target via a
-- bridge-owned navigation, so no write is needed.
function WUI.IsShowingTarget(target)
    local nav, tracked = GetTrackedNavigation()
    if not (nav and tracked and nav.flags == ns.OWNER_FLAG) then return false end
    if nav.mapID ~= target.mapID then return false end
    if not (ns.IsFiniteNumber(nav.x) and ns.IsFiniteNumber(nav.y)) then return false end
    return abs(nav.x * 100 - target.x) < MATCH_TOLERANCE and abs(nav.y * 100 - target.y) < MATCH_TOLERANCE
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
function WUI.DescribeOutsideNavigation()
    local nav, tracked = GetTrackedNavigation()
    if nav and tracked then
        if nav.flags == ns.OWNER_FLAG then return nil end
        return format("another waypoint is tracked (%s)", tostring(nav.name or "unnamed"))
    end

    local questID = C_SuperTrack and C_SuperTrack.GetSuperTrackedQuestID and C_SuperTrack.GetSuperTrackedQuestID()
    if type(questID) == "number" and questID > 0 then
        return format("quest %d is supertracked", questID)
    end
    return "bridge waypoint is no longer tracked (cleared or arrived)"
end

-- Returns true on success, or false plus a reason.
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
    })

    if not ok then
        return false, "Waypoint UI raised an error: " .. tostring(result)
    end
    if not result then
        return false, "Waypoint UI rejected the destination"
    end
    return true
end
