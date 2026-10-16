# Stale markers and quest setter attribution

## Step 100 -> 110 diagnosis

The logs prove that RXP advanced, the resolver found the current coordinates,
and quest supertracking blocked automatic writes. They do not prove who selected
92553 or 94411. Guide association and recent acceptance cannot establish intent.

WUI stores one `sessionData.userNavigation` independently of active native
tracking. Selecting a quest changes tracking priority without removing that
stored session. Sync's override gate returned before any marker retirement;
its invalid-target path also deliberately kept navigation. Consequently the
Step 100 acceptance marker could survive through Step 110 despite no longer
being followed. The resolver and stale-write rejection were working.

The existing checkout already retained acceptance + guide associations beyond
the original transition window. That avoids some re-supertracking freezes, but
cannot distinguish a manual selection of the same accepted quest. Another
one-second exemption or guide-quest whitelist cannot safely fix that ambiguity.
The marker leak and attribution problem are independent: either an automatic
or a genuine manual selection can expose the leak by blocking synchronization.

## Safe public cleanup, verified against installed WUI 1.7.3

- `API.lua` exports `ClearUserNavigation(preserveWaypoint, suppressAdvance)`.
- `Code/MapPin/MapPin.lua:592` clears/saves the stored session and dispatches
  `MapPin.UserNavigationCleared`. With `preserveWaypoint=true` it never invokes
  `ClearUserWaypoint`, so no native removal event or tracking-clear cascade is
  initiated. `suppressAdvance=true` prevents multi-pin advancement.
- `Code/Navigation/Navigation_DataProvider.lua:202` also honors that fourth
  callback argument and skips destination/path clearing.
- `Code/MapPinFrame/MapPinFrame.lua` refreshes marker frames on that callback.

The adapter requires the public flag check, the same stored session, and an
inactive bridge marker immediately before `ClearUserNavigation(true, true)`.
Obsolescence means a different fresh valid RXP destination, or a previously
recorded element proven skipped/inactive/reassigned to another step. Missing or
hidden arrow data alone is insufficient. Foreign markers are never retired.
Synchronous callbacks are observed after cleanup; cleanup never grants sync
permission. Generation invalidation prevents pending work recreating that marker.
Normal unblocked coordinate replacement and eligible native transitions keep
their existing pipeline. Hybrid's eligibility and route selection are unchanged.

This retires WUI's stored marker, **not the native map pin**. The untracked native
waypoint may remain on the map until normal replacement/removal. Preserving it
avoids deleting a replacement Blizzard pin or clearing external tracking; no
private WUI storage, ClearDestination, artificial navigation or restore-quest
workaround is used. Client rendering must be checked in game.

## Attribution with evidence

A guarded `hooksecurefunc` post-hook observes the native quest setter, without
replacing any function. Only the immediate Lua source can supply RXP attribution:
the installed `RXPGuides/functions.lua` and `RXPGuides/GuideWindow.lua` contain
the verified turn-in/objective/step-track setters. A deeper RXP stack frame does
not count. Active RXP work must also associate that quest before recognition.
The bridge's own setters are excluded. Direct RXP calls can be recognized before
or after QUEST_ACCEPTED, after settling, and on later objective log updates.

The current recognized selection survives coordinate writes and later travel
steps, without repeated writes at unchanged coordinates. An observed unknown
setter revokes it, including a manual selection of that exact guide quest.
External replacement, observed full idle clearance and session reset also revoke
it. Protected manual/unproven selections remain protected against later RXP
reassertions. The one-second idle resume uses fresh current target data.

Unknown does not mean proven manual. Blizzard-internal automatic choices may
have no recognizable Lua setter caller, and remain protected. Hook/stack absence,
errors, truncated/unrecognized paths and missing events cannot be turned into
proof of automation. Same-ID changes with neither an observable setter nor a
state change remain indistinguishable. Startup's inherited unknown baseline
policy remains, but a later observed unknown setter supersedes that baseline.

Debug/status distinguish stored inactive markers, active ownership, retirement
outcome, last setter evidence, blocked target and delayed resumption. Repeated
identical attribution/cleanup messages are deduplicated.

## Verification

`tests/stale_marker_test.lua` models Steps 100, 102, 103, 106 and 110, inactive
arrow snapshots, separate native pins/quest tracking, pathfinding mode, late RXP
reassertions, same-quest manual selections, unknown Blizzard selections,
synchronous cleanup events/pin/quest replacement, missing APIs and stack formats.
Existing transition, manual-resume, quest progression, startup, sound and
presentation suites run alongside it. Earlier tests that required obsolete
inactive sessions to remain stored now permit retirement while requiring the
external destination to remain unchanged. Earlier acceptance inference fixtures
now provide explicit RXP caller evidence instead of claiming Blizzard intent.

In game with Lua errors and debug enabled:

1. In Hybrid accept Restocking the Larders and advance through Step 110. Check
   `0/6 High Order Apprentice defeated` at map 2521, 46.13,39.79, coordinates.
2. Observe setter attribution on RXP objective/turn-in processing well after
   acceptance. It should recognize RXP without fighting at unchanged coordinates.
   If attribution remains unknown, retain the log; do not assume Blizzard intent.
3. Manually select that same guide quest, a different quest, a WUI pin and a raw
   Blizzard pin. Advance RXP; active external tracking must remain untouched.
   Check that the obsolete WUI marker retires; an untracked native map pin may
   remain by design. Clear external tracking and verify one delayed, quiet
   restoration of the latest RXP destination.
4. Repeat coordinate -> native turn-in -> coordinate route, rapid progression,
   reload, preview, sync-off and zoning during pending work. Check pathfinding
   with a provider if available. No arrival sounds or cleanup-induced intro
   should play; the normal single resumed WUI intro retains its existing behavior.

No addon dependencies, icon assets, elevation behavior or Innkeeper
classification were changed. No commit or push was made.

Offline result for this handoff: all 24 suites passed on the final full run,
1,238 checks, including 39 in the new stale-marker suite. The nine focused
synchronization/attribution/native-transition/audio suites also passed, 655
checks. An intermediate full run encountered presentation expectation failures
while concurrent quest-icon work was in progress; the final run passed after
that work updated its expectations. Those unrelated assets/expectations were
not changed as part of this fix. `git diff --check` passed.
