# RXP Waypoint Bridge

A World of Warcraft Forever addon that makes **RestedXP Guides** and **Waypoint UI** work as one navigation system.

RestedXP decides where you should go. Waypoint UI shows you how to get there, using its in-world navigation.

> Status: **0.2.0, automatic route mirroring.** Waypoint UI follows RestedXP's arrow target automatically. Quest-aware behaviour is not implemented yet.

## Design goals

- **RestedXP's route is authoritative.** The bridge mirrors the waypoint RestedXP has already chosen (`RXPG_ARROW.element`). It never re-plans the route and never skips intermediate waypoints to point straight at a quest objective.
- **Waypoint UI is the renderer.** The bridge uses only Waypoint UI's documented public API (`WaypointUIAPI.Navigation`).
- **Quest context comes later, as a fallback.** Native quest supertracking will only be used once RestedXP has no explicit coordinate to follow.
- **Small, safe and cheap.** Missing addons or unexpected data produce a message, not a Lua error. Waypoint UI is only updated when the destination changes.
- **No configuration needed** for the normal experience.

## Requirements

| Addon | Folder name | Version verified |
|---|---|---|
| [RestedXP Guides](https://www.curseforge.com/wow/addons/restedxp-guide) | `RXPGuides` | v4.11.23 |
| [Waypoint UI](https://www.curseforge.com/wow/addons/waypointui) | `WaypointUI` | 1.7.3 |

Client: WoW Forever beta (`_classic_beta_`, build 1.60.1, interface `16001`, game type `camelot`).

Both addons are optional load-order dependencies. If either one is missing, the bridge still loads and tells you what is unavailable.

## How it works

```
RestedXP route logic ──► RXPG_ARROW.element ──► RXPAdapter (read + validate)
                                                      │
                                     Sync (0.25 s change check, write on change)
                                                      │
                                   WaypointAdapter ──► WaypointUIAPI.Navigation.NewUserNavigation
```

- Every 0.25 seconds the bridge compares a few fields of RestedXP's current arrow target with the previous check. Nothing else happens unless something changed.
- A changed target must hold steady for about 0.2 seconds. It is then validated and sent to Waypoint UI, but only if it is a different destination (same map and coordinates to 0.001 %) from the last one the bridge handled.
- Bridge waypoints are tagged with the flag `RXPWaypointBridge`. Automatic updates play no sound.
- If RestedXP has no valid waypoint (reached, hidden, inactive step, or no coordinates), the current Waypoint UI destination is left alone.
- If you pick a different destination in Waypoint UI, the bridge doesn't fight you. It waits until RestedXP moves to a new destination, then takes over again. The same applies if a non-bridge waypoint is already tracked when you log in or run `/rxpwb on`.

| File | Role |
|---|---|
| `Core.lua` | Settings, logging, slash commands, initialisation |
| `RXPAdapter.lua` | The only code that reads RestedXP internals: target validation and change detection |
| `WaypointAdapter.lua` | The only code that calls Waypoint UI |
| `Sync.lua` | Automatic and manual sync logic |

## Local development setup

The repository is loaded by WoW directly, with no build step. Link the dev folder into the client's AddOns folder with a directory junction.

In PowerShell (an admin prompt isn't needed for junctions):

```powershell
New-Item -ItemType Junction `
  -Path   "F:\World of Warcraft\_classic_beta_\Interface\AddOns\RXPWaypointBridge" `
  -Target "E:\Dev\RXPWaypointBridge"
```

To remove the link later, delete only the junction. Your dev folder is untouched:

```powershell
(Get-Item "F:\World of Warcraft\_classic_beta_\Interface\AddOns\RXPWaypointBridge").Delete()
```

After editing Lua, run `/reload` in game. **After adding new files, or changing the `.toc` or SavedVariables, restart the client.**

## Commands

| Command | Description |
|---|---|
| `/rxpwb` | List commands |
| `/rxpwb status` | Show dependency, RestedXP waypoint, Waypoint UI destination and sync status |
| `/rxpwb sync` | Send RestedXP's current waypoint to Waypoint UI now. This works even when auto sync is off. |
| `/rxpwb on` | Turn on automatic sync (the default) |
| `/rxpwb off` | Turn off automatic sync. The current Waypoint UI destination is left as it is. |
| `/rxpwb debug` | Turn debug messages about waypoint changes and sync decisions on or off |

The `on`/`off` and `debug` settings are saved account-wide in `RXPWaypointBridgeDB`.

## Current functionality

- Detects RestedXP and Waypoint UI and their APIs at login.
- Reads and validates RestedXP's current arrow target, and recognises stale targets.
- Follows RestedXP automatically: initial target, consecutive waypoints, waypoint changes within a step, and moving steps forwards or backwards.
- Writes to Waypoint UI only when the destination really changes. Doesn't retry a destination Waypoint UI rejected until the target changes or you zone.
- Never clears a Waypoint UI destination, and doesn't keep overwriting one you picked yourself.

## Known limitations

- **RestedXP can take Waypoint UI's focus during quest objective steps.** Its `.complete` handler calls `C_SuperTrack.SetSuperTrackedQuestID` when the step activates and again on quest-log updates. When that happens, Waypoint UI may show the quest instead of the RestedXP coordinate. v0.2 records this, shown in `/rxpwb status` as "Outside change: quest N is supertracked", and doesn't fight it. The bridge takes over again at RestedXP's next destination. Handling this properly is part of the quest-aware milestone.
- If two steps in a row share exactly the same coordinates, Waypoint UI keeps the first step's label.
- Targets that only have world coordinates (RestedXP's corpse and spirit-healer arrows) are not supported yet.
- `RXPG_ARROW.element` is internal RestedXP state, not a public API. A RestedXP update could change it.
- WoW Forever is still in beta. Recheck the interface number and behaviour against the launch client (4 November 2026).

## Roadmap

1. 0.1: proof of concept with manual sync (done).
2. **0.2: automatic route mirroring** (this version).
3. 0.3: robustness. Explicit pause and resume for manual waypoints, a decision on how to handle RestedXP's quest supertracking during objective steps, and more diagnostics.
4. 0.4: quest-aware fallback. When RestedXP has no coordinate to follow, supertrack the relevant quest so Waypoint UI shows its objectives.
5. 1.0: polish. Optionally hide the RestedXP arrow (visual only), support corpse and world-coordinate targets, add minimal settings, and validate against the launch client.

## Licensing

This addon does not bundle any code, data or art from RestedXP or Waypoint UI. It talks to the installed addons at runtime.
