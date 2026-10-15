# Historical review handoff: RXP Waypoint Bridge

> This document records the v0.5.4–v0.5.6 review state before the Stage 2 rename to RestedXP Waypoint. Historical namespace and saved-variable names below describe that earlier state; command examples use the current `/rxpw` command.

**Historical snapshot:** this document describes the pre-review v0.5.6 working tree. The subsequent v0.5.7 F1–F3 fixes, regression evidence and acceptance checklist are documented in [RELIABILITY_F1_F3.md](RELIABILITY_F1_F3.md). Other review findings remain outside that focused change.

Prepared 2026-10-15 as background for an independent code review. It describes the working tree as it stands, including uncommitted work. It is not a design spec, and the code is the source of truth. Wherever a statement rests on offline mocks rather than the game client, this document says so.

Read [AGENTS.md](../AGENTS.md) first for the full set of engineering rules and verified integration facts. This document summarises it and adds review context; it does not repeat everything.

---

## 1. Project overview

RXP Waypoint Bridge is a World of Warcraft **Forever** addon. Target client: `F:\World of Warcraft\_classic_beta_`, build 1.60.1, interface 16001, game type `camelot`.

It mirrors the waypoint that **RestedXP Guides** (v4.11.23) has selected into **Waypoint UI**'s (1.7.3) in-world navigation: the diamond marker, the beam, the label and the distance.

- **RestedXP is the route planner.** The bridge reads `_G.RXPG_ARROW.element`, the waypoint RestedXP's own arrow follows, and never chooses waypoints itself.
- **Waypoint UI is the renderer.** The bridge writes only through Waypoint UI's documented public API, `WaypointUIAPI.Navigation`: `NewUserNavigation`, `GetUserNavigation`, `ClearUserNavigation`, `IsUserNavigationTracked` and `IsUserNavigationFlagged`.
- **Native quest navigation is optional.** In some strategies, quest turn-ins and objectives use WoW's own quest supertracking (`C_SuperTrack.SetSuperTrackedQuestID`), so Waypoint UI shows its native quest marker.
- **Intended experience.** The player follows RestedXP's route through Waypoint UI's marker, with every intermediate waypoint kept. Labels describe the current instruction ("1/15 Windstone Cluster", "Fly to the Undercity"). Markers carry a quest or service icon and colour where that can be determined from the guide's structure. The bridge never fights the player's own waypoints or RestedXP's supertracking.

Hard constraints, from AGENTS.md and the developer:

- Never modify RestedXP or Waypoint UI, on disk or at runtime.
- Only clear navigation the bridge created.
- RestedXP's route is authoritative.
- No hardcoded quest-specific exceptions.
- Never commit without the developer's approval.

The repository folder is junctioned into `Interface\AddOns`, and there is no build step.

## 2. Current architecture

The load order comes from [RestedXPWaypoint_Camelot.toc](../RestedXPWaypoint_Camelot.toc). Every module shares the addon namespace `ns`.

| File | Lines | Role |
|---|---|---|
| `Core.lua` | 472 | Settings in `RXPWaypointBridgeDB` (`autoSync`, `debug`, `strategy`), printing and debug helpers, and the `/rxpw` commands: status, sync, on, off, debug, mode, inspect and preview. `PrintStatus`, `PrintInspect` and `PrintContext` produce the diagnostics. |
| `LabelResolver.lua` | 287 | `Label.Clean` (strips markup) and `Label.Resolve(element)`, which turns RestedXP step data into a label. Reads RestedXP internals. |
| `RXPAdapter.lua` | 189 | `RXP.GetTarget()` returns `(target, reason)` with map, coordinates, key, label and labelInfo. `RXP.HasTargetChanged()` is a cheap field comparison and deliberately ignores text. |
| `NavigationResolver.lua` | 1398 | Structure-only analysis and quest APIs: `FindTurnIn` (hybrid), `FindQuestTarget` (native-first), `SelectQuest`, `VerifyNative`, `Nav.Decide`. Presentation helpers: `GetPresentation`, `StepActivity`, `StepService`, `TintKey`, `GetQuestIconType` and `GetContextDecision` (new). This is the only module that calls `C_SuperTrack` and `C_QuestLog`. |
| `WaypointAdapter.lua` | 307 | The only module that calls Waypoint UI. `SetNavigation`, `IsShowingTarget`, `HasTargetLabel`, `ClearOwnedNavigation`, `ClearNavigationWithFlag`. The quest icon and tint tables are gated to Waypoint UI `1.7.x`. Also holds the service icon map and `SERVICE_PALETTE`. |
| `Sync.lua` | 889 | The single controller: ticker, settle time, `Evaluate`, coordinate and native transitions, retry policy, hold logic, outside-change diagnostics, and (new) `Sync.PrepareTarget` and `CheckLabel`. |
| `Preview.lua` (untracked) | 236 | `/rxpw preview`, an in-game icon test aid. It places temporary markers ahead of the player with the flag `RXPWaypointBridge-Preview`. |
| `Art/Icons/*.blp` (untracked) | 9 files | Service icons. BLP2, raw BGRA, 64×64, 17,556 bytes each. |
| `tools/build_icons.py` (untracked) | 224 | Generates the BLPs from source icons. WoW doesn't load it. |
| `tests/` | — | fengari (Lua in Node) suites with mocked WoW, RestedXP and Waypoint UI APIs. See section 7. |

### Information flow

1. **Every 0.25 s** the Sync ticker calls `RXP.HasTargetChanged()`. A change must stay stable for 0.2 s before `Evaluate("target")` runs.
2. **Quest events** (`QUEST_LOG_UPDATE`, `QUEST_TURNED_IN`, `QUEST_ACCEPTED`, `QUEST_REMOVED`) schedule one coalesced `Evaluate("quest")` 0.5 s later. Since v0.5.6 this happens in every strategy.
3. **Once a second**, `CheckLabel` compares RestedXP's label for the handled coordinate destination with the last one seen. A change schedules the same coalesced evaluation. This is new in v0.5.6.
4. **`Evaluate`** runs these steps in order:
   - `RXP.GetTarget()`.
   - `Nav.Decide(target, strategy, Sync.GetDecisionContext())` returns a decision with `mode` (`"coordinates"` or `"native"`), reason, `nativeId`, quest data, role and context.
   - For coordinate decisions, `PrepareCoordinateTarget` calls `Sync.PrepareTarget`, which sets the presentation: icon, tint and fallback label.
   - The hold checks: a foreign navigation is tracked, or a native→native switch.
   - `EnsureCoordinates` or `EnsureNative`.
5. **Writes happen only when the desired state differs from the handled state** `(handledMode, handledKey, handledId)`. The exception is a same-key label or icon change, which is a silent same-coordinate `NewUserNavigation` (Waypoint UI then only renames).
6. `USER_WAYPOINT_UPDATED` and `SUPER_TRACKING_CHANGED` are **diagnostics only**: `CheckOutsideNavigation` records `state.external`, and these events never trigger a write.

### How navigation decisions are made

The full rules are in AGENTS.md. In short, by strategy:

- **`coordinates`** (the default for new installs): always RestedXP coordinates. The native-first analysis still runs, for diagnostics and presentation.
- **`hybrid`** (v0.4): native only for an **eligible turn-in**. All of these must hold:
  - The arrow is on a non-pass-through `.goto`: no radius, not lowPrio, not dynamic, not generated.
  - The turn-in is linked by `parent`, or it is the first pending non-textOnly instruction after the waypoint.
  - The quest is in the log and ready.
  - Native APIs exist.
- **`native-first`** (v0.5, experimental): `FindQuestTarget` analyses the waypoint's instruction block.
  - A turn-in, or `.complete` objectives of exactly one quest, become native candidates. Several quests inside a `#loop` circuit become a "multi" candidate, passed to `SelectQuest`.
  - Route points, travel instructions, accepts, `.collect`, `+text` objectives and ambiguous blocks stay on coordinates.
  - Objective eligibility requires every unfinished objective of the quest to be targeted in the block.
  - Native transitions are verified after a delay with `VerifyNative`, a distance comparison through `C_Navigation.GetDistance`. The turn-in tolerance is 50 yd and the objective tolerance 100 yd. On failure, the bridge falls back to coordinates or tries the next candidate.
  - **Patrol steps** (`#hidewindow #loop` with only `+1`) delegate to the active steps they serve.
  - **Helper steps** are a sticky step with one waypoint and no instructions. They take quest context from their anchor step, and native turn-ins can persist through them ("continuity").

## 3. Implemented functionality

Everything below is implemented in the working tree. In-game status for each item is in section 8.

- **Coordinate mirroring.** One write per destination, silent automatic writes, and manual `/rxpw sync` with sound.
  - Invalid or stale targets never clear navigation.
  - A first activation respects an already-tracked foreign waypoint.
- **Three strategies:** `coordinates`, `hybrid` and `native-first`, switched with `/rxpw mode`.
- **Quest prioritisation in shared farming circuits (v0.5.3).** `SelectQuest` ranks candidates in this order:
  1. a "Prioritize" text line in a step whose pending quests are exactly that quest
  2. RestedXP's current step
  3. the bridge's current quest, then the WoW-supertracked quest
  4. guide order

  It skips blocked candidates, and `decision.candidates` lists all of them.
- **Retry policy for failed native targets.** A failure blocks retries for 60 s, or for 10 s plus a progress change. Zoning or a strategy change clears it. There is no retry timer.
- **Route-critical waypoint protection.** Native-first roles `travel instruction` and `route point` are `routeCritical` and always stay on coordinates.
  - Own `>>` text on a `.goto` counts as a travel instruction, unless it has no letters, like `>>1`.
  - An intermediate point before more waypoints is a route point.
- **Quest context (v0.5.4).** `decision.context = { questID, title, kind, ready, source }` comes only from a structural association plus the live quest log, and is never cached.
  - It replaces **fallback** labels only ("Step N" becomes "Harvesting Windstones - Ready for turn-in").
- **Labels.** `Label.Resolve` priority:
  1. element title
  2. step arrowtext
  3. the waypoint's own `>>` text
  4. the linked parent objective
  5. the following lines in the waypoint's segment: the first pending real instruction, else a text-only heading, else a warning (route chains use a later waypoint's text)
  6. the preceding lines (first waypoint only)
  7. step title
  8. `Step N`

  Markup and NPC IDs are stripped. Since v0.5.6 progress counts are **kept**, and labels are shortened at 60 bytes, UTF-8 safe.
- **Quest icons on coordinate waypoints (v0.5.5).** The icon is Waypoint UI's own `Art\Icons\<Available|Incomplete|Complete><Type>Quest`, gated to Waypoint UI 1.7.x.
  - The quest comes from `decision.context`, or else the step's first pending actionable instruction (`StepActivity`).
  - The colour uses Waypoint UI's default quest tints through `r`/`g`/`b`:
    - IncompleteQuest 200/200/200 (`#C8C8C8`)
    - NormalQuest 255/255/156
    - RepeatableQuest 158/207/245
    - ImportantQuest 249/196/255
    - Accept markers keep the "Other" colour, so no `r`/`g`/`b` is sent.
- **Service icons (v0.5.6 work).** Used when the step's first pending actionable instruction isn't quest-related:
  - `.fp`/`.fly` → FlightMaster
  - `.home` → Innkeeper
  - `.stable` → StableMaster
  - `.bankdeposit`/`.bankwithdraw` → Banker (Bags icon)
  - `.xp` (not textOnly, not reverse) → Grind
  - `.trainer`/`.train` → ProfessionTrainer when the step has `.skill`, otherwise ClassTrainer; no icon when the step has `.use` (books)
  - `.vendor` → FoodAndDrink (a food or drink `.collect`, checked with `GetItemInfoInstant` class 0 / subclass 5), Repair (vendor text mentions "repair"), or Vendor (Bags)
- **Service colour palette.** `SERVICE_PALETTE` in `WaypointAdapter.lua` holds Primary, Beam, Highlight and Shadow for each service, from the developer's spec. **Only Primary is used**, because Waypoint UI takes a single colour.
  - That colour tints the diamond, label, pinpoint, arrow **and beam**.
  - Waypoint UI forces icon recolour (desaturate plus tint) whenever `r`/`g`/`b` is set, so the icons are built brightness-only ("tint-ready").
  - The developer chose this "coloured markers, tinted icons" option knowingly.
- **Preview mode.** The full syntax is `/rxpw preview [all|next|<name>] [close|far]`, or `/rxpw preview off`.
  - It shows any of the 14 entries (3 quest states, 10 services, 1 default) ahead of the player. `close` is 0.008 map units; `far` is 4× that.
  - `all` cycles every 4 s.
  - Automatic sync pauses (`Sync.Stop`) while a preview is shown. `off` clears only the preview-flagged navigation and restarts sync. `/rxpw on` also ends a preview.
- **Diagnostics.** `/rxpw status` is extended in v0.5.6, see section 4. `/rxpw inspect` dumps the resolver's view of the step: instruction roles, served steps, candidates and the last verification.

## 4. Recent changes since v0.5.4 (all uncommitted)

HEAD is `ced78df RXP Waypoint Bridge v0.5.4`. Everything below is in the working tree only. The TOC says `0.5.6`. **There is no v0.5.5 commit**: the v0.5.5 and v0.5.6 work will land together if the developer approves a commit.

### v0.5.5: quest icons and colours on coordinate waypoints (implemented)

- `Nav.GetPresentation`, `Nav.GetQuestIconType`, `StepActivity` and `TintKey`; `WUI.GetQuestIcon` and `WUI.GetQuestTint`.
- The icon is compared in `HasTargetLabel` and `state.handledIcon`, so an icon-only change (the quest becoming ready) is a silent same-coordinate rename.
- Before v0.5.6, this was limited to the `native-first` strategy.

### v0.5.6 part 1: service icons, palette and preview (implemented)

- `StepService` and `Nav.IsFoodOrDrink`; `WUI.GetServiceIcon`, `GetPresentationIcon`, `GetServiceTint`, `GetPresentationTint` and `GetServicePalette`.
- `Art/Icons` (9 BLPs) and `tools/build_icons.py`.
- `Preview.lua` and `WUI.ClearNavigationWithFlag`. `SetNavigation` now accepts `target.flags`.
- The slash parser passes the rest of the line through as the argument.

### v0.5.6 part 2: quest context and icon fix for intermediate waypoints (implemented, this session)

The bug report, from the developer's in-game `/rxpw status` on Windstone Clusters (quest 93552), before the fix:

- Decision: coordinates, intermediate route waypoint; role route point, route-critical.
- Quest context: none.
- iconTexture: nil, so Waypoint UI showed its default arrow.
- RXP label `1/15 Windstone Cluster`, but Waypoint UI showed `0/15 Windstone Cluster`.

The changes:

- **`IsDone` fix.** The same function is in both resolvers: done means `skip`, or `completed` on a non-textOnly element with text. See section 9.
- **Presentation in every strategy.** This was the developer's explicit choice ("All modes"). `Sync.PrepareTarget` no longer returns early outside native-first.
  - `Nav.GetContextDecision(target, decision)` returns the decision itself when it came from the native-first analysis. In hybrid, it re-runs `Nav.Decide(target, "coordinates")` with no Sync context.
- **Live progress labels.**
  - `Label.Clean` no longer strips trailing counters.
  - `OnQuestEvent` no longer skips coordinates mode.
  - `CheckLabel` was added to the ticker (1 s interval, `state.watchedLabel`).
  - Bursts of quest events coalesce into one evaluation.
- **Label priority.** The first pending **real** instruction now beats a text-only heading; headings are the fallback, before warnings. See section 10 for the test impact.
- **`/rxpw status`** has new lines:
  - `Navigation:` mode, role, route-critical, map and coordinates
  - `Quest context:` from `decision.context`, or else from the presentation's step quest, with ID, kind, status and source
  - `Marker icon:` category, icon name with source, and colour
  - `Marker texture:` the actual texture path
  - `Objective label:` RestedXP's, expected, displayed, and a stale flag. It only prints when the Waypoint UI navigation is bridge-owned. "Stale" is only computed when `IsShowingTarget` is true; otherwise it reads `n/a`.
- **Tests.**
  - `harness.lua` `newStep` now simulates RestedXP's render flags; `{ raw = true }` opts out. The mock also records `suppressAudio`.
  - New `tests/progress_test.lua`.
  - Expectations updated in `label_test`, `hybrid_test` (one line), `icons_test`, `services_test` and `windstones_test`.
- **Docs.** README and AGENTS updated.

### Planned, not implemented

- From the AGENTS roadmap: validating native-first in game, tuning the limits, choosing the default strategy, and the 1.0 items: optional arrow hiding, pause/resume, world-coordinate targets, settings UI.
- Nothing from v0.5.6 is knowingly left unimplemented. The concerns in sections 6 and 10 are unresolved.

## 5. Important design decisions

- **RestedXP decides where; context decides what it looks like.** Navigation, meaning coordinates and the native/coordinates mode, comes only from RestedXP's arrow and the structural rules. Presentation (icon, colour, fallback label) is derived separately and must never move a waypoint or change the route-critical classification.
  - The v0.5.6 bug came from coupling the two: a route-critical point lost its quest presentation.
  - Presentation is now strategy-independent, so switching modes changes only how the player is navigated, not what the marker looks like.
- **Polling instead of hooks.** RestedXP sets `RXPG_ARROW.element` as a plain field inside private functions, so there is nothing reliable to hook. The 0.25 s poll compares raw fields only.
- **Write only on state change.** Evaluation is idempotent, which prevents flicker, audio spam and fights with Waypoint UI.
- **Navigation events are diagnostics only.** Reacting to `USER_WAYPOINT_UPDATED` or `SUPER_TRACKING_CHANGED` by writing would fight the player or RestedXP. RestedXP itself supertracks quests (functions.lua ~1850, the `.complete` handler, on quest-log events).
- **Structure over keywords.** Quest association uses tags, quest IDs, `parent` links, step relationships and `RXPFrame.activeSteps`, never quest names.
  - The one deliberate exception is the English "Prioritize" heading in `SelectQuest`, because RestedXP has no priority field.
  - The "repair" vendor-text check is a second keyword use.
- **Conservative native.** Native requires a structural candidate, a quest-log check and post-transition distance verification. Ambiguity falls back to coordinates.
- **Public API only for Waypoint UI.** Quest icon file names are a Waypoint UI implementation detail, so quest icons and tints are gated to version `1.7.x`. The bridge's own service icons aren't gated.
- **One colour per marker.** The API has no separate beam, highlight or shadow inputs and forces icon recolouring. The palette's other values are kept for reference only.

## 6. Known bugs, risks and limitations

These are stated with their evidence level.

- **Label refresh is skipped while RestedXP has taken supertracking. Confirmed in mocks; whether it happens in game is unknown.**
  - `RefreshLabel` only writes while `IsShowingTarget` is true. If RestedXP supertracks the quest (the `.complete` handler on quest-log events), the label update is skipped with "Waypoint UI is following something else". A probe with mocks reproduced this.
  - `RefreshLabel` sets `state.handledLabel` **before** that check, so the skipped label isn't retried when the user waypoint becomes tracked again. It only updates on the next label change or destination.
  - The developer's in-game report showed `Blizzard native quest: nil, User waypoint: true` at that moment, so it may not happen for this step. **Not verified.**
- **Coordinate markers can't fully match native markers.** There is one name line, no subtitle and no quest-context field, and the icon is slightly greyer because of forced recolouring. Custom colours from Waypoint UI's own settings aren't mirrored.
- **Quest icon dependency.** Quest icons rely on Waypoint UI's shipped file names, so they only appear with Waypoint UI 1.7.x.
- **Native verification is distance-only.** It uses `C_Navigation.GetDistance` and treats `|native − RestedXP distance|` as a lower bound. It can't prove the marker is at the right place. The mocks assume WoW supertracks one target at a time, which is unverified in Forever.
- **English-text heuristics.** "Prioritize" (`SelectQuest`) and "repair" (`StepService`) are English text checks, which would fail on localised guides.
- **Food and drink detection** depends on `GetItemInfoInstant` returning data. If it doesn't, the step falls back to the general vendor.
- **Service icon artwork** is generated from WoW's own icons. The README notes this is fine for personal use and needs thought before publishing.
- **New texture files need a client restart,** not just `/reload`.
- **Untracked `tools/__pycache__/`** exists and isn't in `.gitignore`, so a `git add tools` would include it.
- **Line endings.** Git warns that LF will be replaced by CRLF (`core.autocrlf=true`). This is cosmetic, but expect whitespace noise in diffs.

## 7. Testing

Run with `node tests/run.js`, using fengari from `tests/node_modules` (Node v22.17.1 here). A luaparse syntax check also passes on every `.lua` file; it lives in a temp directory, not in the repo.

**Results today, 2026-10-15, on the current working tree: all 10 suites pass.**

| Suite | Checks | Covers |
|---|---|---|
| `label_test.lua` | 42 (prints "ALL PASSED") | `Label.Clean` markup stripping, UTF-8 shortening, counters kept, resolver priority, render-flag cases. Self-contained; doesn't use the harness. |
| `hybrid_test.lua` | 43 | The v0.4 hybrid regression suite: travel, turn-ins, verification failure and fallback, manual hold, labels. Self-contained, with its own mocks and no render-flag simulation. **One expectation was changed in v0.5.6** (section 10). |
| `native_first_test.lua` | 54 | Kill, collect and interact classification, loops, route chains, parent-linked blocks, ambiguity, coverage, tolerance, objective → turn-in, progress events, overrides, stale callbacks, strategy switching. |
| `agitators_test.lua` | 32 | Skyborne patrol steps: delegation, served steps, circuit references. |
| `vuldren_test.lua` | 32 | Quest prioritisation in a shared circuit. |
| `windstones_test.lua` | 39 | Skyborne Steps 34–36 and the druid helper: continuity, context labels and icons, stale context, travel protection, manual hold, rapid transitions, other strategies. |
| `icons_test.lua` | 25 | Quest icons and colours on coordinate waypoints, campaign/repeatable types, defaults, version gate, strategies. |
| `services_test.lua` | 36 | Service detection and precedence, books, palette colours, strategies. |
| `preview_test.lua` | 27 | Preview placement, icons and colours, pausing and resuming sync, close and far, cycling. |
| `progress_test.lua` (new) | 36 | The v0.5.6 regression, with render flags on:<br>- Windstone coordinates kept, silver `?` and `#C8C8C8` in all three strategies<br>- 0/15 → 1/15 as one silent write, coalesced, with no clear<br>- the update without a quest event (`CheckLabel`)<br>- status lines and the stale flag<br>- manual override<br>- the quest-ready icon<br>- travel and service icons unaffected<br>- preview pauses refreshes |

The harness (`tests/harness.lua`) mocks `C_SuperTrack`, `C_QuestLog`, `C_Navigation`, `C_Map`, HereBeDragons, `RXPG_ARROW`, `RXPFrame.activeSteps`, `WaypointUIAPI.Navigation` and timers.

Mock limits that matter:

- The mock `NewUserNavigation` **does not fire `USER_WAYPOINT_UPDATED`**, so outside-change diagnostics are barely exercised.
- Supertracking is modelled as a single target.
- Waypoint UI's internal rendering (tinting, beam, icon placement) isn't modelled at all; only the API arguments are checked.

**Mutation checks, run this session:** each key v0.5.6 rule was deliberately broken in turn to confirm the tests catch it:

- the old `IsDone` in LabelResolver, and separately in NavigationResolver
- re-adding the native-first gate on presentation
- removing `CheckLabel`
- re-adding counter stripping

Each made at least one suite fail. Removing the quest-event coalescing flag did **not** fail any test, because extra evaluations write nothing. Coalescing is therefore only checked indirectly, through the write count.

**Verified only with offline mocks:**

- all v0.5.6 behaviour
- service detection for every service type except possibly flight masters (see section 8)
- the palette on real markers
- hybrid and coordinates presentation
- `CheckLabel`
- preview cycling and far distance
- the new status lines

## 8. In-game validation

**What the developer has reported from the game:**

- v0.2 coordinate mirroring and v0.4 hybrid passed in-game tests (AGENTS.md).
- v0.5.4 was verified in game (AGENTS.md).
- **v0.5.5 quest icons:** the developer sent screenshots of the Windstone Cluster marker (the bridge's) next to the Cirrusfly Queen marker (Waypoint UI's native one) and said the colours were slightly off. After the quest-tint fix they replied "That's working really well now". So **the silver `?` on a Windstone coordinate waypoint was seen in game under v0.5.5**, in native-first mode. That is also the "earlier screenshot" the v0.5.6 bug report mentions.
- **The v0.5.6 bug report** itself is in-game evidence of the **pre-fix** state (section 4).
- **Service icons:** the developer gave visual feedback (border too thick) and then asked how to test icons in game, which led to `/rxpw preview`. The record doesn't show whether that feedback came from the game or from generated contact-sheet PNGs.

**Not yet verified in game (no in-game report of these exists):**

- **The v0.5.6 fix as a whole:**
  - the corrected quest context on the Windstone route point
  - the silver `?` texture and `#C8C8C8` colour in `coordinates` and `hybrid` modes
  - live progress labels (0/15 → 1/15 → …) updating in place, without sound or flicker
  - preserved coordinates while the label changes
  - the new `/rxpw status` lines and the stale flag

  The offline reproduction and `progress_test.lua` show the intended behaviour. The developer hasn't yet reported a test of this build.
- **The service palette colours on real markers,** and how the tinted brightness-only icons look.
- **Preview mode** in game: the `close`/`far` distances, cycling, and resuming afterwards.
- **The native-first behaviour changes** from the `IsDone` fix (section 9).
- **Whether RestedXP re-supertracks the quest** during Windstone collection and blocks label refresh (section 6).

**Suggested in-game checks:**

1. On the Windstone route, in each mode, run `/rxpw status` and check the `Navigation`, `Quest context`, `Marker texture` and `Objective label` lines.
2. Collect a cluster and watch for the in-place rename, with no sound and no marker reset.
3. Run `/rxpw preview all far`, then `off`.
4. With `/rxpw debug` on, watch for repeated "Outside navigation change" lines.

## 9. Recent behaviour changes: RestedXP's `completed` flag

**The fact, from the installed RXPGuides source.** When RestedXP's guide window draws a step (GuideWindow.lua ~1316–1328), it sets `element.completed = true` on every element that is text-only or has no text. That covers `>>` headings, `*` notes, `.mob`/`.target` and **every `.goto`**.

- Real progress sets `skip`: `SetElementComplete` sets both `completed` and `skip`, and a reached waypoint sets `skip`.
- `#hidewindow` steps aren't drawn, so they keep the parser's flags.

**Before v0.5.6,** `IsDone(e)` was `e.completed or e.skip`. In game, every heading and `.goto` of a drawn step therefore looked done. The offline tests didn't simulate the flag, so they never showed this.

**After v0.5.6,** `IsDone(e)` is `e.skip or (e.completed and not e.textOnly and e.text ~= nil)`.

**Wider implications:**

- **Labels.** In game, headings were effectively always skipped, so labels already showed the first real instruction (for example the live "0/15 Windstone Cluster"). v0.5.6 makes "real instruction first" explicit. Headings are now a deliberate fallback, used before "Step N".
- **Native-first decisions.** These code paths now see unreached `.goto`s in drawn steps:
  - **`AnalyzeServedSteps`:** "served step N has its own waypoint" → coordinates. Before, in game, a served step's pending waypoints looked done, so a patrol could go native even when a served step had its own unreached waypoint. Now it stays on coordinates, as the agitators fixture always expected. **This can change in-game outcomes on patrol steps.**
  - **`PendingWaypointCount` (helper detection):** a visible sticky step with exactly one unreached `.goto` and no instructions can now be classified as a helper. Before, in game, its count was 0. Real helper steps are usually `#hidewindow`, so they weren't affected before or after.
  - **`AnalyzeBlock`, `PendingQuests`, `StepActivity`, `StepService`:** these skip waypoint and textOnly elements anyway, so the change mainly affects real instructions, which keep their real completion state.
- **Coordinates and hybrid** navigation decisions are unchanged. The hybrid suite needed only the label expectation change.
- **No in-game native-first validation of these changes exists yet.** The offline suites pass with render flags on (`harness.lua`) and with them off (`hybrid_test`, `label_test`).

## 10. Outstanding concerns

### Repeated outside-navigation-change messages

- `CheckOutsideNavigation` (Sync.lua) logs a debug line whenever `WUI.DescribeOutsideNavigation()` returns a **different** string from the last one. The string includes the foreign waypoint's name or the supertracked quest ID.
- **Confirmed source: preview.** `OnNavigationEvent` and `CheckOutsideNavigation` are guarded by `ns.db.autoSync`, `state.ready` and `state.handledKey`, but **not** by the ticker. `Sync.Stop()`, which preview uses, leaves `handledKey` and `db.autoSync` set.
  - Each preview marker has a different name and a non-owner flag. So with `/rxpw preview all` and debug on, the bridge logs "Outside navigation change: another waypoint is tracked (Preview: …)" for every marker, about every 4 s.
  - This was reproduced with a throwaway probe: the mock was made to fire `USER_WAYPOINT_UPDATED` after each write, and no code was changed.
- **Likely source: RestedXP supertracking.** RestedXP supertracks quests on quest-log events, so in coordinates mode the description can alternate between "quest N is supertracked" and nil ("following the bridge destination again"). Each flip logs a line.
  - A probe showed one such line when RestedXP's call was simulated. How often this happens in game is unknown.
- These are debug-only messages and never cause writes. The concern is noise, and possibly that they hide real outside changes.
- **I have no record of the specific in-game occurrence the developer has in mind,** so the cause of what they saw is unconfirmed.

### Preview ownership handling

- Preview uses the flag `RXPWaypointBridge-Preview`, not `RXPWaypointBridge`. As a result:
  - The outside-change diagnostics treat the preview as foreign (above).
  - `Preview.Off` clears only preview-flagged navigation, through `WUI.ClearNavigationWithFlag`, and only when `state.active` is true. If preview state is lost (`/reload` or logout during a preview) while Waypoint UI still shows the preview navigation:
    - `/rxpw preview off` prints "No preview is shown" and doesn't clear it.
    - On the next first activation, sync treats the marker as a foreign waypoint and pauses until RestedXP's next destination.
  - **Whether Waypoint UI restores user navigation across `/reload` is unverified.** Its SavedVariables exist, and `Navigation_WorldMap.lua` references a `snapshot.userNavigation`, but I didn't trace it.
- When preview turns off, `Sync.Start()` calls `ResetHandled()`, which is a "first activation". The probe showed the bridge re-writing the RestedXP destination immediately, because the preview marker had already been cleared.
- `EnableAutoSync` (`/rxpw on`) ends an active preview first.

### The modified hybrid test expectation

- AGENTS.md says `hybrid_test.lua` is the v0.4 regression suite and should "keep passing unchanged". In v0.5.6 one expectation was changed (hybrid_test.lua ~line 130). For the step `goto / >>Talk to Karos / .turnin 101 / .accept 102`, the expected label went from `Talk to Karos` to `Turn in Infestation Investigation`. A comment marks the change.
- The reason: the label priority now prefers the first pending real instruction over a text-only heading. `hybrid_test` doesn't simulate render flags, so before the change the heading won offline. In game, the flag hid headings, so players were already seeing the instruction.
- **This is a deliberate change to a protected suite and should be reviewed as such.** No navigation expectation in hybrid_test changed.

### Performance of periodic label checks

- `CheckLabel` runs in the 0.25 s ticker and returns immediately unless all of these hold:
  - the bridge is in coordinates mode with a handled key
  - no native transition is pending
  - no quest evaluation is queued
  - 1 s has passed since the last check
- When it runs, it calls `RXP.GetTarget()`. That calls `Label.Resolve`: a scan of the step's elements with several `gsub` passes per candidate text, plus a `C_Map.GetMapInfo` call. The cost is expected to be small, but it **hasn't been profiled in game**.
- Separately, `QUEST_LOG_UPDATE` (which fires often in WoW) now triggers a coalesced `Evaluate` in **every** strategy. Before, it didn't in coordinates mode. Each evaluation runs `Nav.Decide`.
  - In **hybrid**, `Nav.GetContextDecision` runs a second `Nav.Decide`, which means two full analyses with quest-log calls per evaluation.
  - `/rxpw status` also re-runs these.
  - These are bounded to at most about one evaluation per 0.5 s per burst, but they're new steady-state work.

### Other review notes from this session

- **`RefreshLabel` records the new label before confirming the write.** See section 6.
- **The `Quest context:` status line has two sources.** It shows `decision.context` when present, and otherwise the presentation's step quest. Route points have no `decision.context`, which was deliberately not added, to avoid changing Sync's hold logic. The line can therefore show a quest while `NoteContext` debug logging says there's none.
- **`GetPresentation` now returns extra fields** (`kind`, plus `title` from the step path). Only status uses them.

## 11. Git state

- **Branch:** `master`. No remote is configured, and there are no stashes.
- **Commits:**

  | Commit | Version |
  |---|---|
  | `a362b74` | v0.2.0 |
  | `5dd7752` | v0.4.0 |
  | `72e0ef0` | v0.5.2 |
  | `808af5e` | v0.5.3 |
  | `ced78df` | v0.5.4 (HEAD), committed 2026-10-15 11:51 +0200 |

- **Modified tracked files** (12 files, +729 / −100 against HEAD):

  | File | +/− | Summary |
  |---|---|---|
  | `NavigationResolver.lua` | +213 / −1 | Presentation helpers (quest and service), the `IsDone` fix, `GetContextDecision` |
  | `WaypointAdapter.lua` | +123 / −5 | Quest icons and tints, service icons, palette, `ClearNavigationWithFlag`, `target.flags`, `r`/`g`/`b`/icon in `SetNavigation` and `HasTargetLabel` |
  | `Sync.lua` | +112 / −41 | `Sync.PrepareTarget` with no strategy gate, `CheckLabel`, quest events in every strategy, `handledIcon` and `watchedLabel` state |
  | `Core.lua` | +58 / −9 | Status and inspect lines, the preview command, the slash argument parsing |
  | `LabelResolver.lua` | +33 / −11 | `IsDone` fix, instruction-first priority with heading fallback, counters kept |
  | `RestedXPWaypoint_Camelot.toc` | +2 / −1 | Version 0.5.4 → 0.5.6, plus `Preview.lua` |
  | `README.md` | +88 / −5 | Feature docs |
  | `AGENTS.md` | +43 / −8 | Integration facts (the render flag), rules |
  | `tests/harness.lua` | +18 / −4 | Render-flag simulation, `suppressAudio` recording |
  | `tests/label_test.lua` | +24 / −4 | Counters kept, instruction-first, render-flag cases |
  | `tests/windstones_test.lua` | +13 / −10 | Status format, instruction-first label, presentation in other strategies |
  | `tests/hybrid_test.lua` | +2 / −1 | One label expectation |

- **Untracked:** `Preview.lua`, `Art/` (9 BLPs), `tools/build_icons.py`, `tools/__pycache__/`, and `tests/icons_test.lua`, `tests/services_test.lua`, `tests/preview_test.lua`, `tests/progress_test.lua`.
- **This document** (`docs/REVIEW_HANDOFF.md`) is also new and untracked.

## 12. Recommended independent review areas

These would benefit from fresh eyes. Listing an area here doesn't mean it's wrong.

1. **The `IsDone` semantics** in both resolvers. Is "skip, or completed on a non-textOnly element with text" right for every RestedXP element type? Consider `.goto`s that carry `>>` text, `.collect`, `.use`, `.xp` and elements whose `text` is set dynamically. Are there other RestedXP draw-time mutations the bridge reads?
2. **Native-first under render flags.** Do the `AnalyzeServedSteps` and `PendingWaypointCount` changes (section 9) produce the right decisions on real Forever guide steps? The fixtures were written without render flags.
3. **`RefreshLabel` and `IsShowingTarget`.** Should `handledLabel` be set only after a successful write? How should label refresh behave while RestedXP holds supertracking?
4. **`CheckLabel` and coalescing:** correctness, starvation (it's skipped while `questEvalPending`) and cost. Is a 1 s text poll acceptable against AGENTS rule 8 ("avoid unnecessary polling")?
5. **`Nav.GetContextDecision` in hybrid.** Calling `Nav.Decide` a second time with a nil context: are there side effects (for example through `DecideHelper` or `SelectQuest`) or cost concerns?
6. **Outside-change diagnostics during preview,** and the preview flag's ownership after `/reload` (section 10).
7. **Label priority change:** instruction over heading. Is it right for steps where the heading is the more useful description? The hybrid test change is the visible example.
8. **The presentation fallback in `GetPresentation`.** `StepActivity` takes the first pending actionable instruction of the **arrow's step**. Could an unrelated travel point in a quest step get a quest icon, or a quest point in a service step get a service icon?
9. **Status output.** The two-source `Quest context:` line, and whether "stale" is meaningful when Waypoint UI isn't tracking the bridge's navigation.
10. **Waypoint UI API usage.** `iconTexture`, `iconType`, `r`/`g`/`b` and `stripCoordinates` against `WaypointUI/API.lua` 1.7.3, and the version gate.
11. **`tools/build_icons.py`.** The BLP writer's correctness: header layout, encoding 3, alpha depth.
12. **The test harness.** How faithful the mocks are, especially that Waypoint UI events aren't fired on writes, and single-target supertracking.
