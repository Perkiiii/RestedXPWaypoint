-- RestedXP Waypoint
-- RXPAdapter: RestedXP target reads (instruction reads are in the resolvers).
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
-- validity: RestedXP settings, instances and the "Hide RestedXP Arrow" option
-- can all hide the arrow while the waypoint is still current.

local _, RXPW = ...
local RXP = RXPW.RXP

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
    local loaded = RXPW.IsLoaded(RXP_ADDON)
    return {
        loaded = loaded,
        version = loaded and RXPW.GetVersion(RXP_ADDON) or nil,
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
    local labelInfo = RXPW.Label.Resolve(element)
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
        if RXPW.IsFiniteNumber(element.wx) and RXPW.IsFiniteNumber(element.wy) then
            return target, "world-coordinate-only target (e.g. corpse or spirit healer), not supported yet"
        end
        return target, "waypoint has no map ID"
    end
    if not (RXPW.IsFiniteNumber(x) and RXPW.IsFiniteNumber(y)) then
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

--------------------------------------------------------------------------------
-- RestedXP's own "Hide waypoint arrow" option (settings page, v0.6.0)
--
-- RestedXP stores it as addon.settings.profile.disableArrow (SettingsPanel.lua
-- ~732). It is visual only: updateArrowData (map.lua ~1047) still assigns
-- RXPG_ARROW.element and merely keeps the frame hidden, and DrawArrow returns
-- early, so the bridge keeps receiving RestedXP's targets. The value lives in
-- RestedXP's profile, not RXPWDB: reading it live keeps RestedXP's checkbox and
-- ours identical. Setting it does what RestedXP's own option setter does
-- (save, DrawArrow) and asks RestedXP to re-apply visibility on its next
-- update tick (addon.UpdateMap() only raises its flag). No RestedXP function
-- is replaced. The addon object comes from the public AceAddon registry.
--------------------------------------------------------------------------------

local function GetRXPAddon()
    local LibStub = _G.LibStub
    local AceAddon = (type(LibStub) == "table" or type(LibStub) == "function") and LibStub("AceAddon-3.0", true)
    if type(AceAddon) ~= "table" or type(AceAddon.GetAddon) ~= "function" then return nil end
    local ok, addon = pcall(AceAddon.GetAddon, AceAddon, RXP_ADDON, true)
    if ok and type(addon) == "table" then return addon end
    return nil
end

-- Audio follows actual guide progression, not the arrow's owning sticky or
-- patrol step. GetGuideProgress is RestedXP's own current-step lookup. Require
-- both steps to belong to this processed guide; ambiguity stays quiet.
function RXP.GetAudioStep(target)
    local addon = GetRXPAddon()
    local guide = addon and addon.currentGuide
    if type(guide) ~= "table" or type(guide.steps) ~= "table"
        or type(addon.GetGuideProgress) ~= "function" then return nil end
    local ok, index = pcall(addon.GetGuideProgress)
    if not ok or not RXPW.IsFiniteNumber(index) then return nil end
    local step = guide.steps[index]
    local source = target and target.element
    source = type(source) == "table" and source.step
    if type(step) ~= "table" or not step.active or type(source) ~= "table"
        or not source.active or type(source.index) ~= "number"
        or guide.steps[source.index] ~= source then return nil end
    local key = guide.key
    if type(key) ~= "string" or key == "" then
        if type(guide.group) ~= "string" or type(guide.name) ~= "string" then return nil end
        key = format("%d:%s%s", #guide.group, guide.group, guide.name)
    end
    local id = step.stepId
    if not ((type(id) == "string" and id ~= "") or RXPW.IsFiniteNumber(id)) then
        id = step -- session-local identity; never infer progression from a renumbering
    end
    return { guide = key, revision = guide, step = id }
end

local function GetRXPProfile(addon)
    local settings = addon and addon.settings
    local profile = type(settings) == "table" and settings.profile
    return type(profile) == "table" and profile or nil
end

-- true / false, or nil when RestedXP or its settings are unavailable.
function RXP.IsArrowHidden()
    local profile = GetRXPProfile(GetRXPAddon())
    if not profile then return nil end
    return profile.disableArrow == true
end

-- Returns true when the option was set.
function RXP.SetArrowHidden(hidden)
    local addon = GetRXPAddon()
    local profile = GetRXPProfile(addon)
    if not profile then return false end
    profile.disableArrow = hidden and true or false
    local frame = addon.arrowFrame
    if type(addon.DrawArrow) == "function" and type(frame) == "table" then pcall(addon.DrawArrow, frame) end
    if hidden and type(frame) == "table" and type(frame.Hide) == "function" then pcall(frame.Hide, frame) end
    if type(addon.UpdateMap) == "function" then pcall(addon.UpdateMap) end
    return true
end

-- Proof for retiring a previous marker while the arrow temporarily remains
-- stale. A missing/hidden current arrow alone does not prove obsolescence.
function RXP.IsPreviousTargetObsolete(previous)
    local element = previous and previous.element
    if type(element) ~= "table" then return false end
    if element.skip then return true end
    local step = element.step
    return type(step) == "table" and (not step.active
        or (type(step.index) == "number" and step.index ~= previous.stepIndex))
end

-- Player distance in yards to the target's world position, using the
-- HereBeDragons library RestedXP itself uses for its arrow (element.wx/wy
-- are HBD world coordinates). Returns nil when it cannot be measured.
function RXP.GetDistanceToTarget(target)
    return RXP.GetDistanceToElement(target and target.element)
end

-- Same, for any RestedXP waypoint element (e.g. every point of a #loop circuit).
function RXP.GetDistanceToElement(element)
    if type(element) ~= "table" then return nil end
    if not (RXPW.IsFiniteNumber(element.wx) and RXPW.IsFiniteNumber(element.wy)) then return nil end

    local LibStub = _G.LibStub
    local HBD = type(LibStub) == "table" and LibStub("HereBeDragons-2.0", true)
    if not HBD or type(HBD.GetPlayerWorldPosition) ~= "function" or type(HBD.GetWorldDistance) ~= "function" then
        return nil
    end

    local ok, px, py, instance = pcall(HBD.GetPlayerWorldPosition, HBD)
    if not ok or not px or instance ~= element.instance then return nil end
    local okDistance, distance = pcall(HBD.GetWorldDistance, HBD, instance, px, py, element.wx, element.wy)
    if okDistance and RXPW.IsFiniteNumber(distance) then return distance end
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
local seenStepIndex

function RXP.HasTargetChanged()
    local arrow = _G.RXPG_ARROW
    local element = type(arrow) == "table" and arrow.element or nil
    local zone, x, y, skip, hidden, step, active, stepIndex

    if type(element) == "table" then
        zone, x, y = element.zone, element.x, element.y
        skip, hidden = element.skip, element.hidden
        step = element.step
        if type(step) == "table" then active, stepIndex = step.active, step.index end
    end

    if element == seenElement and zone == seenZone and x == seenX and y == seenY
        and skip == seenSkip and hidden == seenHidden and step == seenStep and active == seenActive
        and stepIndex == seenStepIndex then
        return false
    end

    seenElement, seenZone, seenX, seenY = element, zone, x, y
    seenSkip, seenHidden, seenStep, seenActive = skip, hidden, step, active
    seenStepIndex = stepIndex
    return true
end

-- The raw arrow element (read-only RestedXP data) or nil; no label work, for
-- the once-a-second activity observation (Nav.GetActivitySignature).
function RXP.GetArrowElement()
    local arrow = _G.RXPG_ARROW
    local element = type(arrow) == "table" and arrow.element or nil
    return type(element) == "table" and element or nil
end

-- Makes the next HasTargetChanged() call report a change.
function RXP.ResetObservation()
    seenElement = NEVER
end
