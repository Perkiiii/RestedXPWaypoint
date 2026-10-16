# Adaptive visual elevation: installed API investigation

## Outcome

Waypoint UI 1.7.3 does not expose a documented visual-only elevation or vertical
offset API. Adaptive elevation cannot be implemented in the bridge under the
current integration rules. No runtime Lua, destination coordinates, dependency
files or settings were changed for this investigation. No inert controls or
unused interpolation code were added.

The screenshots show the close-range marker/text overlapping the NPC name as the
player approaches. The installed source confirms a fixed relative anchor, rather
than a distance-adaptive separation. The screenshots alone do not establish the
precise contribution of camera angle, UI scale, terrain, nameplates or animations.

## Source evidence

Dependency root: `F:/World of Warcraft/_classic_beta_/Interface/AddOns/WaypointUI`.
Reads of dependency internals here are investigation only; bridge code must use
the documented public API.

| Source | Verified behavior |
| --- | --- |
| `API.lua`, documentation and exported table | `WaypointUIAPI.Navigation` supports navigation ownership, creation, querying and clearing. Options cover name, map/x/y, flags, icon, tint, recolour, sound suppression and coordinate text. There is no elevation, z-coordinate, screen offset, frame access or presentation-update API. |
| `Code/Waypoint/Waypoint_DataProvider.lua`, nav-frame block around line 210 | Obtains Blizzard's projected navigation frame through `C_Navigation.GetFrame()` and handles its creation/destruction. Distance is read through `C_Navigation.GetDistance()`. |
| `Code/Waypoint/Waypoint.lua`, `Waypoint.UpdateAnchors`, around line 891 | Main waypoint frame anchors to the navigation frame's centre. The close-range pinpoint frame anchors its bottom to the navigation frame's top with a fixed Y offset of 75 in the anchor's UI coordinate system. |
| `Code/Waypoint/Waypoint.lua`, `PinpointMixin` | Pinpoint text, size and intro/outro animations are owned by Waypoint UI. Changing the outer anchor alone without supported integration risks conflicts with anchor refresh, animations and scaling. |
| `Code/Waypoint/Waypoint.lua`, `NavigatorMixin` | Its position interpolation belongs to the separate screen-direction navigator. It is not a public offset mechanism for the close-range pinpoint shown in the screenshots. |
| `Code/Waypoint/Waypoint_DataProvider.lua`, `DataProviderUtil.GetState` | Distance thresholds select area/proximity/hidden states. These are mode/visibility controls, not a per-owner vertical offset. |
| `Code/MapPin/MapPin.lua`, `MapPin.NewUserNavigation`, around line 778 | Creation updates tracking and fires `MapPin.NewUserNavigation`, even for an unchanged destination. Reissuing navigation is not a visual position update. |

The bridge's `WaypointAdapter.SetNavigation` passes the documented options only.
`Sync.lua` observes destination changes at 0.25-second intervals and separately
rate-limits presentation refreshes. Approaching a stable destination alone does
not request a navigation rewrite. No existing bridge setting controls elevation.

## Safest implementation path

Waypoint UI would need to implement and document an owner-filtered visual policy
inside its renderer. The bridge could register that policy through the public
API, without touching renderer frames or repeatedly calling `NewUserNavigation`.
The following is a proposed contract, not an API available in the installed addon:

- Select only currently tracked custom navigation owned by `RestedXPWaypoint`,
  including its path-step presentation. Stored flags alone must not authorize
  changing the marker of a raw replacement pin or external quest.
- Apply a screen-space Y displacement to the marker and text together, relative
  to their existing anchors. Do not change map coordinates, the native navigation
  frame, target height, distance measurement, arrival checks or pathfinding.
- Read the renderer's existing distance cache and update within its existing
  render/animation loop. No new bridge per-frame poller or destination writes.
- Reset the displacement on ownership loss, target/session change, missing
  navigation, preview, loading, cancellation and unsupported API capability.
- Native quest rendering needs an explicit supported ownership/scope mechanism;
  its shared quest marker has no custom-navigation owner flag. Do not offset a
  native quest just because its ID appeared in a RestedXP step.

This works geometrically for NPC, object and ground destinations without looking
up NPC models or guessing world height. Actual nameplate separation still needs
testing across camera angles, zoom, UI scale, tall targets and multilevel terrain.

## Proposed adjustable test parameters

These are starting values for a future supported renderer implementation; they
are not active settings in RestedXP Waypoint:

| Parameter | Starting value | Meaning |
| --- | --- | --- |
| Far distance | 30 yards | At or beyond this distance, desired added elevation is zero. |
| Near distance | 5 yards | At or inside this distance, desired added elevation reaches its maximum. |
| Maximum added Y | 80 UI units | Initial close-range separation to tune in game; do not treat this as a validated physical-pixel value. |
| Smoothing time constant | 0.15 seconds | Frame-rate-independent temporal settling for noisy distance samples. |

With distance `d`, far threshold `F`, near threshold `N` and maximum `M`:

```text
t = clamp((F - d) / (F - N), 0, 1)
desiredY = M * t * t * (3 - 2 * t)
currentY += (desiredY - currentY) * (1 - exp(-elapsed / smoothingTime))
```

Smoothstep makes the target offset continuous with zero slope at both distance
endpoints. Temporal smoothing reduces jitter without a frame-rate-dependent
step size. Validate finite values, `F > N >= 0`, `M >= 0` and positive smoothing
time. Destination/ownership changes must reset presentation explicitly rather
than letting the old marker's animation drift onto a new destination.

Only add bridge configuration and controls after there is a documented capability
that can apply these values. Waypoint UI's existing global size, distance-mode
and hide-distance settings cannot meet the bridge-only elevation requirement.

## Regression and in-game acceptance for that future API

1. Check zero added offset at 30+ yards, maximum at 5 yards or less, continuity,
   monotonicity and bounded output between thresholds; exercise invalid inputs.
2. Compare temporal interpolation at different frame rates and noisy distance
   samples; ownership and target changes must reset promptly without jumping
   between unrelated destinations or preserving stale offsets.
3. Confirm manual WUI navigation, raw Blizzard pins, external quests and previews
   retain their normal anchors. Cover pathfinding and native ownership separately.
4. Verify exact map/x/y, arrival behavior, quest state, labels/icons/tints, write
   history, marker resets, path builds and sound counts remain unchanged by
   distance-driven elevation. No navigation creation is allowed for offset updates.
5. Test the innkeeper approach at approximately 40, 30, 20, 10 and 5 yards, both
   approaching and departing, at different camera pitches, zoom and UI scales.
   Repeat for an object and an unoccupied ground location.

No new automated visual behavior test is claimed: the installed public API
cannot exercise this feature, and mocks inventing such an API would not verify
compatibility. The existing full suite is run as a baseline. Runtime implementation
remains dependent on a supported Waypoint UI presentation interface.
