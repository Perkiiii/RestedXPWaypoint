# Temporary external navigation overrides

An actively tracked external waypoint or a different supertracked quest pauses
automatic bridge writes, including when RestedXP advances. Once navigation is
confirmed idle, Sync starts a **one-second resume delay** (`RESUME_DELAY`). It
does not create a RestedXP marker during that delay. Delayed waypoint removal
cleanup must finish first; the old 0.3-second diagnostic delay remains separate.

Every navigation event resets the idle deadline. A replacement waypoint, quest
or other active tracking type blocks restoration, and its later clearance starts
a new full delay. Polling also observes changes when an event is omitted. At the
deadline, Sync rechecks ownership and tracking, reads the latest valid RestedXP
target, and uses the selected strategy through the existing pipeline. It never
restores cached coordinates, labels, icons or quest IDs.

The override is session-only and must have been observed while automatic sync
was running. Clearing a bridge-owned waypoint alone does not resume navigation.
Stop and preview discard the override; loading preserves it but invalidates
callbacks and requires fresh observation after entry. Invalid RestedXP targets
leave navigation untouched. Native cancellation and failure policies still apply.

## Login and reload

An inherited quest has no observed selection history. With auto-sync enabled at
login, the first active quest observed before the initial valid RestedXP target
is treated as an **unclassified startup baseline**, not a manual override and not
an automatically owned guide quest. RestedXP may start synchronization regardless
of whether that quest matches the vendor/travel waypoint or active guide work.
Only one quest identity can be inherited; a different quest or an external pin
closes acquisition immediately. The first valid RXP target also closes it. This
is an observation phase, with no timeout or grace-period authorization.

That baseline identity can remain selected or be reasserted while RXP advances,
without latching an override or causing unchanged-destination rewrites. A new
different quest/pin revokes the baseline and is protected normally. Observed full
idle clearance also revokes it, so clearing and reselecting the same quest is a
new selection. Coordinate writes do not revoke it just because they take tracking
priority. Observed RXP setter attribution replaces the baseline when available.

Existing Waypoint UI destinations and raw Blizzard user waypoints remain
protected at startup. `/rxpw off` and preview shutdown clear startup acquisition;
`/rxpw on`, preview exit and ordinary zoning never reopen it. Starting with
auto-sync disabled does not acquire a baseline when sync is enabled later.

A quest deliberately selected **before** login/reload is indistinguishable from
an automatically inherited quest. Under this deterministic policy it may be
replaced by RXP; selecting another quest during the session is protected. A
reselection of the exact inherited quest without an observed clearance/change
cannot be identified reliably. See `STARTUP_TRACKING.md` for the Step 84 diagnosis.

The bridge's current/pending native quest is not an external selection. Sync also
remembers the last quest it set or adopted until external navigation supersedes
it or coordinates are applied. This preserves ownership when verification is
cancelled by a new RestedXP activity or a loading screen after the setter ran.
Clearing that native quest alone does not grant permission to resume.

`SUPER_TRACKING_CHANGED` and the tracking getters do not identify the caller.
A non-destructive secure post-hook now observes `SetSuperTrackedQuestID` and
examines only the immediate Lua caller. A direct call from the installed RXP
`functions.lua` or `GuideWindow.lua`, plus active guide association, recognizes
RXP tracking. It survives subsequent coordinate writes and RXP reassertions;
it does not expire on an acceptance timer. Acceptance, quest IDs and guide
membership alone never authorize synchronization. An unknown setter protects
that selection, even for a previously recognized guide quest. A protected
external selection also wins over subsequent RXP calls. A replacement external
pin/quest, observed idle clearance, or session reset revokes the association.

Blizzard-internal automatic selection may provide no recognizable Lua caller;
it remains protected instead of being inferred automatic from acceptance timing.
Same-quest changes without an observable setter or intervening state remain
ambiguous. An inherited startup baseline keeps its existing policy, but a later
observed unknown setter supersedes it. Missing stack/hook support fails closed.
See [STALE_MARKER_LIFECYCLE.md](STALE_MARKER_LIFECYCLE.md) for evidence and limits.

Inactive bridge markers can be retired independently from active navigation.
With positive flag ownership, a provably obsolete stored destination is cleared
using `ClearUserNavigation(true, true)`. This preserves the native map waypoint,
current quest, and queue/path state. The native waypoint may remain as an
untracked map pin; deleting it is not necessary for retiring WUI's stored marker.
Cleanup never authorizes resumption or creates a replacement destination.

`WaypointAdapter.GetForeignNavigationName` also recognizes raw tracked Blizzard
user waypoints, including replacements of an old WUI bridge session. Installed
Waypoint UI 1.7.3 converts supported guard directions into a navigation flagged
`GuidePin`; these use the same external-navigation path. Untracked gossip map
POIs are not treated as active navigation.

`node tests/run.js` includes `manual_resume_test.lua`: clearance, arrival without
events, raw pins, GuidePin/foreign flags, replacement pins, fresh route/native
decisions, native cancellation and fallback, lifecycle guards, own-pin clearance,
pathfinding counters, silence and duplicate-write protection. It also checks the
one-second deadline, external quest clearance and switching, waypoint/quest
transitions, replacements just before the deadline, delayed cleanup, bridge-owned
native quests and loading/session invalidation. Existing tests explicitly clear
external navigation before expecting the next RestedXP destination.

`quest_progression_test.lua` reproduces the Al'Aketh Thugs incident: acceptance,
later `.complete` supertracking, an explicit travel point, completed objectives,
then a quest-free patrol. It also checks synchronous selections during coordinate
writes, retained manual overrides, same-coordinate instruction changes, reused
step tables and native holds. See `docs/QUEST_PROGRESSION_SYNC.md` for the diagnosis.
`startup_tracking_test.lua` covers inherited quest state, Step 84's simultaneous
hidden turn-in/collection/vendor work, unrelated quest IDs, reload tradeoffs,
new manual selections, delayed initial targets/attribution, synchronous setters,
disabled sync and stale callbacks through previews/loading/shutdown.

## In-game acceptance

1. With auto-sync enabled, ask a city guard for directions and accept Waypoint
   UI's replacement prompt if shown. Clear the directions without advancing
   RestedXP: the screen should stay idle for one second after tracking cleanup,
   then its current destination should return once. Repeat by arriving.
2. Replace manual pin A with B, and advance RestedXP while B is active. B must
   remain active; clearing B should resume the latest RestedXP destination.
3. Repeat with a raw Blizzard map waypoint. Select another quest in the quest
   log: it must retain priority even if RestedXP advances. Deselect its navigation
   and verify one delayed resume. Switch quest A to quest B and switch between
   quests and manual pins; there must be no intermediate RestedXP marker.
4. During the one-second idle interval, select another pin or quest, change the
   RestedXP destination, disable sync, open a preview or zone. A stale callback
   must never reclaim navigation. Clear the bridge's own pin/native quest
   directly: it must stay cleared without a preceding external override.
5. Repeat in coordinates, hybrid and native-first, including eligible turn-ins
   and objectives, a native verification failure, auto-sync off, preview mode
   and zoning during clearance. Enable Lua errors and inspect `/rxpw status`.
6. Check with Waypoint UI pathfinding enabled if a provider is available. There
   should be one resumed navigation, without recurring marker resets or paths.

Mocks cannot prove Forever event ordering, quest-log deselection or automatic
arrival cleanup. Verify the guide-driven quest inference during acceptance and
turn-in in game, including combat progress well after acceptance and quest-free
grind/patrol steps. Native verification can finish after the one-second deadline;
the deadline controls when the transition is allowed to start. Resume
suppresses the documented new-navigation sound. Waypoint UI's marker intro can
still play its own sound on the single necessary navigation creation; the public
API has no per-write control for that sound. Dependencies are unchanged.
