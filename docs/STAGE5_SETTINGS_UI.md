# Stage 5: single-page settings menu, v0.6.0

Implemented 2026-10-15. Offline verification only; the page has not been seen in
the game yet. No staging, commit, tag or push was performed, and existing
uncommitted work (v0.5.5 to v0.5.9) was preserved. HEAD is still `ced78df` (v0.5.4).

## What was investigated

**Waypoint UI's settings (1.7.3, installed, read-only).**

- **Registration.** It registers one canvas category
  (`Settings.RegisterCanvasLayoutCategory` + `Settings.RegisterAddOnCategory`)
  and opens it with `Settings.OpenToCategory(category:GetID())`. There is no
  fallback path.
- **Controls.** Every control is drawn by its private UI kit and art; it uses no
  Blizzard widget template.
- **Visual tokens:**
  - 12pt white labels with an inline 11pt description at 50% alpha.
  - 14pt gold section headers above softly shaded cards.
  - A 55% / 45% label/control split.
  - 10px row and section spacing, and a 1px text shadow.
  - Square checkboxes, flat 9-slice buttons, and a custom dropdown that opens
    below its button.
  - No tooltips.
- **Public API.** Waypoint UI documents `WaypointUIAPI.OpenSettingsUI()` as
  public (API.lua header).

**Forever client (1.60.1, Interface 16001).** Addons that target only this
client (Leatrix Plus/Maps, the BetterBlizz Forever GUIs, Waypoint UI) call the
canvas Settings API unguarded. Saved error logs show Blizzard_Settings, Menu
and ScrollBox code running. Two consequences:

- `Settings.OpenToCategory` needs the generated category ID (a name doesn't
  work), and it is a restricted call, so pcall it and never call it in combat.
- `InterfaceOptions_*` only ever appears as a guarded fallback.

## Architecture

- **One source of truth.** `RXPWDB` is the only store. `RXPW.Config` in
  Core.lua is the only way a setting changes:
  - `Config.Set(key, value)` validates the type (and the strategy name), saves
    the value, applies the existing behaviour and calls listeners.
  - The `/rxpw on`, `off`, `debug` and `mode` commands call `Config.Set`.
  - So does every control on the page.
  - The page registers a listener and refreshes itself, so a slash command
    updates an open page and reopening never shows stale values.
  - The page keeps no copy of any setting. Its only local state is the preview
    selector's chosen icon and distance (not settings, not persisted).
- **Behaviour per setting:**
  - `autoSync`: `Sync.Start` (ending a preview first) or `Sync.Stop`, with the
    same messages as before.
  - `strategy`: `Sync.OnStrategyChanged`.
  - `debug`: a chat confirmation.
  - The appearance settings: `Sync.OnPresentationChanged` (see below).
- **Loading.**
  - Registration happens once at ADDON_LOADED (`SettingsPanel.Initialize`,
    called from Core). It is idempotent and needs neither RestedXP nor Waypoint
    UI.
  - Loading costs one hidden frame; the page is built on its first OnShow.
  - With no Settings API, `InterfaceOptions_AddCategory` is used if present.
    Otherwise `/rxpw config` explains that the page is unavailable.
- **Opening.** `/rxpw config` (also `settings`, `options`) calls
  `Settings.OpenToCategory(id)` through pcall, and refuses with a message in
  combat. Nothing on the page is a protected action.
- **No OnDefault.** Blizzard's "Defaults > All Settings" would otherwise
  silently reset the navigation strategy. Restore Defaults is on the page and
  asks first.

## Layout and styling

The page is built from plain `Frame`, `Button`, `ScrollFrame` and `Slider`
frames with colour textures and font objects made from `GameFontNormal`'s font
file. It uses no Blizzard widget templates and none of Waypoint UI's art or
code. It copies Waypoint UI's tokens:

- 12pt white labels with inline 11pt descriptions at 55% alpha.
- 14pt gold section titles over a faint divider.
- One uniform background: no section cards and no row hover shading. (Cards
  were removed after in-game feedback.)
- A 55/45 label/control split.
- Tooltips on rows that need more explanation. (Waypoint UI shows no tooltips;
  ours add the limitations.)

From top to bottom, on one vertically scrolling page:

1. **Header.**
   - "RestedXP Waypoint" in 20pt gold.
   - The subtitle "RestedXP navigation, powered by Waypoint UI.".
   - The logo top-right, drawn at 80×80 from `Art/Logo.blp`, with the version
     centred under it.
   - The logo texture is 128×128 BLP2, raw BGRA. `tools/build_logo.py` builds
     it from `tools/logo_source.png`, using the artwork's own transparency
     (cropped to the visible artwork). Opaque art on a dark background is
     keyed to alpha instead. A new texture file needs a client restart.
   - Three status dots: RestedXP, Waypoint UI and Sync (running, off, paused
     for preview, unavailable).
2. **General:** Enable Automatic Synchronization.
3. **Navigation:**
   - The Navigation Strategy dropdown. Its description shows the selected
     strategy's text.
   - Hide RestedXP Arrow.
   - The note about manual waypoints.
4. **Waypoint Appearance:**
   - Three checkboxes.
   - A note that size, beams and animation are configured in Waypoint UI.
   - An "Open Waypoint UI Settings" button.
5. **Waypoint Preview:**
   - An icon dropdown (each entry shows its icon) with a swatch beside it.
   - A Close/Far segmented control.
   - Show Preview, Next Icon, Preview All and Stop Preview.
   - A live status line ("Preview active: …", "No preview is shown." or a
     leftover-marker notice).
6. **Advanced:**
   - Enable Debug Messages.
   - Print Status and Inspect Current Step.
   - Restore Defaults.

**Scrolling.**

- One scroll frame clips the page, with a thin flat slider scrollbar.
- The mouse wheel moves 60px per step. The scrollbar hides when the page fits.
- Widths follow the panel. Descriptions wrap and the page re-lays itself out on
  resize.
- There is no horizontal scrolling and no nested scroll areas.

**Dropdown lists.**

- Lists are parented to the canvas, not the clipped scroll child, at
  `FULLSCREEN_DIALOG` strata.
- They close on selection, on an outside click (`GLOBAL_MOUSE_DOWN`), on scroll
  and when the page hides.
- They open upward when there is no room below.

## Controls and their actual effect

| Control | Setting / action | Effect | Default |
|---|---|---|---|
| Enable Automatic Synchronization | `autoSync` | Same as `/rxpw on`/`off`. Off stops the ticker and cancels automatic pending work; the current destination stays. | `true` |
| Navigation Strategy | `strategy` | `coordinates` / `hybrid` / `native-first`, the same values and semantics as `/rxpw mode`. Re-evaluates now, subject to manual holds. | `"coordinates"` |
| Hide RestedXP Arrow | RestedXP's `settings.profile.disableArrow` (not stored in `RXPWDB`) | Reads RestedXP's own "Hide waypoint arrow" option live and sets it as RestedXP's own setter does: save, `DrawArrow`, then `UpdateMap()` to flag a refresh on RestedXP's next tick; the arrow hides at once. It is visual only: `updateArrowData` still assigns `RXPG_ARROW.element`, so sync continues. Disabled if RestedXP or its settings can't be read. Restore Defaults leaves it alone. | RestedXP's value |
| Quest-Specific Icons | `questIcons` | Supplies the quest icon (Available/Incomplete/Complete × quest type) on bridge-created custom waypoints. Off: no `iconTexture`, so Waypoint UI's generic "Navigation" icon. | `true` |
| Service Icons | `serviceIcons` | Supplies the bridge's service icons, all ten categories unchanged. Off: generic icon. | `true` |
| Custom Waypoint Colours | `customColors` | Supplies `r/g/b` (Waypoint UI's quest colour, or the service palette). Off: none; Waypoint UI uses its "Other" colour (or the player's own Waypoint UI colours) for frame, text and beam. | `true` |
| Open Waypoint UI Settings | action | `WaypointUIAPI.OpenSettingsUI()` (documented). Disabled if unavailable. | — |
| Preview Icon / Distance | panel-local selection | The 14 existing preview entries and the existing close/far distances. Selecting writes nothing. | Flight Master, close |
| Show Preview / Next Icon / Preview All / Stop Preview | action | `Preview.Show`, `Next`, `ShowAll` and `Off`, the same code and state as `/rxpw preview`. Stop also removes a leftover preview marker after /reload. | — |
| Enable Debug Messages | `debug` | Same as `/rxpw debug`. | `false` |
| Print Status / Inspect Current Step | action | `RXPW.PrintStatus()` / `RXPW.PrintInspect()`, output to chat. | — |
| Restore Defaults | action | A StaticPopup confirmation (or a second click if StaticPopup is missing), then `Config.RestoreDefaults()`, which calls `Config.Set` for each changed key. | — |

**Appearance details.**

- **Where it applies.** `WUI.ResolveAppearance(presentation)` is used by
  `Sync.PrepareTarget` (every strategy, coordinate waypoints) and by Preview.
- **Colour without the icon.** The colour applies only to recognised
  destinations with a shippable icon, as since v0.5.5, whether or not the icon
  is shown. With icons off and colours on, the generic icon is tinted in the
  quest or service colour.
- **Applying a change.** A change schedules the existing coalesced evaluation.
  The F4 path (`RefreshLabel`) then renames only a tracked, bridge-owned
  coordinate destination whose presentation differs, within the 2 s rename
  interval. Manual pins, other addons' waypoints, native quests and an active
  preview are never rewritten. With automatic sync off, a change applies at the
  next `/rxpw sync`.
- **What it never touches:** coordinates, labels, quest selection and
  route-critical rules.

**Inherited limitations, stated in the tooltips.**

- **Native quest markers.** They belong to Waypoint UI, so the appearance
  settings can't change them.
- **Service icons without colour.** They are stored brightness-only for
  tinting, so with custom colours off they look neutral grey.
- **Rename side effects.** Every appearance-driven rename replays Waypoint UI's
  marker intro (and rebuilds its path when pathfinding is on), as documented in
  Stage 4.
- **One colour for everything.** Waypoint UI's public API has no separate beam
  colour.

**Hide RestedXP Arrow and AGENTS rule 5.** This control writes one RestedXP
user option on the player's explicit request, as if they had ticked RestedXP's
own checkbox. No RestedXP function is replaced or hooked. All the access is in
RXPAdapter.lua (`RXP.IsArrowHidden` / `RXP.SetArrowHidden`), through the public
AceAddon registry with every field type-checked.

## Saved variables

`RXPWDB` gains `questIcons`, `serviceIcons` and `customColors` (booleans,
default `true`).

- Existing values and unrelated keys are kept, and the table identity is
  unchanged.
- A missing field, or one of the wrong type, gets its default.
- An invalid strategy falls back to `coordinates`.
- `Config.Set` rejects unknown keys and invalid values without touching the
  store.
- No migration framework was added.

## Tests

`tests/settings_test.lua`, 78 assertions:

- **Registration:**
  - exactly one category, with the right name;
  - idempotent initialization;
  - lazy construction;
  - every control built;
  - the five sections on one page;
  - header values;
  - opening by generated ID;
  - combat refusal;
  - missing RestedXP and Waypoint UI;
  - no Settings API.
- **Scrolling and dropdowns:** the mouse wheel and clamping, the dropdown
  toggle and outside-click close.
- **General/Navigation:**
  - auto-sync from the panel and from slash commands, in both directions;
  - each strategy from the dropdown, with its description and `/rxpw status`;
  - `/rxpw mode` updating an open page or a reopened one;
  - a manual pin kept.
- **Appearance:**
  - each toggle's actual Waypoint UI presentation (icon, r/g/b, label,
    coordinates);
  - one write per change, and none for an off/on toggle before the update;
  - services independent of quests;
  - manual pin, preview and native quest untouched;
  - persistence through a simulated reload.
- **Preview:**
  - defaults and the 14 entries;
  - swatch, selection and distance with no writes;
  - Show, Next (dropdown follows), All (the cycle is shown), Stop resuming sync;
  - appearance applied to previews;
  - closing the page;
  - a manual pin untouched;
  - orphan removal offered and performed from the page.
- **Advanced:**
  - debug in both directions;
  - status and inspect output;
  - Restore Defaults: popup first, only our keys reset, controls updated,
    unrelated keys and the manual pin kept, and the no-StaticPopup fallback.
- **Compatibility:** v0.5.9 settings kept; invalid values and Config
  validation.
- **Background:** one uniform background (no card or hover textures).
- **Hide RestedXP Arrow:**
  - mirrors RestedXP's option in both directions, including a change made in
    RestedXP's own page;
  - hides the arrow and requests RestedXP's refresh;
  - not stored in `RXPWDB`;
  - sync continues while hidden;
  - untouched by Restore Defaults;
  - disabled without RestedXP.

`node tests/run.js`: **15 suites, 671 assertions, 0 failures**, plus TOC
identity, version 0.6.0 and module order (`SettingsPanel.lua` last).

- All 593 earlier assertions (F1–F8, preview recovery, rename throttling,
  icons, progress, all strategies) pass. No existing expectation was changed.
- Every module parses as Lua 5.1, and `git diff --check` is clean.
- The harness's frame mock grew into a small stateful widget mock (sizes, shown
  state with OnShow/OnHide, scripts and hooks, text, textures, slider and scroll
  values; unobserved methods are explicit no-ops). It also gained Settings,
  StaticPopup and InCombatLockdown mocks. Event dispatch is unchanged.

**What offline tests cannot show:** fonts, colours, spacing and clipping;
whether the canvas is anchored as expected; the scrollbar thumb drag; real
`GLOBAL_MOUSE_DOWN` ordering; the Settings panel's restricted-call behaviour;
and the look at different UI scales.

## Performance

| Item | Cost |
|---|---|
| Load | one hidden frame and one category registration |
| First open | builds about 60 small frames and textures |
| Runtime with the page closed | none: no OnUpdate, no ticker; the Config listener returns immediately |
| Runtime with the page open | refreshes only on setting or preview changes |
| Sync | unchanged |
| Appearance changes | at most one coalesced evaluation and one rename each |

## In-game acceptance checklist

1. **Open the page.** Use `/rxpw config`, or Esc > Options > AddOns > RestedXP
   Waypoint. Check the header shows v0.6.0 and three green dots.
2. **One page.** Scroll through General, Navigation, Waypoint Appearance,
   Waypoint Preview and Advanced. There must be no tabs or sub-pages, no clipped
   or overlapping controls, and no horizontal scrollbar. Use both the wheel and
   the thumb drag.
3. **Change the strategy** with the dropdown. The description under it should
   change, and chat should confirm.
4. **Check status.** `/rxpw status` shows the same strategy.
5. **Change by command.** Type `/rxpw mode hybrid` with the page open. The
   dropdown shows Hybrid. Close and reopen the page and check again.
6. **Arrow option.** Tick Hide RestedXP Arrow: RestedXP's arrow disappears and
   Waypoint UI keeps following RestedXP. Open RestedXP Guides > Features: its
   "Hide waypoint arrow" box is ticked. Untick it there, return to RestedXP
   Waypoint, and the box is unticked.
7. **Auto-sync.** Untick Enable Automatic Synchronization: the waypoint stays
   and the Sync dot shows off. Tick it again: sync resumes.
8. **Icons and colours.** In RestedXP Coordinates mode:
   - On a quest step, untick Quest-Specific Icons; within about 2 s the marker
     shows Waypoint UI's generic icon in the quest colour.
   - Untick Custom Waypoint Colours; the marker uses Waypoint UI's default
     colour.
   - On a flight master step, untick Service Icons.
   - Re-tick all three.
   - Set a manual pin and toggle again: the pin must not change.
9. **Preview.**
   - Pick icons in the dropdown and check the swatch.
   - Choose Far, then Show Preview, Next Icon and Preview All.
   - The status line should show "Preview active".
   - Stop Preview resumes navigation.
   - Close the page during a preview, then reopen it and stop the preview.
10. **Advanced.** Toggle debug and check against `/rxpw debug`. Print Status and
   Inspect Current Step print to chat. Restore Defaults shows a confirmation;
   Cancel changes nothing, and accepting resets the settings.
11. **Persistence.** Change several settings, `/reload`, and check the page.
    Then exit the game fully, restart, and check again.
12. **UI scale.** Repeat steps 2 and 9 at a small and a large UI scale (System >
    Graphics > UI Scale): no overlaps; the dropdown list stays on screen.
13. **Missing dependencies.** Disable Waypoint UI and reload. The page opens:
    the Waypoint UI dot is red, the preview buttons and Open Waypoint UI
    Settings are disabled, and there are no Lua errors. Repeat with RestedXP
    disabled.

Also, if possible, try `/rxpw config` in combat: it should print the combat
message.
