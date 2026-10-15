-- RXP Waypoint Bridge
-- RXPAdapter: every read of RestedXP internals lives in this file.
--
-- RXPG_ARROW is RestedXP's arrow frame; RXPG_ARROW.element is the waypoint
-- RestedXP's routing logic has currently resolved (map.lua, updateArrowData).
-- This is internal RestedXP state, not a public API, so every field is
-- validated before use.
--
-- Known element fields (RXPGuides v4.11.23):
--   zone     uiMapID (number)
--   x, y     map coordinates as percentages, 0-100
--   wx, wy   world coordinates; instance = continent ID
--   step     owning guide step (step.index, step.active, step.title, ...)
--   skip     true once the waypoint has been reached
--   hidden   true while RestedXP is hiding the waypoint (activation radius)
--   title    optional arrow label
--   text, parent, tag   used by LabelResolver.lua to describe the waypoint
--
-- RestedXP never clears RXPG_ARROW.element; when no waypoint remains it only
-- hides the arrow. A stale element is recognised by skip/hidden or by its
-- step no longer being active. Arrow visibility is deliberately NOT used for
-- validity: RestedXP settings, instances and a future "hide RXP arrow" option
-- can all hide the arrow while the waypoint is still current.

local _, ns = ...
local RXP = ns.RXP

local RXP_ADDON = "RXPGuides"

local C_Map = C_Map
local format = string.format
local type = type
local tostring = tostring

-- Destination identity: map plus coordinates rounded to 0.001 % of the map
-- (well under a yard). Absorbs floating-point noise without merging distinct
-- nearby waypoints.
function RXP.DestinationKey(mapID, x, y)
    return format("%s:%.3f:%.3f", tostring(mapID), x, y)
end

function RXP.GetStatus()
    local loaded = ns.IsLoaded(RXP_ADDON)
    return {
        loaded = loaded,
        version = loaded and ns.GetVersion(RXP_ADDON) or nil,
        arrowAvailable = type(_G.RXPG_ARROW) == "table",
    }
end

-- Returns target, reason.
-- target is always returned when an element exists (for diagnostics);
-- reason is nil only when the target is valid to send to Waypoint UI, in
-- which case target.key holds its destination identity.
function RXP.GetTarget()
    local arrow = _G.RXPG_ARROW
    if type(arrow) ~= "table" then
        return nil, "RestedXP arrow frame (RXPG_ARROW) not found"
    end

    local element = arrow.element
    if element == nil then
        return nil, "RestedXP has not selected a waypoint yet"
    end
    if type(element) ~= "table" then
        return nil, "unexpected RXPG_ARROW.element type: " .. type(element)
    end

    local step = type(element.step) == "table" and element.step or nil
    local labelInfo = ns.Label.Resolve(element)
    local target = {
        element = element, -- for NavigationResolver; treat as read-only RestedXP data
        mapID = element.zone,
        x = element.x,
        y = element.y,
        label = labelInfo.label,
        labelInfo = labelInfo,
        -- Hide Waypoint UI's coordinate line only when the label says something useful.
        stripCoordinates = not labelInfo.fallback,
        stepIndex = step and step.index,
        stepActive = step and step.active and true or false,
        hasStep = step ~= nil,
        arrowShown = type(arrow.IsShown) == "function" and arrow:IsShown() and true or false,
    }

    if element.skip then
        return target, "waypoint has already been reached"
    end
    if element.hidden then
        return target, "waypoint is currently hidden by RestedXP"
    end
    if step and not step.active then
        return target, "waypoint belongs to a step that is no longer active"
    end

    local mapID, x, y = element.zone, element.x, element.y
    if type(mapID) ~= "number" then
        if ns.IsFiniteNumber(element.wx) and ns.IsFiniteNumber(element.wy) then
            return target, "world-coordinate-only target (e.g. corpse or spirit healer), not supported yet"
        end
        return target, "waypoint has no map ID"
    end
    if not (ns.IsFiniteNumber(x) and ns.IsFiniteNumber(y)) then
        return target, "waypoint coordinates are missing or invalid"
    end
    if x < 0 or x > 100 or y < 0 or y > 100 then
        return target, format("waypoint coordinates out of range (%.2f, %.2f)", x, y)
    end

    local mapInfo = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(mapID)
    if not mapInfo then
        return target, "unknown map ID " .. tostring(mapID)
    end
    target.mapName = mapInfo.name

    if C_Map.CanSetUserWaypointOnMap and not C_Map.CanSetUserWaypointOnMap(mapID) then
        return target, format("map %d (%s) does not allow user waypoints", mapID, tostring(mapInfo.name))
    end

    target.key = RXP.DestinationKey(mapID, x, y)
    return target, nil
end

-- Player distance in yards to the target's world position, using the
-- HereBeDragons library RestedXP itself uses for its arrow (element.wx/wy
-- are HBD world coordinates). Returns nil when it cannot be measured.
function RXP.GetDistanceToTarget(target)
    local element = target and target.element
    if type(element) ~= "table" then return nil end
    if not (ns.IsFiniteNumber(element.wx) and ns.IsFiniteNumber(element.wy)) then return nil end

    local LibStub = _G.LibStub
    local HBD = type(LibStub) == "table" and LibStub("HereBeDragons-2.0", true)
    if not HBD or type(HBD.GetPlayerWorldPosition) ~= "function" or type(HBD.GetWorldDistance) ~= "function" then
        return nil
    end

    local ok, px, py, instance = pcall(HBD.GetPlayerWorldPosition, HBD)
    if not ok or not px or instance ~= element.instance then return nil end
    local okDistance, distance = pcall(HBD.GetWorldDistance, HBD, instance, px, py, element.wx, element.wy)
    if okDistance and ns.IsFiniteNumber(distance) then return distance end
    return nil
end

--------------------------------------------------------------------------------
-- Change observation
--
-- Called by the sync poller several times a second, so it only compares a
-- handful of raw fields against the previous call: no tables, no strings.
-- Instruction text is deliberately not compared: objective progress rewrites
-- it constantly. Labels are resolved only when a target change is evaluated.
-- Covers a new element (next waypoint, other step, other guide), the same
-- element moving or changing map, and validity changes (reached, hidden,
-- step deactivated).
--------------------------------------------------------------------------------

local NEVER = {} -- sentinel: forces the next comparison to report a change
local seenElement, seenZone, seenX, seenY, seenSkip, seenHidden, seenStep, seenActive = NEVER

function RXP.HasTargetChanged()
    local arrow = _G.RXPG_ARROW
    local element = type(arrow) == "table" and arrow.element or nil
    local zone, x, y, skip, hidden, step, active

    if type(element) == "table" then
        zone, x, y = element.zone, element.x, element.y
        skip, hidden = element.skip, element.hidden
        step = element.step
        if type(step) == "table" then active = step.active end
    end

    if element == seenElement and zone == seenZone and x == seenX and y == seenY
        and skip == seenSkip and hidden == seenHidden and step == seenStep and active == seenActive then
        return false
    end

    seenElement, seenZone, seenX, seenY = element, zone, x, y
    seenSkip, seenHidden, seenStep, seenActive = skip, hidden, step, active
    return true
end

-- Makes the next HasTargetChanged() call report a change.
function RXP.ResetObservation()
    seenElement = NEVER
end
