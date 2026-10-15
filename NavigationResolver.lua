-- RXP Waypoint Bridge
-- NavigationResolver: decides whether RestedXP's current arrow target should
-- be shown as a coordinate waypoint (Mode A) or as WoW's native supertracked
-- quest (Mode B), and wraps the native supertracking calls.
--
-- Strategies
--   coordinates   always Mode A.
--   hybrid        (v0.4, unchanged) only quest TURN-INS go native, using
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

local _, ns = ...
local Nav = ns.Nav

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

local function IsDone(element)
    return element.completed or element.skip
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

-- v0.4 hybrid analysis (unchanged). Returns candidate, reason.
-- candidate = { kind = "turnin", questID, title, pendingTurnIns, via }.
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
        and (ns.Label.Clean(element.text) or element.text:gsub("|", "/"):sub(1, 40)) or nil
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
        if type(e) == "table" and IsWaypointElement(e) and ns.IsFiniteNumber(e.wx) and ns.IsFiniteNumber(e.wy) then
            points[#points + 1] = e
        end
    end
    return points
end

-- v0.5 native-first analysis. Returns candidate, reason.
-- candidate = { kind = "turnin"|"objective", questID, title?, objectives?, pendingTurnIns?, via, references? }.
function Nav.FindQuestTarget(element)
    if type(element) ~= "table" then return nil, "no RestedXP waypoint" end
    if element.tag ~= "goto" or element.generated then
        return nil, "not a guide .goto waypoint"
    end
    if type(element.text) == "string" and element.text:find("%S") then
        return nil, "explicit travel instruction on this waypoint"
    end

    local step = element.step
    local elements = type(step) == "table" and step.elements
    if type(elements) ~= "table" then return nil, "waypoint has no step instructions" end
    local index = FindIndex(elements, element)
    if not index then return nil, "waypoint not found in its step" end

    if type(element.parent) == "table" then
        -- The block above the waypoint, back to the previous waypoint.
        local first = index - 1
        while first >= 1 do
            local e = elements[first]
            if type(e) == "table" and IsWaypointElement(e) then break end
            first = first - 1
        end
        local candidate, reason = AnalyzeBlock(elements, first + 1, index - 1, "linked objective block")
        return candidate, reason
    end

    -- The block after the waypoint. More waypoints first = route chain,
    -- unless this is a #loop patrol circuit around the objective area.
    local first = index + 1
    while first <= #elements do
        local e = elements[first]
        if not (type(e) == "table" and IsWaypointElement(e)) then break end
        if not step.loop then
            return nil, "intermediate route waypoint (more waypoints follow before the objective)"
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
        return candidate, reason
    end

    -- Nothing but a placeholder here: only a sticky #loop patrol step may hand
    -- over to the steps it serves (e.g. "#hidewindow / #completewith X / #loop
    -- / .goto ... / +1" in the Forever Skyborne guide).
    if IsStickyLoop(step) then
        candidate, reason = AnalyzeServedSteps(step)
        if candidate then candidate.references = CircuitPoints(step) end
        return candidate, reason
    end
    return nil, reason .. "; not a sticky #loop patrol step"
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
-- On-demand inspection (/rxpwb inspect): what the resolver sees
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
            ns.FormatCoord(e.x), ns.FormatCoord(e.y))
        if e.radius then parts[#parts + 1] = "radius " .. tostring(e.radius) end
        if e.hidePin then parts[#parts + 1] = "optional" end
        if e.lowPrio then parts[#parts + 1] = "lowPrio" end
        if e.dynamic then parts[#parts + 1] = "dynamic" end
        if type(e.parent) == "table" then parts[#parts + 1] = "linked to " .. DescribeInstruction(e.parent) end
        if type(e.text) == "string" and e.text:find("%S") then
            parts[#parts + 1] = format("travel text \"%s\"", tostring(ns.Label.Clean(e.text)))
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
            local d = ns.RXP.GetDistanceToElement(element)
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

    local rxpDistance = ns.RXP.GetDistanceToTarget(target)
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
    local text = ns.Label.Clean(element.text)
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
local function SelectQuest(candidate, context)
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
        if ok and context.blockedReason then
            local blocked = context.blockedReason("objective:" .. tostring(info.questID), progress)
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
--   tolerance       verification tolerance for this kind
--   references      circuit points for verification (#loop / patrol)
--   analysis        "hybrid" or "native-first" (which resolver produced it)
-- context (optional, from Sync): { currentQuest, blockedReason(nativeId, progress) }
function Nav.Decide(target, strategy, context)
    local useHybrid = strategy == "hybrid"
    local decision = { mode = "coordinates", nativeEligible = false,
                       analysis = useHybrid and "hybrid" or "native-first" }

    local candidate, why
    if useHybrid then
        candidate, why = Nav.FindTurnIn(target.element)
    else
        candidate, why = Nav.FindQuestTarget(target.element)
    end

    if not candidate then
        decision.reason = why
    elseif candidate.kind == "multi" then
        decision.kind = "objective"
        decision.tolerance = Nav.OBJECTIVE_TOLERANCE
        decision.references = candidate.references
        if not Nav.IsNativeSupported() then
            decision.reason = "native quest supertracking is not available in this client"
        else
            local selected, selection, list = SelectQuest(candidate, context)
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

        -- A native target that recently failed verification is not retried
        -- until Sync's retry conditions are met.
        if decision.nativeEligible and context and context.blockedReason then
            local blocked = context.blockedReason(decision.nativeId, decision.progress)
            if blocked then
                decision.nativeEligible = false
                decision.reason = "native target failed verification recently: " .. blocked
            end
        end
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
