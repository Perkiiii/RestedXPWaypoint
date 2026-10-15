# RXP Waypoint Bridge

A World of Warcraft Forever addon that makes **RestedXP Guides** and **Waypoint UI** work as one navigation system.

RestedXP decides where you should go. Waypoint UI shows you how to get there and what to do there.

> Status: **0.4.0, hybrid navigation (experimental).**
> - Waypoint UI follows RestedXP's arrow automatically and labels each waypoint with RestedXP's instruction.
> - With `/rxpwb mode hybrid`, eligible quest turn-ins use WoW's native quest marker (quest title, "Ready for turn-in"), and everything else stays on RestedXP's coordinates.
> - The default strategy is still `coordinates` until hybrid has been validated in game.

## Design goals

- **RestedXP's route is authoritative.** The bridge mirrors the waypoint RestedXP has already chosen (`RXPG_ARROW.element`). It never re-plans the route and never skips intermediate waypoints.
- **Waypoint UI is the renderer.** The bridge uses only Waypoint UI's documented public API (`WaypointUIAPI.Navigation`), plus WoW's own `C_SuperTrack` for native quests.
- **Native quest navigation only with evidence.** A turn-in goes native only when RestedXP's own data ties the current arrow waypoint to that turn-in, and the quest is ready. When in doubt, it uses coordinates.
- **Labels must be accurate.** When the link between waypoint and instruction is unclear, the bridge shows "Step N".
- **Small, safe and cheap.** Writes happen only when the desired navigation changes. There are no loops and no fights with the player.

## Requirements

| Addon | Folder name | Version verified |
|---|---|---|
| [RestedXP Guides](https://www.curseforge.com/wow/addons/restedxp-guide) | `RXPGuides` | v4.11.23 |
| [Waypoint UI](https://www.curseforge.com/wow/addons/waypointui) | `WaypointUI` | 1.7.3 |

Client: WoW Forever beta (`_classic_beta_`, build 1.60.1, interface `16001`, game type `camelot`).

## How it works

```
RestedXP route logic ──► RXPG_ARROW.element ──► RXPAdapter (validate) + LabelResolver (describe)
                                                      │
                                         NavigationResolver (coordinates or native quest?)
                                                      │
                                Sync (0.25 s change check + quest events, write on change)
                                       │                                   │
             WaypointAdapter ──► NewUserNavigation             C_SuperTrack.SetSuperTrackedQuestID
               (Mode A: coordinates)                              (Mode B: native quest)
```

### Strategies and modes

| Strategy (`/rxpwb mode …`) | Behaviour |
|---|---|
| `coordinates` (default) | Every destination uses RestedXP's coordinates with the v0.3 labels. This is the v0.3 behaviour. |
| `hybrid` (experimental) | Eligible quest turn-ins use native quest navigation. Everything else uses coordinates. |

Automatic sync (`/rxpwb on` / `off`) is separate. It controls *whether* the bridge follows RestedXP. The strategy controls *how* it does so.

### When a turn-in goes native (hybrid)

All of these must hold:

1. RestedXP's arrow is on a guide `.goto` that is a **final destination**. RestedXP marks a `.goto` with an arrival radius as reached and moves on, so those (cave entrances, road turns, route chains) always stay on coordinates.
2. RestedXP's own data ties that waypoint to a turn-in, in one of two ways:
   - The waypoint's linked instruction (`element.parent`) is a pending `.turnin`.
   - Or, for a step's leading `.goto`, the first *pending* instruction after it (skipping "Talk to …" text lines and completed instructions, and before any other waypoint) is a `.turnin`.
3. The quest is in your quest log and ready for turn-in.
4. After the quest is supertracked, WoW reports a native navigation target. That target must not be measurably inconsistent with RestedXP's destination; the check fails if the distances differ by more than 50 yards.

If several turn-ins are pending at one destination, the first in RestedXP's order is tracked, then the next.

Because the arrow only reaches the turn-in waypoint after RestedXP has passed every intermediate point, the route is always followed first.

### Transitions

- **Coordinates → native.** The bridge clears *only its own* Waypoint UI waypoint and waits 0.25 seconds. It has to wait because Waypoint UI clears all supertracking when a tracked waypoint is removed. It then supertracks the quest, and 0.6 seconds later verifies that a native target exists.
- **Native → coordinates** (e.g. after the turn-in, or when travel resumes). The quest is released if it is still the one being tracked, then the coordinate waypoint is created silently.
- **Native → native** (the next turn-in at the same NPC). The new quest is supertracked and verified.
- **Failure** (no native target, inconsistent target, or supertracking didn't take effect). The bridge releases the quest, falls back to RestedXP's coordinates, and doesn't retry that quest at that destination until you zone or change strategy.

The bridge re-evaluates whenever RestedXP's target changes, and on quest events in hybrid mode (coalesced, 0.5 seconds after the event). An unchanged desired state never causes a write.

### Manual waypoints

If you pick your own destination in Waypoint UI, the bridge leaves it alone. It also won't switch modes at the same destination while your waypoint is tracked. It resumes when RestedXP moves to a new destination. RestedXP supertracking the same quest the bridge chose is treated as the bridge's own navigation.

### Descriptions (coordinate mode)

Labels come from RestedXP's instruction for the arrow's waypoint, in this order:

1. The arrow title.
2. The step's arrow text.
3. The waypoint's own text.
4. The objective RestedXP linked to the waypoint.
5. The following instruction that isn't finished yet.
6. The preceding instruction.
7. The step's title.
8. `Step N`.

Markup is cleaned:

- RestedXP colour tokens, NPC IDs (`Name::12345`), icons and links are removed or reduced to their visible text.
- Progress counters are dropped.
- Only the first line is kept.
- Text over about 60 characters is shortened.

See the header of `LabelResolver.lua` for the details.

| File | Role |
|---|---|
| `Core.lua` | Settings, logging, slash commands, initialisation |
| `LabelResolver.lua` | Waypoint descriptions from RestedXP's step data |
| `RXPAdapter.lua` | Reads and validates RestedXP's arrow target, detects changes, measures distance |
| `NavigationResolver.lua` | Turn-in detection, quest state, mode decision, native supertracking and verification |
| `WaypointAdapter.lua` | The only code that calls Waypoint UI |
| `Sync.lua` | The single controller: change detection, mode transitions, manual sync |
| `tests/` | Offline tests (not loaded by WoW) |

## Local development setup

The repository is loaded by WoW directly, with no build step:

```powershell
New-Item -ItemType Junction `
  -Path   "F:\World of Warcraft\_classic_beta_\Interface\AddOns\RXPWaypointBridge" `
  -Target "E:\Dev\RXPWaypointBridge"
```

After editing Lua, run `/reload`. **After adding files, or changing the `.toc` or SavedVariables, restart the client.**

### Offline tests

```powershell
npm install --prefix tests   # once; installs fengari (a Lua VM in JavaScript)
node tests/run.js
```

The tests run the real addon files against mocked RestedXP, Waypoint UI and WoW APIs. They cover label cleaning and resolution, turn-in detection, intermediate-waypoint protection, transitions, fallbacks, idempotency and manual overrides. They do **not** prove in-game behaviour.

## Commands

| Command | Description |
|---|---|
| `/rxpwb` | List commands |
| `/rxpwb status` | Dependencies, RestedXP waypoint, label, turn-in quest, decision and reason, active mode, ownership, last transition and failure |
| `/rxpwb sync` | Apply the current RestedXP destination now, using the selected strategy. Works with auto sync off. |
| `/rxpwb on` / `off` | Turn automatic sync on (the default) or off. Off leaves the current destination untouched. |
| `/rxpwb mode coordinates` / `hybrid` | Choose the navigation strategy. The current destination is re-evaluated immediately. |
| `/rxpwb debug` | Turn debug messages about decisions and transitions on or off |

Settings (`autoSync`, `strategy`, `debug`) are saved account-wide in `RXPWaypointBridgeDB`.

## Known limitations

- **Hybrid mode is experimental** and only handles turn-ins. Kill and collect objectives, and accepts, always use coordinates.
- Native verification can only *reject* clearly different targets (it compares distances). It can't prove the native marker is on the same NPC. The main evidence is RestedXP's own waypoint-to-turn-in link.
- The native → coordinates and coordinates → native switches briefly remove the marker (about 0.25 seconds plus Waypoint UI's animation).
- RestedXP may supertrack other quests by itself (for example, `.complete` objectives in sticky steps). The bridge records this as an outside change and doesn't fight it.
- A `.goto` with a radius right before a turn-in stays on coordinates. This is deliberate.
- Labels are snapshots taken when the destination changes. Ambiguous steps show `Step N`.
- Corpse and world-coordinate-only targets are not supported.
- `RXPG_ARROW.element` and step data are internal RestedXP state, not a public API.
- WoW Forever is still in beta. Recheck against the launch client (4 November 2026).

## Roadmap

1. 0.1: manual sync (done).
2. 0.2: automatic route mirroring (done).
3. 0.3: step descriptions (implemented).
4. **0.4: hybrid navigation for quest turn-ins** (this version, experimental).
5. Next: validate hybrid in game and decide whether to make it the default. Possibly extend it to other quest steps, and ask the Waypoint UI author about a `contextQuestID`-style API, which would give coordinates plus quest info at once.
6. 1.0: optional visual-only hiding of the RestedXP arrow, explicit pause and resume, world-coordinate targets, minimal settings, and validation against the launch client.

## Licensing

This addon does not bundle any code, data or art from RestedXP or Waypoint UI. It talks to the installed addons at runtime.
