-- RXP Waypoint Bridge
-- Sync: the single controller that turns RestedXP's current target into
-- Waypoint UI navigation, automatically or on /rxpwb sync.
--
-- Mechanism
--   A 0.25 s ticker asks RXPAdapter whether RestedXP's arrow target changed
--   (a few raw field comparisons). A changed target must stay unchanged for
--   SETTLE_TIME before it is evaluated, which absorbs transient states while
--   RestedXP updates. RestedXP assigns RXPG_ARROW.element as a plain field
--   inside private functions, so there is nothing reliable to hook, and
--   RXP_STEP_ACTIVATED misses waypoint changes within a step. Polling the
--   resolved target covers both.
--   With the hybrid strategy, quest events (turn-in, accept, log update)
--   also schedule one coalesced evaluation, because a turn-in becoming ready
--   or done changes the desired mode without moving RestedXP's arrow.
--
-- Modes (decided by NavigationResolver)
--   coordinates  Waypoint UI custom navigation at RestedXP's coordinates.
--   native       WoW's supertracked quest (eligible quest turn-ins, hybrid only).
--   The handled state is (mode, destination key, quest); evaluation is
--   idempotent: an unchanged desired state never causes a write.
--
-- Write rules
--   * Waypoint UI is written only when the desired state differs from the
--     last one the bridge handled (or on /rxpwb sync).
--   * Missing, stale or invalid RestedXP targets never clear or replace the
--     current navigation.
--   * A destination Waypoint UI rejected is not retried until the target
--     changes or the player zones; a quest whose native target failed
--     verification is not retried for that destination until the player
--     zones or the strategy changes.
--   * The bridge never reacts to outside navigation changes by writing. If
--     the player changes what Waypoint UI follows, the bridge leaves it alone
--     until RestedXP moves to a new destination; while a waypoint the bridge
--     did not create is tracked, mode changes at the same destination are
--     also held back. RestedXP supertracking the bridge's own native quest
--     counts as the bridge's navigation, not an outside change.
--   * On the first evaluation after login or /rxpwb on, an already tracked
--     waypoint the bridge did not create is respected the same way.
--   * Labels: same coordinates, different description -> the coordinate
--     navigation is re-sent silently (renames it), only while Waypoint UI is
--     still following the bridge's navigation.
--
-- Native transitions
--   coordinates -> native: clear ONLY the bridge's own custom navigation,
--     wait NATIVE_SET_DELAY (Waypoint UI's waypoint-removed handler may call
--     C_SuperTrack.ClearAllSuperTracked), supertrack the quest, wait
--     NATIVE_VERIFY_DELAY, then verify a native navigation target exists and
--     is consistent. On failure: release the quest and fall back to
--     RestedXP's coordinates.
--   native -> coordinates: release the quest if it is still the supertracked
--     one, then create the coordinate navigation (silently).
--   native -> native: supertrack the new quest and verify.
--   Every transition bumps a generation counter so stale timer callbacks
--   from an earlier transition do nothing.

local _, ns = ...
local Sync = ns.Sync
local RXP = ns.RXP
local WUI = ns.WUI
local Nav = ns.Nav

local POLL_INTERVAL = 0.25
local SETTLE_TIME = 0.2
-- Navigation events within this window after our own write are ours.
local SELF_WRITE_GUARD = 1.0
local OUTSIDE_CHECK_DELAY = 0.3
local NATIVE_SET_DELAY = 0.25
local NATIVE_VERIFY_DELAY = 0.6
-- Lets RestedXP process quest events (mark turn-ins complete) first.
local QUEST_EVAL_DELAY = 0.5

local GetTime = GetTime
local C_Timer = C_Timer
local format = string.format
local tostring = tostring
local max = math.max
local wipe = wipe or function(t) for k in pairs(t) do t[k] = nil end return t end

local state = {
    ready = false,           -- both dependencies usable
    ticker = nil,
    pendingSince = nil,      -- time an observed change is waiting to settle
    -- Handled state: what the bridge last acted on.
    handledMode = nil,       -- nil, "coordinates" or "native"
    handledKey = nil,        -- destination key
    handledLabel = nil,      -- coordinates: label last written
    handledQuest = nil,      -- native: supertracked quest ID
    handledId = nil,         -- native: destination key + quest
    pendingNative = nil,     -- { id, questID } while a native transition runs
    generation = 0,          -- bumped on every transition
    failedKey = nil,         -- destination key Waypoint UI last rejected
    nativeFailed = {},       -- [native id] = reason
    lastSynced = nil,
    lastResult = nil,
    lastResultTime = nil,
    lastTransition = nil,    -- { text, time }
    lastFailure = nil,       -- { text, time }
    lastDecision = nil,
    lastDecisionLog = nil,   -- avoids repeating the same decision message
    lastInvalidReason = nil, -- avoids repeating the same skip message
    lastHeldLog = nil,
    lastStepIndex = nil,
    external = nil,          -- description of an outside navigation change
    selfWriteUntil = 0,
    outsideCheckPending = false,
    questEvalPending = false,
}

local function SetResult(text)
    state.lastResult = text
    state.lastResultTime = GetTime()
end

local function SetExternal(description)
    state.external = description
end

local function NoteTransition(text)
    state.lastTransition = { text = text, time = GetTime() }
    ns.Debug("Transition: %s", text)
end

local function NoteFailure(text)
    state.lastFailure = { text = text, time = GetTime() }
end

local function NativeId(key, questID)
    return format("%s#%s", tostring(key), tostring(questID))
end

local function DescribeHandled()
    if state.handledMode == "native" and state.handledQuest then
        return format("native quest %d", state.handledQuest)
    end
    return state.handledMode or "none"
end

function Sync.GetState()
    local active
    if state.handledMode == "native" then
        active = Nav.IsNativeQuestActive(state.handledQuest)
    elseif state.handledMode == "coordinates" then
        active = WUI.IsOwnedNavigationTracked()
    end
    return {
        running = state.ticker ~= nil,
        mode = state.handledMode,
        questID = state.handledQuest,
        pending = state.pendingNative ~= nil,
        bridgeActive = active and true or false,
        lastSynced = state.lastSynced,
        lastResult = state.lastResult,
        lastResultTime = state.lastResultTime,
        lastTransition = state.lastTransition,
        lastFailure = state.lastFailure,
        external = state.external,
    }
end

local function NoteStep(target)
    if target.stepIndex ~= state.lastStepIndex then
        ns.Debug("RXP waypoint changed: Step %s -> Step %s",
            tostring(state.lastStepIndex or "-"), tostring(target.stepIndex or "-"))
        state.lastStepIndex = target.stepIndex
    end
end

local function LogDecision(target, decision)
    local key = format("%s|%s|%s|%s", decision.mode, tostring(decision.questID), decision.reason or "",
        tostring(target.stepIndex))
    if key == state.lastDecisionLog then return end
    state.lastDecisionLog = key

    if decision.questID then
        local qs = decision.questState or {}
        ns.Debug("Step %s: turn-in candidate quest %d (%s) - in log: %s, ready: %s",
            tostring(target.stepIndex or "-"), decision.questID, tostring(decision.questName or "?"),
            qs.inLog and "yes" or "no", qs.ready and "yes" or "no")
    end
    if decision.mode == "native" then
        ns.Debug("Selected native quest mode: %s", decision.reason)
    else
        ns.Debug("Using RestedXP coordinates: %s", decision.reason or "?")
    end
end

--------------------------------------------------------------------------------
-- Coordinate navigation
--------------------------------------------------------------------------------

local function RecordSuccess(target, result)
    state.handledMode = "coordinates"
    state.handledKey = target.key
    state.handledLabel = target.label
    state.handledQuest = nil
    state.handledId = nil
    state.failedKey = nil
    state.lastSynced = {
        mode = "coordinates",
        label = target.label,
        labelSource = target.labelInfo and target.labelInfo.source,
        mapID = target.mapID,
        mapName = target.mapName,
        x = target.x,
        y = target.y,
        stepIndex = target.stepIndex,
        time = GetTime(),
    }
    SetExternal(nil)
    SetResult(result)
end

-- Writes the coordinate target to Waypoint UI and records the outcome.
-- labelOnly: same destination, new label; a failure then does not mark the
-- destination as rejected.
local function Apply(target, suppressAudio, how, labelOnly)
    state.generation = state.generation + 1
    state.pendingNative = nil
    state.selfWriteUntil = GetTime() + SELF_WRITE_GUARD
    local ok, err = WUI.SetNavigation(target, suppressAudio)
    if ok then
        RecordSuccess(target, "synced (" .. how .. ")")
        ns.Debug("Waypoint UI synchronization successful (%s).", how)
    else
        if not labelOnly then state.failedKey = target.key end
        SetResult("failed (" .. how .. "): " .. err)
    end
    return ok, err
end

-- Switches to (or re-creates) coordinate navigation, leaving native mode
-- first if needed.
local function ToCoordinates(target, how, suppressAudio)
    if state.handledMode == "native" then
        local questID = state.handledQuest
        Nav.ReleaseNativeQuest(questID)
        NoteTransition(format("%s -> coordinates", questID and format("native quest %d", questID) or "native"))
        state.handledMode = "coordinates"
        state.handledQuest = nil
        state.handledId = nil
        state.handledKey = nil
        state.handledLabel = nil
    end
    return Apply(target, suppressAudio, how)
end

-- Same destination as already handled, but RestedXP describes it differently.
local function RefreshLabel(target)
    ns.Debug("Label changed: \"%s\" -> \"%s\" (same destination).",
        tostring(state.handledLabel), target.label)
    state.handledLabel = target.label

    if not WUI.IsShowingTarget(target) then
        ns.Debug("Waypoint UI is following something else; label not updated.")
        return
    end
    if WUI.HasTargetLabel(target) then return end

    local ok, err = Apply(target, true, "label update", true)
    if not ok then
        ns.Debug("Label update failed: %s.", err)
    end
end

--------------------------------------------------------------------------------
-- Native quest navigation
--------------------------------------------------------------------------------

local BeginNative

local function FailNative(target, questID, id, why, announce)
    state.pendingNative = nil
    state.nativeFailed[id] = why
    NoteFailure(format("native quest %d: %s", questID, why))
    ns.Debug("Native target unavailable (%s); falling back to coordinates.", why)
    if announce then
        ns.Print("Native quest navigation unavailable (%s); using RestedXP coordinates.", why)
    end

    -- Fall back to RestedXP's current destination (it may have moved on).
    local current, reason = RXP.GetTarget()
    if reason or not current then current = target end
    local ok, err = ToCoordinates(current, "native fallback", true)
    if not ok then
        NoteFailure(format("native quest %d: %s; coordinate fallback failed: %s", questID, why, err))
    end
end

BeginNative = function(target, decision, how, announce)
    local questID = decision.questID
    local id = NativeId(target.key, questID)
    local name = decision.questName or ("quest " .. questID)
    local from = DescribeHandled()

    state.generation = state.generation + 1
    local generation = state.generation
    state.pendingNative = { id = id, questID = questID }
    -- Optimistic: later evaluations see the transition as already handled.
    state.handledMode = "native"
    state.handledKey = target.key
    state.handledQuest = questID
    state.handledId = id
    state.handledLabel = nil
    state.selfWriteUntil = GetTime() + NATIVE_SET_DELAY + NATIVE_VERIFY_DELAY + SELF_WRITE_GUARD
    ns.Debug("Starting transition: %s -> native quest %d (%s)", from, questID, name)

    local function Verify()
        if generation ~= state.generation then return end
        local ok, detail = Nav.VerifyNative(target, questID)
        if not ok then
            FailNative(target, questID, id, detail, announce)
            return
        end
        state.pendingNative = nil
        state.failedKey = nil
        state.lastSynced = {
            mode = "native",
            questID = questID,
            label = name,
            mapID = target.mapID,
            mapName = target.mapName,
            x = target.x,
            y = target.y,
            stepIndex = target.stepIndex,
            time = GetTime(),
        }
        SetExternal(nil)
        SetResult(format("native quest %d (%s)", questID, how))
        NoteTransition(format("%s -> native quest %d", from, questID))
        ns.Debug("Native quest navigation active: %s.", detail)
        if announce then
            ns.Print("Synced: native quest navigation for %s.", name)
        end
    end

    local function SetQuest()
        if generation ~= state.generation then return end
        if not Nav.SetNativeQuest(questID) then
            FailNative(target, questID, id, "SetSuperTrackedQuestID failed", announce)
            return
        end
        C_Timer.After(NATIVE_VERIFY_DELAY, Verify)
    end

    if WUI.ClearOwnedNavigation() then
        C_Timer.After(NATIVE_SET_DELAY, SetQuest)
    else
        SetQuest()
    end
end

--------------------------------------------------------------------------------
-- Evaluation
--------------------------------------------------------------------------------

-- First destination since login or /rxpwb on, while a waypoint the bridge did
-- not create is tracked: respect it until RestedXP's destination changes.
local function PauseForForeign(target, foreign)
    state.handledMode = "coordinates"
    state.handledKey = target.key
    state.handledLabel = target.label
    state.handledQuest = nil
    state.handledId = nil
    SetExternal(format("another waypoint is tracked (%s)", foreign))
    SetResult("paused: another waypoint is tracked")
    ns.Debug("Synchronization paused: external waypoint selected (%s). Resumes at the next RestedXP destination.", foreign)
end

local function EnsureCoordinates(target, trigger)
    if state.handledMode == "native" then
        local ok, err = ToCoordinates(target, "automatic", true)
        if not ok then
            ns.Print("Automatic sync failed: %s. Will retry when the destination changes.", err)
        end
        return
    end

    if target.key == state.handledKey then
        if target.label ~= state.handledLabel then
            RefreshLabel(target)
        elseif trigger == "target" then
            ns.Debug("Skipped: destination unchanged.")
        end
        return
    end
    if target.key == state.failedKey then
        return
    end

    ns.Debug("New destination: %s [label from %s]", ns.DescribeTarget(target), target.labelInfo.source)

    if state.handledMode == nil then
        local foreign = WUI.GetForeignNavigationName()
        if foreign then
            PauseForForeign(target, foreign)
            return
        end
        if WUI.IsShowingTarget(target) then
            if WUI.HasTargetLabel(target) then
                RecordSuccess(target, "already shown by Waypoint UI")
                ns.Debug("Waypoint UI already shows this destination; nothing to write.")
            else
                Apply(target, true, "label update", true)
            end
            return
        end
    end

    local ok, err = Apply(target, true, "automatic")
    if not ok then
        ns.Print("Automatic sync failed: %s. Will retry when the destination changes.", err)
    end
end

local function EnsureNative(target, decision, trigger)
    local id = NativeId(target.key, decision.questID)
    if state.handledMode == "native" and state.handledId == id then
        if trigger == "target" then ns.Debug("Skipped: native quest unchanged.") end
        return
    end

    if state.handledMode == nil then
        local foreign = WUI.GetForeignNavigationName()
        if foreign then
            PauseForForeign(target, foreign)
            return
        end
    end

    BeginNative(target, decision, "automatic")
end

-- Automatic evaluation of RestedXP's current target.
-- trigger: "target" (RestedXP target changed), "quest", "strategy", "zone".
local function Evaluate(trigger)
    if not (ns.db.autoSync and state.ready) then return end

    local target, reason = RXP.GetTarget()
    if reason or not target then
        reason = reason or "no RestedXP waypoint"
        if reason ~= state.lastInvalidReason then
            state.lastInvalidReason = reason
            ns.Debug("Skipped: %s. Keeping the current navigation.", reason)
            SetResult("waiting: " .. reason)
        end
        return
    end
    state.lastInvalidReason = nil
    NoteStep(target)

    local decision = Nav.Decide(target, ns.db.strategy)
    if decision.mode == "native" then
        local failed = state.nativeFailed[NativeId(target.key, decision.questID)]
        if failed then
            decision.mode = "coordinates"
            decision.reason = "native target failed verification earlier: " .. failed
        end
    end
    state.lastDecision = decision
    LogDecision(target, decision)

    -- Hold mode changes at an unchanged destination while the player follows
    -- a waypoint the bridge did not create (it resumes on a new destination).
    if state.handledMode and target.key == state.handledKey then
        local wantId = decision.mode == "native" and NativeId(target.key, decision.questID) or nil
        local modeChange = decision.mode ~= state.handledMode
            or (decision.mode == "native" and wantId ~= state.handledId)
        if modeChange then
            local foreign = WUI.GetForeignNavigationName()
            if foreign then
                local held = format("%s|%s", tostring(wantId), foreign)
                if held ~= state.lastHeldLog then
                    state.lastHeldLog = held
                    ns.Debug("Mode change held: another waypoint is tracked (%s).", foreign)
                end
                return
            end
        end
    end
    state.lastHeldLog = nil

    if decision.mode == "native" then
        EnsureNative(target, decision, trigger)
    else
        EnsureCoordinates(target, trigger)
    end
end

local function Tick()
    if RXP.HasTargetChanged() then
        state.pendingSince = GetTime()
        return
    end
    if state.pendingSince and GetTime() - state.pendingSince >= SETTLE_TIME then
        state.pendingSince = nil
        Evaluate("target")
    end
end

local function RunQuestEvaluation()
    state.questEvalPending = false
    if state.ticker then Evaluate("quest") end
end

local function OnQuestEvent()
    if not state.ticker or state.questEvalPending then return end
    if ns.db.strategy ~= "hybrid" and state.handledMode ~= "native" then return end
    state.questEvalPending = true
    C_Timer.After(QUEST_EVAL_DELAY, RunQuestEvaluation)
end

--------------------------------------------------------------------------------
-- Outside navigation changes (diagnostics only, never triggers writes)
--------------------------------------------------------------------------------

local function CheckOutsideNavigation()
    state.outsideCheckPending = false
    if not (ns.db.autoSync and state.ready and state.handledKey) then return end
    if state.pendingNative then return end

    local expectedQuest = state.handledMode == "native" and state.handledQuest or nil
    local description = WUI.DescribeOutsideNavigation(expectedQuest)
    if description == state.external then return end
    SetExternal(description)
    if description then
        ns.Debug("Outside navigation change: %s. Bridge resumes at the next RestedXP destination.", description)
    else
        ns.Debug("Waypoint UI is following the bridge destination again.")
    end
end

local function OnNavigationEvent()
    if state.outsideCheckPending or not state.handledKey then return end
    state.outsideCheckPending = true
    -- Let our own write (and Waypoint UI's delayed validation) settle first.
    local delay = max(OUTSIDE_CHECK_DELAY, state.selfWriteUntil - GetTime())
    C_Timer.After(delay, CheckOutsideNavigation)
end

--------------------------------------------------------------------------------
-- Control
--------------------------------------------------------------------------------

local function ResetHandled()
    state.generation = state.generation + 1
    state.pendingNative = nil
    state.handledMode = nil
    state.handledKey = nil
    state.handledLabel = nil
    state.handledQuest = nil
    state.handledId = nil
    state.failedKey = nil
    state.lastInvalidReason = nil
    state.lastDecisionLog = nil
    state.lastHeldLog = nil
    state.pendingSince = nil
    wipe(state.nativeFailed)
    SetExternal(nil)
end

-- Starts automatic sync. Returns false if the dependencies are unavailable.
function Sync.Start()
    if not state.ready then return false end
    if state.ticker then return true end

    -- Treat the next destination as a first activation.
    ResetHandled()
    RXP.ResetObservation()

    state.ticker = C_Timer.NewTicker(POLL_INTERVAL, Tick)
    ns.Debug("Automatic sync started (strategy: %s).", ns.db.strategy)
    return true
end

function Sync.Stop()
    if state.ticker then
        state.ticker:Cancel()
        state.ticker = nil
        ns.Debug("Automatic sync stopped.")
    end
    state.pendingSince = nil
end

-- Called after the strategy setting changed: re-evaluate the current
-- destination now instead of waiting for RestedXP to move.
function Sync.OnStrategyChanged()
    wipe(state.nativeFailed)
    state.lastDecisionLog = nil
    if state.ticker then
        Evaluate("strategy")
    end
end

-- One-time manual sync; works whether or not automatic sync is enabled.
-- Uses the selected strategy, so in hybrid it may choose native quest mode.
function Sync.SyncNow()
    local wui = WUI.GetStatus()
    if not wui.apiAvailable then
        ns.Print("Sync failed: Waypoint UI navigation API is not available.")
        return false
    end

    local target, reason = RXP.GetTarget()
    if reason or not target then
        ns.Print("Sync skipped: %s. Waypoint UI destination left unchanged.", reason or "no RestedXP waypoint")
        return false
    end

    NoteStep(target)
    local decision = Nav.Decide(target, ns.db.strategy)
    state.lastDecision = decision
    if decision.mode == "native" then
        ns.Print("Switching to native quest navigation for %s...", decision.questName or ("quest " .. decision.questID))
        BeginNative(target, decision, "manual", true)
        return true
    end

    local ok, err = ToCoordinates(target, "manual", false)
    if not ok then
        ns.Print("Sync failed: %s.", err)
        return false
    end

    ns.Print("Synced: %s", ns.DescribeTarget(target))
    return true
end

local QUEST_EVENTS = {
    QUEST_LOG_UPDATE = true,
    QUEST_TURNED_IN = true,
    QUEST_ACCEPTED = true,
    QUEST_REMOVED = true,
}

local eventFrame = CreateFrame("Frame")
eventFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_ENTERING_WORLD" then
        -- After a loading screen, re-read RestedXP and allow one retry of a
        -- previously rejected destination. Unchanged destinations are not rewritten.
        state.failedKey = nil
        wipe(state.nativeFailed)
        RXP.ResetObservation()
    elseif QUEST_EVENTS[event] then
        OnQuestEvent()
    else
        OnNavigationEvent()
    end
end)

local function RegisterOptionalEvent(event)
    pcall(eventFrame.RegisterEvent, eventFrame, event)
end

-- Called once at PLAYER_LOGIN.
function Sync.Initialize()
    state.ready = RXP.GetStatus().arrowAvailable and WUI.GetStatus().apiAvailable and C_Timer ~= nil
        and type(C_Timer.NewTicker) == "function"
    if not state.ready then return end

    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    RegisterOptionalEvent("USER_WAYPOINT_UPDATED")
    RegisterOptionalEvent("SUPER_TRACKING_CHANGED")
    for event in pairs(QUEST_EVENTS) do
        RegisterOptionalEvent(event)
    end

    if ns.db.autoSync then
        Sync.Start()
    end
end
