# Stage 4: F7, F8, preview recovery and pathfinding, v0.5.9

Implemented 2026-10-15. Offline verification only; in-game acceptance is pending.
No staging, commit, tag or push was performed, and all earlier uncommitted work
was preserved. HEAD is still the v0.5.4 commit `ced78df`; v0.5.5 to v0.5.9 exist
only in the working tree (see "Git state").

## Investigation summary

**RestedXP (RXPGuides 4.11.23, read-only).** RestedXP does send AceEvent-3.0
messages through a registry shared by every embedder: `RXP_STEP_ACTIVATED`
(next frame), `RXP_STEP_DEACTIVATED` (sync), plus `RXP_STEP_COMPLETE` and
`RXP_OBJECTIVE_COMPLETE`, which are queued and suppressed within 1 s of a step
change. None of them fires for:

- a manual checkbox skip (`ActiveStepElementPostClick`, GuideWindow.lua ~236);
- a waypoint skip;
- a sticky step becoming active again.

`RXPFrame.activeSteps` is one table that SetStep wipes and refills in place
(GuideWindow.lua 667, 811), so its identity never changes. The messages are
therefore incomplete. Using them would also mean embedding another addon's
AceEvent copy and depending on internal message names. A content comparison is
required either way, so it is the only mechanism used.

**Waypoint UI (1.7.3, read-only).** These are confirmed in source:

- **Session persistence.** The custom navigation is saved per character in
  `WaypointDB_Local.mapPinSessionData.userNavigation` (MapPin.lua 115). It holds
  the `CreatePinData` fields `name`, `mapID`, `x`/`y` (0–1), `flags`,
  `iconTexture`, `iconType`, `r`/`g`/`b`, `stripCoordinates` and `superTracked`.
- **Restore.** On load the saved table is assigned as-is (MapPin.lua 1175). No
  NewUserNavigation, no waypoint call, no supertracking.
  `IsUserNavigationFlagged(flag)` is true at once.
- **Tracking after restore.** `IsUserNavigationTracked()` also needs
  supertracking. Waypoint UI's `ADDONS_UNLOADING` handler clears supertracking
  when pathfinding is off (Navigation_DataProvider.lua 776), so after /reload a
  restored navigation is usually present but untracked.
- **Rename side effects.** `NewUserNavigation` with unchanged coordinates skips
  `C_Map.SetUserWaypoint` but always:
  - builds a new navigation table;
  - calls `SetSuperTrackedUserWaypoint`;
  - fires `MapPin.NewUserNavigation`.
- **What that event does.** The Waypoint_Director listener resets the marker:
  it hides all frames, clears its cache and replays the intro animation, including
  the WaypointShow/PinpointShow sound, whatever `suppressAudio` says (that only
  covers the "new navigation" sound). The pathfinding listener, when pathfinding
  is enabled with a FarstriderLib or Mapzeroth provider, synchronously:
  - rebuilds the path;
  - clears and recreates the path-step waypoint;
  - restarts the recalculation ticker.
- **Pathfinding gate.** Pathfinding is off by default (`PathfindingEnabled =
  false`). There is no deduplication on this path and no throttling between
  calls.
- **No rename API.** `WaypointUIAPI.Navigation` has no rename or update
  function. The undocumented `suppressPathfinding` and `syncNativeWaypoint`
  options exist but are not used, under AGENTS rule 4. Neither would avoid the
  Director reset.

## F7: RestedXP activity changes at an unchanged arrow

**Root cause.** The 0.25 s poller compared only arrow-element fields. A served
step skipped, a sticky step finishing or (re)activating, or an instruction
ticked off changes the fresh decision. Examples: the patrol's selected quest,
native eligibility, the current-step priority. None of them moves the arrow or
fires a quest event, so the bridge kept the old decision. Labels only helped
when the changed instruction happened to be the label.

**Fix.**

- `Nav.GetActivitySignature(element)` builds a compact string covering the
  arrow's step and every indexed `RXPFrame.activeSteps` entry. For each step it
  records the index, the active flag and the `IsDone` state of every element.
- `IsDone` is "skip, or completed on a real instruction". The guide window's
  draw-time `completed` flag on headings, helpers and `.goto` lines therefore
  never changes the signature, and the v0.5.6 render-flag bug is not
  reintroduced. Table identities are not used.
- `Sync.CheckActivity` runs from the existing ticker at most once a second
  (`ACTIVITY_CHECK_INTERVAL`). It does no evaluation and no label work, only the
  signature. `RXP.GetArrowElement` reads the element without label resolution.
- A changed signature schedules the existing coalesced evaluation (0.5 s).
  `Evaluate` records the signature, so a change it already saw (for example
  together with an arrow move) is not handled twice.
- Every existing rule then applies unchanged: manual holds and `nativeHold`,
  the native → native switch, idempotent writes, preview (no ticker while a
  preview is shown) and generation gates on pending work.

## F8: the same native quest, a different activity area

**Root cause.** `EnsureNative` returned early whenever `handledId == nativeId`.
That identity (`objective:Q`) deliberately ignores where RestedXP leads, so a
move to another step, objective or distant area was never verified.

**Fix.** "Is it the same quest?" and "is its native target still right for
RestedXP's activity?" are now separate questions.

- `Nav.Decide` adds two fields:
  - `decision.activity`: the native id, objective set, arrow step, the steps
    holding the quest work and a circuit marker.
  - `decision.anchor`: a value copy of the arrow's world position, set outside
    `#loop` circuits and patrols. Hybrid's activity is its existing `key#quest`
    id, so hybrid is unchanged.
- After a verification passes, Sync records `handledActivity` and
  `handledAnchor`; no RestedXP tables are retained.
- With the same id, `AreaChange` asks for re-verification when either:
  - the activity differs; or
  - outside circuits, the destination moved more than the decision's tolerance
    (objective 100 yd, turn-in 50 yd) from the verified anchor.

  Progress updates, cycling `#loop` points and nearby parent-linked points never
  qualify.
- `Reverify` skips the check while another waypoint is tracked, or when WoW is
  no longer following the quest. In those cases nothing is fought or released,
  as before.
- Otherwise `BeginNative(..., reverify = true)` creates a pending operation with
  **no clear and no supertracking call**. After `NATIVE_VERIFY_DELAY`, the
  shared F1–F3 gate (`CurrentNativeTarget`) re-reads RestedXP. Verification then
  uses the fresh decision's tolerance and references, never a captured target.
  - **Pass:** the quest is kept with no write, and the new activity is recorded.
  - **Fail:** the normal `FailNative` path runs. It tries the next eligible
    circuit candidate, or else releases the quest only if it is still
    supertracked and applies RestedXP's current coordinates.
  - **Cancelled:** for example a manual pin, RestedXP selecting another quest,
    an invalid target, stop, preview or loading. Nothing is written and the
    established native state is kept.
- `nativeFailed[id]` now stores the failing activity. A different activity for
  the same quest may be tried immediately, while the same activity keeps the
  existing 60 s / 10 s retry policy.
- Pending transitions also verify against the fresh decision. A same-quest
  activity change during a transition is checked against the current area.
- `/rxpw status` shows "re-checking the native target for RestedXP's new
  activity" while a re-verification is pending.

## Preview recovery after /reload

**Root cause.** `Preview.Off` acted only on in-memory `state.active`, which
/reload resets, while Waypoint UI restores the preview-flagged navigation.
Afterwards:

- `/rxpw preview off` printed "No preview is shown" and left the marker.
- Sync treated a still-tracked restored preview as foreign and paused.

**Behaviour chosen.**

- **Automatic cleanup when automatic sync is on.** At the first evaluation
  after login or `/rxpw on` (`handledMode == nil`), `Preview.RemoveOrphan()`
  removes a navigation that carries exactly `RestedXPWaypoint-Preview`. It does
  this only when no preview session is active. It prints one chat line, and the
  next evaluation writes RestedXP's current destination normally.
- **When automatic sync is off,** nothing happens until the player runs
  `/rxpw preview off`, which removes the confirmed orphan.

Rationale: the preview is a temporary testing aid, and the flag is proof of
ownership. Without cleanup, sync would either overwrite the untracked marker
anyway or pause on it as foreign. Removing it at a defined moment is the
predictable result. With sync off, the player decides.

**Safeguards.**

- Identification uses only the persisted flag, checked through both the stored
  table and the documented `IsUserNavigationFlagged`. Never the label, icon or
  coordinates.
- `ClearNavigationWithFlag` re-checks the flag before
  `ClearUserNavigation(false, true)`.
- Manual pins (no flag), other addons' flags and native quest tracking are never
  touched. Waypoint UI's handler clears all supertracking only when the removed
  waypoint itself was supertracked.
- No compatibility path for the old `RXPWaypointBridge-Preview` flag was added;
  there is no evidence it is needed.

## Same-destination presentation updates (pathfinding)

**Confirmed API behaviour.** See the investigation summary. Every rename
replays the marker intro (and show sound); with pathfinding on, it also rebuilds
the path and recreates the path-step waypoint. When a path is active, the native
waypoint is the path step. A rename therefore first moves it back to the
destination (`IsCurrentWaypoint` is false), and the rebuild then recreates the
step. This is an external API limitation: no supported call updates presentation
in place.

**Mitigation implemented.** This is a small, eventually consistent rate limit
inside the bridge.

- `RefreshLabel` sends a same-destination presentation update immediately when
  the previous successful Waypoint UI write is at least
  `PRESENTATION_MIN_INTERVAL` (2 s) old.
- Otherwise it records the deferral in `presentationRetryAt` and schedules the
  coalesced evaluation for that moment. That evaluation re-reads RestedXP and
  applies the latest label, icon and colour once.
- Unchanged presentation is never written; the existing `HasTargetLabel`
  read-back covers that.
- Destination changes and native transitions are never delayed. Failed writes
  keep the F4 recovery path, and manual pins, preview and inactive destinations
  still block presentation writes.
- Worst-case staleness of the label is about 2 s plus the coalescing delay.
  Live progress is not disabled.

**Offline evidence (counters only).** In the T3 burst (seven progress changes
0.6 s apart), the pre-fix code made 7 renames and 7 marker resets (and 7 path
rebuilds with pathfinding modelled on). The fix makes at most 3 during the burst
and at most 4 overall, and the final label is the latest.

**Limitations.** Each remaining rename still resets the marker and, with
pathfinding, rebuilds the path. The visual result, sound and FPS impact cannot
be measured offline.

## Regression scenarios and results

`tests/stage4_test.lua` (new, 65 assertions) checks actual supertracking,
Waypoint UI destination, flags, labels, icons and writer history.

**F7 (activity at an unchanged arrow):**

1. Patrol unchanged, served quest A → B.
2. An instruction of the arrow's own `#loop` step ticked off; the label is
   unchanged, so only F7 can see it.
3. Sticky step becoming active, then inactive.
4. Current-step prioritization change.
5. Change during a pending transition.
6. Redraw flags and a rebuilt `activeSteps` cause no evaluation.
7. Coordinates mode:
   - idle: no evaluation;
   - an irrelevant real change: one evaluation, no write;
   - an activity change: exact coordinates, presentation follows, no
     supertracking.
8. Manual pin protected.
9. A stable signature over 30 s: no evaluation or write, about one check per
   second.

**F8 (same quest, different area):**

1. Same area: progress and a nearby parent-linked point cause no
   re-verification.
2. A different objective set is re-verified.
3. An equivalent new step keeps native tracking without a write.
4. A destination 190 yd away while Blizzard points at the old area: rejected,
   RestedXP coordinates used, not retried for the same activity; a later new
   activity is reconsidered.
5. `#loop` cycling: no re-verification.
6. A turn-in replaces objective navigation.
7. A pending check superseded by a newer far activity.
8. A manual pin during the check: no release, no fallback.
9. A target hidden during the check: native kept, nothing written, re-verified
   later without a supertracking call. The status line reports the area check.
10. Coordinates strategy follows exact waypoints.

**Preview:**

1. Normal entry and exit.
2. Restored preview, tracked and untracked, with sync on: removed, sync resumes.
3. `preview off` removes an orphan while sync is off.
4. Manual pin untouched (sync on and off).
5. Another addon's flag untouched (sync on and off).
6. Native quest tracking untouched.
7. Preview during a pending transition, then resume.
8. Sync resumes at RestedXP's destination.
9. No preview: no extra writes or clears.

**Presentation.** Each check runs twice, with pathfinding off and on (T6):

- T1: a label change at unchanged coordinates is written once.
- T2: repeated identical events cause no write.
- T3: a rapid burst is bounded.
- T4: an icon-only change is applied.
- T5: a rejected rename recovers.
- T7: coalescing leaves no stale presentation, and marker resets and path
  rebuilds match writes.
- T8: a manual pin is protected.

**Pre-fix reproduction.** The same suite and harness were run against a
snapshot of the v0.5.8 modules: 41 passed, 23 failed. They fall into three
groups:

- **Behavioural reproductions:**
  - F7.1, F7.2, F7.3, F7.4 and F7.5: the old quest or mode was kept.
  - F7.7: the presentation stayed "Gem Work".
  - F8.2: never re-verified.
  - F8.4: native kept despite a 150 yd gap, so the follow-up "not retried" and
    "reconsidered" checks fail too.
  - F8.7.
  - P2 (both variants), P3 and P6 (twice): the orphan was not removed.
  - T3 (both variants): 7 renames.
- **Instrumentation only:** F7.9 (both checks) and F7.7's evaluation count. The
  pre-fix code has no counters.
- **Missing precondition:** F8.8 and F8.9. No area check exists to interrupt.

**Full results.** `node tests/run.js`: **14 Lua suites, 593 assertions, 0
failures**, plus TOC identity, version (0.5.9), dependency and module-order
validation. That is 528 existing assertions and 65 new. The transition suite
(F1–F3, 102) and Stage 3 suite (F4–F6, 50) are included and unchanged.

- Every module parses as Lua 5.1 (luaparse 0.3.1).
- `git diff --check` is clean, and the new untracked files have no trailing
  whitespace.
- No existing test expectation was modified.
- Harness additions:
  - Waypoint UI marker-reset and path-rebuild counters;
  - an opt-in path-step tracking model (`wui.pathfinding`);
  - `H.restoreSession`, which restores a `CreatePinData`-shaped session before
    load;
  - the mock addon version string.

## Performance

| Item | Before | After |
|---|---|---|
| Poll ticker | 0.25 s | unchanged |
| Label check | 1 s | unchanged |
| Timers | — | none new; one comparison per tick at most |
| Activity check | none | once a second: one pass over the arrow step and active steps, no decision, no Waypoint UI call |
| Evaluations | — | at most one coalesced evaluation per actual activity change; zero while the signature is stable |
| Supertracking calls | — | none new; re-verification never supertracks |

- **Signature cost:** about 0.5 ms per call for 5 steps × 20 elements under
  fengari, a JavaScript-interpreted Lua that is much slower than WoW's; native
  cost is expected to be far lower. It has not been profiled in game.
- **Re-verification:** one delayed `C_Timer.After` per actual area change,
  through the existing pending-operation path.
- **Waypoint UI writes:** same-destination renames are now at most one per 2 s.
- **Debug logging:** one debug line per activity change or area check, nothing
  while stable.

## Compatibility and intentional changes

- **Coordinates:** navigation is unchanged and always uses exact RestedXP
  coordinates. Presentation may now follow an activity change without a quest
  event, and renames are rate limited.
- **Hybrid:** navigation decisions are unchanged (activity equals the existing
  `key#quest` id). It gains F7 re-evaluation and the rename limit.
- **Native-first:**
  - An unchanged native quest may now be re-verified, and dropped to RestedXP
    coordinates, when RestedXP moves to an area its native target provably does
    not match.
  - A failed native id can be retried immediately for a different activity.
  - Patrol cycling, progress and helper continuity behave as before.
- **Preview:** restored preview markers are removed automatically when
  automatic sync starts, or by `preview off`.
- The default strategy is unchanged.

## Remaining limitations

- Forever event ordering, RestedXP's in-place `activeSteps` rebuild timing and
  Waypoint UI's real rename and pathfinding visuals are unverified in game.
- Whether WoW restores supertracking for a preview waypoint after /reload is
  unverified; both cases are handled.
- Re-verification is one-sided, like v0.4/v0.5: it can reject a provably far
  native target, never prove a match.
- A rename still resets Waypoint UI's marker; only its frequency is reduced.

## In-game acceptance checklist

Set `/console scriptErrors 1` and `/rxpw debug`, then `/reload`.

1. **Version.** `/rxpw status` shows `status (v0.5.9)` and your saved strategy.
2. **Coordinates.** In `/rxpw mode coordinates`, follow a multi-`.goto` route.
   Expect one write per destination and exact coordinates.
3. **Native-first, changing objectives.** In `/rxpw mode native-first`, on a
   quest whose RestedXP steps move between areas: when the step changes, debug
   shows "Native quest N: RestedXP activity changed" and then either "still
   matches … (no navigation write)" or a fallback to coordinates with a "Native
   target check" gap above the limit. No marker flicker on progress or loop
   cycling. *Needs a guide quest with several areas for one quest.*
4. **Patrol or helper activity.** On a Skyborne patrol (Vuldren/Cirrusfly,
   Agitators), skip a served step in RestedXP's window without moving. Within
   about 1.5 s the native quest switches; `/rxpw inspect` agrees.
   *Needs such a step.*
5. **Manual waypoint.** Place a manual pin, then skip a step or progress the
   objective. The pin stays, and debug says "held".
6. **Preview and /reload.** Run `/rxpw preview flightmaster`, then `/reload`:
   - **Sync on:** "Removed a leftover preview marker" appears, then the RestedXP
     destination returns.
   - **Sync off** (`/rxpw off` before the preview): after `/reload`, run
     `/rxpw preview off`. The marker is removed and the chat line appears.
   - **Repeat with a manual pin:** it is never removed.
7. **Progress, pathfinding on.** Enable Waypoint UI pathfinding (FarstriderLib
   or Mapzeroth provider), then earn several kills quickly on a coordinate
   objective ("1/15 …"). The label catches up within about 2–3 s, with at most
   one marker intro and path rebuild per 2 s. Watch for path-step flicker and FPS.
8. **Progress, pathfinding off.** Repeat item 7 with pathfinding disabled.
9. **Services and turn-in.** At a flight master or innkeeper step, check the
   service icon and colour. At a native turn-in (hybrid or native-first), check
   it goes native and returns to coordinates afterwards.

## Git state

- **Branch:** master. **HEAD:** `ced78df` (v0.5.4). No commit or tag was created.
- **Modified in this stage:**
  - `Sync.lua`, `NavigationResolver.lua`, `RXPAdapter.lua`, `WaypointAdapter.lua`
    and `Core.lua`;
  - `Preview.lua` (untracked);
  - `tests/harness.lua` and `tests/run.js`;
  - `RestedXPWaypoint_Camelot.toc` (untracked);
  - `README.md` and `AGENTS.md`.
- **New:** `tests/stage4_test.lua` and this report.
