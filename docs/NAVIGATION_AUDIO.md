# Navigation audio policy

Bridge-created custom navigation allows Waypoint UI's new-navigation sound once
per observed RestedXP progression step, on a successful destination write.
No setting or SavedVariable was added. There are no new timers, polls, manual
sound calls or navigation operations for audio.

## Installed source findings (Waypoint UI 1.7.3)

- `API.lua` documents `Navigation.NewUserNavigation(options).suppressAudio`.
- `Code/MapPin/MapPin.lua`: `NewUserNavigation` calls
  `MapPinUtil.PlayUserNavigationAudio` only when `suppressAudio ~= true`.
  The sound is `NewUserNavigation` (default sound kit 89712), optionally replaced
  by `AudioCustomNewUserNavigation` when `AudioCustom` is enabled.
- Every successful creation, including a same-coordinate rename, fires
  `MapPin.NewUserNavigation`. `Code/Waypoint/Waypoint_Director.lua` handles it
  through `OnSuperTrackingChange` and resets presentation.
- `Code/Waypoint/Waypoint.lua`: `ShowWaypoint` / `ShowPinpoint` play independent
  `WaypointShow` / `PinpointShow` audio when their intro is pending. They do not
  inspect `suppressAudio`. Defaults are `UI_RUNECARVING_OPEN_MAIN_WINDOW` and
  `UI_RUNECARVING_CLOSE_MAIN_WINDOW`. Custom choices are
  `AudioCustomShowWaypoint` and `AudioCustomShowPinpoint`.
- `packages/sound/index.lua` sends audio to WoW's SFX channel. `Preload.lua`
  connects `AudioGlobal` to the Main sound layer. The settings schema separately
  exposes `AudioCustom` and each custom sound's Mute button (empty sound ID).
- Proximity arrival/leaving sounds are a further independent path, controlled
  by `AudioGlobal`, `AudioProximity`, distance thresholds and the selected
  proximity sound IDs. They are not suppressed by the creation option either.

Automatic bridge writes previously always passed `suppressAudio = true`, so
their repeated sounds were marker introductions (or proximity/native events),
not MapPin's creation sound. Manual sync previously allowed creation audio.
This policy restores useful creation audio at genuine step changes and makes
manual sync obey the same boundary. It cannot make all Waypoint UI audio occur
once per step through the current public API.

For less repetitive audio, the player can enable **Audio > Customize > Use Custom
Sound** in Waypoint UI and use **Mute** for **When Waypoint is shown...** and
**When Pinpoint is shown...**, retaining **When commencing /way navigation...**.
These are Waypoint UI preferences and also affect its markers outside the bridge.
The bridge never changes them. A future Waypoint UI public per-navigation intro
suppression option would allow a narrower solution. No private hooks are used.

## Identity and success

`RXPAdapter.GetAudioStep` gets the RestedXP addon through the existing AceAddon
registry and reads its processed `currentGuide` and `GetGuideProgress()`.
The current progression step must be active, and the arrow's source step must
belong to the same processed guide. This allows active sticky, parent-linked
instructions and hidden patrol sources without treating source switching as
player progression. Quest IDs, labels and coordinates are not step identities.

Identity is the guide's `key` (or length-delimited group/name) plus the current
step's `stepId`, falling back to the step table for this session. Stable step IDs
survive index changes. Reprocessing the same logical guide establishes a quiet
baseline, rather than inferring progression from changed indexes or tables.
Unavailable or inconsistent source data stays quiet; the next known identity
also establishes a quiet baseline. Only evaluated, settled steps count;
automatically skipped intermediate steps do not generate writes or audio.

Sync keeps one session-only pending opportunity for a change of guide or current
progression step. It allows creation audio on that step's first necessary custom
destination write, including a verified native failure's coordinate fallback.
Waypoint UI's own audio preferences still determine whether anything is heard.
Failed writes keep the opportunity. Successful writes consume it. Adopting an
already-correct tracked bridge destination consumes it without a sound-only
write. Same-coordinate presentation changes are always suppressed. A new step
at the same destination is adopted quietly; moving later within it stays quiet.

Login/reload, sync restart (including preview recovery), loading screens,
strategy changes and guide revisions establish quiet baselines. Settings page
refreshes do not affect the policy. Icon, colour and progress refreshes remain
subject to the existing two-second presentation limit. Repeated manual sync is
quiet once that step has been handled. Manual navigation outside the bridge
continues using Waypoint UI's ordinary preferences and APIs.

Native success consumes the opportunity without synthesizing any sound.
Native setters, verification, cancellation and fallback eligibility are unchanged.
Externally generated Blizzard/RestedXP native sounds and independent marker
intros cannot be suppressed through this public custom-navigation option.

## Verification and in-game acceptance

`tests/audio_test.lua` covers login/restoration, new and same-destination steps,
five gotos, ten moving collection updates, progress presentation, sticky/helper
sources, patrol cycling, guide switches/revisions, stable step IDs, ambiguous
data, failed retries, native fallback/cancellation, manual selection during
settling, previews and sync restarts across the three strategies. The harness
records each actual `suppressAudio` argument, creation sound opportunities and
separate potential marker-intro events. It does not simulate rendering or prove
actual sound delivery in game. Existing F1-F8 suites still verify navigation.

In game:

1. Enable Waypoint UI audio; distinguish its new-navigation and marker-intro
   sounds using its custom sound controls. Optionally mute only the two intros.
2. Reload on a current step: no bridge creation sound. Enter a different step
   with a new destination: one creation sound. Follow all its route/patrol
   points and collect objectives: no further creation sound in that step.
3. Watch progress labels and toggle an appearance option: no creation sound.
   Enter a different step at the same destination: no sound-only write.
4. Jump to another step/guide with a different destination: one creation sound.
   Switch among sticky/helper sources and patrol points: no extra sound.
5. Try preview/off, auto-sync off/on, strategy switches and reload: recovery
   stays quiet. A later genuine step can sound again.
6. In Hybrid and Native First, check turn-in/objective transitions and a manual
   pin selected during a pending transition. Navigation and manual ownership
   must remain correct; external native/marker sounds may still occur.
