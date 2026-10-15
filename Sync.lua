-- RXP Waypoint Bridge
-- Sync: automatic and manual synchronisation from RestedXP to Waypoint UI.
--
-- Mechanism
--   A 0.25 s ticker asks RXPAdapter whether RestedXP's arrow target changed
--   (a few raw field comparisons). A changed target must stay unchanged for
--   SETTLE_TIME before it is evaluated, which absorbs transient states while
--   RestedXP updates. RestedXP assigns RXPG_ARROW.element as a plain field
--   inside private functions, so there is nothing reliable to hook, and
--   RXP_STEP_ACTIVATED misses waypoint changes within a step. Polling the
--   resolved target covers both.
--
-- Write rules
--   * Waypoint UI is written only when the valid destination differs from
--     the last one the bridge handled (or on /rxpwb sync).
--   * Missing, stale or invalid RestedXP targets never clear or replace the
--     current Waypoint UI destination.
--   * A destination Waypoint UI rejected is not retried until the target
--     changes or the player zones.
--   * The bridge never reacts to outside navigation changes by writing. If
--     the player (or RestedXP's own quest supertracking) changes what Waypoint
--     UI follows, the bridge leaves it alone until RestedXP moves to a new
--     destination. This cannot loop: writes are triggered only by RestedXP
--     target changes, never by supertracking or waypoint events.
--   * On the first evaluation after login or /rxpwb on, an already tracked
--     waypoint the bridge did not create is respected the same way.

local _, ns = ...
local Sync = ns.Sync
local RXP = ns.RXP
local WUI = ns.WUI

local POLL_INTERVAL = 0.25
local SETTLE_TIME = 0.2
-- Navigation events within this window after our own write are ours.
local SELF_WRITE_GUARD = 1.0
local OUTSIDE_CHECK_DELAY = 0.3

local GetTime = GetTime
local C_Timer = C_Timer
local format = string.format
local tostring = tostring
local max = math.max

local state = {
    ready = false,           -- both dependencies usable
    ticker = nil,
    pendingSince = nil,      -- time an observed change is waiting to settle
    handledKey = nil,        -- destination key the bridge last acted on
    failedKey = nil,         -- destination key Waypoint UI last rejected
    lastSynced = nil,        -- copy of the last successfully synced target
    lastResult = nil,
    lastResultTime = nil,
    lastInvalidReason = nil, -- avoids repeating the same skip message
    lastStepIndex = nil,
    external = nil,          -- description of an outside navigation change
    selfWriteUntil = 0,
    outsideCheckPending = false,
}

local function SetResult(text)
    state.lastResult = text
    state.lastResultTime = GetTime()
end

local function SetExternal(description)
    state.external = description
end

function Sync.GetState()
    return {
        running = state.ticker ~= nil,
        lastSynced = state.lastSynced,
        lastResult = state.lastResult,
        lastResultTime = state.lastResultTime,
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

local function RecordSuccess(target, result)
    state.handledKey = target.key
    state.failedKey = nil
    state.lastSynced = {
        label = target.label,
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

-- Writes the target to Waypoint UI and records the outcome.
local function Apply(target, suppressAudio, how)
    state.selfWriteUntil = GetTime() + SELF_WRITE_GUARD
    local ok, err = WUI.SetNavigation(target, suppressAudio)
    if ok then
        RecordSuccess(target, "synced (" .. how .. ")")
        ns.Debug("Waypoint UI synchronization successful (%s).", how)
    else
        state.failedKey = target.key
        SetResult("failed (" .. how .. "): " .. err)
    end
    return ok, err
end

-- Automatic evaluation of RestedXP's current target.
local function Evaluate()
    if not (ns.db.autoSync and state.ready) then return end

    local target, reason = RXP.GetTarget()
    if reason or not target then
        reason = reason or "no RestedXP waypoint"
        if reason ~= state.lastInvalidReason then
            state.lastInvalidReason = reason
            ns.Debug("Skipped: %s. Keeping the current Waypoint UI destination.", reason)
            SetResult("waiting: " .. reason)
        end
        return
    end
    state.lastInvalidReason = nil
    NoteStep(target)

    if target.key == state.handledKey then
        ns.Debug("Skipped: destination unchanged.")
        return
    end
    if target.key == state.failedKey then
        return
    end

    ns.Debug("New destination: %s", ns.DescribeTarget(target))

    if state.handledKey == nil then
        -- First destination since login or /rxpwb on.
        local foreign = WUI.GetForeignNavigationName()
        if foreign then
            state.handledKey = target.key
            SetExternal(format("another waypoint is tracked (%s)", foreign))
            SetResult("paused: another waypoint is tracked")
            ns.Debug("Synchronization paused: external waypoint selected (%s). Resumes at the next RestedXP destination.", foreign)
            return
        end
        if WUI.IsShowingTarget(target) then
            RecordSuccess(target, "already shown by Waypoint UI")
            ns.Debug("Waypoint UI already shows this destination; nothing to write.")
            return
        end
    end

    local ok, err = Apply(target, true, "automatic")
    if not ok then
        ns.Print("Automatic sync failed: %s. Will retry when the destination changes.", err)
    end
end

local function Tick()
    if RXP.HasTargetChanged() then
        state.pendingSince = GetTime()
        return
    end
    if state.pendingSince and GetTime() - state.pendingSince >= SETTLE_TIME then
        state.pendingSince = nil
        Evaluate()
    end
end

--------------------------------------------------------------------------------
-- Outside navigation changes (diagnostics only, never triggers writes)
--------------------------------------------------------------------------------

local function CheckOutsideNavigation()
    state.outsideCheckPending = false
    if not (ns.db.autoSync and state.ready and state.handledKey) then return end

    local description = WUI.DescribeOutsideNavigation()
    if description == state.external then return end
    SetExternal(description)
    if description then
        ns.Debug("Synchronization paused: %s. Resumes at the next RestedXP destination.", description)
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

-- Starts automatic sync. Returns false if the dependencies are unavailable.
function Sync.Start()
    if not state.ready then return false end
    if state.ticker then return true end

    -- Treat the next destination as a first activation.
    state.handledKey = nil
    state.failedKey = nil
    state.lastInvalidReason = nil
    state.pendingSince = nil
    SetExternal(nil)
    RXP.ResetObservation()

    state.ticker = C_Timer.NewTicker(POLL_INTERVAL, Tick)
    ns.Debug("Automatic sync started.")
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

-- One-time manual sync; works whether or not automatic sync is enabled.
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
    local ok, err = Apply(target, false, "manual")
    if not ok then
        ns.Print("Sync failed: %s.", err)
        return false
    end

    ns.Print("Synced: %s", ns.DescribeTarget(target))
    return true
end

local eventFrame = CreateFrame("Frame")
eventFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_ENTERING_WORLD" then
        -- After a loading screen, re-read RestedXP and allow one retry of a
        -- previously rejected destination. Unchanged destinations are not rewritten.
        state.failedKey = nil
        RXP.ResetObservation()
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

    if ns.db.autoSync then
        Sync.Start()
    end
end
