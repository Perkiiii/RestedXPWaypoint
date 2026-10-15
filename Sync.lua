-- RestedXP Waypoint
-- Sync: the single controller that turns RestedXP's current target into
-- Waypoint UI navigation, automatically or on /rxpw sync.
--
-- Mechanism
--   A 0.25 s ticker asks RXPAdapter whether RestedXP's arrow target changed
--   (a few raw field comparisons). A changed target must stay unchanged for
--   SETTLE_TIME before it is evaluated, which absorbs transient states while
--   RestedXP updates. RestedXP assigns RXPG_ARROW.element as a plain field
--   inside private functions, so there is nothing reliable to hook, and
--   RXP_STEP_ACTIVATED misses waypoint changes within a step. Polling the
--   resolved target covers both.
--   Quest events (turn-in, accept, log update) also schedule one coalesced
--   evaluation, in every strategy, because objectives finishing or a turn-in
--   becoming ready change the desired mode, the label's live progress
--   ("0/15" -> "1/15") or the quest icon without moving RestedXP's arrow.
--   Once a second the ticker also compares RestedXP's label for the handled
--   coordinate destination, so progress text RestedXP updates after the quest
--   event is not missed (v0.5.6), and RestedXP's active-step activity around
--   the arrow (Nav.GetActivitySignature), so a skipped or finished step that
--   changes what the waypoint is for is re-evaluated (v0.5.9, F7).
--   A native quest kept under the same id is re-verified, without a
--   supertracking call, when RestedXP leads to a different activity area for
--   it (v0.5.9, F8).
--
-- Modes (decided by NavigationResolver)
--   coordinates  Waypoint UI custom navigation at RestedXP's coordinates.
--   native       WoW's supertracked quest: eligible turn-ins (hybrid,
--                native-first) and quest objectives (native-first).
--   The handled state is (mode, destination key, native id); evaluation is
--   idempotent: an unchanged desired state never causes a write. The native
--   id comes from the resolver: hybrid keeps v0.4's "key#quest"; native-first
--   uses "kind:quest", so RestedXP cycling #loop points or progress updates
--   on the same objective never re-supertrack.
--
-- Write rules
--   * Waypoint UI is written only when the desired state differs from the
--     last one the bridge handled (or on /rxpw sync).
--   * Missing, stale or invalid RestedXP targets never clear or replace the
--     current navigation.
--   * A destination Waypoint UI rejected is not retried until the target
--     changes or the player zones; native verification failures follow the
--     activity/progress/cooldown retry policy documented below.
--   * The bridge never reacts to outside navigation changes by writing. If
--     the player changes what Waypoint UI follows, the bridge leaves it alone
--     until RestedXP moves to a new destination; while a waypoint the bridge
--     did not create is tracked, mode changes at the same destination are
--     also held back. RestedXP supertracking the bridge's own native quest
--     counts as the bridge's navigation, not an outside change.
--   * On the first evaluation after login or /rxpw on, an already tracked
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
--   Pending work also checks its origin, fresh RXP activity and navigation
--   snapshot. Stop cancels automatic work; loading cancels either origin.
--   An external selection cancels pending work without a fallback or reclaim.

local _, RXPW = ...
local Sync = RXPW.Sync
local RXP = RXPW.RXP
local WUI = RXPW.WUI
local Nav = RXPW.Nav

local POLL_INTERVAL = 0.25
local SETTLE_TIME = 0.2
-- Delay diagnostics after our writes; this is NOT an override-permission window.
local SELF_WRITE_GUARD = 1.0
local OUTSIDE_CHECK_DELAY = 0.3
local NATIVE_SET_DELAY = 0.25
local NATIVE_VERIFY_DELAY = 0.6
-- Lets RestedXP process quest events (mark turn-ins complete) first.
local QUEST_EVAL_DELAY = 0.5
-- Acceptance/turn-in often advances several steps. Evaluate sooner when the
-- target is quiet; never let that event callback bypass the normal 0.2 s
-- target settle. A continuing quest burst gets at most one second to settle.
local QUEST_TRANSITION_DELAY = 0.3
local QUEST_TRANSITION_MAX = 1.0
-- How often the handled coordinate destination's RestedXP label is compared.
local LABEL_CHECK_INTERVAL = 1.0
local PRESENTATION_RETRY_DELAY = 5.0
-- Waypoint UI has no rename API: every NewUserNavigation, even at unchanged
-- coordinates, resets its marker (hide + intro animation and show sound) and,
-- with pathfinding on, rebuilds the path. A same-destination presentation
-- update therefore waits until this long after the previous write; the latest
-- presentation is then applied once (eventual consistency, v0.5.9).
local PRESENTATION_MIN_INTERVAL = 2.0
-- How often RestedXP's active-step activity around the arrow is compared (F7).
local ACTIVITY_CHECK_INTERVAL = 1.0
-- A native target that failed verification is retried only after a
-- meaningful change: NATIVE_RETRY_COOLDOWN has passed, or the quest's
-- progress changed and at least NATIVE_RETRY_MIN has passed. Zoning and
-- strategy changes clear failures. Retries only happen when an evaluation
-- runs anyway (target change or quest event); there is no retry timer.
local NATIVE_RETRY_COOLDOWN = 60
local NATIVE_RETRY_MIN = 10

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
    desiredPresentation = nil, -- latest prepared coordinate target; never proof of application
    presentationRetryAt = nil, -- throttle failed same-destination presentation writes
    handledLabel = nil,      -- coordinates: label successfully written or verified
    handledIcon = nil,       -- coordinates: icon successfully written or verified
    watchedLabel = nil,      -- RestedXP's own label at the last evaluation
    lastLabelCheck = 0,
    handledQuest = nil,      -- native: supertracked quest ID
    handledId = nil,         -- native: decision.nativeId (hybrid: key#quest; native-first: kind:quest)
    handledKind = nil,       -- native: "turnin" or "objective"
    handledProgress = nil,   -- native objective: last logged progress
    handledActivity = nil,   -- native: decision.activity last verified (F8)
    handledAnchor = nil,     -- native: { x, y, instance } value copy of the verified point
    activitySignature = nil, -- RestedXP active-step state at the last evaluation (F7)
    lastActivityCheck = 0,
    lastPresentationWrite = nil, -- time of the last successful Waypoint UI write
    lastAreaHeldLog = nil,
    -- Offline diagnostics only (tests); never shown in chat.
    counters = { evaluations = 0, activityChecks = 0, activityChanges = 0, reverifications = 0,
                 deferredPresentation = 0, orphanedPreviews = 0 },
    pendingNative = nil,     -- operation with origin, target and navigation snapshots
    nativeHold = nil,        -- interrupted operation: leave an external selection alone
    generation = 0,          -- bumped on every transition
    syncSession = 0,         -- invalidates queued automatic quest evaluations
    inWorld = true,
    failedKey = nil,         -- destination key Waypoint UI last rejected
    nativeFailed = {},       -- [native id] = { reason, time, progress }
    lastSynced = nil,
    lastResult = nil,
    lastResultTime = nil,
    lastTransition = nil,    -- { text, time }
    lastFailure = nil,       -- { text, time }
    lastVerification = nil,  -- { questID, ok, detail, time } of the last native check
    contextQuest = nil,      -- quest ID of the current quest context (diagnostics/logging)
    lastContextLabelLog = nil,
    lastDecision = nil,
    lastDecisionLog = nil,   -- avoids repeating the same decision message
    lastInvalidReason = nil, -- avoids repeating the same skip message
    lastHeldLog = nil,
    lastStepIndex = nil,
    external = nil,          -- description of an outside navigation change
    selfWriteUntil = 0,
    outsideCheckPending = false,
    questEvalPending = false,
    questEvalAt = nil,
    questTransitionUntil = nil,
    questTransitionManual = nil, -- explicit user waypoint selected during the wait
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
    RXPW.Debug("Transition: %s", text)
end

local function NoteFailure(text)
    state.lastFailure = { text = text, time = GetTime() }
end

local function DescribeHandled()
    if state.handledMode == "native" and state.handledQuest then
        return format("native quest %d", state.handledQuest)
    end
    return state.handledMode or "none"
end

local function ClearHandledNative()
    state.handledQuest = nil
    state.handledId = nil
    state.handledKind = nil
    state.handledProgress = nil
    state.handledActivity = nil
    state.handledAnchor = nil
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
        kind = state.handledKind,
        pending = state.pendingNative ~= nil,
        areaCheck = state.pendingNative ~= nil and state.pendingNative.reverify == true,
        bridgeActive = active and true or false,
        lastSynced = state.lastSynced,
        lastResult = state.lastResult,
        lastResultTime = state.lastResultTime,
        lastTransition = state.lastTransition,
        lastFailure = state.lastFailure,
        lastVerification = state.lastVerification,
        external = state.external,
        counters = state.counters,
    }
end

-- Returns the failure reason while a failed native target should not be
-- retried, else nil (and forgets the failure). See NATIVE_RETRY_*. A genuinely
-- new RestedXP activity for the same quest (F8) may be tried again at once.
local function NativeBlocked(id, progress, activity)
    local failure = state.nativeFailed[id]
    if not failure then return nil end
    local age = GetTime() - failure.time
    if age >= NATIVE_RETRY_COOLDOWN
        or (activity ~= nil and failure.activity ~= nil and activity ~= failure.activity)
        or (progress ~= nil and failure.progress ~= nil and progress ~= failure.progress and age >= NATIVE_RETRY_MIN) then
        state.nativeFailed[id] = nil
        return nil
    end
    return failure.reason
end

-- Context for Nav.Decide: the bridge's current native quest (for keeping a
-- suitable quest) and the retry policy for failed native targets.
function Sync.GetDecisionContext()
    return {
        currentQuest = state.handledMode == "native" and state.handledQuest or nil,
        currentKind = state.handledMode == "native" and state.handledKind or nil,
        pending = state.pendingNative ~= nil,
        blockedReason = NativeBlocked,
    }
end

--------------------------------------------------------------------------------
-- Quest context and coordinate presentation (v0.5.4; every strategy since v0.5.6)
--------------------------------------------------------------------------------

local function ReadyText()
    local text = _G.QUEST_WATCH_QUEST_READY
    if type(text) == "string" and text ~= "" then return text end
    return "Ready for turn-in"
end

-- Logs quest context changes (never per poll): new context, or cleared.
local function NoteContext(decision)
    local c = decision and decision.context
    local questID = c and c.questID or nil
    if questID == state.contextQuest then return end
    if state.contextQuest then
        local stillInLog = Nav.GetQuestState(state.contextQuest).inLog
        RXPW.Debug("Quest context cleared: quest %d (%s).", state.contextQuest,
            stillInLog and "RestedXP moved to a different activity" or "quest turned in or removed")
    end
    if c then
        RXPW.Debug("Using quest context: %s (quest %d, %s, from %s).", c.title, c.questID,
            c.kind == "turnin" and (c.ready and "ready for turn-in" or "turn-in") or "objective", tostring(c.source))
    end
    state.contextQuest = questID
end

-- Coordinate waypoint presentation, in every strategy (v0.5.6). RestedXP
-- decides WHERE the waypoint is; the quest context decides WHAT it looks like
-- (Nav.GetContextDecision), so a route-critical point that belongs to a quest
-- keeps RestedXP's coordinates and still shows that quest's icon and colour.
--   * label (v0.5.4): a RestedXP label that is only the "Step N" fallback
--     shows the structurally associated quest instead: its title, plus
--     "Ready for turn-in" when the quest log says so. Real RestedXP
--     instructions ("1/15 Windstone Cluster", "Enter the cave", ...) are never
--     replaced; their live progress is refreshed (EnsureCoordinates).
--   * icon (v0.5.5): any coordinate waypoint that belongs to a quest step gets
--     the icon Waypoint UI's native quest marker would show for that quest
--     (Nav.GetPresentation + WUI.GetQuestIcon): "!" to accept, silver "?"
--     while incomplete, gold "?" when ready. Service steps get their service
--     icon and colour; other waypoints keep Waypoint UI's default icon.
-- Fills target.label/labelInfo/stripCoordinates/presentation/iconTexture/tint;
-- returns contextDecision, iconName, tintName. No logging, no state: status
-- uses it too.
function Sync.PrepareTarget(target, decision)
    target.rxpLabel = target.label
    local ctx = Nav.GetContextDecision(target, decision)
    local c = ctx and ctx.context
    if c and target.labelInfo and target.labelInfo.fallback then
        local label = c.title
        if c.kind == "turnin" and c.ready then label = format("%s - %s", c.title, ReadyText()) end
        label = RXPW.Label.Clean(label) or c.title
        target.label = label
        target.labelInfo = {
            label = label, source = "quest context (" .. tostring(c.source) .. ")",
            cleaned = false, shortened = false, fallback = false, contextQuest = c.questID,
        }
        target.stripCoordinates = true
    end

    local presentation = Nav.GetPresentation(target, ctx)
    target.presentation = presentation
    -- Waypoint UI's quest colour for quest destinations, the service palette
    -- for services; the appearance settings decide which of icon and colour
    -- are supplied (WUI.ResolveAppearance, v0.6.0).
    local iconName, tintName
    target.iconTexture, iconName, target.tint, tintName = WUI.ResolveAppearance(presentation)
    return ctx, iconName, tintName
end

local function PrepareCoordinateTarget(target, decision)
    local _, iconName, tintName = Sync.PrepareTarget(target, decision)
    local presentation = target.presentation

    local logKey = format("%s|%s|%s", tostring(target.label), tostring(target.iconTexture), tostring(tintName))
    if logKey ~= state.lastContextLabelLog then
        state.lastContextLabelLog = logKey
        RXPW.Debug("Coordinate waypoint: \"%s\", colour %s, icon %s.", tostring(target.label),
            target.tint and tostring(tintName) or "default",
            iconName and (presentation.questID
                and format("%s (quest %d, %s)", iconName, presentation.questID, tostring(presentation.source))
                or format("%s (%s)", iconName, tostring(presentation.source))) or "default")
    end
end

local function NoteStep(target)
    if target.stepIndex ~= state.lastStepIndex then
        RXPW.Debug("RXP waypoint changed: Step %s -> Step %s",
            tostring(state.lastStepIndex or "-"), tostring(target.stepIndex or "-"))
        state.lastStepIndex = target.stepIndex
    end
end

-- Logs a decision once per meaningful change (not per poll or quest event).
local function LogDecision(target, decision)
    local key = format("%s|%s|%s|%s|%s", decision.mode, tostring(decision.nativeId), decision.reason or "",
        tostring(target.stepIndex), tostring(decision.classification))
    if key == state.lastDecisionLog then return end
    state.lastDecisionLog = key

    if decision.questID then
        local qs = decision.questState or {}
        if decision.kind == "objective" then
            RXPW.Debug("Step %s: quest objective detected: %s quest %d (%s)%s",
                tostring(target.stepIndex or "-"), tostring(decision.classification or "objective"),
                decision.questID, tostring(decision.questName or "?"),
                decision.progress and (" - " .. decision.progress) or "")
        else
            RXPW.Debug("Step %s: turn-in candidate quest %d (%s) - in log: %s, ready: %s",
                tostring(target.stepIndex or "-"), decision.questID, tostring(decision.questName or "?"),
                qs.inLog and "yes" or "no", qs.ready and "yes" or "no")
        end
    end
    if decision.candidates then
        for _, c in ipairs(decision.candidates) do
            RXPW.Debug("  Candidate %d (%s)%s - %s%s", c.questID, tostring(c.title or "?"),
                c.progress and (" " .. c.progress) or "", c.eligible and "eligible" or tostring(c.reason),
                c.selected and " [selected]" or "")
        end
    end
    if decision.mode == "native" and decision.continuity and decision.continuity.ok then
        RXPW.Debug("Preserving native quest %d: %s", decision.questID, decision.reason)
    elseif decision.mode == "native" then
        RXPW.Debug("%s: selecting quest %d - %s", RXPW.db.strategy, decision.questID, decision.reason)
    else
        RXPW.Debug("Coordinate fallback: %s", decision.reason or "?")
    end
end

--------------------------------------------------------------------------------
-- Coordinate navigation
--------------------------------------------------------------------------------

local function RecordSuccess(target, result)
    state.handledMode = "coordinates"
    state.handledKey = target.key
    state.handledLabel = target.label
    state.handledIcon = target.iconTexture
    state.presentationRetryAt = nil
    ClearHandledNative()
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
    state.desiredPresentation = target
    state.generation = state.generation + 1
    state.pendingNative = nil
    state.nativeHold = nil
    state.selfWriteUntil = GetTime() + SELF_WRITE_GUARD
    RXPW.Debug("Bridge coordinate write at %.3f (%s).", GetTime(), how)
    local ok, err = WUI.SetNavigation(target, suppressAudio)
    if ok then
        state.lastPresentationWrite = GetTime()
        RecordSuccess(target, "synced (" .. how .. ")")
        RXPW.Debug("Waypoint UI synchronization successful (%s).", how)
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
        ClearHandledNative()
        state.handledKey = nil
        state.handledLabel = nil
    end
    return Apply(target, suppressAudio, how)
end

local ScheduleEvaluation

-- Same destination as already handled, but RestedXP describes it differently.
local function RefreshLabel(target)
    if not WUI.IsShowingTarget(target) then
        return
    end
    if WUI.HasTargetLabel(target) then
        if state.handledLabel ~= target.label or state.handledIcon ~= target.iconTexture
            or state.presentationRetryAt then
            RecordSuccess(target, "presentation already displayed")
        end
        return
    end
    if state.presentationRetryAt and GetTime() < state.presentationRetryAt then return end
    local wait = state.lastPresentationWrite and state.lastPresentationWrite + PRESENTATION_MIN_INTERVAL - GetTime()
    if wait and wait > 0 then
        -- Coalesce rapid progress into one rename; the evaluation re-reads RXP.
        state.presentationRetryAt = GetTime() + wait
        state.counters.deferredPresentation = state.counters.deferredPresentation + 1
        ScheduleEvaluation(wait)
        return
    end

    RXPW.Debug("Label/icon changed: \"%s\" -> \"%s\" (same destination).",
        tostring(state.handledLabel), target.label)
    local ok, err = Apply(target, true, "label update", true)
    if not ok then
        state.presentationRetryAt = GetTime() + PRESENTATION_RETRY_DELAY
        RXPW.Debug("Label update failed: %s.", err)
    end
end

--------------------------------------------------------------------------------
-- Native quest navigation
--------------------------------------------------------------------------------

local BeginNative

local function CaptureNavigation()
    local quest, priority, empty = Nav.GetTrackingState()
    local user, waypoint = WUI.GetNavigationIdentity()
    return { quest = quest, priority = priority, empty = empty, user = user, waypoint = waypoint }
end

local function NavigationMatches(operation)
    local current, expected = CaptureNavigation(), operation.navigation
    if current.quest == expected.quest and current.priority == expected.priority and current.user == expected.user then
        return true
    end
    -- WUI may finish clearing our user waypoint asynchronously. Only an
    -- empty destination is expected here, never a replacement quest or pin.
    return operation.clearing and current.empty and current.user == nil
end

-- Cancel bookkeeping only: never release a quest or clear a waypoint here.
local function AbandonNative(operation, reason, external)
    if state.pendingNative ~= operation then return end
    state.generation = state.generation + 1
    state.pendingNative = nil
    if operation.reverify then
        -- Nothing was written: the established native state stays handled and
        -- its last verified activity is kept, so a later evaluation re-checks
        -- (or holds) instead of re-supertracking.
        if external then SetExternal(WUI.DescribeOutsideNavigation(state.handledQuest)) end
        SetResult("native area check cancelled: " .. reason)
        RXPW.Debug("Native area check cancelled: %s (no navigation write).", reason)
        RXP.ResetObservation()
        return
    end
    state.handledMode, state.handledKey = nil, nil
    state.handledLabel, state.handledIcon = nil, nil
    ClearHandledNative()
    if external then
        state.nativeHold = { key = operation.key, id = operation.id }
        SetExternal(WUI.DescribeOutsideNavigation())
    end
    SetResult("native transition cancelled: " .. reason)
    RXPW.Debug("Native transition cancelled: %s (no navigation write).", reason)
    RXP.ResetObservation()
end

-- Shared gate before setting, verifying or falling back. Captured targets
-- are identities only; all decisions/writes use fresh validated RXP data.
local function CurrentNativeTarget(operation)
    if state.pendingNative ~= operation or operation.generation ~= state.generation then return nil end
    local reason, external
    if not state.inWorld or (operation.automatic and not (RXPW.db.autoSync and state.ticker))
        or (RXPW.Preview and RXPW.Preview.IsActive()) then
        reason = "synchronization stopped, preview active or loading screen"
    elseif not NavigationMatches(operation) then
        reason, external = "another navigation selection took control", true
    end
    local current, invalid = RXP.GetTarget()
    local decision
    if not reason then
        if invalid or not current then
            reason = invalid or "RestedXP has no target"
        elseif current.key ~= operation.key or current.element ~= operation.element
            or current.stepIndex ~= operation.stepIndex or RXPW.db.strategy ~= operation.strategy then
            reason = "RestedXP target or strategy changed"
        else
            decision = Nav.Decide(current, RXPW.db.strategy, Sync.GetDecisionContext())
            if decision.mode ~= "native" or decision.nativeId ~= operation.id then
                reason = "RestedXP quest activity changed"
            end
        end
    end
    if reason then
        AbandonNative(operation, reason, external)
        return nil
    end
    -- The fresh decision carries the CURRENT activity, references and
    -- tolerance: a same-quest activity change during the wait is verified
    -- against where RestedXP leads now (F8).
    return current, decision
end

local function FailNative(operation, why, manual, progress, activity)
    local current, fresh = CurrentNativeTarget(operation)
    if not current then return end
    local questID, id = operation.questID, operation.id
    state.nativeFailed[id] = { reason = why, time = GetTime(), progress = progress,
                               activity = activity or (fresh and fresh.activity) }
    NoteFailure(format("native quest %d: %s", questID, why))
    state.pendingNative = nil

    -- In a shared farming circuit another eligible quest may still work.
    local nextDecision = Nav.Decide(current, RXPW.db.strategy, Sync.GetDecisionContext())
    if nextDecision.mode == "native" and nextDecision.nativeId ~= id then
        RXPW.Debug("Native verification failed for quest %d (%s); trying the next candidate, quest %d.",
            questID, why, nextDecision.questID)
        state.lastDecision = nextDecision
        BeginNative(current, nextDecision, "next candidate", manual)
        return
    end

    RXPW.Debug("Native verification failed after classification passed (%s); falling back to coordinates.", why)
    if manual then
        RXPW.Print("Native quest navigation unavailable (%s); using RestedXP coordinates.", why)
    end
    PrepareCoordinateTarget(current, nextDecision)
    local ok, err = ToCoordinates(current, "native fallback", true)
    if not ok then
        NoteFailure(format("native quest %d: %s; coordinate fallback failed: %s", questID, why, err))
    end
end

-- reverify (F8): the same native quest is already supertracked and active,
-- but RestedXP now leads to a different activity. Nothing is cleared or
-- supertracked; after NATIVE_VERIFY_DELAY the shared gate re-validates the
-- current RXP target, and the native target is verified against the current
-- activity. A failure takes the normal FailNative path.
BeginNative = function(target, decision, how, manual, reverify)
    local questID = decision.questID
    local id = decision.nativeId
    local name = decision.questName or ("quest " .. questID)
    local from = DescribeHandled()

    state.generation = state.generation + 1
    local operation = {
        generation = state.generation, id = id, questID = questID,
        automatic = not manual, strategy = RXPW.db.strategy,
        key = target.key, element = target.element, stepIndex = target.stepIndex,
        reverify = reverify,
    }
    state.pendingNative = operation
    state.nativeHold = nil

    local function Verify()
        local current, fresh = CurrentNativeTarget(operation)
        if not current then return end
        local ok, detail, m = Nav.VerifyNative(current, questID, fresh.tolerance, fresh.references)
        state.lastVerification = { questID = questID, ok = ok, detail = detail, time = GetTime() }
        RXPW.Debug("Native target check: native %s yd, RestedXP %s yd%s, gap %s yd, limit %s yd.",
            m and m.native and format("%.1f", m.native) or "?", m and m.rxp and format("%.1f", m.rxp) or "?",
            m and m.points and format(" (nearest of %d patrol points)", m.points) or "",
            m and m.gap and format("%.1f", m.gap) or "?", tostring(m and m.tolerance or "?"))
        if not ok then
            FailNative(operation, detail, manual, fresh.progress, fresh.activity)
            return
        end
        state.pendingNative = nil
        state.failedKey = nil
        state.handledKey = current.key
        state.handledActivity = fresh.activity
        state.handledAnchor = fresh.anchor
        state.lastSynced = {
            mode = "native",
            questID = questID,
            label = name,
            mapID = current.mapID,
            mapName = current.mapName,
            x = current.x,
            y = current.y,
            stepIndex = current.stepIndex,
            time = GetTime(),
        }
        SetExternal(nil)
        if reverify then
            SetResult(format("native quest %d kept (area re-verified)", questID))
            RXPW.Debug("Native quest %d still matches RestedXP's new activity: %s (no navigation write).",
                questID, detail)
            return
        end
        SetResult(format("native quest %d (%s)", questID, how))
        NoteTransition(format("%s -> native quest %d", from, questID))
        RXPW.Debug("Native quest navigation active: %s.", detail)
        if manual then
            RXPW.Print("Synced: native quest navigation for %s.", name)
        end
    end

    if reverify then
        operation.navigation = CaptureNavigation()
        RXPW.Debug("Re-verifying native quest %d for RestedXP's new activity (no supertracking call).", questID)
        C_Timer.After(NATIVE_VERIFY_DELAY, Verify)
        return
    end

    -- Optimistic: later evaluations see the transition as already handled.
    state.handledMode = "native"
    state.handledKey = target.key
    state.handledQuest = questID
    state.handledId = id
    state.handledKind = decision.kind
    state.handledProgress = decision.progress
    state.handledActivity = nil -- recorded once verification passes
    state.handledAnchor = nil
    state.handledLabel = nil
    state.selfWriteUntil = GetTime() + NATIVE_SET_DELAY + NATIVE_VERIFY_DELAY + SELF_WRITE_GUARD
    RXPW.Debug("Starting transition: %s -> native quest %d (%s, %s)", from, questID, name,
        tostring(decision.classification or decision.kind))

    -- RestedXP/Blizzard may already be following the desired native quest.
    -- Keep that marker and verify through the same fresh-data/ownership gate.
    -- Clearing an inactive bridge session and re-setting the quest would only
    -- restart Waypoint UI's presentation. Explicit manual sync retains its setter.
    if not manual and Nav.IsNativeQuestActive(questID) then
        operation.navigation = CaptureNavigation()
        RXPW.Debug("Keeping existing native quest %d at %.3f; verifying without a navigation write.", questID, GetTime())
        C_Timer.After(NATIVE_VERIFY_DELAY, Verify)
        return
    end

    local function SetQuest()
        if not CurrentNativeTarget(operation) then return end
        operation.navigation = CaptureNavigation() -- WUI's delayed clear may have finished
        operation.writing = true
        operation.settingQuest = true
        RXPW.Debug("Bridge native quest write: quest %d at %.3f.", questID, GetTime())
        local ok = Nav.SetNativeQuest(questID)
        operation.writing = false
        operation.settingQuest = false
        operation.clearing = false
        local navigation = CaptureNavigation()
        if operation.interrupted or navigation.user ~= operation.navigation.user
            or (navigation.quest ~= questID and (navigation.quest ~= operation.navigation.quest
                or navigation.priority ~= operation.navigation.priority)) then
            AbandonNative(operation, "another navigation selection took control", true)
            return
        end
        operation.navigation = navigation
        if not ok then
            FailNative(operation, "SetSuperTrackedQuestID failed", manual, decision.progress)
            return
        end
        C_Timer.After(NATIVE_VERIFY_DELAY, Verify)
    end

    local beforeClear = CaptureNavigation()
    operation.writing = true
    operation.clearing = WUI.ClearOwnedNavigation()
    operation.writing = false
    operation.navigation = CaptureNavigation()
    local navigation = operation.navigation
    if operation.clearing and ((navigation.quest and navigation.quest ~= beforeClear.quest)
        or (navigation.priority ~= beforeClear.priority and not navigation.empty)
        or (navigation.waypoint and navigation.waypoint ~= beforeClear.waypoint)
        or WUI.GetForeignNavigationName()) then
        AbandonNative(operation, "another navigation selection took control", true)
        return
    end
    if operation.clearing then
        C_Timer.After(NATIVE_SET_DELAY, SetQuest)
    else
        SetQuest()
    end
end

--------------------------------------------------------------------------------
-- Evaluation
--------------------------------------------------------------------------------

-- First destination since login or /rxpw on, while a waypoint the bridge did
-- not create is tracked: respect it until RestedXP's destination changes.
local function PauseForForeign(target, foreign)
    state.handledMode = "coordinates"
    state.handledKey = target.key
    state.handledLabel = nil
    state.handledIcon = nil
    ClearHandledNative()
    SetExternal(format("another waypoint is tracked (%s)", foreign))
    SetResult("paused: another waypoint is tracked")
    RXPW.Debug("Synchronization paused: external waypoint selected (%s). Resumes at the next RestedXP destination.", foreign)
end

local function EnsureCoordinates(target, trigger)
    if state.handledMode == "native" then
        local ok, err = ToCoordinates(target, "automatic", true)
        if not ok then
            RXPW.Print("Automatic sync failed: %s. Will retry when the destination changes.", err)
        end
        return
    end

    state.desiredPresentation = target
    if target.key == state.handledKey then
        RefreshLabel(target)
        return
    end
    if target.key == state.failedKey then
        return
    end

    RXPW.Debug("New destination: %s [label from %s]", RXPW.DescribeTarget(target), target.labelInfo.source)

    if state.handledMode == nil then
        local foreign = WUI.GetForeignNavigationName()
        if foreign then
            PauseForForeign(target, foreign)
            return
        end
        if WUI.IsShowingTarget(target) then
            if WUI.HasTargetLabel(target) then
                RecordSuccess(target, "already shown by Waypoint UI")
                RXPW.Debug("Waypoint UI already shows this destination; nothing to write.")
            else
                Apply(target, true, "label update", true)
            end
            return
        end
    end

    local ok, err = Apply(target, true, "automatic")
    if not ok then
        RXPW.Print("Automatic sync failed: %s. Will retry when the destination changes.", err)
    end
end

-- F8: has RestedXP moved the same native quest to a different activity area?
-- (identity "objective:Q" unchanged, activity or verified point changed).
-- #loop circuits carry no anchor: cycling their points never counts.
local function AreaChange(decision)
    if decision.activity ~= state.handledActivity then return "RestedXP activity changed" end
    if decision.anchor and state.handledAnchor then
        local moved = Nav.AnchorDistance(decision.anchor, state.handledAnchor)
        local limit = decision.tolerance or Nav.TURNIN_TOLERANCE
        if moved > limit then
            return moved == math.huge and "destination changed continent"
                or format("destination moved %.0f yd (limit %d)", moved, limit)
        end
    end
    return nil
end

-- Re-verify the unchanged native quest against RestedXP's new activity without
-- touching navigation. Never while another waypoint is tracked or WoW is no
-- longer following the quest (player, RestedXP or another addon chose
-- something else): those are left alone, as before.
local function Reverify(target, decision, change)
    local why
    local foreign = WUI.GetForeignNavigationName()
    if foreign then
        why = format("another waypoint is tracked (%s)", foreign)
    elseif not Nav.IsNativeQuestActive(decision.questID) then
        why = format("quest %d is no longer the active navigation", decision.questID)
    end
    if why then
        local held = format("%s|%s", tostring(decision.activity), why)
        if held ~= state.lastAreaHeldLog then
            state.lastAreaHeldLog = held
            RXPW.Debug("Native area check held: %s.", why)
        end
        return
    end
    state.lastAreaHeldLog = nil
    state.counters.reverifications = state.counters.reverifications + 1
    RXPW.Debug("Native quest %d: %s.", decision.questID, change)
    BeginNative(target, decision, "re-verification", false, true)
end

local function EnsureNative(target, decision, trigger)
    local id = decision.nativeId
    if state.handledMode == "native" and state.handledId == id then
        -- Same quest and kind: Blizzard and Waypoint UI update progress and the
        -- native target themselves; never re-supertrack. A different RestedXP
        -- activity is re-verified, still without re-supertracking (F8).
        if decision.continuity and decision.continuity.ok then
            -- Helper continuity was verified inside Nav.Decide.
            state.handledActivity, state.handledAnchor = decision.activity, decision.anchor
        elseif not state.pendingNative then
            local change = AreaChange(decision)
            if change then
                Reverify(target, decision, change)
                return
            end
        end
        if decision.progress and decision.progress ~= state.handledProgress then
            state.handledProgress = decision.progress
            RXPW.Debug("Native objective updated: quest %d - %s (no navigation write).", decision.questID, decision.progress)
        elseif trigger == "target" then
            RXPW.Debug("Skipped: native quest unchanged.")
        end
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
    if not (RXPW.db.autoSync and state.ready and state.inWorld) then return end
    if trigger == "quest" or trigger == "target" then
        local now = GetTime()
        -- The event timer can fire before the next poll. Observe raw CURRENT
        -- data here too, rather than publishing an unobserved intermediate.
        if RXP.HasTargetChanged() then state.pendingSince = now end
        local wait = state.pendingSince and SETTLE_TIME - (now - state.pendingSince) or 0
        if state.questTransitionUntil then wait = math.min(wait, state.questTransitionUntil - now) end
        if wait > 0.001 then
            ScheduleEvaluation(wait)
            return
        end
        state.pendingSince = nil
    end
    state.counters.evaluations = state.counters.evaluations + 1
    state.activitySignature = Nav.GetActivitySignature(RXP.GetArrowElement())

    -- First destination since login or /rxpw on: a preview marker restored by
    -- Waypoint UI after /reload (flag RestedXPWaypoint-Preview, no preview
    -- session) is removed, then the next evaluation proceeds normally.
    if state.handledMode == nil and RXPW.Preview and RXPW.Preview.RemoveOrphan() then
        state.counters.orphanedPreviews = state.counters.orphanedPreviews + 1
        RXP.ResetObservation()
        return
    end

    local target, reason = RXP.GetTarget()
    if reason or not target then
        reason = reason or "no RestedXP waypoint"
        if reason ~= state.lastInvalidReason then
            state.lastInvalidReason = reason
            RXPW.Debug("Skipped: %s. Keeping the current navigation.", reason)
            SetResult("waiting: " .. reason)
        end
        return
    end
    state.lastInvalidReason = nil
    local selected = state.questTransitionManual
    state.questTransitionUntil, state.questTransitionManual = nil, nil
    if selected then
        -- A new route key does not grant a deferred operation permission to
        -- replace a pin the player chose during its wait. Resume on a later key.
        PauseForForeign(target, selected)
        return
    end
    NoteStep(target)
    state.watchedLabel = target.label

    local decision = Nav.Decide(target, RXPW.db.strategy, Sync.GetDecisionContext())
    state.lastDecision = decision
    if state.nativeHold then
        if target.key == state.nativeHold.key or decision.nativeId == state.nativeHold.id then return end
        state.nativeHold = nil
    end
    LogDecision(target, decision)
    NoteContext(decision)
    if decision.mode ~= "native" then PrepareCoordinateTarget(target, decision) end

    -- Hold mode changes at an unchanged destination while the player follows
    -- a waypoint the bridge did not create (it resumes on a new destination).
    -- A native -> native switch (e.g. the next quest in a farming circuit) is
    -- not a new RestedXP destination, so it is held too, whatever point the
    -- patrol arrow is on.
    -- Likewise a coordinate helper waypoint for the quest the bridge is already
    -- tracking natively (same quest context) is the same activity (v0.5.4).
    if state.handledMode and (target.key == state.handledKey
        or (state.handledMode == "native" and decision.mode == "native")
        or (state.handledMode == "native" and decision.context ~= nil
            and decision.context.questID == state.handledQuest)) then
        local wantId = decision.mode == "native" and decision.nativeId or nil
        local modeChange = decision.mode ~= state.handledMode
            or (decision.mode == "native" and wantId ~= state.handledId)
        if modeChange then
            local foreign = WUI.GetForeignNavigationName()
            if foreign then
                local held = format("%s|%s", tostring(wantId), foreign)
                if held ~= state.lastHeldLog then
                    state.lastHeldLog = held
                    RXPW.Debug("Mode change held: another waypoint is tracked (%s).", foreign)
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

local function RunQuestEvaluation(session, at)
    if session ~= state.syncSession or at ~= state.questEvalAt then return end
    state.questEvalPending = false
    state.questEvalAt = nil
    if state.ticker then Evaluate("quest") end
end

-- One coalesced evaluation, however many quest events, activity changes or
-- deferred presentation updates arrive. delay defaults to QUEST_EVAL_DELAY.
ScheduleEvaluation = function(delay)
    if not state.ticker then return end
    local at = GetTime() + (delay or QUEST_EVAL_DELAY)
    -- A presentation retry must not hold a new route/quest transition behind
    -- its later deadline. Superseded callbacks are inert, just like old sessions.
    if state.questEvalPending and state.questEvalAt <= at then return end
    state.questEvalPending = true
    state.questEvalAt = at
    local session = state.syncSession
    C_Timer.After(math.max(0, at - GetTime()), function() RunQuestEvaluation(session, at) end)
end

local function ScheduleQuestEvaluation()
    ScheduleEvaluation(QUEST_EVAL_DELAY)
end

-- Observe text separately from prepared presentation. Also recover a pending
-- presentation when the same owned destination is active again. Use the
-- existing coalesced evaluation; never reclaim an inactive/manual destination.
-- Read back all supported presentation fields, including tint and icon type.
local function CheckLabel(now)
    if state.handledMode ~= "coordinates" or not state.handledKey or state.pendingNative
        or state.questEvalPending or not state.watchedLabel then return end
    if now - state.lastLabelCheck < LABEL_CHECK_INTERVAL then return end
    state.lastLabelCheck = now
    local target, reason = RXP.GetTarget()
    if reason or not target or target.key ~= state.handledKey then return end
    local desired = state.desiredPresentation
    local changed = target.label ~= state.watchedLabel
    local pending = desired and desired.key == target.key and WUI.IsShowingTarget(target)
        and not WUI.HasTargetLabel(desired)
        and (not state.presentationRetryAt or now >= state.presentationRetryAt)
    if not changed and not pending then return end
    state.watchedLabel = target.label
    ScheduleQuestEvaluation()
end

-- F7: RestedXP's active steps or instruction state changed while the arrow
-- stayed put (a served step skipped, a sticky step finished, an instruction
-- ticked off). One content comparison per second (Nav.GetActivitySignature);
-- a change schedules the coalesced evaluation, which decides from fresh data.
-- Evaluate records the signature, so a change it already saw is not repeated.
local function CheckActivity(now)
    if not state.inWorld or now - state.lastActivityCheck < ACTIVITY_CHECK_INTERVAL then return end
    state.lastActivityCheck = now
    state.counters.activityChecks = state.counters.activityChecks + 1
    local signature = Nav.GetActivitySignature(RXP.GetArrowElement())
    if signature == state.activitySignature then return end
    state.activitySignature = signature
    state.counters.activityChanges = state.counters.activityChanges + 1
    RXPW.Debug("RestedXP activity changed at the same waypoint; re-evaluating.")
    ScheduleQuestEvaluation()
end

local function Tick()
    if RXP.HasTargetChanged() then
        state.pendingSince = GetTime()
        if state.questTransitionUntil then
            ScheduleEvaluation(math.max(0, math.min(SETTLE_TIME, state.questTransitionUntil - GetTime())))
        end
        return
    end
    if state.pendingSince then
        if GetTime() - state.pendingSince >= SETTLE_TIME then
            Evaluate("target")
        end
        return
    end
    local now = GetTime()
    CheckLabel(now)
    CheckActivity(now)
end

local function OnQuestEvent(event)
    if not state.ticker or not state.inWorld then return end
    if event == "QUEST_ACCEPTED" or event == "QUEST_TURNED_IN" then
        local now = GetTime()
        if not state.questTransitionUntil then
            state.questTransitionUntil = now + QUEST_TRANSITION_MAX
            RXPW.Debug("Quest transition: %s at %.3f (external markers left untouched).", event, now)
        end
        ScheduleEvaluation(QUEST_TRANSITION_DELAY)
    else
        ScheduleQuestEvaluation()
    end
end

--------------------------------------------------------------------------------
-- Outside navigation changes (diagnostics/cancellation only, never writes)
--------------------------------------------------------------------------------

local function CheckOutsideNavigation()
    state.outsideCheckPending = false
    if not (RXPW.db.autoSync and state.ready and state.handledKey) then return end
    if state.pendingNative then return end

    local expectedQuest = state.handledMode == "native" and state.handledQuest or nil
    local description = WUI.DescribeOutsideNavigation(expectedQuest)
    if description == state.external then return end
    SetExternal(description)
    if description then
        RXPW.Debug("Outside navigation change: %s (observed %.3f, no bridge write). Sync resumes at the next RestedXP destination.", description, GetTime())
    else
        RXPW.Debug("Waypoint UI is following the RestedXP Waypoint destination again.")
    end
end

local function OnNavigationEvent()
    if state.questTransitionUntil then
        local _, priority = Nav.GetTrackingState()
        local userType = Enum and Enum.SuperTrackingType and Enum.SuperTrackingType.UserWaypoint
        if userType ~= nil and priority == userType and not WUI.IsOwnedNavigationTracked() then
            state.questTransitionManual = WUI.GetForeignNavigationName() or "user waypoint"
        end
    end
    local operation = state.pendingNative
    if operation and operation.settingQuest and (not Nav.IsNativeQuestActive(operation.questID)
        or WUI.GetNavigationIdentity() ~= operation.navigation.user) then
        operation.interrupted = true -- another addon's synchronous reaction to our setter
    end
    if operation and not operation.writing and not NavigationMatches(operation) then
        -- Events may cancel an operation, but never write/reclaim navigation.
        AbandonNative(operation, "another navigation selection took control", true)
    end
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
    state.nativeHold = nil
    state.handledMode = nil
    state.handledKey = nil
    state.handledLabel = nil
    state.handledIcon = nil
    state.watchedLabel = nil
    state.desiredPresentation = nil
    state.presentationRetryAt = nil
    state.activitySignature = nil
    state.lastAreaHeldLog = nil
    ClearHandledNative()
    state.failedKey = nil
    state.lastInvalidReason = nil
    state.lastDecisionLog = nil
    state.lastHeldLog = nil
    state.pendingSince = nil
    state.questTransitionUntil, state.questTransitionManual = nil, nil
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
    RXPW.Debug("Automatic sync started (strategy: %s).", RXPW.db.strategy)
    return true
end

function Sync.Stop()
    state.syncSession = state.syncSession + 1
    state.questEvalPending = false
    state.questEvalAt = nil
    local operation = state.pendingNative
    if operation and operation.automatic then AbandonNative(operation, "automatic sync stopped") end
    if state.ticker then
        state.ticker:Cancel()
        state.ticker = nil
        RXPW.Debug("Automatic sync stopped.")
    end
    state.pendingSince = nil
    state.questTransitionUntil, state.questTransitionManual = nil, nil
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

-- Called after an appearance setting changed (v0.6.0). The coalesced
-- evaluation re-prepares the current destination; RefreshLabel then writes
-- only a bridge-owned, tracked coordinate destination whose presentation
-- differs, within PRESENTATION_MIN_INTERVAL. Manual pins, other addons' pins,
-- native quests and an active preview (no ticker) are left alone; with
-- automatic sync off the change applies at the next /rxpw sync.
function Sync.OnPresentationChanged()
    state.lastContextLabelLog = nil
    ScheduleEvaluation()
end

-- One-time manual sync; works whether or not automatic sync is enabled.
-- Uses the selected strategy, so in hybrid it may choose native quest mode.
function Sync.SyncNow()
    if not state.inWorld then
        RXPW.Print("Sync skipped: loading screen. Navigation left unchanged.")
        return false
    end
    local wui = WUI.GetStatus()
    if not wui.apiAvailable then
        RXPW.Print("Sync failed: Waypoint UI navigation API is not available.")
        return false
    end

    local target, reason = RXP.GetTarget()
    if reason or not target then
        RXPW.Print("Sync skipped: %s. Waypoint UI destination left unchanged.", reason or "no RestedXP waypoint")
        return false
    end

    state.pendingSince = nil
    state.questTransitionUntil, state.questTransitionManual = nil, nil
    NoteStep(target)
    state.watchedLabel = target.label
    local decision = Nav.Decide(target, RXPW.db.strategy, Sync.GetDecisionContext())
    state.lastDecision = decision
    if decision.mode == "native" then
        RXPW.Print("Switching to native quest navigation for %s...", decision.questName or ("quest " .. decision.questID))
        BeginNative(target, decision, "manual", true)
        return true
    end

    PrepareCoordinateTarget(target, decision)
    local ok, err = ToCoordinates(target, "manual", false)
    if not ok then
        RXPW.Print("Sync failed: %s.", err)
        return false
    end

    RXPW.Print("Synced: %s", RXPW.DescribeTarget(target))
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
    if event == "PLAYER_LEAVING_WORLD" or event == "PLAYER_ENTERING_WORLD" then
        state.inWorld = event == "PLAYER_ENTERING_WORLD"
        state.syncSession = state.syncSession + 1
        state.questEvalPending = false
        state.questEvalAt = nil
        state.pendingSince = nil
        state.questTransitionUntil, state.questTransitionManual = nil, nil
        if state.pendingNative then AbandonNative(state.pendingNative, "world changed") end
        -- After a loading screen, re-read RestedXP and allow one retry of a
        -- previously rejected destination. Unchanged destinations are not rewritten.
        state.failedKey = nil
        wipe(state.nativeFailed)
        RXP.ResetObservation()
    elseif QUEST_EVENTS[event] then
        OnQuestEvent(event)
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
    RegisterOptionalEvent("PLAYER_LEAVING_WORLD")
    RegisterOptionalEvent("USER_WAYPOINT_UPDATED")
    RegisterOptionalEvent("SUPER_TRACKING_CHANGED")
    for event in pairs(QUEST_EVENTS) do
        RegisterOptionalEvent(event)
    end

    if RXPW.db.autoSync then
        Sync.Start()
    end
end
