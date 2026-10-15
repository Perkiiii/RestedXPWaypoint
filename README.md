# RXP Waypoint Bridge

A World of Warcraft Forever addon that makes **RestedXP Guides** and **Waypoint UI** work as one navigation system.

RestedXP decides where you should go. Waypoint UI shows you how to get there and what to do there. Where it fits, Blizzard's own quest marker does the pointing.

> Status: **0.5.4, native-first quest navigation (experimental).** There are three strategies:
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
       ├─ objectives of SEVERAL quests inside a #loop farming circuit ─► pick one (below) native objective
       └─ anything else (two quests outside a loop, an accept, a non-quest instruction) coordinates
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

**Several quests in one farming circuit (0.5.3).** When a `#loop` circuit serves objectives of more than one quest, all of them are relevant to the area, and only the order is open. This applies whether the circuit is in the waypoint's own step or in a patrol step serving others. For example, the Skyborne patrol serves Step 5 (Juvenile Vuldrens, *Harmony in Balance* 92461) and Step 6 (Pesky Cirrusflies, *Infestation Investigation* 92462).

RestedXP has no structured priority field: no `#track` in the Forever guides, and "Prioritize them" is plain text. So every eligible candidate (in the log, unfinished, passing the coverage rule) is ranked like this:

1. **Explicit priority:** a text line starting with "Prioritize" in a step whose pending objectives all belong to that one quest. This only matches English guide text; other locales skip to rule 2.
2. **RestedXP's current step:** the non-sticky active step. `#completewith` steps are background work that finishes with it.
3. **Keep what's already tracked:** the quest the bridge, or you, already tracks, if it's still a candidate.
4. **Guide order:** lowest step, then line order.

The choice only changes for a real reason: an objective finishes, RestedXP's steps change, a quest becomes ineligible, or a native check fails. Patrol points cycling and progress on the other quest don't change it. In the example, Infestation Investigation is tracked first. When the Cirrusflies are done, the bridge switches to Harmony in Balance, and turn-ins wait until RestedXP routes to them. Two quests in one step *without* a `#loop` still use coordinates.

**Continuity between native and coordinate navigation (0.5.4).** Native-first now separates *where you're navigated* from *what you're doing*:

- **Helper waypoints.** RestedXP sometimes adds a hidden helper step: one `.goto`, no instructions, at most a placeholder `>>1`, completing with another step. Example: Skyborne Step 35, `#completewith Harvesting Windstones2 / #hidewindow / .goto 2521,43.37,23.98,60 >>1`, pointing at Dalia while Step 34 holds the turn-in.
  - These are no longer mistaken for travel instructions: `>>1` has no letters.
  - Their quest context comes from the step they complete with.
- **Native continuity.** If the bridge is already tracking that helper's turn-in natively, the native marker is **kept**, so there's no transition at all. This requires:
  - WoW still tracks that quest
  - the quest is ready for turn-in
  - the native marker passes the turn-in distance check against the helper point
  - Objective helpers never keep native tracking. For example, the druid helper that moves you to a second cluster stays on coordinates, because objectives can have several areas.
- **Quest presentation.** When coordinates are needed and RestedXP's label is only the `Step N` fallback, the waypoint shows the associated quest instead, e.g. `Harvesting Windstones - Ready for turn-in`.
  - "Ready for turn-in" appears only when the quest log says so.
  - It uses Waypoint UI's own quest icon, through the documented `iconTexture` option, with Waypoint UI 1.7.x only.
  - Real RestedXP instructions such as "Enter the cave" or "Talk to Ilsa" are never replaced.
  - Context is rebuilt from the guide structure and the quest log at every evaluation, so it disappears when the quest is turned in or RestedXP moves on.

Waypoint UI's public API has no subtitle or quest-context field for custom waypoints, so the coordinate marker can't be identical to the native quest marker. The title, status and icon are as close as the API allows.

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
- `windstones_test.lua`: Skyborne Steps 34–36 and the druid helper (continuity, context labels and icons, stale context, travel protection, manual hold, rapid transitions).
- `vuldren_test.lua`: the Skyborne Steps 4–7 circuit (quest prioritization, switching, next-candidate fallback, retries, travel protection, manual hold).

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

- **Objectives with no RestedXP waypoint at all aren't handled.** The bridge only follows the arrow's waypoint and keeps the previous navigation when RestedXP has none.
- **`.collect` isn't eligible.** Item collection may not be a quest-log objective. `.complete` objectives only.
- **The "Prioritize" rule is English-only.** It reads guide text; RestedXP has no priority field. Without it, the current step or guide order decides.
- **Failed native targets retry on a timer.** A quest whose native target failed is retried after 60 seconds, or after 10 seconds if its progress changed, but only when an evaluation runs anyway. Zoning or changing strategy also clears failures.
- **Verification can only reject.** It can't prove the native marker is on the exact mob or object RestedXP means. The main evidence is RestedXP's own waypoint-to-objective link.
- **Switching between coordinates and native briefly removes the marker**, for about 0.25 seconds plus Waypoint UI's animation.
- **RestedXP may supertrack other quests by itself.** The bridge records that and doesn't fight it.
- **Coordinate markers can't fully match native quest markers.** The API offers one name line and an icon. The quest icon depends on Waypoint UI's shipped file names, so it's only used with Waypoint UI 1.7.x.
- Corpse and world-coordinate-only targets aren't supported.
- `RXPG_ARROW.element` and step data are internal RestedXP state, not a public API.
- WoW Forever is still in beta. Recheck against the launch client (4 November 2026).

## Roadmap

1. 0.1: manual sync (done).
2. 0.2: automatic route mirroring (done).
3. 0.3: step descriptions (done).
4. 0.4: hybrid navigation for turn-ins (done, tested in game).
5. **0.5: native-first quest navigation** (this version, experimental; 0.5.1 adds patrol steps and `/rxpwb inspect`; 0.5.2 checks patrols against the whole circuit; 0.5.3 picks a quest when several share a farming circuit; 0.5.4 adds continuity through helper waypoints and quest-context labels).
6. Next: validate native-first in game, tune the verification limits from the debug values, and decide the default strategy.
7. 1.0: optional visual-only hiding of the RestedXP arrow, explicit pause and resume, world-coordinate targets, minimal settings, and validation against the launch client.

## Licensing

This addon does not bundle any code, data or art from RestedXP or Waypoint UI. It talks to the installed addons at runtime.
