# v0.6.1 service context correction

The installed RXPGuides v4.11.23 source, `Guides/forever/RestedXP-Skyborne.lua`
lines 715–721, contains this sequence (step numbering depends on guide filters):

```text
#completewith Aggressive Encroachment
.train 2575,3 -- Mining Trained
.goto 2521,42.76,24.5
>>Talk to Uualia Suncrest
.collect 2901,1 >>Buy a [Mining Pick]
.collect 277115,1 >>Buy an [Apprentice's Mining Pack]
.target Uualia Suncrest
```

`functions.train` parses flag 3 as `textOnly = true` and `reverse = true`.
This gates the purchase step on Mining knowledge; it is not a training visit.
It has no instruction text, so `GuideLoader.parseLine` does not make it
`lastObjective`. The waypoint has no structured parent in this block. The first
pending purchase following the waypoint supplies the label; after completion,
the second purchase supplies it. Drawing marks the gate, waypoint and heading
`completed`, without marking the purchase instructions done. The fixture models
these flags; live client memory was not inspected.

The old `StepService` scanned the entire step, ignored the training condition
flags, and did not recognize purchase `.collect` instructions. It returned
ClassTrainer from the gate. The new regression reproduced that result against
the pre-fix working files (the purchase classification, palette and second-item
checks failed); the existing 14 suites passed there.

Service presentation now scans the following instruction block up to the next
instruction-bearing waypoint boundary. Consecutive route points may share their
destination's block. When there is no following action, a validated same-step
parent block, or the block before the first waypoint, supplies the association.
A parser parent can be a previous action's completion dependency: a new following
action takes precedence for service presentation. Completed actions still mark
block boundaries, but never select an icon. The first pending action determines
the service; an unknown action conservatively stops classification.

Training conditions are excluded. Genuine training retains the existing local
`.skill` profession distinction and `.use` book exclusion. `.buy`, `.buyAll`,
and `.buyUntilBroke` provide structured purchase evidence. `.collect` requires
its own cleaned text to start with “Buy”, or a local purchase heading when its
own text is empty. Generic gathering never becomes Vendor merely from `.collect`.
Repair text is considered only on `.vendor`, with a word boundary. Food/drink
and training qualifiers cannot be borrowed from another waypoint's block.

Navigation decisions, label resolution, coordinates, Sync, ownership and the
appearance pipeline are unchanged. `status`/`inspect` add `Service source`,
showing the structural association and the selecting instruction. English
purchase/repair text heuristics remain conservative; localized text without
structured buying tags may retain the generic marker.

## In-game verification

1. `/reload` at the reported purchase. `/rxpw status` should show map 2521,
   42.76, 24.50, the existing Mining Pick label, Vendor/Bags, Merchant Blue,
   and `Service source: following instruction .collect (purchase)`.
2. Buy the pick. The pack should retain Vendor and its own label after the
   existing presentation refresh interval. Coordinates must stay unchanged.
3. Toggle Service Icons and Custom Colours off/on. Icons off uses Waypoint UI's
   generic icon; colours off uses its configured fallback. Re-enabling must
   retain Vendor. Check genuine class/profession trainers and vendor trash.
4. Follow a multi-waypoint step, then a quest/turn-in step. Confirm every route
   point, normal quest icons and hybrid/native behaviour. Select a manual
   Waypoint UI destination and confirm the bridge respects it.

Offline validation: `node tests/run.js` includes `service_context_test.lua` plus
all existing navigation, F1–F8, preview and settings regressions. Lua 5.1 syntax
is checked separately with luaparse; no live game acceptance is claimed.
