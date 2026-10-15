# AGENTS.md: RXP Waypoint Bridge

Context and rules for AI coding agents (Codex and others) working on this repository.

## What this project is

A World of Warcraft **Forever** addon. It mirrors the waypoint that **RestedXP Guides** has resolved into **Waypoint UI**'s in-world navigation. RestedXP is the route planner. Waypoint UI is the renderer. This addon is a thin synchronisation layer between them.

The developer tests every change by hand in game with `/reload`. There is no build step: the repository folder is junctioned straight into the client's `Interface\AddOns`. Every file must load as-is in WoW.

## Environment

- Client: WoW Forever beta at `F:\World of Warcraft\_classic_beta_`, build 1.60.1. Interface `16001`, game type `camelot`.
- TOC: `RXPWaypointBridge_Camelot.toc`. The `_Camelot` suffix is the Forever client flavour; Waypoint UI ships `WaypointUI_Camelot.toc` the same way.
- Installed dependencies, which you may read but **must never modify**:
  - `F:\World of Warcraft\_classic_beta_\Interface\AddOns\RXPGuides` (v4.11.23)
  - `F:\World of Warcraft\_classic_beta_\Interface\AddOns\WaypointUI` (1.7.3)
- Lua 5.1 (WoW). No Lua interpreter is installed locally. For syntax checks, use a parser such as `luaparse` through Node in a temporary directory.
- Do not assume a Retail-only API exists. Check the installed addons' code, or guard the call at runtime.

## Engineering rules

1. **RestedXP controls the intended route.** Mirror `RXPG_ARROW.element`. Do not re-implement RestedXP's waypoint selection.
2. **Preserve intermediate waypoints.** A multi-`.goto` route must appear in Waypoint UI as the same sequence.
3. **Never let quest supertracking silently override an explicit RestedXP travel waypoint.** Quest supertracking is a fallback, used only when RestedXP has no valid coordinate target. A step containing a quest ID is not a reason to switch.
4. **Prefer public APIs.** For Waypoint UI, use only `WaypointUIAPI.Navigation` as documented in `WaypointUI/API.lua`. Do not use undocumented options such as `syncNativeWaypoint` or `coordinatesAreNormalized`, or internal modules. RestedXP has no public waypoint API. Keep every read of its internals in the RestedXP-facing files (`RXPAdapter.lua`, `LabelResolver.lua`, `NavigationResolver.lua`).
5. **Never modify RestedXP or Waypoint UI**, either on disk or by replacing their functions at runtime. Hooks must be non-destructive (`hooksecurefunc`) and justified.
6. **Validate external addon data.** Type-check every field read from another addon. Missing or unexpected data must produce a message or a no-op, never an uncaught Lua error.
7. **Only clear navigation the bridge created.** Check ownership with `IsUserNavigationFlagged("RXPWaypointBridge")`. Do not call `ClearDestination()` routinely: it also clears all native supertracking.
8. **Avoid unnecessary polling and repeated API calls.** Write to Waypoint UI only when the target actually changes. No heavy `OnUpdate` work.
9. **Maintain WoW Forever compatibility.** Guard optional APIs, for example `C_AddOns and C_AddOns.IsAddOnLoaded`.
10. **Keep it modular as it grows.** RestedXP reads belong only in `RXPAdapter.lua` (targets), `LabelResolver.lua` (instruction text) and `NavigationResolver.lua` (turn-in detection; also the only place that calls `C_SuperTrack` and `C_QuestLog`). Waypoint UI calls belong only in `WaypointAdapter.lua`, and sync decisions in `Sync.lua`. Add new modules when a milestone needs them, not before.
11. **Prefer clear, maintainable Lua** over clever code. Use locals, no accidental globals, and the shared addon namespace (`local addonName, ns = ...`).
12. **Work incrementally.** Each milestone must be testable in game by hand and come with test steps. Do not implement features from later milestones early.
13. **Never commit without the developer's approval.**
14. **Labels: accuracy over cleverness.** Labels come only from RestedXP's own text, through its own waypoint-to-instruction links. Never show a completed instruction. When the link is ambiguous, fall back to `Step N`. Never change coordinates to improve a label.

## Verified integration facts (from installed source)

### RestedXP (`RXPGuides`)

- `_G.RXPG_ARROW` is a Frame created in `map.lua`. `RXPG_ARROW.element` is set in `updateArrowData()` (`af.element = element`) to the waypoint RestedXP's arrow is currently following.
- Element fields:
  - `zone`: uiMapID (number).
  - `x`, `y`: map coordinates as **percentages, 0–100**. RestedXP's own minimap code passes `element.x / 100`.
  - `wx`, `wy`, `instance`: world coordinates and continent.
  - `step`: the owning step. Includes `index` and `active`, which is `true` for active steps and `nil` otherwise, plus optional `title` and `arrowtext`.
  - `skip`: set once the waypoint is reached.
  - `hidden`: hidden by an activation radius.
  - `title`: optional label, which may contain `RXP_*_` colour tokens and `|c` escapes.
  - `wpHash`: an identifier for the waypoint.
- **`RXPG_ARROW.element` is never cleared.** When no waypoint remains, RestedXP only hides the arrow (`af:Hide()`). Treat the element as stale if `skip` or `hidden` is set, or if `step` exists but `step.active` is falsy.
- The arrow can also be hidden by RestedXP settings (`disableArrow`), in instances, or on the wrong continent. Arrow visibility alone is **not** a reliable "no waypoint" signal.
- The corpse and spirit-healer targets are a shared table with `generated = 1`, **no** `zone`/`x`/`y`, and only `wx`/`wy`/`instance`.
- The arrow element can change inside one step (`UpdateGotoSteps`). The `RXP_STEP_ACTIVATED` message (sent through RestedXP's internal bus) only marks step changes, so it is not enough on its own to detect target changes.
- RestedXP calls `C_SuperTrack.SetSuperTrackedQuestID` itself in these places:
  - `GuideWindow.lua`, on step activation, for `step.track`.
  - The `.accept` element handler (`functions.lua` ~1511), on initial processing.
  - The **`.complete` element handler (`functions.lua` ~1850). This one also runs on quest-log events** whenever `not step.track` and the objective is incomplete.
  - The result is that RestedXP can move native supertracking off the bridge's user waypoint in the middle of an objective step. Never react to this by writing a waypoint straight back: that is a fight with RestedXP.
- `RXPG_ARROW.element` is assigned as a plain field inside private functions (`updateArrowData`, `addon.UpdateGotoSteps` on the private `addon` table). There is nothing reliable to hook, which is why the bridge polls.
- RestedXP also exposes `addon.SendEvent` (AceEvent messages plus WeakAuras `ScanEvents`). `RXP_STEP_ACTIVATED` is sent on `C_Timer.After(0)` after a step activates.
- `_G.RXPGuides` exists but is not a stable integration API.

#### Guide instruction structure (`GuideLoader.lua` `parseLine`, `functions.lua`)

- Each guide line becomes an element in `step.elements`, in guide order. `element.tag` is the command (`goto`, `accept`, `turnin`, `complete`, `fp`, `fly`, `target`, ...).
- `line >> text` sets `element.text`. A bare `>>text` line becomes `{ text, textOnly = true }`; this is the usual "Talk to |cRXP_FRIENDLY_X|r" header. A `+text` line becomes an objective.
- **Waypoint ↔ instruction link:** when a waypoint element is parsed, its `element.parent` is set to `addon.lastObjective`, the most recent *non-textOnly* text-bearing element above it in the same step. RestedXP drops the waypoint once its parent is completed or skipped (`updateArrowData`). A step's first `.goto` usually has no parent, and its instructions follow it.
- A non-optional `.goto` with a radius and no text gets generated text `"Go to %.1f,%.1f (zone)"`. This is just coordinates, so don't use it as a label.
- Quest elements:
  - `.accept`/`.turnin` set `element.title` to the quest name. Their text may contain `*quest*` until the name loads.
  - `.complete` keeps the author's text in `rawtext` (which can be a format string with `%d`) and rewrites `text` with live progress.
  - Helper elements (`.target`, `.use`, `.zoneskip`, ...) only have text when the guide gives `>>`.
- Text markup that appears in guides:
  - `|cRXP_FRIENDLY_|ENEMY_|WARN_|LOOT_|BUY_|PICK_...|r` colour tokens. These are **not** valid hex colours, so strip them before generic `|c` handling.
  - `|T...|t` textures (chat bubble icons, item icons), `|H...|h[...]|h` links, and a literal `\n`.
- Completion: `element.completed` (set by `SetElementComplete`) and `element.skip`. Text-only lines never complete.
- Names may carry NPC IDs: `|cRXP_FRIENDLY_Elatrell Featherlight::251368|r`. RestedXP strips `::%d+` for display (`functions.lua` ~930), and so does the label cleaner.
- `.turnin` elements (`functions.lua` ~1369):
  - `{ tag = "turnin", questId, title = "" -> quest name at runtime, text, flags, reward }`.
  - A negative ID sets `skipIfMissing`. They are **not** `textOnly`, so a `.goto` placed after a turn-in gets it as `parent`.
  - Completed on turn-in via `IsQuestTurnedIn`.
- `.goto` radius semantics: a `.goto` with a radius is marked `skip` when reached (`UpdateGotoSteps`). A `.goto` without a radius stays the step's destination until the step completes. `,0` optional points become `lowPrio`; a negative radius makes them `dynamic`.
  - A radius means "mark reached when within N yd". That is used both for pass-through points (route chains, cave entrances) **and** for "arrive in the objective area". The Forever Windstone step is `#completewith next / .goto 2521,43.53,23.83,7,0 / >>Click on the Crystals / .complete 93552,1`.
  - **Radius alone does not classify a waypoint.** Hybrid (v0.4) still uses it as its conservative turn-in rule; native-first does not.
- `.complete` elements (`functions.lua` ~1789): `{ tag = "complete", questId, obj, objMax, dynamicText = true, rawtext, textOnly = (flags % 2 == 1) }`.
  - `obj` is the 1-based index into `C_QuestLog.GetQuestObjectives(questId)`, whose entries have `type` (`monster`/`item`/`object`/`event`/...), `finished`, `numFulfilled` and `numRequired`.
  - They are `lastObjective` candidates (`dynamicText`), so a `.goto` after them gets them as `parent`.
- `.collect itemId,qty,questId,...`: the quest ID is optional and means item collection, not necessarily a quest-log objective. Native-first ignores it, so it stays on coordinates.
- `#loop` sets `step.loop` (the value is `""`, which is truthy). Forever kill and collect steps are `#loop` steps: a lowPrio `.goto ...,0`, then patrol points `.goto ...,30/40,0`, then `>>Kill ...` text, then one or more `.complete q,n` lines and `.mob` helpers.
- Many Skyborne kill steps have **no** `.goto` at all. The arrow then sits on a separate **patrol step**: `#hidewindow`, `#completewith X`, `#loop`, `.goto` points, then `+1`.
  - `+1` parses to `{ text = "1" }`: no tag, not `textOnly`. It is a placeholder that keeps the step from completing.
  - Example: RestedXP-Skyborne.lua around the Agitators quest 92465, Alliance/!Shaman path. Steps: the patrol; `#completewith next` Windstone `.complete 93552,1`; then Agitators `>>Kill … / *Prioritize … / .complete 92465,1 / .complete 92465,2`.
  - v0.5.0 reported `next instruction is .text` for the `+1`. v0.5.1 delegates such patrol steps to the steps they serve.
- `_G.RXPFrame.activeSteps` (GuideWindow.lua ~667, a named global frame) lists RestedXP's active steps: the sticky steps still running (index order), then the current step, plus a tip window that has no `index`. Each has `step.active = true`. Read-only.
- `step.sticky` is set for every `#completewith` step at load (GuideWindow.lua ~1969). `#hidewindow` sets `step.hidewindow`.
- `.usespell` is a real instruction (not `textOnly`); `.macro` is `textOnly`.
- RestedXP's own quest-state helpers use `C_QuestLog.IsOnQuest` and `C_QuestLog.IsComplete`. Waypoint UI uses `C_QuestLog.ReadyForTurnIn`, `C_Navigation.GetDistance/GetFrame`, `C_SuperTrack.GetHighestPrioritySuperTrackingType` and `Enum.SuperTrackingType`, all unguarded at file scope. Since Waypoint UI runs in Forever, these exist there.

### Waypoint UI (`WaypointUI`)

- Public API: `WaypointUIAPI.Navigation`, documented at the top of `WaypointUI/API.lua`.
- `NewUserNavigation(options)` takes `name, mapID, x, y, flags, iconTexture, r, g, b, requestRecolor, iconType, suppressAudio, stripCoordinates`.
  - **`x` and `y` are percentages, 0–100.** Internally it builds `CreateVector2D(x / 100, y / 100)`.
  - Values outside 0–100 are converted onto the parent map, if possible.
  - It returns the navigation table, or **`nil` without erroring** if `mapID` or x/y are missing or non-numeric, or if `C_Map.CanSetUserWaypointOnMap(mapID)` is false.
  - It sets the native user waypoint and supertracks it. It plays a sound unless `suppressAudio = true`.
- `GetUserNavigation()` returns `{ name, mapID, x, y, flags, ... }`, where **x and y are normalised to 0–1**.
- `IsUserNavigationFlagged(flag)` checks `userNavigation.flags == flag`. The bridge uses the flag `"RXPWaypointBridge"`.
- `ClearUserNavigation(preserveWaypoint?, suppressAdvance?)` clears only the user navigation. `ClearDestination()` also calls `C_SuperTrack.ClearAllSuperTracked()`, so avoid it.
- Waypoint UI's quest presentation depends on native quest supertracking (`C_SuperTrack.GetSuperTrackedQuestID`). The public API cannot attach quest context to a custom coordinate.
- For custom navigation, `Waypoint_DataProvider.CacheSuperTrackingInfo` displays `info.name`, plus a coordinate line unless `info.stripCoordinates` is set.
- **Re-calling `NewUserNavigation` with identical coordinates only renames the navigation.** It skips `C_Map.SetUserWaypoint` when `IsCurrentWaypoint` matches, but still fires `MapPin.NewUserNavigation`, which refreshes the display. With pathfinding enabled, it also re-runs the path request.
- Waypoint UI does not compute quest POI locations itself. Quest-POI location APIs (`C_QuestLog.GetNextWaypoint`, etc.) are unverified in Forever. Native targets are therefore checked with `C_Navigation.GetDistance()` only.
- **Clearing a tracked user waypoint triggers `ClearAllSuperTracked()`.** Waypoint UI's `USER_WAYPOINT_UPDATED` handler calls `C_SuperTrack.ClearAllSuperTracked()` when the user waypoint disappears while supertracked. Any quest supertracking must therefore be set *after* clearing the bridge's waypoint, with a delay. `ClearUserNavigation(false, true)` also removes the native waypoint and suppresses the multi-pin advance.

## Architecture (0.5.0)

The load order is set in the `.toc`. All modules share the addon namespace `ns`.

| File | Namespace | Responsibility |
|---|---|---|
| `Core.lua` | `ns` | Settings (`RXPWaypointBridgeDB`: `autoSync`, `debug`, `strategy` = `"coordinates"` (default for new installs), `"hybrid"` or `"native-first"`; a saved value is always kept), `ns.Print`/`ns.PrintLine`/`ns.Debug`, shared helpers, slash commands (including `/rxpwb mode`), `ADDON_LOADED`/`PLAYER_LOGIN` |
| `LabelResolver.lua` | `ns.Label` | `Resolve(element)` returns `{ label, source, cleaned, shortened, fallback, raw }`, using the priority documented at the top of the file. `Clean(text)` returns `cleaned, wasCleaned, wasShortened`. Reads RestedXP step data. |
| `RXPAdapter.lua` | `ns.RXP` | Reads RestedXP's arrow target. `GetTarget()` returns `(target, reason)`: `reason` is nil when the target is valid, and then `target.key` is set. `target` also has `label`, `labelInfo` and `stripCoordinates`. `target.element` is the raw RestedXP element (read-only). `HasTargetChanged()` is a cheap poll comparison that deliberately ignores text. `ResetObservation()`. `DestinationKey()`. `GetDistanceToTarget()` uses HereBeDragons through `LibStub`, with the element's `wx`/`wy`. |
| `NavigationResolver.lua` | `ns.Nav` | Structure-only analysis, testable offline: `FindTurnIn(element)` (hybrid, unchanged since v0.4) and `FindQuestTarget(element)` (native-first: turn-ins and `.complete` objectives). `GetQuestState(questID, withObjectives)`. `Decide(target, strategy)` returns `{ mode, reason, nativeEligible, kind, classification, questID, questName, questState, objectives, progress, pendingTurnIns, nativeId, tolerance, analysis }`. Native wrappers: `SetNativeQuest()`, `ReleaseNativeQuest()` (only if still supertracked), `IsNativeQuestActive()`, `VerifyNative()`. Reads RestedXP step data and calls `C_SuperTrack`, `C_QuestLog` and `C_Navigation`. |
| `WaypointAdapter.lua` | `ns.WUI` | **Only** place that calls Waypoint UI. `SetNavigation()` (passes `stripCoordinates`), `GetNavigation()`, `IsShowingTarget()` (coordinates), `HasTargetLabel()`, `IsOwnedNavigationTracked()`, `ClearOwnedNavigation()` (bridge-owned only), `GetForeignNavigationName()`, `DescribeOutsideNavigation(expectedQuestID)`. |
| `Sync.lua` | `ns.Sync` | The single controller. `Initialize()`, `Start()`/`Stop()`, `SyncNow()`, `OnStrategyChanged()`, `GetState()`. |
| `tests/` | — | `node tests/run.js` runs `*_test.lua` in fengari against mocked APIs (`npm install --prefix tests` once). The files are `label_test.lua`, `hybrid_test.lua` (the v0.4 regression suite, self-contained; keep it passing unchanged), `native_first_test.lua`, `agitators_test.lua` (the Skyborne patrol-step fixtures) and `vuldren_test.lua` (quest prioritization in a shared circuit). The last three use the shared mocks in `harness.lua`, including `RXPFrame.activeSteps` via `H.setActiveSteps`; `H.verbose` prints debug output on failures. WoW ignores this folder because it isn't in the `.toc`. **Update or extend these tests whenever you change resolver or sync behaviour.** |

### Sync rules (keep these invariants)

- A `C_Timer.NewTicker` runs every 0.25 s and calls `RXP.HasTargetChanged()`, which does only raw field comparisons. A changed target must be stable for 0.2 s before `Evaluate()` runs.
- **Write only when the valid destination key differs from `handledKey`**, or on `/rxpwb sync`. The key is the map plus coordinates rounded to 0.001 %.
- Invalid, stale or missing targets never clear or replace the Waypoint UI destination.
- A key that Waypoint UI rejected (`failedKey`) is not retried until the target changes or `PLAYER_ENTERING_WORLD` fires.
- The `USER_WAYPOINT_UPDATED` and `SUPER_TRACKING_CHANGED` events are **diagnostics only**. They update `state.external` and never trigger a write. That is what prevents sync loops and fights with the player or with RestedXP.
- First evaluation after login or `/rxpwb on`:
  - If a tracked non-bridge navigation exists, mark the key handled and pause.
  - If Waypoint UI already shows the target, record success without writing.
- Automatic writes use `suppressAudio = true`. Manual `/rxpwb sync` keeps the audio.
- **Labels:** if the key equals `handledKey` but the label differs from `handledLabel`, re-send silently as a label update. Only do this while `IsShowingTarget()` is true (bridge-owned, tracked, same coordinates). A failed label update never sets `failedKey`. Text changes alone never trigger an evaluation.

### Hybrid rules (keep these invariants)

- **The handled state is `(handledMode, handledKey, handledQuest/handledId)`.** `Evaluate()` computes the desired state with `Nav.Decide`. It writes only if that differs from the handled state, so repeated evaluations are idempotent.
- **Native only for an eligible turn-in.** All of these must hold:
  - The arrow is on a guide `.goto` that is not pass-through: no radius, not `dynamic`, not `lowPrio`, not `generated`.
  - The turn-in is linked by `parent`, or it is the first pending non-`textOnly` instruction after the waypoint, before the next waypoint.
  - The quest is in the log and ready.
  - Native APIs exist.
  - Never choose native just because a quest ID appears somewhere in the step.
- **Coordinates → native:**
  - Clear only the bridge-owned navigation.
  - Wait `NATIVE_SET_DELAY`, then `SetSuperTrackedQuestID`.
  - After `NATIVE_VERIFY_DELAY`, run `VerifyNative`. It checks: the supertracked quest matches; quest priority (when measurable); `C_Navigation.GetDistance() > 0`; and `|native − RestedXP distance| ≤ 50 yd` (one-sided).
  - Failure → `FailNative`: record `nativeFailed[id]`, release the quest, and fall back to coordinates. Don't retry until `PLAYER_ENTERING_WORLD` or a strategy change.
- **Native → coordinates:** `ToCoordinates` releases the quest only if it is still supertracked, resets `handledKey`, then calls `Apply`.
- **Cancelling stale work:** every transition (`Apply`, `BeginNative`, `ResetHandled`) bumps `generation`, and timer callbacks compare it. `BeginNative` sets the handled state optimistically, so evaluations during a transition see it.
- **Quest events** (`QUEST_LOG_UPDATE`, `QUEST_TURNED_IN`, `QUEST_ACCEPTED`, `QUEST_REMOVED`) schedule one coalesced `Evaluate("quest")` after 0.5 s. This only happens in hybrid or native-first mode, or while native is active. Debug messages about unchanged states are only logged for `"target"` triggers.
- **Native identity comes from `decision.nativeId`:**
  - Hybrid uses `key#quest`, unchanged from v0.4.
  - Native-first uses `kind:quest` (`objective:Q` / `turnin:Q`), so RestedXP cycling `#loop` points and progress updates never re-supertrack.
  - Objective → turn-in for the same quest is an id change, so it is re-verified with the turn-in tolerance.
  - On the same id, a changed `decision.progress` is only logged ("Native objective updated").
- **Patrol references (v0.5.2):** for `#loop` blocks and patrol delegation, `candidate.references` and `decision.references` hold every waypoint of the circuit.
  - `VerifyNative` uses the smallest `|native − point|` across those points. That is still a lower bound on the native target's distance to the circuit.
  - Reason: RestedXP's arrow can sit on the far side of the loop. In game, the arrow point was 161 yd away while Blizzard's marker was 22 yd away inside the area. The old single-point check falsely rejected it with a 139 yd gap.
  - Other candidates still compare against the arrow element only.
- **Retrying failed native targets (v0.5.3):** `nativeFailed[id] = { reason, time, progress }`.
  - `Sync.GetDecisionContext()` passes `blockedReason` = `NativeBlocked` and `currentQuest` to `Nav.Decide`. `Decide` applies `blockedReason` to single candidates; `SelectQuest` applies it to multi candidates.
  - A failure blocks retries until `NATIVE_RETRY_COOLDOWN` (60 s) passes, or the progress changes after `NATIVE_RETRY_MIN` (10 s). Zoning or a strategy change also clears it. There is no retry timer.
  - `FailNative` first re-decides, and if another candidate is eligible it goes to it native → native. Only otherwise does it fall back to coordinates.
- **Manual hold (v0.5.3):** while a non-bridge Waypoint UI navigation is tracked, native → native switches are held regardless of the destination key, because switching quests inside a circuit is not a new RestedXP destination.
- **Verification tolerance comes from `decision.tolerance`:** `TURNIN_TOLERANCE` is 50 yd, `OBJECTIVE_TOLERANCE` is 100 yd. Every verification logs the native and RestedXP distances, the gap and the limit in debug mode.

### Native-first rules (keep these invariants; see the header of `NavigationResolver.lua`)

- The arrow must be on a guide `.goto` with **no own text**: own or generated `>>` text is an explicit travel instruction, so use coordinates.
- **The instruction block comes from RestedXP's structure:**
  - With a `parent`, it is the lines above the waypoint, back to the previous waypoint.
  - Otherwise it is the lines after the waypoint. If another waypoint comes first, the waypoint is an intermediate route point (coordinates), unless `step.loop` is set; then the whole `#loop` circuit is the objective area.
- **Block outcome:**
  - The first pending instruction is a `.turnin` → turn-in candidate.
  - The block's pending instructions are `.complete` objectives of exactly one quest, with no other pending action → objective candidate.
  - Objectives of several quests inside a `#loop` circuit → a multi candidate for `SelectQuest` (v0.5.3).
  - Anything else (several quests outside a loop, an accept, a `+text` objective, `.collect`, ...) → coordinates.
- **Objective eligibility:**
  - The quest is in the log and not complete.
  - `GetQuestObjectives` is available.
  - At least one targeted objective is unfinished.
  - **Every unfinished objective of the quest is one RestedXP targets in this block.** Blizzard picks its own marker among a quest's unfinished objectives.
- **Patrol steps (v0.5.1):** if the block holds nothing but placeholders (untagged `+` lines with no letters), or nothing at all, and the step is a sticky `#loop` (`loop` and `sticky`/`completewith`), analyse the combined elements of every `RXPFrame.activeSteps` entry with a higher index.
  - The block rules then apply to that combined list.
  - A served step with its own pending waypoint → coordinates.
  - Real `+text` objectives never delegate. Neither does a non-sticky loop.
- Text-only headings (`>>text`, `*text`, `.mob`, `.target`, `.macro`) never block an objective.
- **Several quests in a farming circuit (v0.5.3):** `AnalyzeBlock(..., allowMulti)` is true only for own-step `#loop` blocks and patrol delegation. It returns `kind = "multi"` with one entry per quest: `objectives`, `steps`, `firstPos`. Outside loops, several quests are still ambiguous → coordinates.
  - `SelectQuest` checks every quest with `CheckObjective` and skips blocked ones. It then ranks: (1) a text-only line starting with "Prioritize" in a step whose pending quests are exactly that quest (English guide text; RestedXP has no priority field and no `#track` in the Forever guides); (2) RestedXP's current step (active, not sticky, no `completewith`); (3) `context.currentQuest` (the bridge), then the WoW-supertracked quest; (4) guide order (lowest step index, then line order).
  - `decision.candidates` lists every quest's state; `decision.selection` says why the winner won.
  - The selected quest's identity is `objective:Q`, so objective completion switches native → native.
- Never classify by quest names, and never pick between quests outside a `#loop` circuit.
- **Manual waypoints:** while a non-bridge Waypoint UI navigation is tracked, mode changes at the same destination key are held. A new destination key resumes, as in v0.2.
- **RestedXP supertracking:** RestedXP supertracking the bridge's own native quest is not an outside change (`DescribeOutsideNavigation(expectedQuestID)`). Other quests RestedXP supertracks are recorded as outside changes and never fought.

## Current state (0.5.3)

- v0.2 coordinate mirroring and v0.4 hybrid turn-ins have passed in-game tests; the developer was happy with hybrid. Commit `5dd7752` is the v0.4 checkpoint.
- v0.5 adds the experimental `native-first` strategy. It needs in-game acceptance, and its verification limits may need tuning from the debug values.
- v0.5.1 fixes native-first on RestedXP patrol steps (the Agitators bug) and adds `/rxpwb inspect`. `Sync` records `lastVerification`, so verification failures show up separately from classification failures.
- The label cleaner requires a letter, so `+1` is never a label.
- v0.5.2 checks a patrol's native target against the whole circuit, which fixed the in-game false rejection on Agitators.
- v0.5.3 picks a quest when several share a farming circuit, and retries failed native targets on a policy instead of blocking them until zoning.
- `coordinates` and `hybrid` behaviour is unchanged.
- Offline tests (`node tests/run.js`) cover labels, hybrid (as regression), and native-first: kill, collect and interact classification, loops, route chains, parent-linked blocks, ambiguity, coverage, verification and tolerance, objective → turn-in, progress events, manual overrides, stale callbacks and strategy switching. The mocks assume WoW supertracks one target at a time; that is unverified in Forever.

## Roadmap

1. 0.1: proof of concept with manual sync (done).
2. 0.2: automatic route mirroring (done).
3. 0.3: step descriptions (done).
4. 0.4: hybrid navigation for quest turn-ins (done).
5. 0.5: native-first quest navigation (implemented, experimental).
6. Next: validate native-first in game, tune the limits, and decide the default strategy.
7. 1.0: optional visual-only hiding of the RestedXP arrow, explicit pause and resume, world-coordinate targets, minimal settings, and validation against the launch client.

## Testing checklist for any change

- Log in with both dependencies enabled, then with each one disabled. There should be no Lua errors (turn on `/console scriptErrors 1`).
- Run `/rxpwb status` on a step with a waypoint, on a step without one, and after reaching a waypoint.
- With `/rxpwb debug` on, follow a route with several `.goto` waypoints. Waypoint UI must follow A → B → C, with exactly one write per destination.
- Run `/rxpwb sync` and confirm the Waypoint UI destination matches RestedXP's map and coordinates.
- Set a manual Waypoint UI destination. The bridge must not overwrite it until RestedXP's destination changes.
- Run `/reload` and confirm the bridge loads cleanly, settings persist, and an unchanged destination is not rewritten.
- Check that the label matches RestedXP's visible instruction for the arrow's waypoint. If it doesn't, use `/rxpwb status` with debug on to see the label source and raw text.
- Hybrid: a turn-in with intermediate waypoints must follow every waypoint, then go native at the NPC. After the turn-in it must return to coordinates. `/rxpwb status` shows the decision reason.
- Native-first: kill and collect objectives at their area should go native, with no writes on progress. Routes before them must stay coordinates. Check the "Native target check" debug values.
- If native-first misclassifies a step, ask for `/rxpwb inspect` output first. It shows every instruction's role, the served steps, quest state and the last verification. Then turn the real guide step into a fixture in `tests/`.
- Run `node tests/run.js` before handing work back.
