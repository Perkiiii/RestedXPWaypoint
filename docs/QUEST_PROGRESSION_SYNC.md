# Quest progression blocked by tracking attribution

## Diagnosis

The reported Step 74 → 77 freeze is reproduced offline with the current override
code. RestedXP's arrow and the bridge's target reader still have the fresh Step 77
destination. `ObserveManualOverride` instead treats quest 92544 as external and
`Evaluate` returns at that gate before deciding or applying the destination.

The old guide-quest exception lasts only through the acceptance/turn-in settle
window and requires a matching current decision/presentation. Clearing that
temporary override forgets the attribution. Coordinate success also clears
native `ownedQuest` bookkeeping, which does not represent automatic guide quests.
Later supertracking of the same quest therefore creates an ordinary override
that waits indefinitely for tracking to end. The installed RXPGuides 4.11.23
`functions.lua` `.complete` handler (around line 1850) sets the quest ID again
on quest-log processing. This is a concrete source of later automatic tracking,
independent of whether Blizzard initially selected the accepted quest.

The actual Skyborne guide includes the reported upper-temple travel point,
`.complete 92544` work, then a hidden `#loop` patrol serving `Grind6`. Quest-free
patrol/grind steps cannot satisfy the old quest-context exception.

Two apparent inconsistencies follow from that same flow:

- `NoteStep` used to run after the override gate. No Step 74 → 77 message means
  evaluation was blocked, not that the poller necessarily missed the new target.
- Public navigation setters can dispatch synchronous events. An event inside a
  coordinate write could re-arm the override; then `RecordSuccess` logged success
  and cleared the outside description without clearing the override. Temporary
  reactivation of the bridge waypoint could consume an override, permitting a
  later write, before another automatic quest update armed it again.

The supplied log cannot identify the initial setter's caller or prove every
intermediate event ordering. The regression tests demonstrate both the lasting
block and the reentrant-write path without requiring those missing live events.

## Focused changes

- `Sync.lua` retains accepted quest IDs and recognizes guide tracking only with
  matching active RestedXP work. Recognition survives later guide steps and
  coordinate writes. Existing manual overrides still take priority. Positive
  guide attribution also removes a stale native transition hold.
- Coordinate writes defer their own event observation until the setter returns,
  then classify the final navigation. A genuine external selection inside that
  call is protected and logged as a takeover, rather than an unqualified success.
- Current step observation happens before the override gate. Block logs are
  deduplicated per step/destination, and the one-second idle/resume delay remains.
- `RXPAdapter.HasTargetChanged` also compares `step.index`, so in-place reuse of
  step/waypoint tables is observed by the existing cheap poller. The once-second
  activity and label checks remain responsible for same-coordinate progress.
- `NavigationResolver.HasActiveQuest` is attribution-only, with validated reads
  confined to the RestedXP-facing resolver. Navigation strategy rules are unchanged.
- `/rxpw status` distinguishes inferred automatic guide tracking from a real
  override or pending resume and removes the obsolete “next destination” promise.

No RestedXP/Waypoint UI function is hooked or replaced. Dependencies are unchanged.
New unknown quest selections during a session still suspend synchronization;
inherited login/reload tracking now follows the policy in `STARTUP_TRACKING.md`.
The public
[supertracking declarations](https://github.com/Gethe/wow-ui-source/blob/live/Interface/AddOns/Blizzard_APIDocumentationGenerated/SuperTrackManagerDocumentation.lua)
provide no caller/intent argument for `SUPER_TRACKING_CHANGED`; upstream source
is evidence about that API shape, not proof of every Forever implementation detail.
Same-quest intent and pre-reload attribution limits are documented in
`MANUAL_WAYPOINT_RESUME.md`.

## In-game verification

1. In hybrid, accept Al'Aketh Thugs, follow the temple points, finish its
   objectives, then enter the Grind6 patrol. Check for one write per changed
   destination and an “Automatic guide quest tracking recognized” message.
2. Repeat normal acceptance/progression in coordinates and native-first. Leave
   enough time after acceptance to exercise later `.complete` quest-log updates.
3. Select another quest, a Waypoint UI destination, and a raw Blizzard map pin.
   Advance several RestedXP steps. Each external destination must retain control;
   after clearing it, wait a full second and verify the latest RXP destination.
4. Verify `/rxpw status` while blocked, during the delay, and after resumption.
   Repeat with sync off, a preview and a loading screen, using the existing
   manual-resume acceptance checklist. Confirm no repeated writes or new sounds.

Offline tests model API/event ordering and marker/path counters. They cannot
prove client UI rendering or determine which caller produced the original log.

Validation: `node tests/run.js` passed all 21 suites / 1,096 checks, including
76 checks in `quest_progression_test.lua`. Existing manual-resume, native-transition,
audio, settings and presentation tests passed without changing their expectations.
`git diff --check` passed. No commit or push was performed.
