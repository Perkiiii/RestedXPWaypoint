# RestedXP Waypoint

An **unofficial companion addon for World of Warcraft Forever**. RestedXP Guides
chooses the route; RestedXP Waypoint mirrors its resolved waypoint into Waypoint
UI's in-world navigation. It is not affiliated with either project.

Current development version: **0.6.1**, undergoing final release-candidate testing.
This is not a v1.0 release. Coordinates is the default for new installations;
existing settings are preserved. Native First remains experimental.

## Requirements and installation

Verified environment: WoW Forever beta, build **1.60.1**, interface **16001**,
client flavour `camelot`. Other WoW clients have not been validated.

Install these addons separately:

| Dependency | Required folder | Verified version |
|---|---|---|
| RestedXP Guides | `RXPGuides` | v4.11.23 |
| Waypoint UI | `WaypointUI` | 1.7.3 |

1. Close WoW. Extract the release-candidate ZIP into your Forever client's
   `Interface/AddOns` directory.
2. Check the resulting layout is `Interface/AddOns/RestedXPWaypoint/`, containing
   `RestedXPWaypoint_Camelot.toc`, eight Lua modules and `Art/`. Avoid a second
   nested `RestedXPWaypoint` folder. Keep the folder name exactly as shown.
3. Enable RestedXP Waypoint and both dependencies in the character-selection
   AddOns list, then start a RestedXP guide with a coordinate waypoint.
4. Type `/rxpw status` to confirm version, dependencies and the selected route.
   Open `/rxpw config` to choose your settings.

Both dependencies are required for live synchronization. They are optional TOC
load dependencies so this addon's settings and missing-dependency messages can
still load when one is absent. The package does not bundle either dependency.
No build tools, Node or Python are needed to play. Restart the client after
installing or changing TOC/module files; `/reload` is sufficient for Lua edits.

## Navigation strategies

| `/rxpw mode ...` | Behaviour |
|---|---|
| `coordinates` | Always follow RestedXP's actual coordinates. Quest/service context changes presentation only. |
| `hybrid` | Use native quest tracking for eligible ready turn-ins; preserve intermediate and explicit travel points. |
| `native-first` | Also allow eligible `.complete` quest objectives, with structural and quest-log checks plus native destination verification. |

Native tracking is selected only when RestedXP's instruction structure supports
it. Routes, cave entrances, unrelated actions and ambiguous objectives stay on
coordinates. Multi-quest farming circuits can select one eligible quest without
repeatedly switching as patrol points cycle. Native targets are rechecked when
the same quest moves to a different activity area; failed checks fall back to
RestedXP coordinates. Item `.collect` instructions alone are not native objectives.

Manual waypoints are respected at the current handled destination. A genuinely
new RestedXP destination can resume automatic navigation. During a pending native
transition, a manual pin or quest selection cancels delayed work. Use `/rxpw off`
for a longer pause; `/rxpw sync` explicitly applies the current route even while
auto-sync is off. Invalid or stale RestedXP data leaves existing navigation alone.

## Icons, colours and labels

Coordinate waypoints retain RestedXP's destination and instruction label, including
live objective counts such as `1/15 Windstone Cluster`. Ambiguous labels fall back
to `Step N`. Quest icons show Available (`!`), Incomplete (silver `?`) and Complete
(gold `?`), with supported campaign/repeatable variants.

Service markers cover Flight Master, Class Trainer, Profession Trainer, Food &
Drink, Repair, Innkeeper, Stable Master, Vendor, Banker and Grind. Vendor and
Banker share a bags glyph. Services use their own colours; generic navigation
uses Waypoint UI's fallback. Classification uses guide tags and waypoint-local
instruction context. English purchase/repair text is used conservatively where
RestedXP lacks a dedicated tag; unfamiliar text can retain the generic marker.

Quest icons and quest colours rely on Waypoint UI's 1.7.x shipped icon files.
Other versions fall back to the generic marker. The bundled service art has no
such version gate. Explicit colours also tint icons and beams; Waypoint UI's
private custom quest palettes are not copied.

## Settings and previews

Open **Options > AddOns > RestedXP Waypoint**, or `/rxpw config` (also `settings`
and `options`). One scrolling page contains General, Navigation, Waypoint
Appearance, Waypoint Preview and Advanced sections.

- Automatic sync, strategy and debug controls share the same settings as slash
  commands. Changes from either side refresh an open page.
- Quest Icons, Service Icons and Custom Colours default to on. These affect the
  custom waypoints this addon creates; native quest markers use Waypoint UI's own
  presentation. Size, beams, animation and sound remain Waypoint UI settings.
- Hide RestedXP Arrow mirrors RestedXP's own profile option. Its waypoint data
  continues updating. This option is separate from `RXPWDB` and Restore Defaults.
- Preview selection, Close/Far, Show, Next, All and Stop use the same preview
  session as `/rxpw preview`. A preview pauses automatic sync; stopping resumes
  it if it was previously running and auto-sync is still enabled.
- Advanced provides Status, Inspect and confirmed Restore Defaults. Defaults
  restore this addon's settings, including Coordinates and auto-sync on, so
  automatic navigation can resume or change. Dependency settings are untouched.

Settings persist in `RXPWDB` across reload/restart. Preview selection is temporary.
The page cannot be opened during combat.

| Command | Purpose |
|---|---|
| `/rxpw` | Show help |
| `/rxpw config` | Open settings |
| `/rxpw status` | Version, dependencies, destination, ownership, label/icon and last verification |
| `/rxpw inspect` | Dump the current guide structure and native eligibility |
| `/rxpw on` / `/rxpw off` | Enable/disable automatic sync; off leaves the destination in place |
| `/rxpw sync` | Explicitly synchronize now |
| `/rxpw mode coordinates` / `hybrid` / `native-first` | Select the saved strategy |
| `/rxpw debug` | Toggle diagnostic chat messages |
| `/rxpw preview all close` / `/rxpw preview all far` | Cycle every marker at 4-second intervals |
| `/rxpw preview vendor` / `/rxpw preview next` | Show one marker or advance; optional `close` or `far` |
| `/rxpw preview off` | Remove only the preview marker and end preview mode |

Preview keys: `available`, `incomplete`, `complete`, `flightmaster`, `classtrainer`,
`professiontrainer`, `food`, `repair`, `innkeeper`, `stable`, `vendor`, `banker`,
`grind`, `default`. Far is four times the map offset of Close; yard distances vary
by map. If a preview survives `/reload`, auto-sync removes it on startup, or use
`/rxpw preview off` with auto-sync off.

## Known limitations and troubleshooting

- RestedXP's arrow and step data are internal interfaces and can change after
  dependency updates. This addon does not replace or modify dependency functions.
- No valid coordinate waypoint (including corpse/world-coordinate-only targets)
  means no new synchronization. Existing navigation is retained.
- Native distance verification can reject a clearly wrong destination; it cannot
  prove the native marker points to the exact intended mob or object. Missing
  RestedXP world distance weakens this check. Native First needs in-game acceptance.
- RestedXP or the client may create a native quest marker before the bridge sees
  the final route after acceptance/turn-in. Waypoint UI may briefly display it.
  The bridge cannot suppress that external presentation through supported APIs.
- Same-coordinate label/icon updates call `NewUserNavigation`, which restarts
  Waypoint UI's marker intro and can rebuild enabled pathfinding. Updates are
  coalesced and spaced at least two seconds apart; they are not visually inert.
  Failed presentation writes retry no sooner than five seconds while still owned.
- Native transitions can briefly remove the marker. A failed native target is
  reconsidered on later evaluations after a new activity, zoning/strategy change,
  a 60-second cooldown, or changed progress after 10 seconds. No retry ticker runs.
- The English “Prioritize” hint is optional; other locales use the remaining
  structural ranking rules. Other clients and future Forever builds are untested.

If no marker appears, check `/rxpw status`, both dependency folders, `/rxpw on`,
the selected guide and whether a preview/manual destination is active. Try
`/rxpw preview off`, then `/rxpw sync` when you intend to resume the guide route.
For a wrong label/icon/native destination, use `/rxpw debug`, `/rxpw status` and
`/rxpw inspect`; record map, coordinates, quest ID and the relevant guide lines.
Turn debug off afterward. `/console scriptErrors 1` makes Lua errors visible.
Test persistence after a normal logout/full restart, since settings may not yet
have been flushed to disk during a running session.

## Development and release verification

There is no runtime build step. Run `npm ci --prefix tests`, then
`node tests/run.js` for offline mocked tests. They do not prove live rendering or
Forever behaviour. Tools and tests are excluded from runtime release packages.
`python tools/package_release.py` creates a uniquely named 0.6.1 RC archive under
ignored `.release/`, with an allowlisted runtime tree and verified entry hashes.

The project was named RXP Waypoint Bridge through v0.5.7. Old saved variables are
not automatically imported from another profile; keep a backup and select the
desired settings in the new page. Machine-specific junction migration is a
maintainer tool, not an installation requirement.

Detailed history and acceptance evidence live in [docs/](docs/), including the
[Stage 6 readiness report](docs/STAGE6_RELEASE_READINESS.md). The release ZIP
contains this README; development reports are available in the source checkout.

This unofficial addon does not bundle RestedXP or Waypoint UI code or art.
Artwork provenance and distribution terms should be recorded before public release.
