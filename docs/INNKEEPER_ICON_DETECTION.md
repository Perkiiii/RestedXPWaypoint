# Innkeeper icon classification

Installed source inspected: RXPGuides 4.11.23, `Guides/forever/RestedXP-Skyborne.lua`
and `functions.lua`.

The reported Step 90 is `.goto 2521,43.02,43.24`, a Coriella conversation
heading, `.complete 92514,2`, and `.target`. There is no Innkeeper service
directive on this step. The comment identifies the objective as “Speak with
the Innkeeper”; the live `.complete` text supplies the progress instruction.
Previously `Nav.GetPresentation` returned the quest-context icon immediately,
before service detection. In addition, `StepService` did not recognise that
conversation as a service. Both prevented the Innkeeper icon.

The following step has the same coordinates and `.home` binding action,
followed by `.bindlocation 16624`. `.home` was already supported; its failure
was not reproduced with this installed structure. The new regression covers
both steps consecutively, including their shared coordinates and the single
label refresh. No synchronization changes were needed.

RestedXP metadata distinctions:

- `.home` creates `tag = "home"` and implements binding automation, including
  binder gossip and `HEARTHSTONE_BOUND` handling.
- `.bindlocation` also creates `tag = "home"`, but sets `textOnly = true`.
  It is a step condition, not evidence of a service visit.
- `.hs` implements teleportation and spellcast completion; its handler initially
  returns `{text = text}`. Neither the teleport directive nor teleport wording
  qualifies as binding.
- `.gossip` supplies conversation/NPC metadata; it does not identify an
  Innkeeper service by itself. `.target` identifies the NPC, not its service.

The change recognises a pending `.home` action or a narrow English fallback
on the first pending actionable instruction in the waypoint's existing service
block. Accepted conversation phrases are “Speak with/to [the/an] Innkeeper”
and “Talk with/to [the/an] Innkeeper”, with progress counts and markup removed.
Binding phrases start with “Set/Bind/Change your Hearthstone to” or equal
“Make this inn your home”. Headers, notes, quest titles and NPC names are not
evidence. Completed instructions and unrelated waypoint blocks are excluded.

Only Innkeeper presentation can override generic objective context; explicit
quest context for pickups/turn-ins and existing specialised service precedence
remain intact. Quest association and navigation strategy remain independent.
The WaypointAdapter, assets, palette, appearance settings and texture paths
are unchanged. Native navigation still uses Waypoint UI's native quest marker.
Status adds one `Icon reason` line; debug status can show a service rejected
in favour of explicit quest context.

Text fallback is deliberately conservative and English-only. Structured `.home`
detection works regardless of guide language. Unrecognised wording retains the
existing quest/default presentation. No NPC or quest ID lookup is hardcoded.

## In-game acceptance

1. With both dependencies enabled and coordinate strategy selected, `/reload`
   on the reported objective. `/rxpwaypoint status` should show service Innkeeper,
   its conversation evidence, the existing Innkeeper texture and Hearth Teal,
   while preserving quest 92514 objective context and the RXP destination.
2. Advance to binding. Confirm Innkeeper remains, the label changes to the
   binding instruction once, and there is no repeated marker refresh or sound.
3. Check a generic conversation, quest pickup/turn-in, flight master, vendor,
   and Hearthstone teleport. Confirm their usual icons and colours.
4. Toggle service icons/custom colours and confirm existing appearance settings
   still apply. With native-first selected, native quest navigation should retain
   its existing native marker.

Offline fixtures are in `tests/innkeeper_test.lua`; run `node tests/run.js`.
These mocks do not establish live client rendering or API behaviour.
