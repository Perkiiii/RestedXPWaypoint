# Quest transition smoothing (after v0.6.1)

## Source findings

Checked the installed RXPGuides v4.11.23 and Waypoint UI 1.7.3 without editing
either addon. The supplied log reports an external native quest selection,
followed by one bridge coordinate write. It does not establish that the bridge
created an intermediate destination or identify the external setter's caller.

- `RXPGuides/functions.lua`, `accept` (1153 onwards), marks the accepted
  instruction complete and updates step state; it does **not** call
  `SetSuperTrackedQuestID`. The older AGENTS.md integration notes attributing
  line 1511 to `.accept` are inaccurate for the currently installed file.
  Line 1511 belongs to `.turnin` initialization. `.complete` initialization
  explicitly sets quest supertracking at line 1850. `GuideWindow.lua` line 790
  also sets it for a step's explicit `track` directive.
- `Guides/forever/RestedXP-Skyborne.lua` lines 738–774 accept quest 92473,
  process several conditional helper steps, then lead to a `#loop` beginning at
  map 2521, 41.05, 25.70. Its objective is `.complete 92473,1`. Guide advancement
  and objective initialization can therefore precede the bridge observing the
  resolved arrow. This is a source-supported explanation, not a captured live
  call trace for the reported session.
- `WaypointUI/Code/Waypoint/Waypoint_Director.lua` handles
  `SUPER_TRACKING_CHANGED` independently. A new target triggers
  `OnSuperTrackingChange` and `AwaitDistance`. Its distance-ready refresh waits
  at least 0.075 s, then uses a positive `C_Navigation.GetDistance()` value.
  Quest acceptance/log events also request a distance refresh. It can render a
  native quest target before RestedXP Waypoint writes anything.
- The bridge polls the resolved arrow every 0.25 s and normally requires
  0.2 s of observed stability. Previously a separate quest callback after
  0.5 s could evaluate a changed target without respecting that quiet period.
  This could add intermediate **bridge** writes to an external transition.

The client implementation of Blizzard/Forever acceptance auto-supertracking
is not available in this checkout. Automatic Blizzard selection remains a
possible contributor, but it cannot be distinguished from another addon's
setter using `SUPER_TRACKING_CHANGED` or the supplied log. No claim is made
that Blizzard alone caused this particular flash. RestedXP's explicit setters
and Waypoint UI's independent rendering are verified in the installed source.

## Behaviour

The existing coalesced scheduler is shared with target settling:

1. Acceptance/turn-in requests evaluation after **300 ms**, rather than the
   general quest-event delay of 500 ms. Other quest/activity events retain
   their existing delay.
2. Automatic target/quest evaluations compare the current raw arrow fields
   again. If they changed, the existing **200 ms** quiet period applies. A quest
   callback cannot bypass it between polls. No target is captured for replay.
3. A continuing acceptance/turn-in burst is bounded at **one second** from its
   first event. Repeated events do not extend that deadline. At the deadline,
   the current validated target may be evaluated without further quiet time.
   This bounds the smoothing wait, not native verification or recovery when
   RestedXP has no valid destination.
4. Earlier route/quest deadlines can supersede a later presentation timer;
   superseded callbacks are inert. There is still one effective queued
   evaluation. Poll frequency is unchanged and there is no new ticker.
5. A user waypoint selected during this quest wait holds the destination
   resolved at its end; a later genuine route key resumes normal syncing.
   Raw native user pins are included. Preview, Stop and world transitions
   invalidate deferred state. Manual sync bypasses it. Navigation events still
   never write, and external native quest changes are never forcefully reclaimed
   at an unchanged handled coordinate key.
6. If the final eligible native quest is already active, the bridge keeps it
   and verifies through the existing fresh-data/ownership gate. It neither
   clears an inactive bridge session nor re-sets the quest. Verification
   failures still fall back, and external overrides cancel verification.
   This also avoids a redundant setter on objective-to-turn-in transitions
   for the same active native quest. Manual sync retains its explicit setter.

This introduces no extra quiet period for ordinary route changes: the same
200 ms/poll behaviour applies. Stable destinations produce no extra writes.
Route-critical decisions, native eligibility, coordinates, labels, appearance
settings, preview ownership, F1–F8 and presentation/pathfinding throttling retain
their existing logic. Already-appropriate native markers stay visible throughout
their normal 600 ms verification wait.

## Diagnostics and public API limit

With `/rxpw debug`, quest transition, bridge coordinate-write and native-setter
messages include `GetTime()` timestamps. Outside-navigation messages identify
the observation time and explicitly say no bridge write occurred. Native reuse
is logged as verification without a navigation write. No setter hooks or
rendering modifications were added.

Waypoint UI's public API has no way to defer only an externally selected quest
marker. Suppressing that first flash would require fighting supertracking or
touching private rendering; neither is done. A purely external native-to-RXP
transition can therefore remain visible. This change prevents additional bridge
destinations and redundant native resets, and requests a quiet final target
sooner where possible. In-game observation is still required.

## Regression evidence

`tests/quest_transition_test.lua` uses realistic draw-time completion flags,
route chains, eligible turn-ins/objectives and writer-tagged operation history.
The initial tests against the pre-change working files produced 10 failures:
intermediate bridge writes in all three strategies, a quest-timer race,
redundant native resets and deferred work overwriting manual/raw pins.

Deterministic timing results (not visual measurements):

| Scenario | Before | After |
| --- | --- | --- |
| Rapid changes at 0.26/0.36/0.46/0.56 s, all three strategies | 2 bridge writes, 1 intermediate at 0.50 s | 1 write, 0 intermediate, final at 0.90 s |
| Same burst ending in already-active eligible native turn-in | 1 bridge quest setter and inactive-session clear | 0 coordinate writes, 0 setters, no clear; verified at 1.30 s |
| New destination stable after 0.10 s | existing poll/event behaviour | applied within 0.52 s of acceptance |
| Ordinary route change | existing 0.25 s poll plus quiet period | unchanged; fixture applies within 0.50 s |

Coverage also includes repeated events, continuous changes/deadline, newer guide
activity, genuine sequential route points, native objective adoption, failed
native verification, manual selections during verification, previews, auto-sync
off, loading, explicit sync, turn-in and quest-log event races.

## In-game verification

1. Enable `/rxpw debug`, accept Aggressive Encroachment, and follow the route.
   Compare `Quest transition`, `Outside navigation change` and `Bridge ... write`
   timestamps. Confirm the final map/coordinates match RestedXP and every
   meaningful route point is followed. An external flash may still occur.
2. Repeat on a stable acceptance step and a turn-in. In native-first, check an
   eligible objective; in hybrid, check an eligible turn-in. An already-active
   correct native marker should report reuse without a bridge native setter.
3. During advancement select a manual waypoint, start a preview, or turn sync
   off. Confirm delayed work does not replace it. `/rxpw sync` should act
   immediately. `/reload` should load cleanly.
4. Check ordinary waypoint changes, quest progress labels, services and the
   appearance toggles. Existing presentation rate limiting must still apply.
