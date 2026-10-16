# Startup quest tracking and the Step 84 vendor

## Root cause

`ObserveManualOverride` previously classified every active quest without bridge
ownership or a recognized session-local guide association as external. At login,
session-local tracking associations are empty. The first poll/event therefore
latched an override, and `Evaluate` returned at that gate before sending the valid
Step 84 vendor destination. No player-selection event or other intent evidence
was required to create that permanent suspension.

Quest 92472 is “The Next Step” in the installed Skyborne guide. Immediately before
the vendor instructions, the guide has a hidden sticky `.turnin 92472` step with
`#completewith VendorStep`, alongside Galestrider collection work. The Rogue/Warrior
vendor route starts at map 2521, 44.67,45.19 and continues to 44.78,45.05. This
matches the report. RestedXP's installed `.turnin` handler can supertrack the quest
while the arrow points to the vendor. `Nav.HasActiveQuest` can find that separate
active instruction, but without a session-local acceptance or transition event
the prior attribution logic deliberately refused to classify its source.

Guide association is evidence of relevance, not evidence of player intent. The
logs do not prove which caller initially selected the quest. Neither the public
supertracking event nor its getters expose that caller. This fix does not search
future guide steps, whitelist every guide quest, or special-case 92472.

## Deterministic startup policy

With automatic sync enabled on login/reload, snapshot the initial active quest as
an **unclassified inherited quest**. If the first valid RXP target is delayed,
the first quest seen during initial acquisition can supply that snapshot. A second
different quest selection, any tracked external pin, or the first valid RXP target
ends acquisition. There is no arbitrary timer and the snapshot never changes to
an arbitrary later quest.

The inherited quest does not block automatic navigation, including at a vendor
with no quest context. It is not claimed as manual, automatic or bridge-owned.
Its identity may remain/reappear during normal guide progression without causing
a new override. An actual new different quest or a pin revokes the baseline and
activates the existing protection. Observed full idle clearance also revokes it.
Observed RXP setter evidence plus active guide work can upgrade that identity
to guide attribution. A later unknown setter supersedes the inherited baseline,
even for the same quest; see `STALE_MARKER_LIFECYCLE.md`.

This policy explicitly trades away preservation of an unknowable pre-reload
manual quest selection. A manually selected quest already present at login/reload
may be replaced. Different selections observed during the session remain protected,
including other quests in the guide. Re-selecting the exact inherited quest with
no observable clearance/change remains ambiguous. Clearing it and selecting again
provides an observable new selection. Manual WUI destinations and raw map pins
are protected even when inherited at login.

Sync shutdown/preview clear startup state; restarting sync and zoning do not open
another startup window. Auto-sync disabled at login never acquires this baseline.
Existing target settling, native verification, sound policy, appearance settings,
ownership checks and the one-second resume delay remain in use.

## Changes and verification

- `Sync.lua`: initial acquisition and one inherited quest ID; revoke on external
  takeover/idle/stop, without changing resolver eligibility or routing.
- `Core.lua`: status labels the inherited quest as unknown-origin and nonblocking.
- `tests/startup_tracking_test.lua`: reproduces the old failure before the fix;
  covers all strategies, known/unrelated IDs, active parallel guide instructions,
  manual quest/pin overrides, one-second fresh-target resume, reload policy,
  delayed attribution, reentrant setters and lifecycle cancellation.

In game, reload with 92472 already tracked while on the vendor route. Verify the
vendor icon, label, colour and coordinates, then advance to the next RXP point.
`/rxpw status` should show an unknown-origin startup quest without a pause. Select
a different quest and advance several guide steps: it must retain priority.
Clear it, wait one second and verify the latest RXP destination returns silently.
Repeat with a WUI destination and raw pin, including a reload with each present.
Check initial loading with RXP data appearing late, preview/off/zoning during a
pending resume, and a quest that receives observed RXP setter attribution later.

Mocks cannot determine the caller of a live tracking change or prove Forever's
UI event ordering. No dependency files are modified. The subsequent marker-lifecycle correction
adds a non-destructive secure post-hook of the native quest setter; it replaces
no runtime functions.

Validation: `node tests/run.js` passed all 22 suites / 1,164 checks, including
68 new startup checks. Existing sound, appearance, quest progression, manual
override, resume and native-transition suites passed unchanged. `git diff --check`
passed. No commit or push was performed.
