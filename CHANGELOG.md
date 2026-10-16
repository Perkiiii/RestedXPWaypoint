# Changelog

The TOC is the authoritative version. Entries describe changes in this codebase;
an entry does not establish that a version was published or tested in game.
Earlier milestones are documented in the source repository's development reports;
historical release notes have not been reconstructed here.

## [Unreleased]

Record future changes here under Added, Changed, Fixed or Known Issues. Move them
to a versioned section when preparing that version.

## [0.6.2] - Publication pending

### Changed

- Hybrid is the recommended default navigation strategy for new installations
  and Restore Defaults. Existing saved strategy selections are preserved.
- The navigation dropdown labels it "Hybrid (Recommended)".
- Debug remains off by default; all other menu checkboxes default to on.
  Hide RestedXP Arrow is enabled once for a new installation and by Restore
  Defaults through RestedXP's own option. Existing choices survive normal startup.

### Fixed

- Updated the authoritative TOC version to 0.6.2, which supplies the settings
  menu, slash-command output and release package filenames.
- Settings tests now use the TOC version instead of a duplicated version value
  and check that the menu follows installed addon metadata.

## [0.6.1] - Publication pending

### Added

- Repeatable RC and production packaging with validation, manifests and checksums.
- A bundled default waypoint icon and gold quest glyphs.

### Fixed

- Service presentation for waypoint-local purchase instructions, including the
  Mining Pick case, and innkeeper instruction detection.
- Automatic navigation resumption after external tracking is cleared, stale
  bridge marker cleanup, and startup handling of inherited quest tracking.

### Changed

- Navigation creation audio is limited to the first necessary coordinate write
  for an observed RestedXP progression step; marker-intro audio is controlled
  separately by Waypoint UI.

### Known Issues

- Native First remains experimental; mocked tests cannot prove live quest POIs,
  rendering, Settings behavior or client persistence.
- Same-coordinate presentation updates can restart Waypoint UI's marker intro
  and rebuild enabled pathfinding.
- Inherited same-quest tracking at reload has an intent ambiguity; manual pins
  remain protected. See the README for startup behavior.
- Public distribution requires the maintainer's artwork permission/provenance
  review and project license selection; see ARTWORK.md.
