# Stage 6: release readiness — RestedXP Waypoint

Audit date: 15 October 2026 (Europe/Berlin). TOC version: **0.6.1**.
Scope: final maintenance audit and local release-candidate preparation.

## 1. Assessment and release gates

**Ready to enter final RC testing, subject to checkpoint approval. Not yet v1.0.**
The existing navigation architecture remains intact. A reproduced presentation
bug was corrected with a small change and six observable regression assertions.
All offline checks pass. No unresolved reproduced navigation/ownership blocker
was found in the audited paths. This is not proof that every possible guide
structure or client state works.

The developer reports successful in-game use, most recently explicitly confirmed
at v0.6.0. This audit did not operate WoW, inspect live client memory or perform
new in-game tests. v0.6.1 service changes, transition smoothing and the Stage 6
presentation correction need the targeted acceptance checks below.

Before v1.0:

1. Approve and create a complete source checkpoint. No current commit captures
   the implemented addon; important runtime files are still untracked.
2. Complete the priority in-game matrix below, including an actual extracted
   installation, full restart, all strategies and manual-override delays.
3. Resolve any reproduced navigation, ownership or destination regression found
   there. Record client/dependency versions and observed results.

No version bump, Git staging, commit, tag, push or publication occurred. No
RestedXP or Waypoint UI implementation was changed, on disk or at runtime.

## 2. Git checkpoint and source inventory

Branch **master**, HEAD **ced78dfaa167b20ed6d72e376704df7f3db4742f**,
`RXP Waypoint Bridge v0.5.4`. Index is empty. No remote is configured.
The rename is currently a tracked deletion of `RXPWaypointBridge_Camelot.toc`
plus untracked `RestedXPWaypoint_Camelot.toc`; it is not a missing runtime TOC.
This working tree contains several milestones beyond HEAD, not just Stage 6.

Before Stage 6 edits, a byte-for-byte local snapshot of all 54 existing tracked
and non-ignored untracked source files was saved to:

`.release/stage6-baseline-2026-10-15T18-16-07-507Z/`

`BASELINE_MANIFEST.json` records byte lengths and SHA-256 hashes. This is an
ignored local recovery aid, **not a Git checkpoint or off-machine backup**.
The index and history were left untouched. Existing edits were preserved.

Include in the proposed checkpoint:

- `.gitignore`, `AGENTS.md`, `README.md`.
- All eight runtime modules: `Core.lua`, `LabelResolver.lua`, `RXPAdapter.lua`,
  `NavigationResolver.lua`, `WaypointAdapter.lua`, `Sync.lua`, `Preview.lua`,
  `SettingsPanel.lua`.
- New `RestedXPWaypoint_Camelot.toc`, including interface 16001, version 0.6.1,
  optional load dependencies and `SavedVariables: RXPWDB`; record deletion of
  `RXPWaypointBridge_Camelot.toc`.
- `Art/Logo.blp` and **all nine** `Art/Icons/*.blp`. These generated files are
  required runtime assets and must be committed, not regenerated on installation.
- Entire non-ignored `tests/` source, runner, package manifest and lockfile.
- All eight `docs/*.md` reports, including this report. Historical reports remain
  historical; they are not claims that the present version was tested in game.
- `tools/build_icons.py`, `tools/build_logo.py`, `tools/logo_source.png` and the
  new `tools/package_release.py` for source maintenance/release reproduction.
- `tools/Migrate-Install.ps1`: intentionally machine-specific historical migration
  utility, already documented. Keep in the source checkpoint for recovery context;
  exclude from runtime ZIPs. Do not run it for ordinary installations.

Keep ignored/untracked locally: `tests/node_modules/`, `tools/__pycache__/`,
`.release/` snapshots/ZIPs/checksums, logs and editor state. No personal
SavedVariables files were found in the intended source tree. Root personal
`RestedXPWaypoint.lua*`, `RXPWaypointBridge.lua*` and `/WTF/` are now explicitly
ignored. SavedVariables *code* in Core and the TOC is required; personal WoW
SavedVariables output is not source. No runtime absolute drive paths were found.
Development paths in AGENTS and the migration utility are intentional.

Recommended checkpoint message:

`Checkpoint RestedXP Waypoint 0.6.1 release candidate and Stage 6 audit`

After explicit developer approval, a maintainer can review/stage this exact scope:

```powershell
git add -A -- .gitignore AGENTS.md README.md Core.lua LabelResolver.lua RXPAdapter.lua NavigationResolver.lua WaypointAdapter.lua Sync.lua Preview.lua SettingsPanel.lua RXPWaypointBridge_Camelot.toc RestedXPWaypoint_Camelot.toc Art docs tests tools
git diff --cached --stat
git diff --cached --check
git commit -m "Checkpoint RestedXP Waypoint 0.6.1 release candidate and Stage 6 audit"
```

These commands were **not executed**. Review the staged file list before committing.
Concerns: accumulated history is large, binary art must be included, and the old
TOC deletion must accompany the new TOC. The RC and snapshot remain local and
ignored. Original service-icon input images are not in this checkout; current
BLPs are sufficient to run, but exact regeneration needs those input images.
Artwork provenance and distribution terms deserve a short maintainer record
before public distribution; no license or rights determination is made here.

## 3. Review findings and actual changes

| Classification | Finding / action | Behaviour and regression risk |
|---|---|---|
| Release blocker, already resolved before Stage 6 | Mining Pick at 2521, 42.76, 24.50 was misclassified from a `.train 2575,3` condition. The v0.6.1 fix is present; verified against installed Skyborne lines 715–721 and service-context tests. | Vendor/Bags, Merchant Blue, correct label/coordinates. No new fix needed here. |
| Confirmed presentation defect, fixed in Stage 6 | `GetPresentation` fallback used `StepActivity` over the entire step. A pending acceptance at waypoint A gave waypoint B's vendor visit an Available Quest icon. | Scope fallback quest lookup to the existing waypoint instruction-block bounds. Explicit structured quest context still takes precedence. No navigation or label resolver change. Low risk; existing suites plus all-strategy destination/icon/colour checks pass. |
| Recommended improvement, implemented | Restore Defaults copy promised the current waypoint could not change, although restoring strategy/auto-sync applies normal navigation behaviour. | Corrected panel note, confirmation and Core comment only. No reset behaviour change; low risk. |
| Recommended improvement, implemented | AGENTS contained a non-UTF-8 byte `0x96` in `F4-F6`, stale version/roadmap, conflicting native eligibility wording and an incorrect `.accept` attribution for the installed `.turnin` setter. | UTF-8 repaired, safeguards retained, current timing documented. Documentation only. |
| Recommended improvement, implemented | README mixed install guidance with a large development history, lacked ordinary extraction instructions and claimed silent labels meant no flicker. | Rewritten around installation, controls, limitations and troubleshooting; detailed history stays in docs. Documentation only. |
| Recommended improvement, implemented | Label tests had no numerical suite summary; lockfile still carried the pre-rebrand package name. | Added pass accounting, corrected two lockfile names; no dependencies or test expectations changed. |
| Recommended improvement, deferred | `SettingsPanel.Initialize` ignores the success result of `RegisterAddOnCategory`, potentially reporting registration success after an API exception. | No failure reproduced on Forever; handle the return and add a throwing-API fixture later. Small defensive change, not a release blocker. |
| Recommended improvement, deferred | Minor unused surfaces: `EnsureCoordinates`' unused `trigger`, write-only `state.lastDecision`, legacy `Nav.NATIVE_DISTANCE_TOLERANCE` alias. Preview can still generate debug-only outside-navigation messages. | Cosmetic/diagnostic debt; removal or suppression is unnecessary before the checkpoint. No routing risk demonstrated. |
| Future enhancement | Shared helper consolidation, localization beyond conservative English hints, world-coordinate targets. | Out of Stage 6; no architectural refactor or eligibility expansion justified. |
| Known external limitation | Same-coordinate `NewUserNavigation` resets marker presentation and may rebuild a path. | Public API has no rename-only operation; retain two-second limit. |
| Known external limitation | An external native quest marker may render before the bridge resolves the final post-acceptance route. | No supported API to selectively suppress it. No private renderer access or supertracking fight added. |

The focused mixed-step fixture uses normal drawn-step flags and a runtime-populated
accept instruction without a parser parent. Against the saved pre-fix resolver,
**46 passed / 3 failed**: each strategy displayed the wrong icon/colour. With the
fix, **49 passed / 0 failed**. Checks assert final coordinates, map, owner flag,
label, bags texture and Merchant Blue, rather than only writer counts.

The small duplicated `IsDone`, waypoint tests and scanning helpers remain readable
and serve different boundaries. `IsDone` is identical in both resolvers. Merging
them now would add scope without a demonstrated correctness/performance benefit.
Sync's shared freshness gate, generation/session invalidation and desired/applied
presentation separation are warranted complexity; they were not rewritten.

## 4. Navigation and F1–F8 audit

| Area | Code-level conclusion | Regression evidence |
|---|---|---|
| Coordinates | Valid arrow coordinates remain authoritative; presentation cannot move the destination. Invalid/stale/missing targets retain current navigation. | hybrid, progress, icons, services, service-context |
| Hybrid | Ready, logged turn-in only; radius/dynamic/lowPrio/generated and explicit travel protection remain. Parent links are validated. | hybrid, stage3, transitions |
| Native First | Own travel text, route chains, non-quest actions and ambiguous objectives remain protected. Coverage, live quest state and distance verification remain required. | native-first, agitators, vuldren, windstones |
| F1: stop/session | Stop invalidates queued automatic evaluations and automatic native operations; manual sync while off remains possible. | transitions |
| F2: ownership | Pending operations compare native priority, quest, WUI session and raw waypoint identity by value before setters/verification/fallback; cancellation writes nothing. | transitions; quest-transition manual/raw-pin fixtures |
| F3: stale targets | Delayed work re-reads valid current RXP data; fallback never substitutes a captured target. Loading, strategy and target changes invalidate work. | transitions |
| F4: presentation recovery | Applied state advances only after success/readback; retries require same actively tracked owned destination and fresh data. | stage3, stage4 |
| F5: parent-linked routes | Shared-parent waypoint groups retain the validated quest block; cross-step/completed/invalid parents are rejected. | stage3; strengthened native-first final-state assertion |
| F6: travel protection | Both resolvers reject explicit own travel text for native substitution. | stage3, hybrid |
| F7: activity observation | Once-second signatures compare indexed active-step content and meaningful done state; no table-identity or redraw false positives. | stage4 |
| F8: same quest / new area | Activity or moved non-circuit anchor re-verifies without re-setting quest; active navigation/ownership and fresh decision are checked. Circuits ignore normal point cycling. | stage4, vuldren |

Manual protection has the established scope: it is not a permanent global pause.
A genuinely new RXP destination can resume synchronization. Native verification
is a one-sided distance rejection and accepts positive native distance when RXP
world distance is unavailable. This remains a documented limitation, not a new
claim of exact native-location proof. No eligibility rule was loosened.

The available review material is `REVIEW_HANDOFF.md` plus F1–F3, Stage 3, Stage 4,
Stage 5, service-context and quest-transition reports. No separate original raw
independent-review transcript was found in this checkout. Current source and
regressions were used to verify the findings represented by those reports.

## 5. Icons, services and transition smoothing

Available/Incomplete/Complete quest states, campaign/repeatable variants, all ten
service categories and generic fallback are covered by existing tests. Vendor
and Banker share Bags; nine local service textures plus the logo are present.
All 24 referenced Waypoint UI quest textures exist in installed 1.7.3. Local BLPs
have valid expected raw BLP2 headers, dimensions/payload sizes, transparent pixels
and visible artwork. Palette RGB values remain in the existing appearance path.

Service classification remains local to instruction blocks, respects same-step
validated parents and preserves waypoint coordinates. Training conditions are
excluded. `.collect` requires purchase evidence; English repair matching is
restricted to vendor instructions. No new keyword classifier was introduced.
Explicit quest context still wins over service fallback, preserving structured
route relationships. The new fallback fix prevents borrowing an unrelated
acceptance from another destination. Unknown tags/text remain conservative.

Acceptance/turn-in callback: **0.3 s**; normal quest coalescing: **0.5 s**;
target quiet period: **0.2 s**; continuing quest-burst ceiling: **1 s**. The
ceiling bounds smoothing, not native verification or an invalid target's recovery.
No new timing option or ticker was added. Scheduler callbacks re-read live state;
superseded deadlines and sessions are inert. Manual selections during the wait,
preview, Stop and world transitions retain their cancellation gates. Existing
native targets are reused only through normal freshness/ownership verification.
F7/F8 use the same scheduler/gate and their suites continue to pass.

Measured deterministic fixture results, not visual/in-game timings:

| Scenario | Result |
|---|---|
| Rapid route changes at 0.26/0.36/0.46/0.56 s, all strategies | One final bridge write at 0.900 s, zero intermediate writes, zero native setters. Historical pre-smoothing fixture produced two writes. |
| Same burst ending in already-active eligible native turn-in | Zero coordinate writes, zero setters/clears; verification at 1.300 s. |
| Ordinary route point | Existing poll plus quiet period; fixture applies within 0.50 s. |
| Stable acceptance | Fixture applies within 0.52 s; no extra unconditional one-second wait. |

## 6. Settings assessment

One idempotently registered canvas category; one lazy-built scrolling page;
five sections, no nested categories/tabs, no private Waypoint UI UI kit.
`RXPW.Config.Set` validates/persists/applies settings and notifies the single panel
listener. Slash/page synchronization, strategy, auto-sync, icon/colour toggles,
preview Show/Next/All/Stop, debug, status/inspect and defaults pass offline tests.
Arrow hiding exclusively uses the approved RXP adapter exception and lives in
RestedXP's own profile, not `RXPWDB`. Defaults leave that external option alone.

Build and registration guards prevent repeated frame construction. Fonts are
cached; menus are reused and closed on hide; `GLOBAL_MOUSE_DOWN` is registered
while visible and unregistered on hide. No panel OnUpdate/ticker exists. The
Config listener returns while hidden. While open, changes refresh/layout the
page; some handlers also call Refresh after the listener, so a click can perform
redundant layout work. This is infrequent UI work, not a gameplay polling cost;
no optimization is justified without a measured issue.

Visual acceptance remains necessary for wrapping, clipping, scaling, scrollbar
thumb drag, dropdown placement and real Settings restricted-call behaviour.
Status dots and the external arrow checkbox refresh on page/config activity,
not continuously; reopening refreshes them. Do not infer live-rendering quality
from the widget mocks.

## 7. Performance evidence

Temporary read-only wrappers counted existing function calls in the harness;
no permanent profiling subsystem was added. After settling initial navigation:

| 60 s simulated idle | Coordinates | Native objective |
|---|---:|---:|
| Raw target comparisons | 240 | 240 |
| Full target/label reads | 60 | 0 |
| Activity signature checks | 60 | 60 |
| New decisions / evaluations | 0 / 0 | 0 / 0 |
| Coordinate writes | 0 | 0 |
| Native setters / area reverifications | 0 / 0 | 0 / 0 |

Poll is four times per second; label/activity checks are at most once per second
and yield while settling/coalescing. Label reads allocate a target/label result
and clean text; activity scans active-step elements and builds compact strings,
reusing scratch tables. These are bounded by active guide steps, not the entire
guide catalog. Evaluations can rescan relevant blocks and served active steps;
hybrid additionally runs native-first analysis for presentation. That duplication
is intentional separation of navigation and appearance. No busy full-guide scan
or heavy OnUpdate was found.

Quest events coalesce; unchanged progress events produce no writes. Presentation
refreshes are at least two seconds apart and apply the latest desired value;
failed refreshes wait at least five seconds. Destination writes are not delayed
by the presentation limit. Native verification occurs after transitions or real
activity/area changes, not every poll. Preview All has one four-second ticker,
which is cancelled on stop/completion; ordinary preview has none. Hidden settings
have no periodic refresh. Inert superseded timer callbacks can exist briefly;
there is one effective queued evaluation.

Stage4 exercises rapid progress with pathfinding both on and off, final label,
actual destination, marker resets and path-build counters. Supported API limits
remain documented. No offline wall-clock benchmark is presented as gameplay FPS,
CPU utilization or long-session memory evidence; those need the client.

## 8. Verification results

Initial current-tree baseline: **17 suites, 759 assertions, 0 failures**.
The earlier reported 16/716 was stale. The old label suite printed no numeric
summary (42 assertions); Stage 6 now makes it explicit. Final result:
**17 suites, 765 assertions, 0 failures**, plus TOC metadata/order checks.
No existing navigation assertion was weakened or deleted by Stage 6.

| Suite | Assertions |
|---|---:|
| agitators | 32 |
| hybrid | 43 |
| icons | 25 |
| label | 42 |
| native_first | 55 |
| preview | 27 |
| progress | 36 |
| quest_transition | 44 |
| rebrand | 9 |
| service_context | 49 |
| services | 36 |
| settings | 79 |
| stage3 | 50 |
| stage4 | 65 |
| transitions | 102 |
| vuldren | 32 |
| windstones | 39 |

- Complete `node tests/run.js` passes, including all reliability, presentation,
  settings and transition-smoothing suites.
- luaparse 0.3.1 installed only in an OS temporary directory parses **26 Lua
  files as Lua 5.1**: eight runtime modules, harness and seventeen suites.
  Execution uses fengari (Lua 5.3 semantics); parsing separately covers syntax,
  not every possible Lua 5.1 runtime semantic difference.
- TOC interface/title/version/dependencies/SavedVariables/module order pass.
- All ten local BLP files checked; dependency quest-texture existence checked.
- All three Python maintenance tools compile; package tool executed successfully.
- `git diff --check` passes. Primary docs/runtime source decode as strict UTF-8.
- RC ZIP CRC, allowlist, hashes and current-source byte equality pass.
- Extracted RC loaded its eight actual modules from an OS temporary normal
  `RestedXPWaypoint` folder through the harness, and produced the owned vendor
  destination with a normal addon-relative Bags texture path.

Tests include real destination, quest ID, priority, ownership and writer-history
checks, not just counts. The older self-contained hybrid suite still has some
coarse call-count assertions, but F1–F8 and native-first suites provide stronger
observable-state checks. Its pre-existing instruction-label expectation change
is documented in the historical review; Stage 6 did not change that expectation.
Mocks simplify the client's simultaneous quest/user supertracking and rendering.
No test here proves visual continuity, real pathfinding, live Settings APIs,
launch-client compatibility or long-session memory/FPS behaviour.

## 9. Release-candidate package

Use the **latest** archive:

`.release/RestedXPWaypoint-0.6.1-RC-20261015T182031981850Z.zip`

Size: **146,508 bytes**. SHA-256:

`639066af0023d6ce77f033e99ad624a3e696c79a67986516aa7a2bde5b729ef9`

A sibling `.zip.sha256` is provided. An earlier intermediate candidate was kept
without overwriting it; use the timestamp above for current runtime/README bytes.
The archive does not include this development report or maintenance tools.

Exactly **21 entries** under the single `RestedXPWaypoint/` prefix:

- `RestedXPWaypoint_Camelot.toc` and the eight modules listed in section 2.
- `Art/Logo.blp` (128x128).
- `Art/Icons/{Bags,ClassTrainer,FlightMaster,FoodAndDrink,Grind,Innkeeper,ProfessionTrainer,Repair,StableMaster}.blp` (64x64 each).
- `README.md` and `RELEASE_MANIFEST.json` (hashes/lengths of the 20 source files).

No `.git`, tests, Node modules, Python/cache files, developer scripts, personal
SavedVariables, dependency addons or logs. The allowlist is explicit, not a
whole-checkout archive or `git archive HEAD` (which would omit required new work).
The package script exclusively creates uniquely named ZIPs, checks TOC metadata,
module order, runtime absolute paths and BLP format, then reopens and byte-checks
every entry. A separate verification compared manifest hashes and current source.
No runtime files are missing. The folder/TOC suffix and interface agree with the
installed Waypoint UI Forever TOC; RXPGuides' ordinary TOC also includes 16001.
The actual development junction points to this repository, but the extracted
smoke check did not rely on it. An actual clean client installation remains a
priority acceptance test; the development junction was not replaced.

## 10. Prioritized in-game acceptance matrix

All entries below are **pending developer execution**, not claimed test results.
Enable `/console scriptErrors 1`. Use `/rxpw debug` while diagnosing, then toggle
it off. Record version, strategy, quest/step, map/coordinates and any Lua error.
Do not remove or replace the development junction while WoW is running. Test an
extracted installation in a separate client/AddOns arrangement or after backing
up and deliberately managing that junction outside this audit.

| Priority / structure | Commands / action | Acceptance criterion |
|---|---|---|
| P0 installation | Fresh extracted RC, start client; `/rxpw status`, `/rxpw config` | Correct title, v0.6.1, all assets, one AddOns category, dependencies detected; no errors. |
| P0 dependencies | Disable each dependency separately, restart/reload and `/rxpw status` | Clear missing-dependency message, no sync/errors; page still opens. Re-enable and restart. |
| P0 persistence | Select settings, `/reload`; normal logout, exit and full restart | Settings/strategy persist; startup navigation follows documented ownership rules. |
| P0 coordinate route; multi-goto guide required | `/rxpw mode coordinates`, `/rxpw on`; follow A→B→C; `/rxpw status` | Actual RestedXP map and coordinates at every meaningful route point; one destination write per change. |
| P0 hybrid; travel + ready turn-in required | `/rxpw mode hybrid`; follow road/cave/intermediate points to NPC | Travel points kept, native only at eligible turn-in; after turn-in correct next destination. |
| P0 native objective; eligible `.complete` required | `/rxpw mode native-first`; `/rxpw inspect` | Correct quest, verified native target, no setters on ordinary progress/patrol cycling. |
| P0 same quest/new area; two objective clusters required | Remain native-first, progress/skip to next cluster; inspect debug verification | Reverification without repeated setter; wrong-area native target falls back to current RXP coordinates. |
| P0 manual override during delay | Select a manual map pin or another quest before native set/verify finishes | Selected destination survives; no stale fallback. `/rxpw off` keeps a longer pause; `/rxpw sync` explicitly resumes. |
| P0 cancellation | During delayed transition: `/rxpw off`, preview, skip guide step, zone/loading | No old setter or captured coordinates restored; correct current target on authorized resume. |
| P0 Mining Pick; matching Skyborne purchase required | `/rxpw mode coordinates`; at 2521,42.76,24.50 `/rxpw status` | Vendor/Bags, Merchant Blue, Buy a Mining Pick; second purchase keeps Vendor; no trainer icon from condition. |
| P0 mixed step; separate acceptance/vendor without structured parent required | At later vendor, `/rxpw status` and `/rxpw inspect` | Vendor label, actual coordinates and Bags/blue; earlier pending accept cannot lend `!`. Repeat strategies if possible. |
| P0 rapid accept/turn-in; advancing guide required | Accept/turn in while debug on; compare external/bridge timestamps | Final intended route, no added intermediate bridge write. External native flash may remain. |
| P1 shared parents; guide fixture required | Follow consecutive parent-linked waypoints in hybrid/native-first | Association stays correct, no unexplained mode fallback; explicit travel remains coordinates. |
| P1 active steps; sticky/patrol guide required | Manually tick/skip a served instruction without moving arrow | Within observer/coalescing delay, current relevant quest/work changes correctly; no stale quest. |
| P1 stale/absent target | Finish step or guide with no valid target | Existing navigation remains; status reports reason; never restores an old point. |
| P1 quest states | Preview available/incomplete/complete; then actual accept/objective/turn-in steps | Correct quest icon/colour at real coordinates, live progress and ready transition. Preview alone is not classification proof. |
| P1 services; real service steps required | `/rxpw preview all close`, `/rxpw preview all far`, `/rxpw preview off`; visit each service | Flight/class/profession/food/repair/inn/stable/vendor/banker/grind plus generic look correct; unrelated actions do not override. |
| P1 progress/pathfinding; provider required for on case | Rapid objective updates with WUI pathfinding off, then on | Latest label eventually shown; presentation updates at least 2 s apart; marker/path reset limitation acceptable. Routes stay correct. |
| P1 preview recovery | `/rxpw preview vendor`, `/reload`; repeat with auto-sync off; `/rxpw preview off` | Orphan removed on automatic start or explicit off; manual/foreign marker untouched; sync resumes only as configured. |
| P1 settings/slash synchronization | Open `/rxpw config`; change page strategy/on/debug, then `/rxpw mode hybrid`, `/rxpw off`, `/rxpw debug` | One page, controls/chat match both directions, repeated open does not duplicate UI. |
| P1 appearance | Toggle quest icons, service icons and custom colours individually on real steps | Only owned coordinate presentation changes; manual/native destination preserved; values survive restart. |
| P1 arrow mirror | Toggle Hide RestedXP Arrow; inspect RestedXP's option and toggle there, reopen page | Both options match; synchronization continues while RXP arrow hidden. |
| P1 reset/defaults | Confirm/cancel Restore Defaults; test with manual pin, then owned native destination | Cancel changes nothing; confirm restores only own settings, may resume/change own navigation, keeps manual pin and external arrow option. |
| P1 UI/actions | All preview buttons, Status, Inspect, Open WUI Settings; small/large UI scale; combat open attempt | No clipping/overlap or off-screen dropdown; scroll wheel/thumb work; no duplicate rendering settings; combat message. |
| P2 sustained play | Idle, normal questing, rapid quest-log events, zoning and long play session | No unchanged-destination write loop, error/chat flood or visible sustained overhead; monitor actual client performance/memory. |

Specific quest/guide structures are required where marked; if unavailable, record
“not exercised” and retain native-first's experimental status rather than treating
preview screenshots or offline fixtures as in-game coverage. Restore preferred
mode and `/rxpw on` afterward. Turn off debug once evidence is captured.

## 11. Final recommendation

Proceed with the local 0.6.1 RC after reviewing/approving the checkpoint scope.
There is **no currently reproduced unresolved code blocker** after the focused
presentation fix. The required v1.0 gates are the complete source checkpoint and
final in-game acceptance, especially post-v0.6.0 changes and a normal extracted
installation. Visual imperfections and public-API rendering limitations do not
by themselves justify rewriting the controller or blocking RC testing.

## 12. Final Git status

No commits, tags or index changes were made. The following output includes the
entire accumulated working tree, not only this audit's edits. `M` files predate
Stage 6 except the lockfile metadata correction; Stage 6 also edited existing
modified/untracked files as described above. Ignored caches, snapshots and RC
artifacts are intentionally absent from the ordinary list.

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
 M tests/package-lock.json
 M tests/package.json
 M tests/run.js
 M tests/vuldren_test.lua
 M tests/windstones_test.lua
?? Art/Icons/Bags.blp
?? Art/Icons/ClassTrainer.blp
?? Art/Icons/FlightMaster.blp
?? Art/Icons/FoodAndDrink.blp
?? Art/Icons/Grind.blp
?? Art/Icons/Innkeeper.blp
?? Art/Icons/ProfessionTrainer.blp
?? Art/Icons/Repair.blp
?? Art/Icons/StableMaster.blp
?? Art/Logo.blp
?? Preview.lua
?? RestedXPWaypoint_Camelot.toc
?? SettingsPanel.lua
?? docs/QUEST_TRANSITIONS.md
?? docs/RELIABILITY_F1_F3.md
?? docs/REVIEW_HANDOFF.md
?? docs/STAGE3_F4_F6.md
?? docs/STAGE4_F7_F8_PREVIEW.md
?? docs/STAGE5_SETTINGS_UI.md
?? docs/STAGE6_RELEASE_READINESS.md
?? docs/V0_6_1_SERVICE_CONTEXT.md
?? tests/icons_test.lua
?? tests/preview_test.lua
?? tests/progress_test.lua
?? tests/quest_transition_test.lua
?? tests/rebrand_test.lua
?? tests/service_context_test.lua
?? tests/services_test.lua
?? tests/settings_test.lua
?? tests/stage3_test.lua
?? tests/stage4_test.lua
?? tests/transitions_test.lua
?? tools/Migrate-Install.ps1
?? tools/build_icons.py
?? tools/build_logo.py
?? tools/logo_source.png
?? tools/package_release.py
```
