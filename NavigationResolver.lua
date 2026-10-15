-- RestedXP Waypoint
-- NavigationResolver: decides whether RestedXP's current arrow target should
-- be shown as a coordinate waypoint (Mode A) or as WoW's native supertracked
-- quest (Mode B), and wraps the native supertracking calls.
--
-- Strategies
--   coordinates   always Mode A.
--   hybrid        only quest TURN-INS go native, using
--                 Nav.FindTurnIn (radius = pass-through rule).
--   native-first  (v0.5) turn-ins AND quest objectives (.complete) go native
--                 when RestedXP's own structure ties the arrow waypoint to them,
--                 using Nav.FindQuestTarget.
--
-- RestedXP structure (GuideLoader.lua parseLine, functions.lua, v4.11.23)
--   * A step's lines become step.elements in guide order.
--   * .goto        tag "goto"; radius = mark reached and skip (pass-through
--                  OR "arrive in the objective area", e.g. ".goto x,y,7,0" before
--                  ".complete"), so radius alone does NOT classify a waypoint.
--                  ",0" -> lowPrio; negative radius -> dynamic (closest point).
--                  "line >> text" gives the waypoint its own text: an explicit
--                  travel instruction ("Enter the crypt"). A non-optional radius
--                  with no text gets generated "Go to x,y (zone)" text, which is
--                  also shown as a travel instruction.
--                  element.parent = most recent text-bearing objective ABOVE it
--                  in the step (addon.lastObjective); RestedXP drops the
--                  waypoint once that parent completes.
--   * .complete    tag "complete", questId, obj (objective index into
--                  C_QuestLog.GetQuestObjectives), objMax; textOnly when its
--                  flags hide the line. Completed when the objective is done.
--   * .turnin      tag "turnin", questId; title = quest name at runtime.
--   * #loop        sets step.loop: the step's .goto run is a patrol circuit
--                  around the objective area, cycled by RestedXP.
--   * .mob/.target/.use/>>text/*text are textOnly helper lines.
--
-- Native-first rules (Nav.FindQuestTarget), all required:
--   1. The arrow element is a guide .goto (not a corpse/generated target).
--   2. It has no own text (own or generated text = explicit travel step).
--   3. Its instruction block is found through RestedXP's structure:
--        - with element.parent: the instructions between the previous
--          waypoint and this one (the block the parent belongs to);
--        - without: the instructions right after it. If another waypoint
--          comes first, it is an intermediate route point (coordinates),
--          unless the step is a #loop circuit (all points are the area).
--      Text-only lines (">>Kill X", "*Prioritize Y", .mob, .target) are
--      descriptive headings/helpers and are skipped.
--   3b. Patrol steps (v0.5.1): if the block holds nothing but a placeholder
--      objective ("+1": an untagged "+" line without letters) and the step is
--      a sticky #loop (#completewith), the step is a navigation-only patrol
--      circuit and the quest work lives in the active steps it serves:
--      every RXPFrame.activeSteps entry after it. Their combined pending
--      instructions go through rule 4; any served step with its own pending
--      waypoint -> coordinates. Real "+text" objectives never delegate.
--   4. In that block, the first pending instruction is a .turnin (then the
--      first pending turn-in is the candidate) or the block's pending
--      instructions are .complete objectives of exactly ONE quest and no
--      other pending action (else: ambiguous -> coordinates).
--   5. Quest state (Nav.GetQuestState): turn-in -> in log and ready;
--      objective -> in log, not yet complete, and every unfinished objective
--      of the quest is one RestedXP targets in this block (so Blizzard's
--      native target cannot point at an objective RestedXP plans elsewhere).
--   6. Native APIs exist; after supertracking a native navigation target
--      exists and is not measurably inconsistent with RestedXP's destination
--      (Nav.VerifyNative, run by Sync).

local _, RXPW = ...
local Nav = RXPW.Nav

-- Native target verification
--   RXP.GetDistanceToTarget: horizontal distance (yards) from the player to
--     RestedXP's point, in HereBeDragons world coordinates (what RestedXP's own
--     arrow uses).
--   C_Navigation.GetDistance: Blizzard's distance (yards) to the current
--     navigation target (what Waypoint UI shows). Whether it includes height
--     is not documented.
--   Measured from the same player position, |native - RestedXP| is a LOWER
--   BOUND on how far apart the two targets are (triangle inequality; a height
--   difference can add up to |dz|). So the check can only reject targets that
--   are provably far apart; it can never prove they are the same.
--   Turn-in: the native target is the quest giver and RestedXP points at the
--     same NPC; 50 yd was validated in game in v0.4.
--   Objective: Blizzard marks the quest's objective area while RestedXP picks a
--     point (or patrol point) inside it, so the two legitimately differ by up
--     to the area's size; 100 yd tolerates that while still rejecting other
--     regions, zone exits and wrong objectives. Tunable; every verification
--     logs the measured values in debug mode for calibration.
Nav.TURNIN_TOLERANCE = 50     -- yards
Nav.OBJECTIVE_TOLERANCE = 100 -- yards
Nav.NATIVE_DISTANCE_TOLERANCE = Nav.TURNIN_TOLERANCE -- v0.4 name

local type = type
local ipairs = ipairs
local pairs = pairs
local tostring = tostring
local format = string.format
local concat = table.concat
local sort = table.sort
local pcall = pcall
local abs = math.abs

--------------------------------------------------------------------------------
-- RestedXP structure analysis (no WoW API calls; offline-testable)
--------------------------------------------------------------------------------

local function IsWaypointElement(element)
    return element.arrow == true or element.tag == "goto" or element.tag == "waypoint"
end

-- RestedXP's guide window sets completed = true on EVERY text-only or
-- text-less element it draws (GuideWindow.lua ~1316-1328: ">>" headers, "*"
-- notes, .mob/.target, and every .goto), so "completed" alone does not mean
-- done. Real progress: SetElementComplete sets completed AND skip, and a reached
-- waypoint sets skip. So: skip, or completed on a real instruction.
local function IsDone(element)
    return element.skip or (element.completed and not element.textOnly and element.text ~= nil) or false
end

local function IsTurnIn(element)
    return element.tag == "turnin" and type(element.questId) == "number" and element.questId > 0
end

local function IsObjective(element)
    return element.tag == "complete" and type(element.questId) == "number" and element.questId > 0
        and type(element.obj) == "number"
end

local function FindIndex(elements, element)
    for i, e in ipairs(elements) do
        if e == element then return i end
    end
end

local function HasTravelInstruction(element)
    return type(element.text) == "string" and element.text:find("[%a\128-\255]") ~= nil
end

-- Hybrid turn-in analysis. Returns candidate, reason.
-- candidate = { kind = "turnin", questID, title, pendingTurnIns, via }.
function Nav.FindTurnIn(element)
    if type(element) ~= "table" then return nil, "no RestedXP waypoint" end
    if element.tag ~= "goto" then
        return nil, "not a guide .goto waypoint"
    end
    if HasTravelInstruction(element) then
        return nil, "explicit travel instruction on this waypoint"
    end
    if element.radius ~= nil or element.dynamic or element.lowPrio or element.generated then
        return nil, "intermediate route waypoint (pass-through point)"
    end

    local parent = element.parent
    if type(parent) == "table" then
        if RXPW.Label.LinkedBlock(element) and IsTurnIn(parent) then
            return { kind = "turnin", questID = parent.questId, title = parent.title, pendingTurnIns = 1, via = "linked turn-in" }
        end
        return nil, "waypoint is linked to a non-turn-in instruction"
    end

    local step = element.step
    local elements = type(step) == "table" and step.elements
    if type(elements) ~= "table" then return nil, "waypoint has no step instructions" end

    local index = FindIndex(elements, element)
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
                    candidate = { kind = "turnin", questID = e.questId, title = e.title, pendingTurnIns = 1, via = "next instruction" }
                elseif IsTurnIn(e) then
                    candidate.pendingTurnIns = candidate.pendingTurnIns + 1
                end
            end
        end
    end

    if not candidate then return nil, "no pending turn-in at this waypoint" end
    return candidate
end

-- A "+text" line is an objective without a tag; "+1" (no letters at all) is a
-- placeholder RestedXP uses to keep a navigation-only step from completing.
local function IsPlaceholder(element)
    return element.tag == nil and not element.textOnly and type(element.text) == "string"
        and not element.text:find("[%a\128-\255]")
end

-- Short, markup-free description of an instruction for diagnostics.
local function DescribeInstruction(element)
    local name
    if element.tag then
        name = "." .. tostring(element.tag)
    elseif element.textOnly then
        name = "text"
    else
        name = IsPlaceholder(element) and "+placeholder" or "+objective"
    end
    local text = type(element.text) == "string"
        and (RXPW.Label.Clean(element.text) or element.text:gsub("|", "/"):sub(1, 40)) or nil
    if text and not element.tag then
        return format("%s \"%s\"", name, text)
    end
    return name
end
Nav.DescribeInstruction = DescribeInstruction

-- Pending quest instructions in elements[first..last].
-- Returns candidate, reason, summary. summary.onlyPlaceholders is true when
-- nothing but placeholder objectives (or nothing at all) is pending.
-- Text-only lines (">>Kill X", "*Prioritize Y", .mob, .target) are
-- descriptive headings/helpers and never block a quest objective.
-- allowMulti (v0.5.3): inside a #loop farming circuit, objectives of several
-- quests are all relevant to the same area; return them as a "multi"
-- candidate for SelectQuest instead of rejecting the block.
local function AnalyzeBlock(elements, first, last, via, allowMulti)
    local firstAction, other
    local turnin, pendingTurnIns = nil, 0
    local quests, order = {}, {}
    local placeholders = 0

    for i = first, last do
        local e = elements[i]
        if type(e) == "table" and not IsWaypointElement(e) and not IsDone(e) then
            if IsTurnIn(e) then
                firstAction = firstAction or "turnin"
                turnin = turnin or e
                pendingTurnIns = pendingTurnIns + 1
            elseif IsObjective(e) then
                firstAction = firstAction or "objective"
                local q = e.questId
                local info = quests[q]
                if not info then
                    info = { questID = q, title = e.title, objectiveSet = {}, steps = {}, firstPos = i }
                    quests[q] = info
                    order[#order + 1] = info
                end
                info.objectiveSet[e.obj] = true
                if type(e.step) == "table" then info.steps[e.step] = true end
            elseif IsPlaceholder(e) then
                placeholders = placeholders + 1
            elseif not e.textOnly then
                firstAction = firstAction or "other"
                other = other or e
            end
        end
    end

    local summary = { onlyPlaceholders = firstAction == nil, placeholders = placeholders }
    if not firstAction then
        if placeholders > 0 then
            return nil, "only a placeholder objective (+1) is pending at this waypoint", summary
        end
        return nil, "no pending quest instruction at this waypoint", summary
    end
    if firstAction == "turnin" then
        return { kind = "turnin", questID = turnin.questId, title = turnin.title,
                 pendingTurnIns = pendingTurnIns, via = via }, nil, summary
    end
    if firstAction == "other" then
        return nil, format("next instruction is %s, not a quest objective", DescribeInstruction(other)), summary
    end
    if other then
        return nil, format("waypoint also has a non-quest instruction (%s)", DescribeInstruction(other)), summary
    end

    for _, info in ipairs(order) do
        local objectives = {}
        for obj in pairs(info.objectiveSet) do objectives[#objectives + 1] = obj end
        sort(objectives)
        info.objectives = objectives
        info.objectiveSet = nil
    end

    if #order > 1 then
        if allowMulti then
            return { kind = "multi", quests = order, via = via }, nil, summary
        end
        local ids = {}
        for _, info in ipairs(order) do ids[#ids + 1] = info.questID end
        sort(ids)
        return nil, "multiple candidate quests (" .. concat(ids, ", ") .. ")", summary
    end

    local info = order[1]
    return { kind = "objective", questID = info.questID, title = info.title, objectives = info.objectives,
             steps = info.steps, via = via }, nil, summary
end

-- RestedXP's active steps (GuideWindow.lua: RXPFrame.activeSteps = sticky
-- steps that are still running + the current step). Read-only.
local function GetActiveSteps()
    local frame = _G.RXPFrame
    local steps = type(frame) == "table" and frame.activeSteps
    if type(steps) ~= "table" then return nil end
    return steps
end
Nav.GetActiveSteps = GetActiveSteps

-- True for a sticky #loop step (#completewith ...): a patrol circuit that
-- stays active while later steps run.
local function IsStickyLoop(step)
    return step.loop ~= nil and (step.sticky or step.completewith ~= nil) and true or false
end
Nav.IsStickyLoop = IsStickyLoop

-- The active steps a sticky patrol step serves: every active step after it
-- (a sticky step only stays active while the current step is within its
-- #completewith span). Returns served (sorted by index) or nil, reason.
local function GetServedSteps(patrolStep)
    local active = GetActiveSteps()
    if not active then return nil, "RestedXP's active steps are unavailable" end
    if type(patrolStep.index) ~= "number" then return nil, "patrol step has no index" end
    local served = {}
    for _, s in ipairs(active) do
        if type(s) == "table" and s ~= patrolStep and s.active and type(s.index) == "number"
            and s.index > patrolStep.index and type(s.elements) == "table" then
            served[#served + 1] = s
        end
    end
    sort(served, function(a, b) return a.index < b.index end)
    if #served == 0 then return nil, "patrol step serves no active step" end
    return served
end
Nav.GetServedSteps = GetServedSteps

-- The arrow is on a navigation-only patrol step (only "+1"): the quest work
-- happens in the active steps it serves. Their combined pending instructions
-- go through the same block rules (one quest, nothing else pending, ...).
local function AnalyzeServedSteps(patrolStep)
    local served, why = GetServedSteps(patrolStep)
    if not served then return nil, why end

    local combined, indexes = {}, {}
    for _, s in ipairs(served) do
        indexes[#indexes + 1] = tostring(s.index)
        for _, e in ipairs(s.elements) do
            if type(e) == "table" then
                if IsWaypointElement(e) and not IsDone(e) then
                    return nil, format("served step %d has its own waypoint", s.index)
                end
                combined[#combined + 1] = e
            end
        end
    end
    local via = format("patrol step %s serving step(s) %s", tostring(patrolStep.index), concat(indexes, ", "))
    local candidate, reason = AnalyzeBlock(combined, 1, #combined, via, true)
    if not candidate then
        return nil, format("%s: %s", via, reason)
    end
    return candidate
end

-- Every waypoint of a #loop circuit with a world position: RestedXP's
-- destination for a patrol is the whole circuit (used by VerifyNative).
local function CircuitPoints(step)
    local points = {}
    for _, e in ipairs(step.elements) do
        if type(e) == "table" and IsWaypointElement(e) and RXPW.IsFiniteNumber(e.wx) and RXPW.IsFiniteNumber(e.wy) then
            points[#points + 1] = e
        end
    end
    return points
end

-- The step a sticky helper step completes with (#completewith next / label),
-- if it is one of RestedXP's active steps.
local function FindAnchorStep(step)
    local active = GetActiveSteps()
    if not active then return nil end
    local completewith = step.completewith
    for _, s in ipairs(active) do
        if type(s) == "table" and s ~= step and s.active and type(s.elements) == "table" then
            if completewith == "next" then
                if type(step.index) == "number" and s.index == step.index + 1 then return s end
            elseif type(completewith) == "string" and s.label == completewith then
                return s
            end
        end
    end
    return nil
end

local function PendingWaypointCount(step)
    local count = 0
    for _, e in ipairs(step.elements) do
        if type(e) == "table" and IsWaypointElement(e) and not IsDone(e) then count = count + 1 end
    end
    return count
end

--------------------------------------------------------------------------------
-- Activity observation (v0.5.9, F7)
--
-- RestedXP can change what a waypoint is FOR without moving its arrow: a
-- sticky step finishes, the player ticks an instruction off, a served step is
-- skipped. RestedXP sends no message for manual or waypoint skips, and
-- RXPFrame.activeSteps is one table rebuilt in place, so its identity says
-- nothing. The signature is therefore built from content only: the index and
-- active flag of the arrow's step and of every indexed active step, plus the
-- IsDone state of each of their elements. IsDone ignores the guide window's
-- draw-time completed flag, so redraws never change the signature. Cost: one
-- pass over a handful of steps; Sync calls it once a second.
--------------------------------------------------------------------------------

local signatureParts, signatureBits = {}, {}

local function AppendStepSignature(step, marker)
    if type(step) ~= "table" or type(step.index) ~= "number" or type(step.elements) ~= "table" then return end
    local count = 0
    for i, e in ipairs(step.elements) do
        signatureBits[i] = type(e) == "table" and (IsDone(e) and "1" or "0") or "-"
        count = i
    end
    signatureParts[#signatureParts + 1] = format("%s%d%s:%s", marker, step.index, step.active and "" or "i",
        concat(signatureBits, "", 1, count))
end

-- Compact string describing RestedXP's active guide state around the arrow
-- element; equal strings mean nothing a navigation decision reads has changed.
function Nav.GetActivitySignature(element)
    for i = #signatureParts, 1, -1 do signatureParts[i] = nil end
    AppendStepSignature(type(element) == "table" and element.step or nil, "a")
    local active = GetActiveSteps()
    if active then
        for _, s in ipairs(active) do AppendStepSignature(s, "s") end
    end
    return concat(signatureParts, " ")
end

local ROUTE_CRITICAL = { ["travel instruction"] = true, ["route point"] = true }

-- v0.5 native-first analysis. Returns candidate, reason, info.
-- candidate = { kind = "turnin"|"objective"|"multi", questID, title?, objectives?, pendingTurnIns?, via, references? }.
-- info = { role, routeCritical, helper? } describes the waypoint for
-- diagnostics and continuity. Roles: "travel instruction", "route point",
-- "turn-in destination", "objective area", "loop circuit", "patrol",
-- "helper", "other". helper = { step, anchor, candidate } (v0.5.4): a hidden
-- navigation-only step (one waypoint, no instructions, at most placeholder
-- text such as ">>1") that completes with an active anchor step; candidate
-- is the anchor's own quest instruction, used for quest context and, for
-- turn-ins only, native continuity (see Nav.Decide).
function Nav.FindQuestTarget(element)
    local function result(candidate, reason, role, extra)
        local info = extra or {}
        info.role = role
        info.routeCritical = ROUTE_CRITICAL[role] or false
        return candidate, reason, info
    end
    local function candidateRole(candidate, default)
        if not candidate then return default end
        if candidate.kind == "turnin" then return "turn-in destination" end
        return default == "other" and "objective area" or default
    end

    if type(element) ~= "table" then return result(nil, "no RestedXP waypoint", "other") end
    if element.tag ~= "goto" or element.generated then
        return result(nil, "not a guide .goto waypoint", "other")
    end
    -- Own text with letters is an explicit instruction ("Enter the crypt", or
    -- RestedXP's generated "Go to x,y"). Text without letters (">>1") is a
    -- placeholder authors use to suppress the generated text; not an instruction.
    if HasTravelInstruction(element) then
        return result(nil, "explicit travel instruction on this waypoint", "travel instruction")
    end

    local step = element.step
    local elements = type(step) == "table" and step.elements
    if type(elements) ~= "table" then return result(nil, "waypoint has no step instructions", "other") end
    local index = FindIndex(elements, element)
    if not index then return result(nil, "waypoint not found in its step", "other") end

    if type(element.parent) == "table" then
        local first, last = RXPW.Label.LinkedBlock(element)
        if not first then return result(nil, "invalid linked objective in this step", "other") end
        local candidate, reason = AnalyzeBlock(elements, first, last, "linked objective block")
        return result(candidate, reason, candidateRole(candidate, "other"))
    end

    -- The block after the waypoint. More waypoints first = route chain,
    -- unless this is a #loop patrol circuit around the objective area.
    local first = index + 1
    while first <= #elements do
        local e = elements[first]
        if not (type(e) == "table" and IsWaypointElement(e)) then break end
        if not step.loop then
            return result(nil, "intermediate route waypoint (more waypoints follow before the objective)", "route point")
        end
        first = first + 1
    end
    local last = first
    while last <= #elements do
        local e = elements[last]
        if type(e) == "table" and IsWaypointElement(e) then break end
        last = last + 1
    end
    local candidate, reason, summary = AnalyzeBlock(elements, first, last - 1,
        step.loop and "loop circuit block" or "following block", step.loop ~= nil)
    if candidate or not summary.onlyPlaceholders then
        if candidate and step.loop ~= nil then candidate.references = CircuitPoints(step) end
        return result(candidate, reason, candidateRole(candidate, step.loop ~= nil and "loop circuit" or "other"))
    end

    -- Nothing but a placeholder here: only a sticky #loop patrol step may hand
    -- over to the steps it serves (e.g. "#hidewindow / #completewith X / #loop
    -- / .goto ... / +1" in the Forever Skyborne guide).
    if IsStickyLoop(step) then
        candidate, reason = AnalyzeServedSteps(step)
        if candidate then candidate.references = CircuitPoints(step) end
        return result(candidate, reason, "patrol")
    end

    -- A sticky non-loop step with this single waypoint and no instructions is a
    -- navigation helper (e.g. "#completewith Harvesting Windstones2 / #hidewindow
    -- / .goto 2521,43.37,23.98,60 >>1"). Its quest context is the anchor step it
    -- completes with. It never becomes a native candidate by itself.
    if (step.sticky or step.completewith ~= nil) and PendingWaypointCount(step) == 1 then
        local anchor = FindAnchorStep(step)
        if anchor then
            local anchorCandidate, anchorReason = AnalyzeBlock(anchor.elements, 1, #anchor.elements,
                format("anchor step %s", tostring(anchor.index)))
            local helperReason = format("navigation helper step %s (completes with step %s): %s", tostring(step.index),
                tostring(anchor.index), anchorCandidate
                    and format("%s of quest %d", anchorCandidate.kind == "turnin" and "turn-in" or "objective", anchorCandidate.questID)
                    or tostring(anchorReason))
            return result(nil, helperReason, "helper",
                { helper = { step = step, anchor = anchor, candidate = anchorCandidate } })
        end
        return result(nil, reason .. "; helper step without an active anchor step", "other")
    end
    return result(nil, reason .. "; not a sticky #loop patrol step", "other")
end

--------------------------------------------------------------------------------
-- WoW quest and supertracking state
--------------------------------------------------------------------------------

local Inspect -- defined after GetQuestState

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

-- Returns { inLog, ready, title, objectives? }.
-- objectives (when withObjectives and the API exists): array of
-- { type, finished, numFulfilled, numRequired } in quest-log order.
function Nav.GetQuestState(questID, withObjectives)
    local QL = type(C_QuestLog) == "table" and C_QuestLog or {}
    local inLog = Call(QL.IsOnQuest, questID) and true or false
    local ready = false
    if inLog then
        ready = (Call(QL.ReadyForTurnIn, questID) or Call(QL.IsComplete, questID)) and true or false
    end
    local title = Call(QL.GetTitleForQuestID, questID)
    if type(title) ~= "string" or title == "" then title = nil end

    local objectives
    if withObjectives and inLog then
        local list = Call(QL.GetQuestObjectives, questID)
        if type(list) == "table" then
            objectives = {}
            for i, o in ipairs(list) do
                if type(o) == "table" then
                    objectives[i] = {
                        type = o.type,
                        finished = o.finished and true or false,
                        numFulfilled = o.numFulfilled,
                        numRequired = o.numRequired,
                    }
                end
            end
        end
    end
    return { inLog = inLog, ready = ready, title = title, objectives = objectives }
end

--------------------------------------------------------------------------------
-- On-demand inspection (/rxpw inspect): what the resolver sees
--------------------------------------------------------------------------------

local MAX_INSPECT_ELEMENTS = 16
local MAX_INSPECT_QUESTS = 4

local function DescribeStep(step)
    local flags = {}
    if step.loop ~= nil then flags[#flags + 1] = "#loop" end
    if step.completewith ~= nil then
        flags[#flags + 1] = "#completewith " .. tostring(step.completewith)
    elseif step.sticky then
        flags[#flags + 1] = "sticky"
    end
    if step.hidewindow ~= nil then flags[#flags + 1] = "#hidewindow" end
    flags[#flags + 1] = step.active and "active" or "inactive"
    return format("step %s (%s)", tostring(step.index or "?"), concat(flags, ", "))
end

local function DescribeElement(e)
    local parts = {}
    if IsWaypointElement(e) then
        parts[#parts + 1] = format(".%s %s, %s", tostring(e.tag or "waypoint"),
            RXPW.FormatCoord(e.x), RXPW.FormatCoord(e.y))
        if e.radius then parts[#parts + 1] = "radius " .. tostring(e.radius) end
        if e.hidePin then parts[#parts + 1] = "optional" end
        if e.lowPrio then parts[#parts + 1] = "lowPrio" end
        if e.dynamic then parts[#parts + 1] = "dynamic" end
        if type(e.parent) == "table" then parts[#parts + 1] = "linked to " .. DescribeInstruction(e.parent) end
        if type(e.text) == "string" and e.text:find("%S") then
            parts[#parts + 1] = format("travel text \"%s\"", tostring(RXPW.Label.Clean(e.text)))
        end
    else
        parts[#parts + 1] = DescribeInstruction(e)
        if type(e.questId) == "number" then
            parts[#parts + 1] = format("quest %d%s", e.questId, type(e.obj) == "number" and (" obj " .. e.obj) or "")
        end
        if e.textOnly then
            parts[#parts + 1] = "heading/helper"
        elseif IsPlaceholder(e) then
            parts[#parts + 1] = "placeholder"
        end
    end
    parts[#parts + 1] = IsDone(e) and "done" or "pending"
    return concat(parts, " | ")
end

local function AddStepLines(lines, step, marker, questIds)
    local count = 0
    for _, e in ipairs(step.elements) do
        if type(e) == "table" then
            count = count + 1
            if count > MAX_INSPECT_ELEMENTS then
                lines[#lines + 1] = format("    ... %d more", #step.elements - MAX_INSPECT_ELEMENTS)
                break
            end
            lines[#lines + 1] = format("  %s %s", e == marker and "->" or "  ", DescribeElement(e))
            if type(e.questId) == "number" then questIds[e.questId] = true end
        end
    end
end

-- Returns an array of lines describing the arrow element, its step, the
-- steps a patrol step serves, RestedXP's active steps and candidate quests.
Inspect = function(element)
    local lines = {}
    if type(element) ~= "table" then
        lines[1] = "No RestedXP arrow element."
        return lines
    end
    local questIds = {}
    lines[#lines + 1] = "Arrow element: " .. DescribeElement(element)

    local step = type(element.step) == "table" and element.step or nil
    if step and type(step.elements) == "table" then
        lines[#lines + 1] = "Arrow " .. DescribeStep(step) .. ":"
        AddStepLines(lines, step, element, questIds)
        if IsStickyLoop(step) then
            local served, why = GetServedSteps(step)
            if served then
                for _, s in ipairs(served) do
                    lines[#lines + 1] = "Served " .. DescribeStep(s) .. ":"
                    AddStepLines(lines, s, nil, questIds)
                end
            else
                lines[#lines + 1] = "Patrol step serves nothing: " .. tostring(why)
            end
        end
    end

    local active = GetActiveSteps()
    if active then
        local indexes = {}
        for _, s in ipairs(active) do
            if type(s) == "table" then indexes[#indexes + 1] = tostring(s.index or "tip") end
        end
        lines[#lines + 1] = "RestedXP active steps: " .. (#indexes > 0 and concat(indexes, ", ") or "none")
    else
        lines[#lines + 1] = "RestedXP active steps: unavailable"
    end

    local ids = {}
    for q in pairs(questIds) do ids[#ids + 1] = q end
    sort(ids)
    for i, q in ipairs(ids) do
        if i > MAX_INSPECT_QUESTS then break end
        local qs = Nav.GetQuestState(q, true)
        local objectives = {}
        for n, o in ipairs(qs.objectives or {}) do
            objectives[#objectives + 1] = format("%d %s %s", n, tostring(o.type or "?"),
                o.finished and "done" or format("%s/%s", tostring(o.numFulfilled or "?"), tostring(o.numRequired or "?")))
        end
        lines[#lines + 1] = format("Quest %d (%s): in log %s, ready %s%s", q, tostring(qs.title or "?"),
            qs.inLog and "yes" or "no", qs.ready and "yes" or "no",
            #objectives > 0 and (", objectives: " .. concat(objectives, "; ")) or "")
    end
    return lines
end

function Nav.Inspect(element)
    return Inspect(element)
end

local CLASSIFICATION = {
    monster = "kill",
    item = "collect",
    object = "interact",
    event = "event",
    reputation = "reputation",
    log = "log",
}

-- "obj 1 3/8, obj 2 done"
local function DescribeObjectives(objectives, wanted)
    local parts = {}
    for _, obj in ipairs(wanted) do
        local o = objectives and objectives[obj]
        if o then
            if o.finished then
                parts[#parts + 1] = format("obj %d done", obj)
            elseif type(o.numFulfilled) == "number" and type(o.numRequired) == "number" then
                parts[#parts + 1] = format("obj %d %d/%d", obj, o.numFulfilled, o.numRequired)
            else
                parts[#parts + 1] = format("obj %d open", obj)
            end
        else
            parts[#parts + 1] = format("obj %d ?", obj)
        end
    end
    return concat(parts, ", ")
end

-- Checks an objective candidate against the quest log.
-- Returns eligible, reason, classification, progress.
local function CheckObjective(candidate, questState)
    local q = candidate.questID
    if not questState.inLog then
        return false, format("quest %d is not in the quest log", q)
    end
    if questState.ready then
        return false, format("quest %d is already complete; RestedXP has not moved on yet", q)
    end
    local objectives = questState.objectives
    if not objectives then
        return false, "quest objectives are unavailable (C_QuestLog.GetQuestObjectives)"
    end

    local wanted, open = {}, nil
    for _, obj in ipairs(candidate.objectives) do
        wanted[obj] = true
        local o = objectives[obj]
        if not o then
            return false, format("quest %d has no objective %d", q, obj)
        end
        if not o.finished then open = open or obj end
    end
    local progress = DescribeObjectives(objectives, candidate.objectives)
    if not open then
        return false, format("RestedXP's objectives for quest %d are already finished", q), nil, progress
    end
    for i, o in pairs(objectives) do
        if not o.finished and not wanted[i] then
            return false, format("quest %d has another unfinished objective (%d) that RestedXP does not target here", q, i),
                nil, progress
        end
    end

    local classification = CLASSIFICATION[objectives[open].type] or tostring(objectives[open].type or "objective")
    return true, "quest objective eligible", classification, progress
end

function Nav.GetSuperTrackedQuest()
    local id = Call(C_SuperTrack and C_SuperTrack.GetSuperTrackedQuestID)
    if type(id) == "number" and id > 0 then return id end
    return nil
end

-- Snapshot for pending transitions, not an ownership claim about a quest ID.
-- Priority also detects non-quest destinations taking control.
function Nav.GetTrackingState()
    local ST = type(C_SuperTrack) == "table" and C_SuperTrack or {}
    local quest = Nav.GetSuperTrackedQuest()
    local priority = Call(ST.GetHighestPrioritySuperTrackingType)
    local empty = Call(ST.IsSuperTrackingAnything) == false or (quest == nil and priority == nil)
    return quest, priority, empty
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

-- Called after supertracking questID. Returns ok, detail, measurements.
-- measurements = { native, rxp, gap, tolerance, points } (yards; nil when unknown).
-- references: for a #loop circuit, every point of the circuit. RestedXP's
-- destination is then the whole patrol area, not the one point its arrow is
-- currently on (which can be the far side of the circuit). The smallest
-- |native - point| over all points is still a lower bound on the native
-- target's distance to the circuit, so the check stays one-sided: it only
-- rejects a native target that is provably far from EVERY patrol point.
function Nav.VerifyNative(target, questID, tolerance, references)
    tolerance = tolerance or Nav.TURNIN_TOLERANCE
    local m = { tolerance = tolerance }
    local current = Nav.GetSuperTrackedQuest()
    if current ~= questID then
        return false, format("supertracking did not take effect (now %s)", tostring(current or "none")), m
    end
    if not QuestHasPriority() then
        return false, "another supertracked target has priority over the quest", m
    end

    local nativeDistance = Call(C_Navigation.GetDistance)
    if type(nativeDistance) ~= "number" or nativeDistance <= 0 then
        return false, "no native navigation target for the quest", m
    end
    m.native = nativeDistance

    if type(references) == "table" and #references > 1 then
        local count = 0
        for _, element in ipairs(references) do
            local d = RXPW.RXP.GetDistanceToElement(element)
            if d then
                count = count + 1
                local gap = abs(nativeDistance - d)
                if not m.gap or gap < m.gap then
                    m.gap, m.rxp = gap, d
                end
            end
        end
        if count > 0 then
            m.points = count
            if m.gap > tolerance then
                return false, format("native target is at least %.0f yd from every one of RestedXP's %d patrol points (limit %d)",
                    m.gap, count, tolerance), m
            end
            return true, format("native %.0f yd vs nearest of %d RestedXP patrol points %.0f yd (gap %.0f, limit %d)",
                nativeDistance, count, m.rxp, m.gap, tolerance), m
        end
    end

    local rxpDistance = RXPW.RXP.GetDistanceToTarget(target)
    if rxpDistance then
        m.rxp = rxpDistance
        m.gap = abs(nativeDistance - rxpDistance)
        if m.gap > tolerance then
            return false, format("native target is at least %.0f yd from RestedXP's destination (limit %d)", m.gap, tolerance), m
        end
        return true, format("native %.0f yd vs RestedXP %.0f yd (gap %.0f, limit %d)", nativeDistance, rxpDistance, m.gap, tolerance), m
    end
    return true, format("native target at %.0f yd (RestedXP distance unknown)", nativeDistance), m
end

--------------------------------------------------------------------------------
-- Native activity area (v0.5.9, F8)
--
-- The native id ("objective:Q") says WHAT is tracked; it deliberately stays the
-- same while RestedXP cycles #loop points or progress changes, so the quest is
-- never re-supertracked. The activity says WHERE RestedXP is leading for it:
-- the objectives, the arrow's step and the steps holding the quest work, and
-- for a #loop circuit or patrol the circuit itself. Sync re-verifies (without
-- re-supertracking) when the activity changes, or when a non-circuit
-- destination moves further than the verification tolerance from the point the
-- native target was last verified against. The anchor is a value copy of the
-- arrow element's world position; no RestedXP table is retained.
--------------------------------------------------------------------------------

local function StepIndexes(steps)
    local list = {}
    for step in pairs(steps or {}) do
        if type(step) == "table" and type(step.index) == "number" then list[#list + 1] = step.index end
    end
    sort(list)
    return concat(list, ",")
end

local function Activity(nativeId, objectives, steps, stepIndex, circuit)
    return format("%s|obj %s|step %s|work %s%s", tostring(nativeId), concat(objectives or {}, ","),
        tostring(stepIndex or "-"), StepIndexes(steps), circuit and "|circuit" or "")
end

local function Anchor(element)
    if type(element) ~= "table" or not (RXPW.IsFiniteNumber(element.wx) and RXPW.IsFiniteNumber(element.wy)) then
        return nil
    end
    return { x = element.wx, y = element.wy, instance = element.instance }
end

-- Distance in yards between two anchors (HereBeDragons world coordinates are
-- yards); math.huge on different continents or when unknown.
function Nav.AnchorDistance(a, b)
    if not (a and b) or a.instance ~= b.instance then return math.huge end
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

--------------------------------------------------------------------------------
-- Quest selection inside a shared farming circuit (v0.5.3)
--
-- When a #loop circuit (own step or patrol step) serves objectives of several
-- quests, every quest is relevant to the area; only the order is open.
-- RestedXP has no structured priority field (no #track in the Forever
-- guides; "Prioritize them" is plain guide text), so the order is:
--   1. explicit priority: a text-only line starting with "Prioritize" in a
--      step whose pending objectives all belong to ONE candidate quest
--      (English guide text; other locales simply skip this rule)
--   2. RestedXP's current step: the non-sticky active step (sticky
--      #completewith steps are background work that finishes with it)
--   3. keep the quest already tracked (by the bridge, else by WoW) if it is
--      still an eligible candidate: avoids needless switching
--   4. RestedXP's guide order (lowest step index, then line order)
-- Every candidate must pass CheckObjective (in log, unfinished, coverage).
-- Candidates whose native target recently failed verification are skipped.
--------------------------------------------------------------------------------

local function IsPriorityLine(element)
    if element.tag ~= nil or not element.textOnly or type(element.text) ~= "string" then return nil end
    local text = RXPW.Label.Clean(element.text)
    if text and text:lower():find("^prioriti[sz]e") then return text end
    return nil
end

-- Quest IDs with pending objectives or turn-ins in a step.
local function PendingQuests(step)
    local set, count = {}, 0
    for _, e in ipairs(step.elements or {}) do
        if type(e) == "table" and not IsDone(e) and (IsObjective(e) or IsTurnIn(e)) and not set[e.questId] then
            set[e.questId] = true
            count = count + 1
        end
    end
    return set, count
end

local function IsCurrentStep(step)
    return step.active and not step.sticky and step.completewith == nil
end

-- Priority text that applies to exactly this candidate's quest, or nil.
local function PriorityFor(entry)
    for step in pairs(entry.steps or {}) do
        local quests, count = PendingQuests(step)
        if count == 1 and quests[entry.questID] then
            for _, e in ipairs(step.elements or {}) do
                local text = type(e) == "table" and IsPriorityLine(e)
                if text then return text, step end
            end
        end
    end
    return nil
end

local function CurrentStepFor(entry)
    for step in pairs(entry.steps or {}) do
        if IsCurrentStep(step) then return step end
    end
    return nil
end

local function MinStepIndex(entry)
    local best
    for step in pairs(entry.steps or {}) do
        if type(step.index) == "number" and (not best or step.index < best) then best = step.index end
    end
    return best or math.huge
end

-- Returns selected entry (or nil), selection reason, list of all entries.
-- entry = { questID, title, objectives, steps, eligible, reason, classification,
--           progress, questState, blocked, selected }
local function SelectQuest(candidate, context, stepIndex)
    context = context or {}
    local list, eligible = {}, {}
    for _, info in ipairs(candidate.quests) do
        local qs = Nav.GetQuestState(info.questID, true)
        local ok, reason, classification, progress = CheckObjective(info, qs)
        local entry = {
            questID = info.questID, title = qs.title or info.title, objectives = info.objectives,
            steps = info.steps, firstPos = info.firstPos, eligible = ok, reason = reason,
            classification = classification, progress = progress, questState = qs,
        }
        local id = "objective:" .. tostring(info.questID)
        entry.activity = Activity(id, info.objectives, info.steps, stepIndex, candidate.references ~= nil)
        if ok and context.blockedReason then
            local blocked = context.blockedReason(id, progress, entry.activity)
            if blocked then
                entry.eligible = false
                entry.blocked = true
                entry.reason = "native target failed verification recently: " .. blocked
            end
        end
        list[#list + 1] = entry
        if entry.eligible then eligible[#eligible + 1] = entry end
    end

    local function pick(entry, why)
        entry.selected = true
        return entry, why, list
    end

    if #eligible == 0 then return nil, "no eligible candidate quest", list end
    if #eligible == 1 then return pick(eligible[1], "only eligible candidate") end

    local prioritized, text
    for _, entry in ipairs(eligible) do
        local found = PriorityFor(entry)
        if found then
            if prioritized then prioritized = false break end
            prioritized, text = entry, found
        end
    end
    if prioritized then return pick(prioritized, format("explicit RestedXP priority (\"%s\")", text)) end

    local current, currentStep
    for _, entry in ipairs(eligible) do
        local step = CurrentStepFor(entry)
        if step then
            if current then current = false break end
            current, currentStep = entry, step
        end
    end
    if current then return pick(current, format("RestedXP's current step %s", tostring(currentStep.index))) end

    local supertracked = Nav.GetSuperTrackedQuest()
    for _, entry in ipairs(eligible) do
        if context.currentQuest and entry.questID == context.currentQuest then
            return pick(entry, "already tracked by the bridge")
        end
    end
    for _, entry in ipairs(eligible) do
        if supertracked and entry.questID == supertracked then
            return pick(entry, "already supertracked")
        end
    end

    sort(eligible, function(a, b)
        local ia, ib = MinStepIndex(a), MinStepIndex(b)
        if ia ~= ib then return ia < ib end
        return (a.firstPos or 0) < (b.firstPos or 0)
    end)
    local first = eligible[1]
    local index = MinStepIndex(first)
    return pick(first, format("first in RestedXP's guide order (step %s)", index == math.huge and "?" or tostring(index)))
end

--------------------------------------------------------------------------------
-- Marker presentation for coordinate waypoints (v0.5.5)
--
-- Waypoint UI picks the native quest marker icon from the quest's state
-- (Available / Incomplete / Complete) and type (Waypoint_ContextIcon.lua:
-- C_QuestInfoSystem.GetQuestClassification, C_QuestLog.GetQuestType,
-- C_QuestLog.IsRepeatableQuest). When the bridge follows a RestedXP
-- coordinate for a quest step, the same state and type are resolved here so
-- the custom marker can carry the icon the native marker would show
-- (WUI.GetQuestIcon). Presentation only: never changes navigation.
--------------------------------------------------------------------------------

-- Quest types Waypoint UI ships icons for (Art\Icons\<State><Type>Quest).
local ICON_TYPES = { Important = true, Campaign = true, Legendary = true, Calling = true,
                     Meta = true, Recurring = true, Repeatable = true }

-- Type part of Waypoint UI's quest icon name ("" for a normal quest).
function Nav.GetQuestIconType(questID)
    local QC = Enum and Enum.QuestClassification
    local QIS = type(C_QuestInfoSystem) == "table" and C_QuestInfoSystem or {}
    local QL = type(C_QuestLog) == "table" and C_QuestLog or {}
    local classification = Call(QIS.GetQuestClassification, questID)
    local questType = Call(QL.GetQuestType, questID)
    local key
    if QC and classification ~= nil then
        if classification == QC.Important then key = "Important"
        elseif classification == QC.Campaign then key = "Campaign"
        elseif classification == QC.Legendary then key = "Legendary"
        elseif classification == QC.Calling then key = "Calling"
        elseif classification == QC.Meta then key = "Meta"
        elseif classification == QC.Recurring then key = "Recurring"
        end
    end
    if not key and Enum and Enum.QuestTag and questType ~= nil and questType == Enum.QuestTag.Legendary then
        key = "Legendary"
    end
    if not key and (not QC or classification ~= QC.Normal) and Call(QL.IsRepeatableQuest, questID) then
        key = "Repeatable"
    end
    return ICON_TYPES[key] and key or ""
end

-- First pending actionable instruction of the associated waypoint block.
-- Returns kind ("accept" / "turnin" / "objective"), questID; nil otherwise
-- (a step that starts with a non-quest action gets no quest presentation).
local function StepActivity(step, first, last)
    for i = first, last do
        local e = step.elements[i]
        if type(e) == "table" and not IsWaypointElement(e) and not IsDone(e) and not e.textOnly
            and not IsPlaceholder(e) then
            if e.tag == "accept" and type(e.questId) == "number" and e.questId > 0 then return "accept", e.questId end
            if IsTurnIn(e) then return "turnin", e.questId end
            if IsObjective(e) then return "objective", e.questId end
            return nil
        end
    end
    return nil
end

-- Waypoint UI's marker colour for a quest state (DataProviderUtil.GetTrackingType
-- + Waypoint.GetTintColorInfo): incomplete -> IncompleteQuest; complete ->
-- RepeatableQuest (Recurring/Meta/Calling), ImportantQuest (Important) or
-- NormalQuest. Available quests are not tracked natively, so they keep
-- Waypoint UI's "Other" colour (nil here = no explicit colour).
local function TintKey(questID, status)
    if status == "Incomplete" then return "IncompleteQuest" end
    if status ~= "Complete" then return nil end
    local QC = Enum and Enum.QuestClassification
    local QIS = type(C_QuestInfoSystem) == "table" and C_QuestInfoSystem or {}
    local classification = Call(QIS.GetQuestClassification, questID)
    if QC and classification ~= nil then
        if classification == QC.Recurring or classification == QC.Meta or classification == QC.Calling then
            return "RepeatableQuest"
        elseif classification == QC.Important then
            return "ImportantQuest"
        end
    end
    return "NormalQuest"
end

-- Service steps (v0.5.6): flight master, innkeeper, stable master, trainers,
-- food and drink, repair.
-- Detected from RestedXP's structured tags in the waypoint's step:
--   .fp / .fly                      -> FlightMaster
--   .home (set hearthstone)         -> Innkeeper
--   .stable                         -> StableMaster
--   .trainer / .train  + .skill     -> ProfessionTrainer (".skill <profession>" gates the step)
--   .trainer / .train  (no .skill)  -> ClassTrainer (also pet/weapon trainers)
--     (a step with .use is learning from an item, e.g. "Mining for Dummies": no icon)
--   .vendor + .collect of a food & drink item -> FoodAndDrink
--     (item class from GetItemInfoInstant: Consumable / Food & Drink)
--   .vendor whose text mentions "repair"      -> Repair
--     (RestedXP has no repair tag; English guide text, like "Prioritize")
--   any other .vendor (sell junk / restock)   -> Vendor
--   .bankdeposit / .bankwithdraw              -> Banker
--   .xp grind target (not a skip-step / "<" condition) -> Grind
-- v0.6.1: resolve only the current waypoint's instruction block. A .train
-- condition is not a visit to a trainer, and .collect needs purchase evidence.
local function GetItemInfoInstantSafe(itemID)
    local fn = (type(C_Item) == "table" and C_Item.GetItemInfoInstant) or _G.GetItemInfoInstant
    if type(fn) ~= "function" then return nil end
    local ok, _, _, _, _, _, classID, subclassID = pcall(fn, itemID)
    if ok then return classID, subclassID end
    return nil
end

function Nav.IsFoodOrDrink(itemID)
    if type(itemID) ~= "number" then return false end
    local classID, subclassID = GetItemInfoInstantSafe(itemID)
    local consumable = Enum and Enum.ItemClass and Enum.ItemClass.Consumable or 0
    local foodDrink = Enum and Enum.ItemConsumableSubclass and Enum.ItemConsumableSubclass.Fooddrink or 5
    return classID == consumable and subclassID == foodDrink
end

local function StepHasTag(step, tag)
    for _, e in ipairs(step.elements) do
        if type(e) == "table" and e.tag == tag and not IsDone(e) then return true end
    end
    return false
end

local function ServiceText(text)
    local clean = RXPW.Label.Clean(text)
    return clean and clean:lower() or ""
end

local function IsPurchaseText(text)
    return ServiceText(text):find("^buy%f[%W]") ~= nil
end

local function IsTraining(e)
    -- functions.train: bit 1 = text-only condition, bit 2 = reverse condition.
    local flags = type(e.flags) == "number" and e.flags or 0
    return not e.textOnly and not e.reverse and flags % 4 == 0
end

local SERVICE_TAGS = { fp = true, fly = true, home = true, stable = true,
    bankdeposit = true, bankwithdraw = true, vendor = true,
    buy = true, buyAll = true, buyUntilBroke = true }

-- No crossing an instruction-bearing waypoint boundary. Consecutive route
-- points may share the block at their end, as they do in the label resolver.
local function ServiceBlock(element, step)
    local elements = step.elements
    local index = FindIndex(elements, element)
    if not index then return nil end
    local last, hasAction = #elements, false
    for i = index + 1, #elements do
        local e = elements[i]
        if type(e) == "table" then
            if IsWaypointElement(e) then
                if hasAction then last = i - 1; break end
            elseif SERVICE_TAGS[e.tag] or ((e.tag == "train" or e.tag == "trainer") and IsTraining(e))
                or (not e.textOnly and (e.text ~= nil or e.tag == "collect")) then
                -- Count completed instructions too: they still define a boundary.
                hasAction = true
            end
        end
    end
    if hasAction then return index + 1, last, "following instruction" end
    if type(element.parent) == "table" then
        local first, linkedLast = RXPW.Label.LinkedBlock(element)
        return first, linkedLast, "linked instruction"
    end
    -- Some guides put service instructions before their first/only waypoint.
    for i = 1, index - 1 do
        local e = elements[i]
        if type(e) == "table" and IsWaypointElement(e) then return nil end
    end
    return 1, last, "waypoint instruction block"
end

-- Returns service key, source and structural association. Never uses the
-- selected display label as evidence (it may be a title or a fallback).
local function StepService(step, element)
    if not step.active or type(step.elements) ~= "table" or type(element) ~= "table"
        or IsDone(element) then return nil end
    local first, last, association = ServiceBlock(element, step)
    if not first then return nil end
    local block = { elements = {} }
    for i = first, last do block.elements[#block.elements + 1] = step.elements[i] end
    -- Prefix conditions (e.g. .skill before the first .goto) apply here too.
    local prefix = {}
    for _, e in ipairs(step.elements) do
        if type(e) == "table" and IsWaypointElement(e) then
            if e == element then
                for _, qualifier in ipairs(prefix) do block.elements[#block.elements + 1] = qualifier end
            end
            break
        end
        if type(e) == "table" and (e.tag == "skill" or e.tag == "use") then
            prefix[#prefix + 1] = e
        end
    end
    local heading
    local function result(service, source)
        return service, source, association
    end
    for _, e in ipairs(block.elements) do
        if type(e) == "table" and IsDone(e) and (not e.textOnly or SERVICE_TAGS[e.tag]) then
            heading = nil
        end
        if type(e) == "table" and not IsDone(e) and not IsWaypointElement(e) then
            local tag = e.tag
            if tag == "fp" or tag == "fly" then
                return result("FlightMaster", "." .. tag)
            elseif tag == "home" then
                return result("Innkeeper", ".home")
            elseif tag == "stable" then
                return result("StableMaster", ".stable")
            elseif tag == "bankdeposit" or tag == "bankwithdraw" then
                return result("Banker", "." .. tag)
            elseif tag == "xp" and not e.textOnly and not e.reverseLogic then
                -- ".xp 2 >> Grind to level 2"; ".xp <6,1" (skip-step / reverse) are conditions
                return result("Grind", ".xp")
            elseif (tag == "trainer" or tag == "train") and IsTraining(e) then
                if not StepHasTag(block, "use") then
                    if StepHasTag(block, "skill") then return result("ProfessionTrainer", "." .. tag .. " + .skill") end
                    return result("ClassTrainer", "." .. tag)
                end
                return nil
            elseif tag == "vendor" then
                for _, c in ipairs(block.elements) do
                    if type(c) == "table" and c.tag == "collect" and not IsDone(c) and Nav.IsFoodOrDrink(c.id) then
                        return result("FoodAndDrink", ".vendor + food/drink .collect")
                    end
                end
                if ServiceText(e.text):find("%f[%a]repair%f[%A]") then return result("Repair", ".vendor (repair)") end
                return result("Vendor", ".vendor")
            elseif tag == "buy" or tag == "buyAll" or tag == "buyUntilBroke"
                or (tag == "collect" and (IsPurchaseText(e.text)
                    or (ServiceText(e.text) == "" and IsPurchaseText(heading)))) then
                return result(Nav.IsFoodOrDrink(e.id) and "FoodAndDrink" or "Vendor", "." .. tag .. " (purchase)")
            elseif not tag and e.textOnly and not e.hideTooltip then
                heading = e.text
            elseif not e.textOnly and (e.text ~= nil or tag == "collect") then
                -- An unrecognised active action is not permission to search for
                -- a more attractive service later in the step.
                return nil
            end
        end
    end
    return nil
end
Nav.StepService = StepService

-- Returns { questID, status = "Available"|"Incomplete"|"Complete", iconType, tintKey, source },
-- or { service = "FlightMaster"|"ClassTrainer"|..., source } for a service step, or nil.
-- Uses the decision's quest context when it has one (structural association,
-- v0.5.4), else the waypoint's own step activity (the quest work the step is
-- leading to, e.g. a collection route before "Click on the Crystals").
function Nav.GetPresentation(target, decision)
    local c = decision and decision.context
    if c then
        local status = c.ready and "Complete" or "Incomplete"
        return { questID = c.questID, status = status, iconType = Nav.GetQuestIconType(c.questID),
                 tintKey = TintKey(c.questID, status), source = tostring(c.source), kind = c.kind }
    end
    local element = target and target.element
    local step = type(element) == "table" and type(element.step) == "table" and element.step or nil
    if not step or type(step.elements) ~= "table" then return nil end
    -- The step can contain several destinations. An earlier quest acceptance
    -- must not lend its icon to a later vendor/trainer visit (or vice versa).
    -- Keep explicit quest context above authoritative; scope only the fallback.
    local first, last = ServiceBlock(element, step)
    if not first then return nil end
    local kind, questID = StepActivity(step, first, last)
    if not kind then
        local service, source, association = StepService(step, element)
        if service then
            return { service = service, source = format("step %s %s", tostring(step.index or "?"), source),
                     serviceSource = association .. " " .. source }
        end
        return nil
    end
    local qs = Nav.GetQuestState(questID)
    local status
    if qs.inLog then
        status = qs.ready and "Complete" or "Incomplete"
    elseif kind == "accept" then
        status = "Available"
    end
    if not status then return nil end
    return { questID = questID, status = status, iconType = Nav.GetQuestIconType(questID),
             tintKey = TintKey(questID, status), source = format("step %s %s", tostring(step.index or "?"), kind),
             kind = kind, title = qs.title }
end

-- Quest context: what the player is working on, independent of how they are
-- navigated (v0.5.4). Only built from a structural association and a quest
-- that is in the log right now, so it can never outlive the quest.
local function MakeContext(questID, questState, kind, source)
    if not (questState and questState.inLog and type(questState.title) == "string") then return nil end
    return { questID = questID, title = questState.title, kind = kind,
             ready = questState.ready and true or false, source = source }
end

-- Native continuity through a helper waypoint (v0.5.4). Keeps the bridge's
-- active native turn-in only when ALL hold:
--   * the helper's anchor step's first pending instruction is the turn-in of
--     the quest the bridge is already tracking natively as a turn-in
--     (turn-ins have one destination, the quest giver; objective areas can
--     have several clusters, so objectives never use continuity)
--   * no native transition is in progress, the quest is in the log and ready
--   * WoW is still supertracking that quest (no player/RestedXP override)
--   * the native target passes the turn-in distance check against the
--     helper waypoint (one-sided: rejects a helper that is provably elsewhere)
-- Otherwise the helper is followed with coordinates.
local function DecideHelper(decision, target, helper, context)
    local hc = helper.candidate
    local q = hc.questID
    local qs = Nav.GetQuestState(q, hc.kind == "objective")
    local source = format("helper step %s -> step %s", tostring(helper.step.index), tostring(helper.anchor.index))
    decision.context = MakeContext(q, qs, hc.kind, source)
    if hc.kind ~= "turnin" then
        decision.continuity = { ok = false, detail = "only turn-ins keep native tracking through helper waypoints" }
        return
    end

    context = context or {}
    local why
    if not (context.currentQuest == q and context.currentKind == "turnin") then
        why = format("native turn-in of quest %d is not active", q)
    elseif context.pending then
        why = "a native transition is in progress"
    elseif not (qs.inLog and qs.ready) then
        why = format("quest %d is not ready for turn-in", q)
    elseif not Nav.IsNativeQuestActive(q) then
        why = format("quest %d is no longer supertracked", q)
    end
    if why then
        decision.continuity = { ok = false, detail = why }
        decision.reason = decision.reason .. "; native continuity not applicable: " .. why
        return
    end

    local ok, detail, m = Nav.VerifyNative(target, q, Nav.TURNIN_TOLERANCE)
    decision.continuity = { ok = ok, detail = detail }
    if not ok then
        decision.reason = "native continuity rejected: " ..
            (m and m.gap and "the native target is not consistent with the helper waypoint" or detail)
        return
    end
    decision.kind = "turnin"
    decision.questID = q
    decision.questState = qs
    decision.questName = qs.title
    decision.classification = "turn-in"
    decision.tolerance = Nav.TURNIN_TOLERANCE
    decision.nativeId = format("turnin:%s", tostring(q))
    decision.activity = format("%s|helper step %s", decision.nativeId, tostring(helper.step.index))
    decision.anchor = Anchor(target.element)
    decision.nativeEligible = true
    decision.reason = format("native continuity: helper step %s leads to the same turn-in (quest %d, step %s)",
        tostring(helper.step.index), q, tostring(helper.anchor.index))
end

--------------------------------------------------------------------------------
-- Decision
--------------------------------------------------------------------------------

-- Returns decision:
--   mode            "native" or "coordinates" for the given strategy
--   reason          why
--   nativeEligible  true when the analysed candidate passed every check
--   kind            "turnin" or "objective" (when a candidate was found)
--   classification  "turn-in", "kill", "collect", "interact", ...
--   questID, questName, questState, objectives, progress, pendingTurnIns
--   candidates      (shared circuit only) every candidate quest with its state
--   selection       (shared circuit only) why the selected quest won
--   nativeId        identity of the native state (Sync compares it)
--   activity        (v0.5.9) native id + where RestedXP leads for it; a change
--                   means re-verify the unchanged native quest (see Activity)
--   anchor          (v0.5.9) { x, y, instance } copy of the arrow's world
--                   position outside circuits, for the moved-destination check
--   tolerance       verification tolerance for this kind
--   references      circuit points for verification (#loop / patrol)
--   analysis        "hybrid" or "native-first" (which resolver produced it)
--   role, routeCritical   (native-first) what the waypoint is, see FindQuestTarget
--   context         (native-first) quest context for coordinate labels: { questID, title, kind, ready, source }
--   continuity      (helper waypoints) { ok, detail } of the native continuity check
-- context (optional, from Sync): { currentQuest, currentKind, pending, blockedReason(nativeId, progress, activity) }
function Nav.Decide(target, strategy, context)
    local useHybrid = strategy == "hybrid"
    local decision = { mode = "coordinates", nativeEligible = false,
                       analysis = useHybrid and "hybrid" or "native-first" }

    local candidate, why, info
    if useHybrid then
        candidate, why = Nav.FindTurnIn(target.element)
    else
        candidate, why, info = Nav.FindQuestTarget(target.element)
    end
    decision.role = info and info.role or nil
    decision.routeCritical = info and info.routeCritical or false

    if not candidate then
        decision.reason = why
        if info and info.helper and info.helper.candidate then
            DecideHelper(decision, target, info.helper, context)
        end
    elseif candidate.kind == "multi" then
        decision.kind = "objective"
        decision.tolerance = Nav.OBJECTIVE_TOLERANCE
        decision.references = candidate.references
        if not Nav.IsNativeSupported() then
            decision.reason = "native quest supertracking is not available in this client"
        else
            local selected, selection, list = SelectQuest(candidate, context, target.stepIndex)
            decision.candidates = list
            decision.selection = selection
            if not selected then
                decision.reason = format("%s: %s", candidate.via, selection)
            else
                decision.questID = selected.questID
                decision.questName = selected.title
                decision.questState = selected.questState
                decision.objectives = selected.objectives
                decision.progress = selected.progress
                decision.classification = selected.classification or "objective"
                decision.activity = selected.activity
                decision.nativeEligible = true
                decision.reason = format("quest objective eligible (%s); selected quest %d: %s",
                    candidate.via, selected.questID, selection)
            end
        end
        if decision.questID then
            decision.nativeId = format("objective:%s", tostring(decision.questID))
        end
    else
        local q = candidate.questID
        decision.kind = candidate.kind
        decision.questID = q
        decision.pendingTurnIns = candidate.pendingTurnIns
        decision.objectives = candidate.objectives
        decision.references = candidate.references
        local questState = Nav.GetQuestState(q, candidate.kind == "objective")
        decision.questState = questState
        decision.questName = questState.title
            or (type(candidate.title) == "string" and candidate.title ~= "" and candidate.title) or nil

        if candidate.kind == "turnin" then
            decision.classification = "turn-in"
            decision.tolerance = Nav.TURNIN_TOLERANCE
            if not Nav.IsNativeSupported() then
                decision.reason = "native quest supertracking is not available in this client"
            elseif not questState.inLog then
                decision.reason = format("quest %d is not in the quest log", q)
            elseif not questState.ready then
                decision.reason = format("quest %d is not ready for turn-in", q)
            else
                decision.nativeEligible = true
                decision.reason = format("confirmed turn-in destination (%s)", candidate.via)
            end
        else
            decision.tolerance = Nav.OBJECTIVE_TOLERANCE
            if not Nav.IsNativeSupported() then
                decision.reason = "native quest supertracking is not available in this client"
            else
                local eligible, reason, classification, progress = CheckObjective(candidate, questState)
                decision.classification = classification or "objective"
                decision.progress = progress
                decision.nativeEligible = eligible
                decision.reason = eligible and format("%s (%s)", reason, candidate.via) or reason
            end
        end

        if useHybrid then
            -- v0.4 identity: destination + quest.
            decision.nativeId = format("%s#%s", tostring(target.key), tostring(q))
        else
            -- v0.5 identity: what is tracked, not where RestedXP's point is, so
            -- RestedXP cycling #loop points does not re-supertrack the quest.
            decision.nativeId = format("%s:%s", candidate.kind, tostring(q))
        end
        decision.activity = useHybrid and decision.nativeId
            or Activity(decision.nativeId, candidate.objectives, candidate.steps, target.stepIndex,
                candidate.references ~= nil)

        -- A native target that recently failed verification is not retried
        -- until Sync's retry conditions are met.
        if decision.nativeEligible and context and context.blockedReason then
            local blocked = context.blockedReason(decision.nativeId, decision.progress, decision.activity)
            if blocked then
                decision.nativeEligible = false
                decision.reason = "native target failed verification recently: " .. blocked
            end
        end
    end

    if decision.activity and not decision.anchor and not (decision.references and #decision.references > 1) then
        decision.anchor = Anchor(target.element)
    end

    if not decision.context and decision.questID and not useHybrid then
        decision.context = MakeContext(decision.questID, decision.questState, decision.kind,
            decision.role or "quest instruction")
    end

    if decision.nativeEligible then
        if strategy == "hybrid" or strategy == "native-first" then
            decision.mode = "native"
        else
            decision.reason = "coordinates strategy selected (native-first would use the native quest)"
        end
    end
    return decision
end

-- Quest context for presentation, whatever the navigation strategy (v0.5.6).
-- Where the waypoint is comes from RestedXP and the decision; which quest it
-- belongs to (icon, colour, fallback label) uses the native-first structural
-- analysis in every mode. The hybrid resolver does not build context, so in
-- hybrid the analysis is repeated with the coordinates strategy, which never
-- selects native mode and is given no Sync context (no continuity check, no
-- retry bookkeeping): it only describes the waypoint.
function Nav.GetContextDecision(target, decision)
    if decision and decision.analysis == "native-first" then return decision end
    return Nav.Decide(target, "coordinates")
end
