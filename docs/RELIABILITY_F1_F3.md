# v0.5.7: pending native-transition reliability

This change fixes F1–F3 from the independent review of the v0.5.6 working tree.
It preserves the existing uncommitted presentation, service-icon and preview
work. No commit or tag is part of this change. F4–F8 remain outside its scope.

## Root causes

- **F1:** `Sync.Stop` stopped the poller but did not invalidate pending native
  callbacks. Those callbacks checked only the transition generation. A queued
  quest evaluation could also run in a newly restarted automatic session.
- **F2:** `Evaluate` checked for a foreign waypoint, but delayed `SetQuest`,
  `Verify` and `FailNative` bypassed that check. A newly selected pin or quest
  could be replaced by the old setter or by coordinate fallback.
- **F3:** `FailNative` substituted its captured target when `RXP.GetTarget`
  reported invalid/missing current data. This could restore a reached or
  irrelevant destination. Pending callbacks did not recheck target/activity
  identity before acting.

## Implementation

`Sync.lua` retains its existing generation system. A pending native operation
now also records its automatic/manual origin, strategy, RXP element/key/step
identity and observable navigation snapshot.

One shared gate runs before setting the native quest, verifying it and handling
failure. It checks that:

1. The operation still matches the pending operation and generation.
2. Its origin is still permitted, preview is inactive and the player is not
   between leaving and entering the world.
3. Navigation still matches the operation's expected snapshot.
4. A freshly validated RXP target still matches its original identity.
5. A fresh navigation decision still selects the same native activity.

Snapshots include the supertracked quest and priority, Waypoint UI session
identity, and the native user waypoint where that optional API is available.
They are compared by value because external session tables can mutate in place.
The small read-only wrappers remain in `NavigationResolver.lua` and
`WaypointAdapter.lua`; Sync does not read RXP fields or call supertracking APIs
directly.

The expected asynchronous disappearance of a cleared bridge waypoint is
allowed. A replacement pin, quest or other priority is not treated as that
clear. Reactions from another addon during the setter are also checked before
adopting the resulting state.

Cancellation changes bookkeeping only. It neither clears navigation nor
releases a quest. An external selection holds the interrupted destination or
native identity so quest events do not immediately reclaim it. A genuinely
new destination follows the normal synchronization rules; explicit `/rxpw sync`
and a new synchronization session can request control again.

`Stop` cancels pending **automatic** native work and invalidates queued automatic
quest evaluations. Explicit manual sync remains functional while automatic
sync is disabled, including its authorized fallback. Preview supersedes pending
work from either origin. Leaving/entering the world invalidates pending work;
automatic evaluation is suspended between those events.

`FailNative` never substitutes captured coordinates. For a changed valid target,
the old operation retires and normal evaluation handles the new target. Invalid
current data leaves the displayed destination untouched, even if a quest was
already set before the data became invalid. The bridge does not reassert or
claim that abandoned native session.

## Regression evidence

`tests/transitions_test.lua` adds **102 deterministic assertions**, including
positive controls. Checks use final navigation state, quest identity, actual
native user-waypoint coordinates, pending/active status and navigation writer
history. Setter offsets include 0.01, 0.08, 0.24, 0.26 and 0.84 seconds relative
to the scheduled transition, covering both sides of the 0.25-second setter and
the 0.85-second verification boundary.

| Finding | Reproduction | Corrected result |
|---|---|---|
| F1 | Stop before SetQuest or after setting but before verification | No subsequent automatic setter, fallback or navigation release |
| F1 | Stop/restart with queued callbacks or quest evaluation | Old work cannot execute in the new session; current work succeeds |
| F1 | Manual `/sync` while off, including another `/off` | Explicit operation and valid fallback remain functional |
| F1/F2 | Preview begins before setting or verification | Preview stays tracked and its independent cycle continues |
| F2 | Player pin, player quest or RestedXP quest selected during either delay | External destination survives; no coordinate fallback or reclaim |
| F2 | Raw map pin replaces a stale stored WUI session; external event omitted | Observable state change is still detected at the callback |
| F2 | Another addon reacts synchronously to clearing or setting | Its replacement is preserved rather than adopted as bridge ownership |
| F2 | New explicit native operation supersedes an old operation | Only the current quest is set; old callback cannot restore its quest |
| F3 | Arrow missing, step inactive, waypoint skipped/hidden, map/coordinates unavailable or unsupported | No write from stale work; no captured-coordinate fallback |
| F3 | New travel point, quest activity or same-arrow quest mutation | Old work retires; normal evaluation handles current activity |
| F3 | Leaving/entering the world while pending | No old delayed write during loading; current destination resumes afterward |
| Control | Valid native target, missing native POI, or native setter error | Native success and authorized coordinate fallback still work |

The shared harness now supports independent tickers and cancellation, FIFO
equal-time callbacks, navigation events, native waypoint coordinate matching,
and player/addon/bridge writer history. Its delayed removed-waypoint handler
rechecks current state before clearing, matching the installed WUI handler's
conditions rather than unconditionally clearing a newer destination.

The new suite was also run **in memory against the pre-change working-tree
`Sync.lua`**, with the strengthened harness and current adapter wrappers. It
reported **30 passed / 72 failed**. The original file was not restored over the
working tree and no existing expectations were relaxed.

Final offline validation:

| Suite | Passing assertions |
|---|---:|
| agitators | 32 |
| hybrid | 43 |
| icons | 25 |
| label | 42 |
| native_first | 54 |
| preview | 27 |
| progress | 36 |
| services | 36 |
| transitions | 102 |
| vuldren | 32 |
| windstones | 39 |
| **Total** | **468** |

- All 11 suites pass via `node tests/run.js`.
- Lua 5.1 parsing passes for all seven TOC modules and all 12 test/harness files,
  using `luaparse` installed outside the repository.
- TOC module order is unchanged; no module, SavedVariables field or dependency
  was added. Existing coordinate decisions, resolver rules, labels, icons and
  colors were not changed by this task.

## Limits and outstanding risks

These are offline results, not in-game verification. Mocks still simplify
supertracking and do not implement Waypoint UI pathfinding or rendering.
Snapshots conservatively abandon a transition on unexpected observable state;
real WUI event ordering and pathfinding should be checked in the client.

Public state/events do not identify the writer of a no-op re-selection of the
exact same quest and unchanged navigation. The bridge does not infer exclusive
ownership from that quest ID; it requires the live operation and the whole
observable snapshot to remain consistent. An observed override remains
cancelled even if an external writer later returns to the expected quest ID.

The review's label-update recovery, resolver association, served-step observation
and completed-native area-verification issues (F4–F8) are not fixed here. They
do not block the focused transition protections, but remain separate work.

## In-game acceptance before committing

Enable Lua errors (`/console scriptErrors 1`) and `/rxpw debug`.

1. In coordinates mode, confirm normal A → B → C mirroring, labels, progress,
   silver quest icon and service colors. Set a manual waypoint and confirm the
   existing override behavior.
2. At a ready turn-in, switch to hybrid/native-first and immediately run
   `/rxpw off`. Wait several seconds: no later quest switch or fallback should
   occur. Repeat after the native marker first appears. The pre-stop displayed
   destination should not be cleared by Stop itself.
3. Repeat a native transition and immediately select your own WUI pin or another
   quest. It must remain selected without a bridge fallback/reclaim on quest
   updates. Try both just before and just after the native marker appears.
4. Start `/rxpw preview all far` during a transition. The preview must stay
   tracked and cycle. `preview off` must resume the current RXP destination.
5. During a transition, advance/skip the RXP step or zone. There must be no old
   coordinate restoration; synchronization should follow the current valid
   route after settling/loading.
6. With auto-sync off, run `/rxpw sync` on a ready turn-in and an objective in
   native-first. Confirm success; on an activity with no usable native marker,
   confirm a normal coordinate fallback. Turn auto-sync on again.
7. Repeat the native/manual/preview cases with WUI pathfinding enabled and
   disabled. Check `/rxpw status` and `inspect` for Lua errors and stuck pending
   operations. Normal repeated progress should not trigger extra navigation
   writes.

The narrow delay windows can take several attempts by hand; the deterministic
offline regressions exercise them directly. `/reload` picks up these Lua changes
when the existing modules are loaded; the TOC now reports v0.5.7.
