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
4. **Prefer public APIs.** For Waypoint UI, use only `WaypointUIAPI.Navigation` as documented in `WaypointUI/API.lua`. Do not use undocumented options such as `syncNativeWaypoint` or `coordinatesAreNormalized`, or internal modules. RestedXP has no public waypoint API. Keep every read of its internals in one clearly marked place.
5. **Never modify RestedXP or Waypoint UI**, either on disk or by replacing their functions at runtime. Hooks must be non-destructive (`hooksecurefunc`) and justified.
6. **Validate external addon data.** Type-check every field read from another addon. Missing or unexpected data must produce a message or a no-op, never an uncaught Lua error.
7. **Only clear navigation the bridge created.** Check ownership with `IsUserNavigationFlagged("RXPWaypointBridge")`. Do not call `ClearDestination()` routinely: it also clears all native supertracking.
8. **Avoid unnecessary polling and repeated API calls.** Write to Waypoint UI only when the target actually changes. No heavy `OnUpdate` work.
9. **Maintain WoW Forever compatibility.** Guard optional APIs, for example `C_AddOns and C_AddOns.IsAddOnLoaded`.
10. **Keep it modular as it grows.** RestedXP reads belong only in `RXPAdapter.lua`, Waypoint UI calls only in `WaypointAdapter.lua`, and sync decisions in `Sync.lua`. Add new modules when a milestone needs them, not before.
11. **Prefer clear, maintainable Lua** over clever code. Use locals, no accidental globals, and the shared addon namespace (`local addonName, ns = ...`).
12. **Work incrementally.** Each milestone must be testable in game by hand and come with test steps. Do not implement features from later milestones early.
13. **Never commit without the developer's approval.**

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

## Architecture (0.2.0)

The load order is set in the `.toc`. All modules share the addon namespace `ns`.

| File | Namespace | Responsibility |
|---|---|---|
| `Core.lua` | `ns` | Settings (`RXPWaypointBridgeDB`: `autoSync`, `debug`), `ns.Print`/`ns.PrintLine`/`ns.Debug`, shared helpers, slash commands, `ADDON_LOADED`/`PLAYER_LOGIN` |
| `RXPAdapter.lua` | `ns.RXP` | **Only** place that reads RestedXP internals. `GetTarget()` returns `(target, reason)`: `reason` is nil when the target is valid, and then `target.key` is set. `HasTargetChanged()` is a cheap poll comparison. `ResetObservation()`. `DestinationKey()`. |
| `WaypointAdapter.lua` | `ns.WUI` | **Only** place that calls Waypoint UI. `SetNavigation()`, `GetNavigation()`, `IsShowingTarget()`, `GetForeignNavigationName()`, `DescribeOutsideNavigation()`. |
| `Sync.lua` | `ns.Sync` | `Initialize()`, `Start()`/`Stop()`, `SyncNow()`, `GetState()`. Contains the automatic sync logic. |

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

## Current state (0.2.0)

Automatic coordinate mirroring is implemented and waiting for in-game acceptance tests. There is no quest logic, no arrow hiding and no settings UI.

## Roadmap

1. 0.1: proof of concept with manual sync (done).
2. 0.2: automatic route mirroring (implemented).
3. 0.3: explicit pause and resume for manual waypoints, a policy for RestedXP's quest supertracking during objective steps, and more diagnostics.
4. 0.4: quest-supertracking fallback when RestedXP has no coordinate target.
5. 1.0: optional visual-only hiding of the RestedXP arrow, world-coordinate targets, minimal settings, and validation against the launch client.

## Testing checklist for any change

- Log in with both dependencies enabled, then with each one disabled. There should be no Lua errors (turn on `/console scriptErrors 1`).
- Run `/rxpwb status` on a step with a waypoint, on a step without one, and after reaching a waypoint.
- With `/rxpwb debug` on, follow a route with several `.goto` waypoints. Waypoint UI must follow A → B → C, with exactly one write per destination.
- Run `/rxpwb sync` and confirm the Waypoint UI destination matches RestedXP's map and coordinates.
- Set a manual Waypoint UI destination. The bridge must not overwrite it until RestedXP's destination changes.
- Run `/reload` and confirm the bridge loads cleanly, settings persist, and an unchanged destination is not rewritten.
