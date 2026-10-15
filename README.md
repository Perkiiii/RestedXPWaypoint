# RXP Waypoint Bridge

A World of Warcraft Forever addon that makes **RestedXP Guides** and **Waypoint UI** work as one navigation system.

RestedXP decides where you should go. Waypoint UI shows you how to get there and what to do there. Where it fits, Blizzard's own quest marker does the pointing.

> Status: **0.5.2, native-first quest navigation (experimental).** There are three strategies:
> - `coordinates`: always RestedXP coordinates.
> - `hybrid`: native quest marker for turn-ins (v0.4, tested in game).
> - `native-first`: native quest marker for turn-ins **and** quest objectives RestedXP is leading you to (v0.5).
>
> Your saved strategy is kept. Nobody is switched to native-first automatically.

## Design goals

- **RestedXP's route is authoritative.** The bridge mirrors the waypoint RestedXP has chosen (`RXPG_ARROW.element`). Intermediate route waypoints are always followed with coordinates.
- **Prefer Blizzard's marker only when it fits.** Native quest tracking is used when RestedXP's own guide data ties the current waypoint to one quest objective or turn-in, and the quest log confirms it. In every other case the bridge uses RestedXP's coordinates.
- **Waypoint UI is the renderer.** The bridge uses only Waypoint UI's documented public API (`WaypointUIAPI.Navigation`), plus WoW's `C_SuperTrack` for native quests. Waypoint UI draws the quest name, progress and "Ready for turn-in" itself.
- **Small, safe and cheap.** Writes happen only when the desired navigation changes. There are no loops and no fights with the player.

## Requirements

| Addon | Folder name | Version verified |
|---|---|---|
| [RestedXP Guides](https://www.curseforge.com/wow/addons/restedxp-guide) | `RXPGuides` | v4.11.23 |
| [Waypoint UI](https://www.curseforge.com/wow/addons/waypointui) | `WaypointUI` | 1.7.3 |

Client: WoW Forever beta (`_classic_beta_`, build 1.60.1, interface `16001`, game type `camelot`).

## Strategies

| Strategy (`/rxpwb mode …`) | Native quest marker for | Otherwise |
|---|---|---|
| `coordinates` (default for new installs) | nothing | RestedXP coordinates with instruction labels |
| `hybrid` | quest turn-ins (v0.4 rules, unchanged) | coordinates |
| `native-first` (experimental) | quest turn-ins and quest objectives (`.complete`) | coordinates |

`/rxpwb on` / `off` controls *whether* the bridge follows RestedXP. The strategy controls *how*.

## How native-first decides

```
RestedXP arrow waypoint
  ├─ not a guide .goto, or it has its own travel text ("Enter the crypt") ......... coordinates
  ├─ more waypoints follow before any instruction (route chain, not a #loop) ...... coordinates
  └─ RestedXP's instruction block for this waypoint
       ├─ first pending instruction is a .turnin ─► quest in log and ready? ......... native turn-in
       ├─ only .complete objectives of ONE quest, nothing else pending
       │     ─► quest in log, not complete, every unfinished objective of the quest
       │        is one RestedXP targets here? .................................... native objective
       └─ anything else (two quests, an accept, a non-quest instruction, ...) ...... coordinates
  then: supertrack the quest and verify a native target exists and is consistent;
        if not ─► release the quest and fall back to coordinates
```

The **instruction block** comes from RestedXP's own structure:

- For a `.goto` placed after its objectives (it has a `parent`), the block is the lines above it, back to the previous waypoint.
- Otherwise, the block is the lines after it.
- In a `#loop` step, the whole patrol circuit belongs to the objective area. That is how RestedXP writes kill and collect areas.
- **Patrol steps (0.5.1).** RestedXP often puts the patrol circuit in its own hidden, sticky step (`#hidewindow`, `#completewith X`, `#loop`, `.goto` points, `+1`). The real objectives then sit in the steps running alongside it. For example, Skyborne has the Agitators kill step with no `.goto` of its own.
  - When the arrow's step contains nothing but the `+1` placeholder and is a sticky `#loop`, the bridge looks at the steps it serves: RestedXP's other active steps after it.
  - All of those steps' pending objectives must belong to one quest, and none of them may have its own waypoint.
  - A real `+text` instruction (e.g. "Kill … until you have 60 copper") is never treated as a placeholder.

Descriptive lines such as `>>Kill X and Y` or `*Prioritize Y` are headings and never block an objective.

**Arrival radius is not used to classify waypoints in native-first.** `.goto x,y,7,0` before "Click on the Crystals" (Windstone Clusters) is the objective area, while `.goto a,8,0` → `.goto b,8,0` → `.goto c` before a kill is a route.

**Why the coverage rule matters.** Blizzard picks its own marker among a quest's unfinished objectives. If the quest still has an objective RestedXP plans to do somewhere else, the native marker could lead there instead, so the bridge stays on coordinates.

### Verifying the native target

After supertracking, the bridge compares two distances measured from the player's position:

- Blizzard's navigation distance (`C_Navigation.GetDistance`).
- The distance to RestedXP's point (`HereBeDragons`, the library RestedXP's own arrow uses).

The difference between them is a **lower bound** on how far apart the two targets are, so the check can reject a clearly different target but never prove they're the same. The limits are:

| Kind | Limit | Why |
|---|---|---|
| Turn-in | 50 yd | The quest giver; validated in game in v0.4 |
| Objective | 100 yd | Blizzard marks the objective area, RestedXP picks a point in it |

For a `#loop` patrol, RestedXP's destination is the **whole circuit**, not just the point its arrow is on, which can be the far side of the loop. So the native marker is compared with **every** patrol point, and rejected only if it's provably more than the limit away from all of them (0.5.2).

Every check logs the measured values in debug mode, so the limits can be tuned from real data. For a patrol, the RestedXP value shown is the nearest patrol point. Height may or may not be included in Blizzard's distance; that's undocumented.

### Transitions

- Coordinates ↔ native, objective → objective, objective → turn-in (even at the same coordinates), and turn-in → coordinates all go through one controller (`Sync.lua`).
- Native identity in native-first is **what** is tracked (`objective:questID` / `turnin:questID`), not where RestedXP's point is. So RestedXP cycling loop points, and kill or loot progress, **never** re-supertrack the quest. Waypoint UI updates the progress itself.
- Quest events are coalesced: one evaluation 0.5 seconds after a burst. A failed native attempt isn't retried for that quest until you zone or change strategy.

### Manual waypoints

If you pick your own destination in Waypoint UI, the bridge leaves it alone. That includes while RestedXP cycles a loop on the same objective, and while you make progress. It takes over again when RestedXP moves to a new destination. RestedXP supertracking the same quest counts as the bridge's own navigation.

### Labels (coordinate mode)

Labels come from RestedXP's instruction for the arrow's waypoint. Colour codes, icons, NPC IDs and progress counters are removed, and `Step N` is used when the link is unclear. See `LabelResolver.lua`.

| File | Role |
|---|---|
| `Core.lua` | Settings, logging, slash commands, initialisation |
| `LabelResolver.lua` | Waypoint descriptions from RestedXP's step data |
| `RXPAdapter.lua` | Reads and validates RestedXP's arrow target, detects changes, measures distance |
| `NavigationResolver.lua` | Hybrid turn-in rules, native-first objective rules, quest state, decisions, native supertracking and verification |
| `WaypointAdapter.lua` | The only code that calls Waypoint UI |
| `Sync.lua` | The single controller: change detection, mode transitions, manual sync |
| `tests/` | Offline tests (not loaded by WoW) |

## Local development setup

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

These run the real addon files against mocked RestedXP, Waypoint UI and WoW APIs:

- `label_test.lua`: label cleaning and resolution.
- `hybrid_test.lua`: the v0.4 strategy, as a regression test.
- `native_first_test.lua`: step structures taken from the installed Forever guides.
- `agitators_test.lua`: the Skyborne Agitators patrol step and its neighbours.

They don't prove in-game behaviour.

## Commands

| Command | Description |
|---|---|
| `/rxpwb` | List commands |
| `/rxpwb status` | Dependencies, RestedXP step and waypoint, label, quest, classification, objective progress, native eligibility and reason, active mode, ownership, last transition and failure |
| `/rxpwb sync` | Apply the current RestedXP destination now, using the selected strategy. Works with auto sync off. |
| `/rxpwb on` / `off` | Turn automatic sync on (the default) or off. Off leaves the current destination untouched. |
| `/rxpwb mode coordinates` / `hybrid` / `native-first` | Choose the strategy. Saved, and the current destination is re-evaluated immediately. |
| `/rxpwb debug` | Turn debug messages about decisions, verification values and transitions on or off |
| `/rxpwb inspect` | One-off dump of what the resolver sees: the arrow waypoint, its step (loop, sticky, hidden), each instruction (heading, placeholder, objective, done or pending), the steps a patrol serves, RestedXP's active steps, candidate quests with objective progress, the native-first analysis and reason, and the last native verification |

## Known limitations

- **Patrol areas shared by two quests stay on coordinates.** In Skyborne, Windstone Clusters and Agitators share a patrol. Native tracking starts once only one quest's objectives remain.
- **Objectives with no RestedXP waypoint at all aren't handled.** The bridge only follows the arrow's waypoint and keeps the previous navigation when RestedXP has none.
- **`.collect` isn't eligible.** Item collection may not be a quest-log objective. `.complete` objectives only.
- **The two quests' order isn't known.** When two quests share an area, coordinates are used.
- **Verification can only reject.** It can't prove the native marker is on the exact mob or object RestedXP means. The main evidence is RestedXP's own waypoint-to-objective link.
- **Switching between coordinates and native briefly removes the marker**, for about 0.25 seconds plus Waypoint UI's animation.
- **RestedXP may supertrack other quests by itself.** The bridge records that and doesn't fight it.
- Corpse and world-coordinate-only targets aren't supported.
- `RXPG_ARROW.element` and step data are internal RestedXP state, not a public API.
- WoW Forever is still in beta. Recheck against the launch client (4 November 2026).

## Roadmap

1. 0.1: manual sync (done).
2. 0.2: automatic route mirroring (done).
3. 0.3: step descriptions (done).
4. 0.4: hybrid navigation for turn-ins (done, tested in game).
5. **0.5: native-first quest navigation** (this version, experimental; 0.5.1 adds patrol steps and `/rxpwb inspect`; 0.5.2 checks patrols against the whole circuit).
6. Next: validate native-first in game, tune the verification limits from the debug values, and decide the default strategy.
7. 1.0: optional visual-only hiding of the RestedXP arrow, explicit pause and resume, world-coordinate targets, minimal settings, and validation against the launch client.

## Licensing

This addon does not bundle any code, data or art from RestedXP or Waypoint UI. It talks to the installed addons at runtime.
