# AGENTS.md: RestedXP Waypoint

Context and rules for AI coding agents (Codex and others) working on this repository.

## What this project is

An **unofficial** World of Warcraft **Forever** companion addon. It mirrors the waypoint that **RestedXP Guides** has resolved into **Waypoint UI**'s in-world navigation. RestedXP is the route planner. Waypoint UI is the renderer. Both addons are required for live synchronization. RestedXP Waypoint is not affiliated with either project.

The display name, addon folder, and settings panel title are **RestedXP Waypoint**. The project was called RXP Waypoint Bridge through v0.5.7. The WoW private addon table is passed as the second Lua chunk argument and each module refers to it as local `RXPW`; it is not published as a new global.

The developer tests every change by hand in game with `/reload`. There is no build step: the repository folder is junctioned straight into the client's `Interface\AddOns`. Every file must load as-is in WoW.

## Environment

- Client: WoW Forever beta at `F:\World of Warcraft\_classic_beta_`, build 1.60.1. Interface `16001`, game type `camelot`.
- TOC: `RestedXPWaypoint_Camelot.toc`. The `_Camelot` suffix is the Forever client flavour; Waypoint UI ships `WaypointUI_Camelot.toc` the same way.
- Development repository: `E:\Dev\RestedXPWaypoint`.
- WoW addon folder: `F:\World of Warcraft\_classic_beta_\Interface\AddOns\RestedXPWaypoint`, junctioned to the development repository. If the checkout is still at its former path (`E:\Dev\RXPWaypointBridge`), close VS Code and WoW and run `tools\Migrate-Install.ps1` from a PowerShell window outside the repository.
- Installed dependencies, which you may read but **must never modify**:
  - `F:\World of Warcraft\_classic_beta_\Interface\AddOns\RXPGuides` (v4.11.23)
  - `F:\World of Warcraft\_classic_beta_\Interface\AddOns\WaypointUI` (1.7.3)
- Lua 5.1 (WoW). No Lua interpreter is installed locally. For syntax checks, use a parser such as `luaparse` through Node in a temporary directory.
- SavedVariables: `RXPWDB`. The development profile's on-disk values were copied to `RestedXPWaypoint.lua`; the prior `RXPWaypointBridge.lua` and its backup were retained. Confirm in-game settings after restart when a recent session value may not have been written yet.
- Do not assume a Retail-only API exists. Check the installed addons' code, or guard the call at runtime.

## Engineering rules

1. **RestedXP controls the intended route.** Mirror `RXPG_ARROW.element`. Do not re-implement RestedXP's waypoint selection.
2. **Preserve intermediate waypoints.** A multi-`.goto` route must appear in Waypoint UI as the same sequence.
3. **Never let quest supertracking silently override an explicit RestedXP travel waypoint.** Native quest tracking may replace coordinates only under the documented hybrid/native-first eligibility and verification rules below. A step containing a quest ID is not a reason to switch.
4. **Prefer public APIs.** For Waypoint UI, use only `WaypointUIAPI.Navigation` as documented in `WaypointUI/API.lua`. Do not use undocumented options such as `syncNativeWaypoint` or `coordinatesAreNormalized`, or internal modules. RestedXP has no public waypoint API. Keep every read of its internals in the RestedXP-facing files (`RXPAdapter.lua`, `LabelResolver.lua`, `NavigationResolver.lua`).
5. **Never modify RestedXP or Waypoint UI**, either on disk or by replacing their functions at runtime. Hooks must be non-destructive (`hooksecurefunc`) and justified. **One approved exception (v0.6.0, requested by the developer):** the settings page's "Hide RestedXP Arrow" checkbox reads and writes RestedXP's own user option `settings.profile.disableArrow`, exactly as RestedXP's checkbox does. It goes only through `RXP.IsArrowHidden` / `RXP.SetArrowHidden` in RXPAdapter.lua, using the AceAddon registry plus `DrawArrow` and `UpdateMap()`. The option is visual only: `RXPG_ARROW.element` keeps updating.
6. **Validate external addon data.** Type-check every field read from another addon. Missing or unexpected data must produce a message or a no-op, never an uncaught Lua error.
7. **Only clear navigation the bridge created.** Check ownership with `IsUserNavigationFlagged("RestedXPWaypoint")`. Do not call `ClearDestination()` routinely: it also clears all native supertracking.
8. **Avoid unnecessary polling and repeated API calls.** Write to Waypoint UI only when the target actually changes. No heavy `OnUpdate` work.
9. **Maintain WoW Forever compatibility.** Guard optional APIs, for example `C_AddOns and C_AddOns.IsAddOnLoaded`.
10. **Keep it modular as it grows.** RestedXP reads belong only in `RXPAdapter.lua` (targets), `LabelResolver.lua` (instruction text) and `NavigationResolver.lua` (turn-in detection; also the only place that calls `C_SuperTrack` and `C_QuestLog`). Waypoint UI calls belong only in `WaypointAdapter.lua`, and sync decisions in `Sync.lua`. Add new modules when a milestone needs them, not before.
11. **Prefer clear, maintainable Lua** over clever code. Use locals, no accidental globals, and the shared addon namespace (`local addonName, RXPW = ...`).
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
- **Step-change messages are incomplete (verified for v0.5.9).**
  - RestedXP sends AceEvent-3.0 messages through a registry shared by every embedder: `RXP_STEP_ACTIVATED` (next frame) and `RXP_STEP_DEACTIVATED` (sync), from SetStep. `RXP_STEP_COMPLETE` and `RXP_OBJECTIVE_COMPLETE` are queued, and suppressed within 1 s of a SetStep.
  - Nothing is sent for manual checkbox skips (`ActiveStepElementPostClick`), waypoint skips, or a sticky step becoming active again.
  - The bridge therefore uses a content signature (F7), not these messages, and doesn't embed AceEvent.
- RestedXP calls `C_SuperTrack.SetSuperTrackedQuestID` itself in these places:
  - `GuideWindow.lua`, on step activation, for `step.track`.
  - The `.turnin` element handler (`functions.lua` ~1511), on initial processing. The installed `.accept` handler does not set supertracking (see `docs/QUEST_TRANSITIONS.md`).
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
- Completion: `SetElementComplete` sets `element.completed` **and** `element.skip`; a reached waypoint sets `skip`.
  - **Render flag trap:** RestedXP's guide window (GuideWindow.lua ~1316–1328) sets `completed = true` on every text-only or text-less element **when it draws the step**: `>>` headings, `*` notes, `.mob`/`.target`, every `.goto`. `#hidewindow` steps aren't drawn, so they keep the parser's flags.
  - So `completed` alone never means done. `IsDone` (LabelResolver and NavigationResolver, kept identical) is `skip`, or `completed` on a non-textOnly element with text.
  - Treating the render flag as progress hid quest context and froze labels before v0.5.6. `harness.lua`'s `newStep` simulates the flag (`{ raw = true }` opts out), so tests see what the game sees.
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
- `_G.RXPFrame.activeSteps` (GuideWindow.lua ~667, a named global frame) lists RestedXP's active steps: the sticky steps still running (index order), then the current step, plus a tip window that has no `index`. Each has `step.active = true`. Read-only. **It is one table that SetStep wipes and refills in place** (GuideWindow.lua 667, 811), so compare contents, never its identity.
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
- `IsUserNavigationFlagged(flag)` checks `userNavigation.flags == flag`. The bridge uses the flag `"RestedXPWaypoint"`.
- `ClearUserNavigation(preserveWaypoint?, suppressAdvance?)` clears only the user navigation. `ClearDestination()` also calls `C_SuperTrack.ClearAllSuperTracked()`, so avoid it.
- Waypoint UI's quest presentation depends on native quest supertracking (`C_SuperTrack.GetSuperTrackedQuestID`). The public API cannot attach quest context to a custom coordinate.
- For custom navigation, `Waypoint_DataProvider.CacheSuperTrackingInfo` displays `info.name`, plus a coordinate line unless `info.stripCoordinates` is set.
- **Re-calling `NewUserNavigation` with identical coordinates keeps the destination, but it is still a new navigation (verified for v0.5.9).**
  - It skips `C_Map.SetUserWaypoint` when `IsCurrentWaypoint` matches, but it always builds a new table, calls `SetSuperTrackedUserWaypoint` and fires `MapPin.NewUserNavigation`.
  - That event resets `Waypoint_Director`: it hides the frames, clears the cache and replays the intro animation plus the WaypointShow/PinpointShow sound. `suppressAudio` only covers the "new navigation" sound.
  - With pathfinding enabled (off by default; it needs a FarstriderLib or Mapzeroth provider), the path is rebuilt synchronously and the path-step waypoint recreated. With an active path the native waypoint is the path step, so a rename first moves it back to the destination.
  - There is no throttling, deduplication or public rename API. `suppressPathfinding` and `syncNativeWaypoint` are undocumented; don't use them.
- **Session persistence.**
  - The custom navigation is saved per character (`WaypointDB_Local.mapPinSessionData.userNavigation`, `CreatePinData` fields: `name, mapID, x, y` (0–1), `flags, iconTexture, iconType, r, g, b, stripCoordinates, superTracked`).
  - On load it is restored as-is, without NewUserNavigation, so `IsUserNavigationFlagged` is true at once.
  - Waypoint UI's `ADDONS_UNLOADING` handler clears supertracking when pathfinding is off. A restored navigation is therefore usually present but not tracked (`IsUserNavigationTracked` false).
- **Custom waypoint presentation (public API):**
  - `name` is the only text line. The second line is the coordinates, or nothing with `stripCoordinates`. There is **no subtitle and no quest-context field**.
  - `iconTexture`, `iconType` (`TEXTURE`/`ATLAS`) and `requestRecolor` become the marker's context icon for a tracked custom navigation (`Waypoint_DataProvider.GetContextIconForPinData`).
  - Native quest icons are Waypoint UI's own files in `Art\Icons`, e.g. `CompleteQuest` and `IncompleteQuest` (`Waypoint_ContextIcon.lua`). Those names are an implementation detail.
  - "Ready for turn-in" is Waypoint UI's private locale string.
  - A same-coordinate `NewUserNavigation` updates the name and icon without moving the native waypoint, but it replays the marker intro (above). Sync sends such updates at most once per `PRESENTATION_MIN_INTERVAL` (2 s).
- Waypoint UI does not compute quest POI locations itself. Quest-POI location APIs (`C_QuestLog.GetNextWaypoint`, etc.) are unverified in Forever. Native targets are therefore checked with `C_Navigation.GetDistance()` only.
- **Clearing a tracked user waypoint triggers `ClearAllSuperTracked()`.** Waypoint UI's `USER_WAYPOINT_UPDATED` handler calls `C_SuperTrack.ClearAllSuperTracked()` when the user waypoint disappears while supertracked. Any quest supertracking must therefore be set *after* clearing the bridge's waypoint, with a delay. `ClearUserNavigation(false, true)` also removes the native waypoint and suppresses the multi-pin advance.

## Architecture (0.5.0)

The load order is set in the `.toc`. All modules share the addon namespace `RXPW`.

| File | Namespace | Responsibility |
|---|---|---|
| `Core.lua` | `RXPW` | Settings (`RXPWDB`: `autoSync`, `debug`, `strategy` = `"coordinates"`, `"hybrid"` (recommended default for new installs) or `"native-first"`; a saved value is always kept; v0.6.0 adds `questIcons`, `serviceIcons`, `customColors`, all default `true`). **`RXPW.Config` (v0.6.0) is the only way a setting changes:** `Get`, `GetDefault`, `Set(key, value)` (validates, saves, applies the existing behaviour and notifies listeners), `Toggle`, `RestoreDefaults`, `RegisterListener`, `Notify`. The slash commands and the settings page both call it. `/rxpw config` (`settings`, `options`) opens the page. `RXPW.Print`/`RXPW.PrintLine`/`RXPW.Debug`, shared helpers, slash commands (including `/rxpw mode`), `ADDON_LOADED`/`PLAYER_LOGIN` |
| `LabelResolver.lua` | `RXPW.Label` | `Resolve(element)` returns `{ label, source, cleaned, shortened, fallback, raw }`, using the priority documented at the top of the file. `Clean(text)` returns `cleaned, wasCleaned, wasShortened`. Reads RestedXP step data. |
| `RXPAdapter.lua` | `RXPW.RXP` | Reads RestedXP's arrow target. `GetTarget()` returns `(target, reason)`: `reason` is nil when the target is valid, and then `target.key` is set. `target` also has `label`, `labelInfo` and `stripCoordinates`. `target.element` is the raw RestedXP element (read-only). `HasTargetChanged()` is a cheap poll comparison that deliberately ignores text. `ResetObservation()`. `GetArrowElement()` (raw element, no label work, for the activity check). `DestinationKey()`. `GetDistanceToTarget()` uses HereBeDragons through `LibStub`, with the element's `wx`/`wy`. |
| `NavigationResolver.lua` | `RXPW.Nav` | Structure-only analysis, testable offline: `FindTurnIn(element)` (hybrid; v0.5.8 adds explicit travel protection and parent validation) and `FindQuestTarget(element)` (native-first: turn-ins and `.complete` objectives). `GetQuestState(questID, withObjectives)`. `Decide(target, strategy)` returns `{ mode, reason, nativeEligible, kind, classification, questID, questName, questState, objectives, progress, pendingTurnIns, nativeId, tolerance, analysis }`. Native wrappers: `SetNativeQuest()`, `ReleaseNativeQuest()` (only if still supertracked), `IsNativeQuestActive()`, `VerifyNative()`. Reads RestedXP step data and calls `C_SuperTrack`, `C_QuestLog` and `C_Navigation`. |
| `WaypointAdapter.lua` | `RXPW.WUI` | **Only** place that calls Waypoint UI. `SetNavigation()` (passes `stripCoordinates`), `GetNavigation()`, `IsShowingTarget()` (coordinates), `HasTargetLabel()`, `IsOwnedNavigationTracked()`, `ClearOwnedNavigation()` (bridge-owned only), `GetForeignNavigationName()`, `DescribeOutsideNavigation(expectedQuestID)`, `HasNavigationWithFlag(flag)` (stored flag plus documented `IsUserNavigationFlagged`; tracked or not), `ClearNavigationWithFlag(flag)`, `ResolveAppearance(presentation)` (v0.6.0: icon/tint after the appearance settings; used by Sync and Preview), `CanOpenSettings()` / `OpenSettings()` (Waypoint UI's documented `WaypointUIAPI.OpenSettingsUI`). |
| `Sync.lua` | `RXPW.Sync` | The single controller. `Initialize()`, `Start()`/`Stop()`, `SyncNow()`, `OnStrategyChanged()`, `GetState()`. |
| `Preview.lua` | `RXPW.Preview` | `/rxpw preview` testing aid: a temporary Waypoint UI navigation ahead of the player (`DISTANCES`: close 0.008 map, far 4×; the slash parser passes the rest of the line, e.g. `all far`) (`C_Map.GetPlayerMapPosition`, HereBeDragons fallback, `GetPlayerFacing`) with the flag `RestedXPWaypoint-Preview`, `WUI.GetPresentationIcon` and the quest tints. It pauses automatic sync (`Sync.Stop`, `db.autoSync` untouched); `off` clears only the preview flag (`WUI.ClearNavigationWithFlag`) and restarts sync if it was running. `WUI.SetNavigation` accepts `target.flags` for this. `RemoveOrphan()` (v0.5.9) removes a navigation with exactly that flag when no preview session is active (restored by Waypoint UI after /reload). Sync calls it at its first evaluation, and `off` calls it when no session is active. Add new icons to `ENTRIES` so they can be previewed; the `default` entry shows DefaultWaypoint. The panel API (v0.6.0) is `GetEntries`, `GetEntryArt`, `GetState` (including `orphan`), `Show(key, distance)`, `Next`, `ShowAll` and `Off`; `Command` dispatches to the same functions. Previews follow the appearance settings. |
| `SettingsPanel.lua` | `RXPW.SettingsPanel` | The single settings page (v0.6.0).<br>- **Registration:** `Initialize()` (called once at ADDON_LOADED by Core) registers exactly one canvas category with `Settings.RegisterCanvasLayoutCategory` + `RegisterAddOnCategory`, with a guarded `InterfaceOptions_AddCategory` fallback. `Open()` calls `Settings.OpenToCategory(category:GetID())` through pcall, and not in combat.<br>- **Construction:** built on first show from plain Frame, Button, ScrollFrame and Slider frames with colour textures, using Waypoint UI's layout tokens. No Blizzard widget templates and no Waypoint UI art.<br>- **State:** keeps no settings of its own: controls call `RXPW.Config.Set`, preview buttons call `Preview.Show/Next/ShowAll/Off`, and a Config listener refreshes the page.<br>- **No OnDefault:** Blizzard's "All Settings" reset must not change the strategy. |
| `tests/` | — | `node tests/run.js` checks TOC metadata and module order, then runs `*_test.lua` in fengari against mocked APIs (`npm install --prefix tests` once). The files include `rebrand_test.lua` (identity, saved settings and command dispatch), `transitions_test.lua` (v0.5.7 F1–F3 reliability), `label_test.lua`, `hybrid_test.lua` (the v0.4 regression suite, self-contained; keep its navigation expectations unchanged), `native_first_test.lua`, `agitators_test.lua` (the Skyborne patrol-step fixtures), `vuldren_test.lua` (quest prioritization in a shared circuit), `windstones_test.lua` (helper continuity and quest context), `icons_test.lua` (quest icons on coordinate waypoints), `services_test.lua` (service icons), `default_icon_test.lua` (DefaultWaypoint priority, settings, preview, foreign navigation), `preview_test.lua` and `progress_test.lua` (render flags, presentation in every strategy, live progress labels), `stage3_test.lua` (F4–F6) and `settings_test.lua` (v0.6.0 page, Config, appearance effects, preview controls, restore defaults; the harness mocks widgets, `Settings`, `StaticPopup` and `InCombatLockdown`), `stage4_test.lua` (F7 activity, F8 area re-verification, orphaned preview, rename rate limit; harness: `wui.pathfinding`, `wui.markerResets`/`pathBuilds`, `H.restoreSession`, `Sync.GetState().counters`). All but the first two use the shared mocks in `harness.lua`, including `RXPFrame.activeSteps` via `H.setActiveSteps`; `H.verbose` prints debug output on failures. WoW ignores this folder because it isn't in the `.toc`. **Update or extend these tests whenever you change resolver or sync behaviour.** |

### Sync rules (keep these invariants)

- A `C_Timer.NewTicker` runs every 0.25 s and calls `RXP.HasTargetChanged()`, which does only raw field comparisons. A changed target must be stable for 0.2 s before `Evaluate()` runs.
- **Write only when the valid destination key differs from `handledKey`**, or on `/rxpw sync`. The key is the map plus coordinates rounded to 0.001 %.
- Invalid, stale or missing targets never replace active navigation. While externally blocked, a provably obsolete inactive bridge marker may be retired with `ClearUserNavigation(true, true)`, preserving native tracking and pins. Missing current data alone is not proof of obsolescence.
- A key that Waypoint UI rejected (`failedKey`) is not retried until the target changes or `PLAYER_ENTERING_WORLD` fires.
- The `USER_WAYPOINT_UPDATED` and `SUPER_TRACKING_CHANGED` events update diagnostics, observe external overrides and may cancel pending native work after an external selection. They never write directly. After a genuine override ends, the existing coalesced evaluation may resume fresh RestedXP navigation following one second of confirmed idle tracking, with a final ownership check.
- First evaluation after login or `/rxpw on`:
  - If a tracked non-bridge navigation exists, mark the key handled and pause.
  - If Waypoint UI already shows the target, record success without writing.
  - **Login/reload quest exception:** with auto-sync enabled at login, initial acquisition may record one inherited quest as unknown-origin baseline tracking. It does not block RXP, even without current quest context. A different quest, any external pin or the first valid RXP observation closes acquisition; new selections retain protection. Never label this snapshot as proof of manual/automatic intent or whitelist guide quests. Pins remain protected on reload. Sync restart, preview exit and zoning never reopen initial acquisition. See `docs/STARTUP_TRACKING.md` for the same-quest/pre-reload intent limitation.
- Automatic writes use `suppressAudio = true`. Manual `/rxpw sync` keeps the audio.
- **Labels:** if the key equals `handledKey` but the label (or icon) differs from `handledLabel` (`handledIcon`), re-send silently as a label update. Only do this while `IsShowingTarget()` is true (bridge-owned, tracked, same coordinates). A failed label update never sets `failedKey`.
  - **Live progress (v0.5.6):** labels keep progress counts ("1/15 Windstone Cluster"). Quest events evaluate in every strategy. `CheckLabel` in the ticker compares RestedXP's label for the handled coordinate destination once per `LABEL_CHECK_INTERVAL` (1 s) against `state.watchedLabel`. On a change it schedules the same coalesced quest evaluation, once per change. This is the only text-triggered evaluation; `HasTargetChanged` still ignores text.
- **Activity observation (v0.5.9, F7).**
  - `CheckActivity` in the ticker compares `Nav.GetActivitySignature(RXP.GetArrowElement())` once per `ACTIVITY_CHECK_INTERVAL` (1 s). The signature covers the index, active flag and per-element `IsDone` of the arrow's step and every indexed active step.
  - A change schedules the same coalesced evaluation. `Evaluate` records the signature.
  - Redraw `completed` flags and table identities never count, because `IsDone` ignores the render flag. No decision runs while the signature is stable.
- **Presentation rate limit (v0.5.9).** `RefreshLabel` writes a same-destination presentation change at most `PRESENTATION_MIN_INTERVAL` (2 s) after the previous successful write. Otherwise it sets `presentationRetryAt` and schedules the coalesced evaluation for then, which applies the latest presentation. Destination writes are never delayed.

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
- **Pending-transition safety (v0.5.7, F1–F3):** a pending operation records its automatic/manual origin, destination/element identity, strategy and navigation snapshot. A shared gate before setting, verifying or falling back requires fresh valid RXP data and the same native activity. Never substitute a captured target for invalid current data. External navigation changes cancel the operation and hold the interrupted destination/activity without writing or releasing anything. `Stop` cancels automatic work and queued automatic evaluations; explicit manual sync remains available while off. Preview supersedes either origin. Leaving/entering the world invalidates pending work; no automatic writes run during loading. `tests/transitions_test.lua` exercises callback timing, observable destinations and writer history.
- **Quest events** (`QUEST_LOG_UPDATE`, `QUEST_TURNED_IN`, `QUEST_ACCEPTED`, `QUEST_REMOVED`) schedule one coalesced `Evaluate("quest")` in every strategy: acceptance/turn-in after 0.3 s with the 0.2 s target quiet period and a 1 s burst ceiling; other quest events after 0.5 s (v0.5.6; before that, not in coordinates mode, which left progress labels stale). Debug messages about unchanged states are only logged for `"target"` triggers.
- **Native area re-verification (v0.5.9, F8).**
  - `decision.activity` is the native id, objective set, arrow step, the steps holding the quest work and a circuit marker; hybrid uses its `key#quest` id. `decision.anchor` is a value copy of the arrow's world position, outside circuits only.
  - After verification, Sync stores `handledActivity`/`handledAnchor`. With the same id, a different activity, or an anchor more than `decision.tolerance` away, starts `BeginNative(..., reverify = true)`: no clear and no supertracking call; the gate and `FailNative` work as for transitions, and verification uses the fresh decision.
  - It is skipped while another waypoint is tracked or the quest is no longer the active navigation.
  - An abandoned re-verification keeps the established native state (no hold).
  - `nativeFailed[id].activity` allows an immediate retry for a different activity.
  - Helper continuity (`decision.continuity.ok`) records the activity directly.
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
  - With a valid `parent` in the same active step, it is the instruction block before the parent-linked waypoint group. Consecutive waypoints may be crossed only when they share that exact parent; different parents remain boundaries.
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
- **Helper waypoints (v0.5.4):**
  - Own `.goto` text without letters (`>>1`) is a placeholder, not a travel instruction.
  - A sticky non-loop step with exactly one pending waypoint and no instructions is a **helper**. Its anchor is found by `FindAnchorStep`: the active step matching `completewith` by `label`, or index+1 for `next`.
  - `FindQuestTarget` returns `nil, reason, { role = "helper", helper = { step, anchor, candidate } }`. The candidate is `AnalyzeBlock` over the anchor's elements. A helper is never a native candidate by itself.
  - `FindQuestTarget` now returns `(candidate, reason, info)`, where `info.role` is one of: travel instruction, route point, turn-in destination, objective area, loop circuit, patrol, helper, other. `info.routeCritical` is true for travel instruction and route point.
- **Native continuity (`DecideHelper`), turn-ins only.** All of these must hold:
  - the anchor candidate is a turn-in of `context.currentQuest`, and `context.currentKind == "turnin"`
  - no transition is pending (`context.pending`)
  - the quest is in the log and ready
  - `Nav.IsNativeQuestActive`
  - `VerifyNative` against the helper point passes, with `TURNIN_TOLERANCE`
  - Then the decision is native with the same `turnin:Q` id, so Sync writes nothing. Objectives never use continuity, because their areas can have several clusters (the Skyborne druid helper).
- **Quest context (`decision.context`):** built only from a structural association, plus a quest that is in the log right now. Never cache it across evaluations.
  - `Sync.PrepareTarget` (every strategy since v0.5.6; `PrepareCoordinateTarget` adds the logging) replaces **only** fallback labels (`labelInfo.fallback`). It uses the quest title, plus "Ready for turn-in" (`QUEST_WATCH_QUEST_READY`, else English) when the log says ready, and `WUI.GetQuestIcon(ready)`, which only returns an icon for Waypoint UI 1.7.x.
  - `HasTargetLabel` compares the icon too, so icon changes go through the silent same-coordinate rename.
- **Appearance settings (v0.6.0).**
  - `WUI.ResolveAppearance` drops the icon when `questIcons`/`serviceIcons` is off, and the r/g/b when `customColors` is off.
  - Without an icon, Waypoint UI draws its generic custom-navigation icon, recoloured with the marker colour. Without r/g/b, it uses its "Other" colour or the player's own Waypoint UI colours, and a supplied icon keeps its own colours. The bridge's greyscale service icons then look neutral.
  - The colour still applies only to recognised destinations that have a shippable icon, shown or not.
  - **Default icon:** when there is no quest or service icon (no presentation, or a quest icon this Waypoint UI version cannot show), `ResolveAppearance` returns `WUI.GetDefaultIcon()` (`Art/Icons/DefaultWaypoint`, the logo's arrow silhouette, brightness-only) with **no r/g/b**. `WUI.SetNavigation` adds the documented `requestRecolor = true` for that icon only (and `HasTargetLabel` compares it), so Waypoint UI desaturates it and tints it with its own custom-waypoint colour ("Other", or the player's Waypoint UI colour), the same colour as frame, text and beam (`Waypoint.GetTintColorInfo`), as for its generic icon. No setting changes it; Quest/Service Icons off still gives those destinations Waypoint UI's generic icon. Only bridge-owned and preview navigation ever carry it.
  - A change calls `Sync.OnPresentationChanged()`, a coalesced evaluation. Only a tracked bridge-owned coordinate destination is renamed, within the rename interval.
  - Native markers are never affected.
- **Presentation is separate from navigation (v0.5.6).** RestedXP decides where the waypoint is; the quest context decides its icon, colour and fallback label. This applies in every strategy.
  - `Nav.GetContextDecision(target, decision)` returns the decision itself when it came from the native-first analysis (native-first, coordinates). In hybrid, it repeats the analysis with the coordinates strategy and no Sync context. That never selects native mode, runs no continuity check and keeps no retry bookkeeping.
  - Never let presentation change coordinates or the route-critical classification, and never let the strategy change presentation.
- **Coordinate marker icons (v0.5.5):** `Nav.GetPresentation(target, decision)` returns the quest and its icon state (plus `kind` and, from the step path, `title` for status).
  - The quest comes from `decision.context` if present, else the arrow step's first pending actionable instruction (`StepActivity`: accept, turn-in, or objective; a non-quest action first means none).
  - The state is `Available` (accept, quest not in the log), `Incomplete`, or `Complete` (quest ready). A quest that is not in the log has no icon, except for accepts.
  - `Nav.GetQuestIconType` mirrors `Waypoint_ContextIcon`'s classification (Campaign, Important, Legendary, Calling, Meta, Recurring, Repeatable; otherwise "").
  - `WUI.GetQuestIcon(status, iconType)` builds `Art\Icons\<State><Type>Quest`, for Waypoint UI 1.7.x only.
  - Labels are unchanged: only fallback labels are replaced, by the quest context.
  - `/rxpw status` shows these independently: `Navigation:` (mode, role, route-critical, coordinates), `Quest context:` (the decision's context, else the presentation's step quest), `Marker icon:` and `Marker texture:`, and `Objective label:` (RestedXP's, expected, displayed, stale).
  - `state.handledIcon` plus an icon-aware check in `EnsureCoordinates` mean an icon-only change (e.g. the quest becoming ready) goes through the silent same-coordinate rename.
- **Coordinate marker colour (v0.5.5):** `GetPresentation` also returns `tintKey`, mirroring `DataProviderUtil.GetTrackingType`: incomplete → IncompleteQuest; complete → RepeatableQuest (Recurring/Meta/Calling), ImportantQuest (Important) or NormalQuest; Available → nil, i.e. Waypoint UI's "Other" colour.
  - `WUI.GetQuestTint` returns Waypoint UI 1.7.x's default `Enum.ColorRGB01` values. These are passed as `r`/`g`/`b`, and only together with a quest icon.
  - **Quest gold (developer-approved):** normal (`iconType == ""`) Available and Complete quests use `QUEST_GOLD` `#FFD100` (classic WoW quest yellow) instead of "Other"/NormalQuest, tint name `QuestGold`, with the bridge's tint-ready copies `Art/Icons/QuestAvailable`/`QuestComplete` (Waypoint UI's `AvailableQuest`/`CompleteQuest` with identical alpha, brightness-only; `build_icons.py` `as_glyph`, source = Waypoint UI's `Art/Icons` folder). `WaypointAdapter.lua` `GoldQuestIcon` decides both icon and colour; with `customColors` off Waypoint UI's original icons are used, uncoloured. Quest types, incomplete quests, services and the default icon are unchanged. Waypoint UI ships no licence file; shipping these derived copies was the developer's decision.
  - Waypoint UI forces icon recolor on when `r`/`g`/`b` are set (`Waypoint.GetTintColorInfo`), so the icon is desaturated and tinted slightly. That is unavoidable through the public API.
  - `HasTargetLabel` compares `r`/`g`/`b` as well.
- **Service icons (v0.5.6):** when the step's first pending actionable instruction is not quest-related, `Nav.GetPresentation` falls back to `StepService(step)`. The first pending service instruction decides:
  - `.fp`/`.fly` → FlightMaster
  - `.home` → Innkeeper
  - `.stable` → StableMaster
  - `.bankdeposit`/`.bankwithdraw` → Banker
  - an `.xp` that is not `textOnly` (skip-step) and not `reverseLogic` (`<`) → Grind
  - `.trainer`/`.train` → ProfessionTrainer if the step has `.skill`, else ClassTrainer; no icon if the step has `.use` (books)
  - `.vendor` → FoodAndDrink if a pending `.collect` item is Consumable / Food & Drink (`Nav.IsFoodOrDrink` via `GetItemInfoInstant`, classID 0 / subclass 5), else Repair if the vendor text mentions repair, else Vendor
  - Service → icon file mapping is in `WUI.GetServiceIcon`. Vendor and Banker share `Bags.blp`.
  - The result is `{ service, source }`. `WUI.GetServiceIcon` builds `Interface\AddOns\<addon>\Art\Icons\<Service>` (the bridge's own files, no version gate). `WUI.GetPresentationIcon` resolves quest or service. Service icons get `r`/`g`/`b` from the service palette (`SERVICE_PALETTE` in WaypointAdapter.lua, the user's design spec; `WUI.GetServiceTint`, `WUI.GetPresentationTint`).
  - Waypoint UI applies that one colour to the frame, text, pinpoint, arrow **and beam**, and forces icon recolor (desaturate plus tint). The palette's beam, highlight and shadow values are reference only, because there is no public input for them.
  - Icons are built brightness-only (`TINT_READY` in tools/build_icons.py) so the tinted result reads well. Don't add full-colour icons expecting them to keep their colours.
- **Icon assets:** `Art/Icons/*.blp` are generated by `tools/build_icons.py`. Waypoint UI's recipe: 64×64 canvas, glyph about 54×54, thin soft black edge (the source's dark rim is peeled, `PEEL = 2`, then a 1 px outline at 55% opacity is added), BLP2 colour encoding 3 (raw BGRA), alpha depth 8, no mipmaps, 148-byte header plus a 1024-byte palette (17,556 bytes for 64×64). Pillow cannot read encoding 3; the script reads and writes it directly. New texture files need a client restart, not just `/reload`. `DefaultWaypoint`'s source is drawn as vector geometry by `tools/draw_default_waypoint.py` into `tools/icon_sources/DefaultWaypoint.png` (neutral grey, a subtle left/right brightness split echoing the logo's halves) and built with `python tools/build_icons.py tools/icon_sources` (`ICON_OPTIONS`: `peel = 0`, `glyph = 40` for padding, since a solid silhouette reads heavier than a detailed glyph, `dy = -1`). `tools/package_release.py` lists every shipped icon in `ICONS`. The settings-page logo `Art/Logo.blp` (128×128, drawn at 80×80) is built by `tools/build_logo.py` from `tools/logo_source.png`: it uses the source's own alpha (cropped to the artwork), or light-over-black keying for opaque art, with the same BLP writer.
- **Manual hold (v0.5.4):** besides the same key and native → native, a coordinate decision whose `context.questID` equals the bridge's native quest is the same activity, so it is held while a foreign navigation is tracked.
- Never classify by quest names, and never pick between quests outside a `#loop` circuit.
- **Temporary external overrides:** tracked non-bridge Waypoint UI navigation, raw Blizzard user waypoints and different active supertracked quests suspend automatic writes even when RestedXP advances. After tracking becomes idle, wait one second before resolving the current target and strategy afresh. Replacement navigation resets the delay. Clearing the bridge's own pin/native quest alone must not resume. Current/pending bridge-native quests and the last native quest the bridge set/adopted retain ownership until superseded. A non-destructive secure post-hook of `C_SuperTrack.SetSuperTrackedQuestID` identifies direct RXP setters from the immediate Lua caller; `Nav.HasActiveQuest` verifies guide relevance. Acceptance timing/IDs alone never grant permission. This association survives coordinate writes and later travel/grind steps, but an unknown setter (including the same quest), an external replacement or observed idle clearance revokes it. No structural acceptance-window exemption remains. An existing pin/different-quest override always takes priority over attribution. See `docs/MANUAL_WAYPOINT_RESUME.md` for intent limits and lifecycle rules, and `docs/QUEST_PROGRESSION_SYNC.md` for the Step 74 → 77 regression.
- **RestedXP supertracking:** the bridge's native quest and positively recognized automatic guide quest do not activate manual protection. Automatic quest tracking alone never triggers an unchanged-coordinate rewrite; normal guide destination changes still follow RestedXP. Unknown/different quest selections remain protected. The event alone cannot identify who reselected the same quest; setter provenance is observed where available and unknown calls remain protected. See `docs/STALE_MARKER_LIFECYCLE.md`.

## Current state (0.6.1, Stage 6 audit)

- The TOC remains 0.6.1. Stage 6 scopes fallback quest presentation to the waypoint instruction block; navigation eligibility and synchronization timing are unchanged. See `docs/STAGE6_RELEASE_READINESS.md` for current evidence, checkpoint inventory, package and in-game acceptance gates. No v1.0 declaration or commit is authorized by this report.
- v0.6.1 includes the Mining Pick service-context fix; the subsequent quest-transition smoothing is also implemented. See `docs/V0_6_1_SERVICE_CONTEXT.md` and `docs/QUEST_TRANSITIONS.md`.
- Counts below are historical stage results, not the current test total.

- v0.6.0 (Stage 5) adds the single-page settings menu (uniform background, no cards), `RXPW.Config`, the three appearance settings and the Hide RestedXP Arrow mirror of RestedXP's option. Offline regressions pass (15 suites, 671 assertions). The page's look, the Settings API calls and the dropdown and scroll behaviour need in-game acceptance. See `docs/STAGE5_SETTINGS_UI.md`.

- v0.5.9 (Stage 4) adds F7 activity observation, F8 native area re-verification, orphaned-preview recovery after /reload and a same-destination rename rate limit. Offline regressions pass (14 suites, 593 assertions); in-game acceptance is still required. See `docs/STAGE4_F7_F8_PREVIEW.md`.
- v0.5.8 (Stage 3) fixes F4–F6; see `docs/STAGE3_F4_F6.md`.
- v0.5.7 fixes pending native-transition reliability (F1–F3), preserving the v0.5.6 presentation work. Offline regressions pass; in-game acceptance is still required. See `docs/RELIABILITY_F1_F3.md`.

- v0.2 coordinate mirroring and v0.4 hybrid turn-ins have passed in-game tests; the developer was happy with hybrid. Commit `5dd7752` is the v0.4 checkpoint.
- v0.5 adds the experimental `native-first` strategy. It needs in-game acceptance, and its verification limits may need tuning from the debug values.
- v0.5.1 fixes native-first on RestedXP patrol steps (the Agitators bug) and adds `/rxpw inspect`. `Sync` records `lastVerification`, so verification failures show up separately from classification failures.
- The label cleaner requires a letter, so `+1` is never a label.
- v0.5.2 checks a patrol's native target against the whole circuit, which fixed the in-game false rejection on Agitators.
- v0.5.3 picks a quest when several share a farming circuit, and retries failed native targets on a policy instead of blocking them until zoning.
- v0.5.4 adds helper-waypoint detection, native continuity for turn-ins, and quest-context labels and icons on fallback coordinate labels. It was verified in game.
- v0.5.5 puts native-style quest icons on every quest-related coordinate waypoint, not only fallback labels, and colours the marker with Waypoint UI's quest colours. Verified in game.
- v0.5.6 adds service icons and the service palette from `Art/Icons`. It also fixes the render-flag bug: route-critical waypoints had no quest icon and progress labels went stale. Presentation and live labels now apply in every strategy.
- Navigation decisions in `coordinates` and `hybrid` are unchanged. In game, native-first now sees unreached `.goto`s that the render flag used to hide. This affects the patrol "served step has its own waypoint" rule and visible single-waypoint helper steps, which now behave as the offline tests always assumed.
- Offline tests (`node tests/run.js`) cover labels, hybrid (as regression), and native-first: kill, collect and interact classification, loops, route chains, parent-linked blocks, ambiguity, coverage, verification and tolerance, objective → turn-in, progress events, manual overrides, stale callbacks and strategy switching. The mocks assume WoW supertracks one target at a time; that is unverified in Forever.

## Roadmap

1. 0.1: proof of concept with manual sync (done).
2. 0.2: automatic route mirroring (done).
3. 0.3: step descriptions (done).
4. 0.4: hybrid navigation for quest turn-ins (done).
5. 0.5: native-first quest navigation (implemented, experimental).
6. Stage 6: checkpoint, final audit, packaging and in-game release-candidate acceptance. As of v0.6.2, Hybrid is the recommended default; preserve saved strategy selections.
7. v1.0 requires final in-game verification. Arrow hiding, on/off and settings already exist; world-coordinate targets remain a future enhancement. Revalidate against future client/dependency updates.

## Menu defaults (v0.6.2)

Hybrid is recommended. Debug is off; auto-sync, quest icons, service icons,
custom colours and Hide RestedXP Arrow default to on. The external arrow option
is applied only via `RXP.SetArrowHidden(true)` on a new installation and explicit
Restore Defaults. Normal startup preserves existing choices. A saved
`arrowDefaultPending` marker defers that one-time operation if RestedXP is absent;
it is removed on success, with no polling or duplicate stored arrow value.
Restore Defaults now includes this external arrow option; earlier milestone
notes saying it was untouched are historical.

## Testing checklist for any change

- Log in with both dependencies enabled, then with each one disabled. There should be no Lua errors (turn on `/console scriptErrors 1`).
- Run `/rxpw status` on a step with a waypoint, on a step without one, and after reaching a waypoint.
- With `/rxpw debug` on, follow a route with several `.goto` waypoints. Waypoint UI must follow A → B → C, with exactly one write per destination.
- Run `/rxpw sync` and confirm the Waypoint UI destination matches RestedXP's map and coordinates.
- Set a manual Waypoint UI destination or select a different supertracked quest. It must remain active even if RestedXP advances. Clear it: after one second of idle navigation the latest valid RestedXP destination must resume once, silently. Replace it during the delay and verify there is no reclaim. Clearing only the bridge's own destination must leave it cleared.
- Run `/reload` and confirm the bridge loads cleanly, settings persist, and an unchanged destination is not rewritten.
- Check that the label matches RestedXP's visible instruction for the arrow's waypoint. If it doesn't, use `/rxpw status` with debug on to see the label source and raw text.
- Hybrid: a turn-in with intermediate waypoints must follow every waypoint, then go native at the NPC. After the turn-in it must return to coordinates. `/rxpw status` shows the decision reason.
- Native-first: kill and collect objectives at their area should go native, with no writes on progress. Routes before them must stay coordinates. Check the "Native target check" debug values.
- If native-first misclassifies a step, ask for `/rxpw inspect` output first. It shows every instruction's role, the served steps, quest state and the last verification. Then turn the real guide step into a fixture in `tests/`.
- Run `node tests/run.js` before handing work back.

## Stage 3 corrective milestone (v0.5.8)

F4-F6 are covered by `tests/stage3_test.lua`; see `docs/STAGE3_F4_F6.md`.
`watchedLabel` observes RXP text, `desiredPresentation` holds the prepared target,
and successful writes or active-destination verification establish applied
presentation. Actual WUI presentation is authoritative, including colour,
coordinate visibility and icon type. A failed presentation refresh is eligible
again after five seconds, through the existing one-second label check and
coalesced evaluation, only while that same bridge destination is active.
Destination creation failures still follow the original failed-key policy.
`Label.LinkedBlock` is the shared same-step parent validation/block boundary
helper used by both resolvers. Hybrid and native-first share meaningful own
travel-text protection. In-game verification of Stage 3 remains pending.
