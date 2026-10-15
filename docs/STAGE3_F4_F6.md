# Stage 3: F4-F6, v0.5.8

Implemented 2026-10-15. Offline verification only. In-game acceptance is pending.
No staging, commit, tag or push was performed; existing work was preserved.

## Root causes and implementation

**F4:** RefreshLabel assigned handledLabel/handledIcon before checking active
ownership or write success. PauseForForeign also recorded unapplied presentation.
EnsureCoordinates gated only on label/texture, overlooking colour changes.
CheckLabel noticed only new RXP text, so failed/skipped updates could be forgotten.

Sync now separates observed RXP text (watchedLabel) from the prepared desired
target (desiredPresentation). Handled label/icon advance only after successful
writes or independent verification of the active owned destination. The actual
WUI navigation is authoritative for applied label, texture/type, RGB and
coordinate visibility. Refresh checks this complete presentation even when text
has not changed. WaypointAdapter now also compares iconType.

The existing one-second label check detects pending presentation mismatches only
while that same bridge destination is actively tracked. It schedules the existing
coalesced quest evaluation, which obtains fresh RXP/quest data before writing.
Skipped/failed updates retain desired presentation. Failed refresh attempts are
spaced at least five seconds apart. There is no new ticker, recursive retry or
normal chat spam. Persistent refusal can cause one silent attempt roughly every
five to six seconds while authorized. Destination-creation failures retain the
original failed-key policy. Manual pins, inactive destinations, stale RXP targets,
preview, stopped sync and loading cannot authorize presentation recovery.
Navigation events remain diagnostics/cancellation only.

**F5:** FindQuestTarget stopped at the immediately preceding waypoint, producing
an empty block on the second shared-parent point and silently switching to
coordinates. Label.Resolve already followed parent directly, but did not validate
same-step membership, allowing stale associations and disagreement with navigation.

Label.LinkedBlock now provides shared validation and block boundaries. Parent and
waypoint must occur in order in the same active step, the parent must be pending,
and intervening waypoints must have that exact parent. The full instruction block
retains sibling objectives and pending actions; different waypoint groups remain
boundaries. Both resolvers use this association. Own travel text still wins.
Hidden/loop flags do not bypass validation. RXPAdapter still rejects inactive steps.

The old native-first test's intended expectation was correct; its assertion was
incomplete: unchanged supertracking calls also passed after a coordinate fallback.
It now checks actual native mode, quest 600, final supertracking, user tracking off
and no leftover coordinate navigation. No existing expectations were relaxed.

**F6:** Hybrid checked radius/flags and turn-in links but omitted native-first's
own travel-text protection, so a no-radius cave entry could become native turn-in.
Both analyses now share HasTravelInstruction. Text containing letters stays on
coordinates, preserving native-first's handling of generated text and numeric
placeholders. Hybrid's other eligibility rules remain. Ordinary eligible direct
turn-ins still go native. Parent-linked hybrid turn-ins also validate their link.

## Modified files in this stage

- Sync.lua: desired/applied separation, full readback comparison, bounded recovery.
- LabelResolver.lua: shared same-step parent validation and label integration.
- NavigationResolver.lua: shared-parent blocks and shared travel protection.
- WaypointAdapter.lua: include icon type in presentation matching.
- tests/harness.lua: counters for temporary WUI refusal or error before mutation.
- tests/stage3_test.lua: focused observable F4-F6 regression suite.
- tests/native_first_test.lua: strengthen parent continuation assertions.
- RestedXPWaypoint_Camelot.toc and tests/run.js: v0.5.8 and metadata check.
- README.md, AGENTS.md and this report: behaviour, evidence and acceptance notes.

## Regression evidence

The initial focused suite ran against the original modules: **31 passed,
10 failed**. Failures included rejected/error rename recovery without another
event, external-supertracking recovery, colour-only changes, second through fourth
parent-linked points, stale cross-step parents and hybrid no-radius travel.
Additional focused checks were added afterward; all now pass.

The final focused suite has **50 assertions**, checking actual destination,
label, icon, RGB and mode/quest state where relevant:

- F4: 1/15 to 2/15, rapid coalesced progress, nil rejection, thrown error,
  no-further-event recovery, persistent refusal rate limiting/recovery,
  external quest tracking and return to owned tracking, colour-only/icon-only
  changes, already displayed presentation without a write, manual protection
  and explicit resume, preview interruption/resume.
- F5: two/three ordinary and four hidden-loop shared-parent points, incomplete
  objectives, quest context/icon/label, different parents, explicit travel,
  cross-step invalid parents, inactive steps and shared ready turn-in points.
  The existing multi-objective fixture now checks actual final native state.
- F6: all three strategies, own travel with/without radius, sticky parent-linked
  travel, multiple cave/doorway points, final ordinary eligible turn-in and
  direct parent-linked turn-in.

Harness additions are small failure counters. Existing ownership, foreign
navigation, supertracking, preview and actual-destination mocks are reused.

## Validation and compatibility

`node tests/run.js`: **13 Lua suites, 528 assertions, zero failures**, plus TOC
identity/version/dependency/module-order validation. The transition suite was
also executed separately through fengari: **102 assertions, zero failures**
(already included in the 528 total).

Existing quest/service icons, progress, previews, patrol/selection, hybrid,
native-first and F1-F3 suites pass. Intentional navigation changes are confined
to valid shared-parent continuation, rejection of invalid links and hybrid
explicit travel protection. Coordinates mode still follows RXP coordinates.
Native verification, generation checks, interrupted-operation holds and existing
manual resume policy are preserved. F7/F8, preview recovery after reload,
settings UI and pathfinding redesign remain out of scope.

No game client validation was performed. Mocks do not implement WUI rendering
or pathfinding and do not prove Forever event ordering or runtime performance.

## Performance

Polling frequencies remain 0.25 seconds for raw target comparison and one second
for label inspection. The latter adds public WUI ownership/coordinate and
presentation comparisons. Pending active mismatches schedule a fresh evaluation
through the existing coalesced path; unchanged matching presentation causes no
extra evaluation or write. Parent traversal stays within the current step.
Normal coordinate evaluations now compare complete actual presentation rather
than only handled text/texture. Persistent failures are rate limited; external
navigation cannot trigger recovery writes. Same-coordinate presentation updates
can still restart WUI pathfinding: this API limitation remains Stage 4 work.

## In-game acceptance

Enable `/console scriptErrors 1`, `/rxpw debug`, then `/reload`.

1. `/rxpw status`: confirm v0.5.8 and saved strategy. In `/rxpw mode coordinates`,
   earn progress 1/15 to 2/15 and several rapid updates. Check live text, quest
   icon, colour and unchanged destination.
2. Let a different quest become supertracked during progress: no reclaim.
   When the same owned waypoint is tracked again, latest text should recover
   without another quest event. Check `/rxpw status`.
3. `/rxpw mode native-first`: incomplete objective stays native through progress
   and a multi-waypoint parent-linked route. Use `/rxpw inspect` and status to
   check mode, quest ID and context rather than appearance alone.
4. `/rxpw mode hybrid`: cave/bridge/doorway points stay coordinates, including
   no-radius and sticky/parent-linked travel. The final eligible turn-in goes
   native. Direct eligible turn-ins should still work.
5. Set a manual WUI pin, then earn progress. It must remain selected.
   `/rxpw sync` explicitly resumes with current text, or let RXP advance to a
   genuinely new destination. Invalid/inactive targets must not restore stale pins.
6. `/rxpw preview incomplete`, earn progress, then `/rxpw preview off`:
   preview remains protected and resumed navigation uses latest progress.
7. Visit a flight master/innkeeper step and check service icon, colour and text.
   Repeat route/manual cases with WUI pathfinding on and off; watch for errors,
   repeated writes and flicker.

Real WUI failures, tracking return, event ordering and hidden/sticky parent
structures particularly need in-game acceptance. Offline results are not proof
of in-game behaviour.

## Git state at handoff

Branch: master. HEAD: ced78dfaa167b20ed6d72e376704df7f3db4742f.
All existing uncommitted/untracked work remains. The old TOC deletion was already
present before this stage. No automatic commit was created.

Working-tree status (directories below include previously untracked artifacts):

```text
 M .gitignore
 M AGENTS.md
 M Core.lua
 M LabelResolver.lua
 M NavigationResolver.lua
 M README.md
 M RXPAdapter.lua
 D RXPWaypointBridge_Camelot.toc
 M Sync.lua
 M WaypointAdapter.lua
 M tests/agitators_test.lua
 M tests/harness.lua
 M tests/hybrid_test.lua
 M tests/label_test.lua
 M tests/native_first_test.lua
 M tests/package.json
 M tests/run.js
 M tests/vuldren_test.lua
 M tests/windstones_test.lua
?? Art/
?? Preview.lua
?? RestedXPWaypoint_Camelot.toc
?? docs/
?? tests/icons_test.lua
?? tests/preview_test.lua
?? tests/progress_test.lua
?? tests/rebrand_test.lua
?? tests/services_test.lua
?? tests/stage3_test.lua
?? tests/transitions_test.lua
?? tools/
```

Untracked files:

```text
Art/Icons/Bags.blp
Art/Icons/ClassTrainer.blp
Art/Icons/FlightMaster.blp
Art/Icons/FoodAndDrink.blp
Art/Icons/Grind.blp
Art/Icons/Innkeeper.blp
Art/Icons/ProfessionTrainer.blp
Art/Icons/Repair.blp
Art/Icons/StableMaster.blp
Preview.lua
RestedXPWaypoint_Camelot.toc
docs/RELIABILITY_F1_F3.md
docs/REVIEW_HANDOFF.md
docs/STAGE3_F4_F6.md
tests/icons_test.lua
tests/preview_test.lua
tests/progress_test.lua
tests/rebrand_test.lua
tests/services_test.lua
tests/stage3_test.lua
tests/transitions_test.lua
tools/Migrate-Install.ps1
tools/build_icons.py
```
