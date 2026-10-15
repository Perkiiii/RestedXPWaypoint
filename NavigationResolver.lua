-- RXP Waypoint Bridge
-- NavigationResolver: decides whether RestedXP's current arrow target should
-- be shown as a coordinate waypoint (Mode A) or as WoW's native supertracked
-- quest (Mode B), and wraps the native supertracking calls.
--
-- v0.4 only promotes quest TURN-INS to native mode, and only with evidence:
--
--   1. The arrow element is a guide ".goto" (not a corpse/generated target).
--   2. It is a final destination, not a pass-through point. In RestedXP a
--      .goto with a radius is marked reached and skipped (map.lua
--      UpdateGotoSteps), so radius / dynamic / low-priority waypoints are
--      intermediate route points and always stay coordinates.
--   3. RestedXP's own link ties the waypoint to a turn-in:
--        - element.parent is the instruction the waypoint belongs to
--          (GuideLoader parseLine); it must be a pending .turnin, or
--        - with no parent (the usual first .goto of a step), the first
--          PENDING instruction after the waypoint, before the next
--          waypoint, must be a .turnin. Text-only lines (">>Talk to X",
--          .target, ...) are skipped; completed instructions are skipped.
--      If several turn-ins are pending at the destination, the first one in
--      RestedXP's order is used (it is the one the player does next).
--   4. The quest is in the quest log and ready for turn-in.
--   5. Native supertracking APIs exist in this client.
--   6. After supertracking, a native navigation target must exist and must
--      not be measurably inconsistent with RestedXP's destination (checked
--      by Sync via Nav.VerifyNative; see there).
-- Anything else stays on coordinates. RestedXP keeps controlling the route:
-- the arrow only reaches the turn-in .goto after RestedXP has moved past
-- every intermediate waypoint.

local _, ns = ...
local Nav = ns.Nav

-- Distances are compared one-sidedly: if |native - RestedXP| exceeds this,
-- the two targets are provably at least this far apart (triangle inequality).
-- It cannot prove they match; it only catches clearly different targets.
Nav.NATIVE_DISTANCE_TOLERANCE = 50 -- yards

local type = type
local ipairs = ipairs
local tostring = tostring
local format = string.format
local pcall = pcall
local abs = math.abs

--------------------------------------------------------------------------------
-- RestedXP structure analysis (no WoW API calls; offline-testable)
--------------------------------------------------------------------------------

local function IsWaypointElement(element)
    return element.arrow == true or element.tag == "goto" or element.tag == "waypoint"
end

local function IsDone(element)
    return element.completed or element.skip
end

local function IsTurnIn(element)
    return element.tag == "turnin" and type(element.questId) == "number" and element.questId > 0
end

-- Returns candidate, reason. candidate = { questID, title, pendingTurnIns, via }.
function Nav.FindTurnIn(element)
    if type(element) ~= "table" then return nil, "no RestedXP waypoint" end
    if element.tag ~= "goto" then
        return nil, "not a guide .goto waypoint"
    end
    if element.radius ~= nil or element.dynamic or element.lowPrio or element.generated then
        return nil, "intermediate route waypoint (pass-through point)"
    end

    local parent = element.parent
    if type(parent) == "table" then
        if IsTurnIn(parent) and not IsDone(parent) then
            return { questID = parent.questId, title = parent.title, pendingTurnIns = 1, via = "linked turn-in" }
        end
        return nil, "waypoint is linked to a non-turn-in instruction"
    end

    local step = element.step
    local elements = type(step) == "table" and step.elements
    if type(elements) ~= "table" then return nil, "waypoint has no step instructions" end

    local index
    for i, e in ipairs(elements) do
        if e == element then index = i break end
    end
    if not index then return nil, "waypoint not found in its step" end

    local candidate
    for i = index + 1, #elements do
        local e = elements[i]
        if type(e) == "table" then
            if IsWaypointElement(e) then break end
            if not IsDone(e) and not e.textOnly then
                if not candidate then
                    if not IsTurnIn(e) then
                        return nil, format("next instruction is .%s, not a turn-in", tostring(e.tag or "text"))
                    end
                    candidate = { questID = e.questId, title = e.title, pendingTurnIns = 1, via = "next instruction" }
                elseif IsTurnIn(e) then
                    candidate.pendingTurnIns = candidate.pendingTurnIns + 1
                end
            end
        end
    end

    if not candidate then return nil, "no pending turn-in at this waypoint" end
    return candidate
end

--------------------------------------------------------------------------------
-- WoW quest and supertracking state
--------------------------------------------------------------------------------

local function Call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, result = pcall(fn, ...)
    if ok then return result end
    return nil
end

function Nav.IsNativeSupported()
    return type(C_SuperTrack) == "table"
        and type(C_SuperTrack.SetSuperTrackedQuestID) == "function"
        and type(C_SuperTrack.GetSuperTrackedQuestID) == "function"
        and type(C_Navigation) == "table"
        and type(C_Navigation.GetDistance) == "function"
        and type(C_QuestLog) == "table"
        and type(C_QuestLog.IsOnQuest) == "function"
end

-- Returns { inLog, ready, title }.
function Nav.GetQuestState(questID)
    local QL = type(C_QuestLog) == "table" and C_QuestLog or {}
    local inLog = Call(QL.IsOnQuest, questID) and true or false
    local ready = false
    if inLog then
        ready = (Call(QL.ReadyForTurnIn, questID) or Call(QL.IsComplete, questID)) and true or false
    end
    local title = Call(QL.GetTitleForQuestID, questID)
    if type(title) ~= "string" or title == "" then title = nil end
    return { inLog = inLog, ready = ready, title = title }
end

function Nav.GetSuperTrackedQuest()
    local id = Call(C_SuperTrack and C_SuperTrack.GetSuperTrackedQuestID)
    if type(id) == "number" and id > 0 then return id end
    return nil
end

function Nav.SetNativeQuest(questID)
    if not Nav.IsNativeSupported() then return false end
    local ok = pcall(C_SuperTrack.SetSuperTrackedQuestID, questID)
    return ok
end

-- Stops supertracking questID, but only if it is still the supertracked quest.
function Nav.ReleaseNativeQuest(questID)
    if questID and Nav.GetSuperTrackedQuest() == questID then
        pcall(C_SuperTrack.SetSuperTrackedQuestID, 0)
        return true
    end
    return false
end

local function QuestHasPriority()
    local getType = C_SuperTrack and C_SuperTrack.GetHighestPrioritySuperTrackingType
    local questType = Enum and Enum.SuperTrackingType and Enum.SuperTrackingType.Quest
    if type(getType) ~= "function" or questType == nil then return true end -- cannot tell
    return Call(getType) == questType
end

-- True while the native quest is what WoW (and so Waypoint UI) is following.
function Nav.IsNativeQuestActive(questID)
    return questID ~= nil and Nav.GetSuperTrackedQuest() == questID and QuestHasPriority()
end

-- Called after supertracking questID. Returns ok, detail.
function Nav.VerifyNative(target, questID)
    local current = Nav.GetSuperTrackedQuest()
    if current ~= questID then
        return false, format("supertracking did not take effect (now %s)", tostring(current or "none"))
    end
    if not QuestHasPriority() then
        return false, "another supertracked target has priority over the quest"
    end

    local nativeDistance = Call(C_Navigation.GetDistance)
    if type(nativeDistance) ~= "number" or nativeDistance <= 0 then
        return false, "no native navigation target for the quest"
    end

    local rxpDistance = ns.RXP.GetDistanceToTarget(target)
    if rxpDistance then
        local gap = abs(nativeDistance - rxpDistance)
        if gap > Nav.NATIVE_DISTANCE_TOLERANCE then
            return false, format("native target is at least %.0f yd from RestedXP's destination", gap)
        end
        return true, format("native %.0f yd vs RestedXP %.0f yd", nativeDistance, rxpDistance)
    end
    return true, format("native target at %.0f yd (RestedXP distance unknown)", nativeDistance)
end

--------------------------------------------------------------------------------
-- Decision
--------------------------------------------------------------------------------

-- Returns decision:
--   mode        "native" or "coordinates" (for the given strategy)
--   reason      why
--   questID, questName, questState   when a turn-in candidate was found
--   hybridMode  what hybrid would choose (for diagnostics in coordinates strategy)
function Nav.Decide(target, strategy)
    local decision = { mode = "coordinates", hybridMode = "coordinates" }

    local candidate, why = Nav.FindTurnIn(target.element)
    if not candidate then
        decision.reason = why
    else
        decision.questID = candidate.questID
        decision.pendingTurnIns = candidate.pendingTurnIns
        local questState = Nav.GetQuestState(candidate.questID)
        decision.questState = questState
        local title = questState.title or (type(candidate.title) == "string" and candidate.title ~= "" and candidate.title) or nil
        decision.questName = title

        if not Nav.IsNativeSupported() then
            decision.reason = "native quest supertracking is not available in this client"
        elseif not questState.inLog then
            decision.reason = format("quest %d is not in the quest log", candidate.questID)
        elseif not questState.ready then
            decision.reason = format("quest %d is not ready for turn-in", candidate.questID)
        else
            decision.hybridMode = "native"
            decision.reason = format("confirmed turn-in destination (%s)", candidate.via)
        end
    end

    if strategy == "hybrid" then
        decision.mode = decision.hybridMode
    elseif decision.hybridMode == "native" then
        decision.reason = "coordinates strategy selected (hybrid would use the native quest)"
    end
    return decision
end
