# Settings redesign and integration handoff

Status: included in the v0.6.3 UI update. Installed dependencies are unchanged.
In-game acceptance is pending.

## Investigation and architecture

Inspected the bridge controller, Config, navigation/appearance adapter, sync audio
opportunity, previews, settings and regression harness. Read the installed Waypoint
UI settings schema, constructor, widgets, UI, preload, API, saved-variable handler,
callback registry, map-pin compatibility and audio paths. A separate checkout of
[Waypoint UI](https://github.com/Adaptvx/Waypoint-UI) at
`cc4cc14601839070008f193e1ae34b55c1640c55` supplies the development API implementation.
The checkout and installed source both identify as 1.7.3.

Before implementation, the key limitations were established:

- Released Waypoint UI exposes navigation and OpenSettingsUI, no settings API.
  Direct DB writes cannot safely substitute for SetVariable/runtime callbacks.
- Its private settings constructor writes DBGlobal:SetVariable, then triggers
  Setting.Refresh. SavedVariables defaults are fallback values: raw stored nil
  differs reliably from explicit false. Global reset wipes and reloads.
- Its artwork has no confirmed redistribution permission, so none is copied or
  bundled. The visual-parity revision (below) references the installed Waypoint
  UI 1.7.x textures by file path at runtime, like the existing quest glyphs.
- Audio creation, waypoint appearance, pinpoint appearance and proximity are
  distinct paths. NewUserNavigation.suppressAudio only affects creation audio.
- MapPin.IsCustomMapPinsEnabled requires the saved preference AND absence of
  MapPinEnhanced. The bridge leaves this compatibility gate untouched.

The implementation is split into:

| Module | Responsibility |
|---|---|
| SettingsPanel.lua | One canvas registration, sidebar, tab selection, responsive layout, scrolling, refresh and reset confirmation |
| SettingsWidgets.lua | Waypoint UI-matched tab button, check button, text buttons, selection menu, range, input and scroll bar; artwork resolver with flat fallback |
| SettingsTabs.lua | Six tab definitions and owned-setting/status refresh |
| SettingsSchema.lua | Shared display labels, groups and expected types; no shared values or duplicated numeric constraints |
| WaypointSettingsAdapter.lua | Public API capability check, validation, fresh reads, subscriptions, failures and one-time map default |
| Core.lua | Existing Config plus owned stepSound default and new-install initialization marker |
| Sync.lua | A single additional suppression condition in the existing audio write path |

General has synchronization, strategy, real RestedXP arrow preference and compact
connection status. Waypoint mirrors mode and behavior controls. Appearance contains
bridge icons/colours plus grouped shared visual controls. Map handles shared pin
preferences. Audio separates the owned new-step toggle from global/proximity/custom
sounds. About sits at the sidebar bottom and has logo, current version, credits,
links, diagnostics, open-Waypoint-UI and confirmed bridge reset. Public preview
controls are removed; Preview.lua and slash commands are unchanged.

The first layout approximated Waypoint UI; it was replaced by the visual-parity
revision below.

## Visual-parity revision (Waypoint UI-matched layout)

The first tabbed page was a loose approximation (bordered grey tab rectangles,
flat black rows) and its tabs did not switch in game. It was rebuilt from
Waypoint UI's own source values:

| Element | Waypoint UI source | Implementation |
|---|---|---|
| Frame placement | Settings.lua OnShow | Root 16 px left of, 10 px above and 6 px below Blizzard's canvas (all points with ElvUI) |
| Sidebar | Settings_UI.lua | 212 px; 2 px divider (142.5 grey, 0.2375 alpha); tabs inset 22.5 px, 35 px high, 3 px apart; About anchored at the bottom |
| Tab button | Settings_Widgets TabButton, Art/Settings/TabButton | Transparent when idle, white text at 0.5, left-aligned 11.5 px in; grey hover/pushed art; gold selected art with white text |
| Pages | Settings_Widgets Tab | One frame and scroll frame per tab, shown/hidden by SelectTab like OpenTabByIndex; content 17.5 px inset, 22 px scroll-bar gap, 22 px top; 0.1 s hold + 0.2 s fade intro |
| Containers | ContainerWithTitle, Art/Settings/Widget-Container | Gold 14 pt title in a 32 px strip, 15 px in; rounded container art 3.5 px outset; rows 12.5 px inside, 10 px apart, 7 px tail |
| Rows | ElementBase, Art/Settings/Widget-Background | Label 12 pt, description 11 pt at 0.5; 10 px margins; info 55 % - 20; control right-aligned 2 px in; hover highlight 5 px outset; Waypoint UI indents (15 px) |
| Check button | uic-common check-button | 25 x 25 atlas, checked/disabled variants |
| Selection menu | uic-common button/selection-menu | Grey button art, 12 pt text, arrow; menu 6 px below, at least 175 px, 28 px rows (14 pt, gold selected), menu art at 0.925 |
| Range | uic-common range | 188 x 19; right-aligned gold 11 pt value; track, thumb and stepper art |
| Input, buttons, scroll bar | uic-common | 188 x 32 input, red text buttons, 10 px scroll bar with 6 px track; 150 px interpolated wheel steps |

Art: `SettingsWidgets.lua` lists the texture regions; `WUI.HasVerifiedArt()`
requires a loaded Waypoint UI 1.7.x. Otherwise flat colours draw the same layout.

Deliberate differences from Waypoint UI:

- The dropdown widens past 125 px to fit its longest option, and a wide control
  makes the row's text wrap rather than overlap (Waypoint UI lets a 188 px range
  overlap long labels). Sliders shrink to 140 px only on very narrow canvases.
- A page whose blocks fit the view gets no scroll bar; Waypoint UI always adds
  240 px of scroll room, which this page adds only to pages that already scroll.
- No custom-font preference (Waypoint UI's Font option is private); text uses
  the game font, as Waypoint UI's default "Game Font" does.
- No menu outro animation; the menu simply hides.

General starts with a compact header (logo, name, version, subtitle), then
Synchronization (auto-sync, Navigation Strategy, Hide RestedXP Arrow in one
container) and Connection Status. The strategy dropdown lists Hybrid
(Recommended), RestedXP Coordinates and Blizzard Waypoints (ids `hybrid`,
`coordinates`, `native-first`, unchanged); the description under it follows the
selection. About shows Waypoint UI's title layout (faint 138 px logo, name,
version) above the information, diagnostics and reset containers.

Connection Status rows show an icon and label left and the status right:
Connected (green check), Disconnected (red cross), Active (green check),
Disabled (grey pause), Paused (amber pause: manual navigation or preview) and
errors (red warning: RestedXP arrow or Waypoint UI API missing, or sync
unavailable). Details are on hover. They refresh on opening, on Config changes,
on dependency ADDON_LOADED while shown, and from `Sync.RegisterStatusListener`,
which reports running/paused changes from Start/Stop and the existing ticker
(no new timer). Glyphs are original drawings (`tools/draw_status_icons.py`).

Tab-switch investigation: BugGrabber held no error from this addon, and the
previous panel, replayed in the new geometry harness, received the tab clicks
and switched pages. The in-game cause could therefore not be reproduced
offline. The rebuild removes the paths by which the old page depended on later
steps: page visibility and the selected look change first (one frame per tab,
not one shared item list re-filtered by Layout), a refresh error cannot prevent
the switch, layout of a not-yet-sized canvas is retried on the next frame, and
the offline suite now clicks every tab through hit-testing.

`tests/harness.lua` now resolves anchors into rectangles, clips scroll frames,
orders frames by strata/level and hit-tests clicks (`H.ui.click`, `H.ui.wheel`,
`H.ui.moveTo`). `tests/settings_ui_test.lua` covers frame and sidebar geometry,
clicking every tab, a single visible page, selected/hover/pushed looks, controls
reachable in view and unreachable on other tabs, a failing refresh, containers
and rows, the strategy dropdown (order, labels, no truncation, description,
outside click), per-page scrolling and clipping, provider-driven sliders,
steppers, dropdowns, inputs, indents and conditional rows, fallback buttons,
layout at five canvas sizes, connection states and the flat-art fallback. It
approximates fonts and draws nothing.

Visual-parity in-game checklist (restart the client once: new textures):

1. Click every tab, then General again: one page at a time, gold selected tab,
   others transparent with faded text; hover gives the grey highlight.
2. Compare with Waypoint UI's own page side by side: sidebar position relative
   to the AddOns list, divider, container corners, headings, spacing.
3. Toggle checkboxes; open the strategy dropdown and pick each option (full
   labels, description changes); click outside an open menu.
4. With the development API build: drag sliders and use the arrow steppers;
   edit a sound ID; check conditional and indented rows.
5. Without it: each shared tab shows only its one Waypoint UI button, which
   opens Waypoint UI's settings.
6. Scroll a long page with the wheel and the bar; switch tabs and back.
7. Open About; check the logo appears only in General's header.
8. Check Connection Status with auto-sync off, a manual pin, `/rxpw preview`,
   and Waypoint UI disabled at character select.
9. `/reload` and restart: settings persist; repeat at UI scale 0.65 and 1.15.

## Every shared preference

**Synchronization column:** `API v1` means bidirectional writes/notifications work
in offline provider and actual-source tests with the proposed patch. **All rows
are disabled on standard Waypoint UI 1.7.3. None is claimed live-client verified.**
Defaults below are Waypoint UI defaults; only the eligible first-run map-pin
initialization changes the default preference. Range notation is min..max / step.

| Control | Key | Waypoint UI default | Values / constraints | Two-way |
|---|---|---|---|---|
| Waypoint Mode | `WaypointSystemType` | `1` | 1 Both; 2 Waypoint; 3 Pinpoint | API v1 |
| Show When UI Is Hidden | `AlwaysShow` | `false` | boolean | API v1 |
| Right-Click To Clear | `RightClickToClear` | `true` | boolean | API v1 |
| Fade On Hover | `BackgroundPreview` | `true` | boolean | API v1 |
| Show Pinpoint At... | `DistanceThresholdPinpoint` | `100 on Forever; 325 otherwise` | 50..500 / 5 yd (client metric conversion) | API v1 |
| Hide At... | `DistanceThresholdHidden` | `25` | 1..100 yd (converted endpoints), step 1 | API v1 |
| Additional Info | `WaypointDistanceTextType` | `1` | 1 All; 2 Distance; 3 Arrival Time; 4 Destination Name; 5 None | API v1 |
| Show Destination Info | `PinpointInfo` | `true` | boolean | API v1 |
| Show Extended Info | `PinpointInfoExtended` | `true` | boolean | API v1 |
| Show In Quest Blob | `PinpointAllowInQuestArea` | `false` | boolean | API v1 |
| Enable Navigator | `NavigatorShow` | `true` | boolean | API v1 |
| Context Icons | `ContextIconAppearance` | `Enum.ContextIconAppearance.Diamond` | 1 Diamond; 2 Circle | API v1 |
| Waypoint Scale | `WaypointScale` | `1` | 0.1..5 / 0.1 | API v1 |
| Use World Scale | `WaypointUseWorldScale` | `true` | boolean | API v1 |
| Minimum World Scale | `WaypointScaleMin` | `0.01` | 0.01..1 / 0.01 | API v1 |
| Maximum World Scale | `WaypointScaleMax` | `2` | 1..2 / 0.1 | API v1 |
| Waypoint Opacity | `WaypointAlpha` | `1` | 0.1..1 / 0.1 | API v1 |
| Show Waypoint Beam | `WaypointBeam` | `true` | boolean | API v1 |
| Beam Opacity | `WaypointBeamAlpha` | `1` | 0.1..1 / 0.1 | API v1 |
| Footer Font Style | `WaypointDistanceTextFontFlags` | `1` | 1 None; 2 Outline; 3 Thick Outline; 4 Monochrome | API v1 |
| Show Footer | `WaypointDistanceText` | `true` | boolean | API v1 |
| Footer Scale | `WaypointDistanceTextScale` | `1` | 0.1..2 / 0.1 | API v1 |
| Footer Opacity | `WaypointDistanceTextAlpha` | `0.7` | 0..1 / 0.1 | API v1 |
| Additional Text Opacity | `WaypointDistanceSubtextAlpha` | `0.7` | 0..1 / 0.1 | API v1 |
| Pinpoint Scale | `PinpointScale` | `1` | 0.5..2 / 0.1 | API v1 |
| Pinpoint Opacity | `PinpointAlpha` | `1` | 0.1..1 / 0.1 | API v1 |
| Pinpoint Context Icon Visibility | `PinpointShowContextIcon` | `true` | boolean | API v1 |
| Pinpoint Font Style | `PinpointFontFlags` | `1` | 1 None; 2 Outline; 3 Thick Outline; 4 Monochrome | API v1 |
| Pinpoint Text Alignment | `PinpointTextAlignment` | `1` | 1 Leading; 2 Justified; 3 Trailing | API v1 |
| Navigator Show Context Icon | `NavigatorShowContextIcon` | `true` | boolean | API v1 |
| Show Arrow | `NavigatorShowArrow` | `true` | boolean | API v1 |
| Navigator Scale | `NavigatorScale` | `1` | 0.5..2 / 0.1 | API v1 |
| Arrow Scale | `NavigatorArrowScale` | `1` | 0.8..1.2 / 0.1 | API v1 |
| Navigator Opacity | `NavigatorAlpha` | `1` | 0.1..1 / 0.1 | API v1 |
| Navigator Distance | `NavigatorDistance` | `1` | 0.1..3 / 0.1 | API v1 |
| Dynamic Distance | `NavigatorDynamicDistance` | `true` | boolean | API v1 |
| Use Waypoint UI Map Pins | `CustomMapPinsEnabled` | `false` | boolean | API v1 |
| Auto-Track Pin | `AutoTrackPlacedPinEnabled` | `true` | boolean | API v1 |
| Auto-Track Pin from Link | `AutoTrackChatLinkPinEnabled` | `true` | boolean | API v1 |
| Track Guide Pin | `GuidePinAssistantEnabled` | `true` | boolean | API v1 |
| Enable Sound | `AudioGlobal` | `true` | boolean | API v1 |
| Use Proximity | `AudioProximity` | `false` | boolean | API v1 |
| Arrival Distance | `AudioProximityDistance` | `200` | 1..1000 / 1 | API v1 |
| Arrival Sound ID | `AudioProximitySound` | `Enum.Sound.ProximityEntry` | nonnegative integer sound ID; blank = mute | API v1 |
| Departure Distance | `AudioProximityLeavingDistance` | `200` | 1..1000 / 1 | API v1 |
| Departure Sound ID | `AudioProximityLeavingSound` | `Enum.Sound.ProximityLeaving` | nonnegative integer sound ID; blank = mute | API v1 |
| Use Custom Sounds | `AudioCustom` | `false` | boolean | API v1 |
| Waypoint Appearance Sound ID | `AudioCustomShowWaypoint` | `Enum.Sound.WaypointShow` | nonnegative integer sound ID; blank = mute | API v1 |
| Pinpoint Appearance Sound ID | `AudioCustomShowPinpoint` | `Enum.Sound.PinpointShow` | nonnegative integer sound ID; blank = mute | API v1 |
| New Navigation Sound ID | `AudioCustomNewUserNavigation` | `Enum.Sound.NewUserNavigation` | nonnegative integer sound ID; blank = mute | API v1 |

`PrefMetric` is an additional allowlisted dependency, default false, observed for
formatting and dynamic range refresh; it is not a mirrored control in this panel.

## Dependencies and formatting

Describe walks each allowed setting's path in Waypoint UI's own schema and
resolves all ancestor showWhen/disableWhen conditions. Mode 1 shows both marker
families, mode 2 waypoint, mode 3 pinpoint. The transition distance is mode 1 only.
Extended info requires PinpointInfo. World min/max require world scale; beam
opacity requires the beam; navigator appearance requires NavigatorShow. Proximity
and Customize require AudioGlobal; their children additionally require their own
parent toggles. Chat-link auto-track is shown only when placed-pin auto-track is
off. Empty conditional group headings are hidden.

The native schema currently checks a misspelled key
`waypointwaypointDistanceTextType` for footer visibility. This patch deliberately
preserves native behavior; correcting that upstream defect is a separate change.
The adapter does not invent substitute conditions.

Numeric descriptors and formatting come fresh from the provider. In metric mode
Waypoint UI converts threshold endpoints with ceil(yd * 0.9144), and its formatter
converts values again for display. For example its threshold range becomes
46..458 / 5 and Format(100) is 92 m. Audio thresholds retain the source's numeric
1..1000 range. These source semantics are preserved, not corrected speculatively.
Scale/alpha sliders use the schema's percentage format.

Sound IDs are committed on Enter; blank mutes. Sound preview and reset remain
available through Open Waypoint UI Settings, preserving its FileMap and native
sound-player mechanisms. No bridge replacement sound player was introduced.

## Public API and fallback

The portable development patch is `integrations/waypoint-ui-settings-api.patch`.
It adds an allowlisted Settings v1 block to upstream API.lua and SETTINGS_API.md;
no installed files are changed and no upstream source is bundled in release ZIPs.
The separate development checkout is `E:\Dev\Waypoint-UI-settings-api`.
Apply the patch to a clean compatible checkout with `git apply --check` and
`git apply` only when preparing that separate development environment.
Upstream acceptance and release are external dependencies, not completed work.

The contract is Get, Set, Describe, Format, IsExplicit and OnChange. Describe
returns detached scalar metadata/options, using the existing schema and defaults.
Set validates types, finite bounds, steps, enum indices and sound IDs; it uses
DBGlobal:SetVariable so existing callbacks run normally, and then the native UI
refresh path. Unknown/arbitrary database keys are rejected. OnChange supports a
specific key or wildcard and returns an unsubscribe function. Consumer callback
errors are isolated. No-ops produce no duplicate writes or callbacks.

The bridge adapter verifies API version and methods, validates descriptors and
returned values, catches provider errors, and registers one reusable subscription.
Replacing providers unsubscribes the old one. Panel listeners refresh only when
shown, reread on opening and suppress slider writes during programmatic updates.
There are no new polling loops or navigation writes for shared settings (the
only OnUpdate is the short-lived smooth-scroll interpolation). Without the public
API the shared rows are not shown at all: each shared tab shows one stacked
"Open Waypoint UI — <Tab> Settings" button instead. Waypoint UI's public
OpenSettingsUI() cannot select a tab (tab selection is the private
Setting:OpenTabByIndex), so the button opens Waypoint UI's settings where they
were last left (General the first time) and its text says which tab to choose.
With the API connected the editable rows replace the button; an individual
invalid descriptor still shows that one row disabled with an explanation.
Shared preferences never enter RXPWDB.

## First-run map-pin default and persistence

Only creation of a new RXPWDB table records mapPinsDefaultPending. At login or
opening the page, an available API must positively report IsExplicit(false)
before the adapter sets CustomMapPinsEnabled(true). Explicit true/false is
preserved and resolves the marker. Successful initialization removes the marker.
Existing RXPWDB tables never acquire it. No API or uncertain explicitness means
no write; the pending marker can safely defer until support is installed. It is
never re-created by Restore Defaults. Later opt-outs remain false. A reset affects
only bridge-owned settings plus the existing approved RestedXP arrow default.
The native MapPinEnhanced compatibility gate remains authoritative even with the
preference enabled. Other map/pathfinding/provider settings are untouched.

The only new normal saved preference is stepSound=true. Existing false values,
strategies, debug, sync and appearance choices remain. Turning stepSound off gates
the existing successful navigation write; it does not change step observation,
create new writes or replay a consumed opportunity when reenabled. Global audio
and independent marker/proximity paths stay under Waypoint UI's control.

## Validation

Recorded on 2026-10-17:

- `node tests/run.js`: 26 suites, 1,606 assertions passed, zero failures.
- Visual-parity revision: 27 suites, 1,728 assertions passed, zero failures
  (adds `settings_ui_test.lua`, 121 hit-tested interaction assertions).
- `node tests/run-waypoint-api.js <separate-Waypoint-UI-checkout>`: 328 real-source
  assertions passed: schema, defaults, enums, handler, callback registry and API.
- `python -m unittest discover -s tests -p test_package_release.py`: 18 tests
  passed, including TOC-selected modules and exclusion of development artifacts.
- luaparse in Lua 5.1 mode: all 12 bridge runtime modules and patched upstream
  API.lua parsed successfully (13 files).
- Both repositories pass git diff --check. The portable patch passes reverse
  applicability against the development implementation. No public package was
  built or released.

Tests cover every shared key in both directions, no-op deduplication, invalid
values/descriptors/provider failures, slider/dropdown bounds, conditional rows,
subscription replacement/unsubscribe, repeated opening, saved preference migration,
first-run unset versus false, reset scope, retained preview slash commands,
new-step audio toggle, right-click-equivalent ClearDestination safety, and the
unchanged route/native/manual-resumption regression suites. Mocked tests and
source execution do not prove actual in-game integration.

## Focused WoW Forever acceptance (not performed by this agent)

1. Standard Waypoint UI first: `/console scriptErrors 1`, `/rxpw config`; visit
   all six tabs and run the visual-parity checklist above.
2. Use a separately installed development API build only in a deliberate test
   environment. Change a checkbox, dropdown, slider and sound ID in each menu;
   reopen/switch back and confirm the other menu and live renderer/audio agree.
   Test metric toggling in Waypoint UI, all three modes and each parent condition.
3. Test fresh bridge variables plus unset Waypoint UI map preference, then saved
   false, saved true and existing bridge profiles. Inspect pin appearance after
   `/reload`; test with MapPinEnhanced present. Never erase a real profile solely
   for testing: use a disposable profile or back it up while the game is closed.
4. Follow A -> B -> C in one guide step, then a genuine new step. Confirm one
   creation sound per real step with the bridge toggle on, none with it off,
   quiet login/recovery and no sound replay on reenabling. Test global mute,
   independent waypoint/pinpoint show sounds and proximity entry/departure.
5. Right-click the bridge marker: it must stay cleared through quest events and
   reopening settings. Set a foreign pin/quest; advance the guide; clear the
   foreign target and confirm the existing one-second idle resumption rule.
6. Check coordinates/hybrid/native-first, intermediate travel waypoints, native
   turn-in verification, objectives/progress, labels, quest/service icons and
   colours. Shared appearance changes must not modify RXP route selection.
7. Start `/rxpw preview all far`, open/close settings, then `/rxpw preview off`.
   Confirm preview remains controllable and synchronization resumes correctly.
8. Change bridge and shared values; cancel then confirm About's Restore Defaults.
   Shared Waypoint UI settings must survive. `/reload` and normal logout/restart
   must preserve both addons' authoritative preferences without duplicate writes.

Release gate: in-game rendering, actual audio, Forever API behavior, persistence
and the development API integration remain unverified. The redesign can run with
the normal dependency today; full shared editing requires a compatible future
upstream API or explicitly installed development build. No claim of upstream
acceptance or production release readiness is made before those acceptance tests.
