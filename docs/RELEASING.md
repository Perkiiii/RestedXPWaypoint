# Releasing RestedXP Waypoint

One development checkout produces installation packages. Nothing needs moving or
deleting for normal development. Generated ZIPs/checksums stay in ignored
`.release/`; tests, tools, artwork sources and internal reports stay in the repo.
There is no automatic commit, tag, upload or publication.

## Commands (from the repository root)

Use Python **3.9+**, Node.js and npm. Packaging uses only Python's standard
library. Install the existing pinned Lua test dependency once (or after its
lockfile changes):

```powershell
npm ci --prefix tests
node tests/run.js
python -m unittest discover -s tests -p test_package_release.py
```

Then choose a package:

```powershell
# Fast RC, including structural/asset/ZIP checks but without running regressions
python tools/package_release.py
# Same RC, with both test suites
python tools/package_release.py --kind rc --test
# Production: both test suites are mandatory, with no skip option
python tools/package_release.py --kind release
```

The tool reads `## Version` from `RestedXPWaypoint_Camelot.toc`. For example:

- RC: `.release/RestedXPWaypoint-0.6.1-RC-20261016.zip`. Further RCs on the same
  machine-local date gain a time suffix; previous candidates are preserved.
- Production: `.release/RestedXPWaypoint-0.6.1.zip`.
- Both have a sibling `.zip.sha256` and an internal `RELEASE_MANIFEST.json` with
  per-file SHA-256/lengths, version, build kind and whether regressions ran.

Production refuses to overwrite an existing ZIP or checksum. If intentionally
rebuilding an unpublished version, retain the old pair elsewhere under `.release/`
first. Published changes should get a new version. Build from any working
directory by using the absolute path to the script; outputs still go here.
No clean-Git requirement: packages include current working files, including
untracked required assets. Review and back up your changes independently.

## Version and changelog

1. Develop normally and run the tests above.
2. Set the TOC's `## Version` to `MAJOR.MINOR.PATCH`, without leading zeros.
   Patch = bug fixes; minor = features; major = significant breaking changes.
   For this pre-1.0 project, document breaking changes explicitly; the maintainer
   decides when 1.0 is appropriate. RC is a filename/build kind, not a TOC suffix.
3. Move the relevant Unreleased notes into `## [X.Y.Z]` in `CHANGELOG.md`, with
   Added, Changed, Fixed and Known Issues as relevant. Set a publication date only
   when known. Do not infer historical notes or claim unperformed in-game tests.
4. Generate an RC if useful, then the production ZIP. Production requires a
   nonempty changelog section matching the TOC version.
5. Test the **extracted production ZIP** in WoW, then manually upload that exact
   ZIP. Any source change after testing requires another build and acceptance.

The TOC is the only authoritative version field. The README refers users to it;
changelog headings record history and the test runner checks version syntax.
Core reads installed addon metadata at runtime; the settings menu, help and
status all use it. The Lua test runner also supplies the TOC version to its mock
metadata, so tests need no separate version edit. After changing the TOC, fully
exit and restart WoW so the client rereads addon metadata; do not rely on
`/reload` to refresh a TOC version.

## What the tool validates

- TOC identity, interface 16001, dependency declarations, SavedVariables name,
  unique safe root Lua entries, valid version and presence of all loaded modules.
- Referenced local BLPs, including logo, service, default and gold quest icons:
  existence, dimensions, raw BGRA BLP2 encoding and payload lengths.
- A narrow package policy: TOC modules, resolved BLPs, README, CHANGELOG, ARTWORK
  and generated manifest only. No recursive directory copy or dependency bundle.
- Packaged text for obvious drive/home/UNC paths, private keys, recognizable
  GitHub tokens and top-level personal SavedVariables/account dumps. This is a
  heuristic, not a comprehensive personal-data or secret detector.
- User documentation's local file links point to packaged files.
- Production runs packaging tests and every existing Lua regression suite through
  `node tests/run.js`. Failure/missing tooling blocks production before ZIP output.
- Reopened ZIP: exact expected entries, no duplicates/traversal, single addon
  folder, CRC integrity, manifest hashes and actual temporary extraction with
  byte equality to the source snapshot. Sources are rechecked after tests/build.
- SHA-256 sidecar. Invalid newly created ZIPs are removed; older files are kept.

Missing dependencies **in the client** are not packaging blockers: they remain
external requirements. Guarded runtime handling is unchanged. A dirty checkout,
untracked required files, and pending manual acceptance/license decisions are not
automatic test failures. A successful build means automated checks passed, not
that permission, gameplay acceptance or CurseForge moderation has been established.

## Maintaining the package policy

Root `.lua` entries in the TOC are collected automatically in TOC order. Nested
Lua/XML entries are intentionally unsupported until explicitly reviewed. TOC
module-order regressions remain checked by `tests/run.js`; update its expected
order when deliberately changing module architecture.

`required_assets()` in `tools/package_release.py` reads literal double-quoted
`\\Art\\...` suffixes and the current WaypointAdapter `SERVICE_ICONS`,
`QUEST_GOLD_ICONS`, `DEFAULT_ICON` conventions. Adding a mapped icon or changing
one of those filenames is picked up automatically; its `.blp` must already exist.
Only referenced assets are packaged; unrelated BLP/PNG/source art is ignored.
This small static scanner is not a Lua evaluator. New dynamic constructions,
single-quoted/long-string paths, a new texture format or directory layout require
reviewing the scanner and adding a focused packaging test. Never replace this
policy with a whole-repository or whole-art-directory glob.

If a license/required notice is added later, add it explicitly to `DOCUMENTS` and
test the resulting package. Keep `ARTWORK.md` accurate. Do not regenerate artwork
or copy installed dependency files as part of a release build.

## Manual installation and upload checklist

- [ ] Review the diff, TOC version and changelog. Confirm all intended changes
  are present; no commit or tag is made by these commands.
- [ ] Resolve the provenance/redistribution review in `ARTWORK.md`, choose the
  project's distribution license, and include any required permission notices.
- [ ] Compare the ZIP's SHA-256 with its sidecar (`Get-FileHash <zip> -Algorithm SHA256`).
- [ ] Close WoW; extract into a safe test client's `Interface/AddOns`. Do not
  overwrite the development junction. Exactly one `RestedXPWaypoint` directory
  should contain the Camelot TOC, Lua files and Art directory.
- [ ] Install RestedXP Guides and Waypoint UI separately; start Forever 1.60.1,
  enable all three addons, `/console scriptErrors 1`, `/rxpw status`, `/rxpw config`.
- [ ] Check multi-waypoint routes, labels/progress, quest/service/default icons,
  settings, preview/off, manual override and resumption, each supported strategy,
  `/reload` and normal logout/full restart. Native First stays experimental.
- [ ] Disable each dependency separately and restart: clear status/missing-addon
  feedback, settings still accessible, no Lua errors. Restore both afterward.
- [ ] Record actual results/client and dependency versions. Offline mocks and
  extracted-byte checks do not test rendering, live APIs, pathfinding or persistence.
- [ ] Upload the validated production ZIP manually, with its version's changelog.

## CurseForge settings to configure manually

Create **RestedXP Waypoint**, game **World of Warcraft**, class **Addons**, an
appropriate quest/navigation category, clear unofficial description, logo and
the license you have selected. Add screenshots after checking them in game.

For each file select **Forever**, game version **1.60.1** (TOC interface **16001**,
client flavour **camelot**). Do not claim Retail, Classic Era or other client
compatibility without testing. CurseForge currently lists Forever / 1.60.1 on
[Forever addon files](https://www.curseforge.com/wow/addons/forever-unit-frames/files/all).
Recheck available labels when uploading rather than selecting an unrelated version.

Mark production files **Release** and externally shared RCs **Beta**. Configure
**Required Dependency** relations for the correct RestedXP Guides and Waypoint UI
projects/files, ensuring each supports Forever. If the appropriate dependency
project is unavailable on CurseForge, state its separate installation requirement
and official download location in the project description instead of linking an
unrelated project. The folder names remain `RXPGuides` and `WaypointUI`. TOC
OptionalDeps are deliberately kept so missing-dependency diagnostics can load.

CurseForge's [submission guide](https://support.curseforge.com/support/solutions/articles/9000197241-creating-and-submitting-a-project)
documents file type, changelog, supported-version and Related Projects settings.
The site can change; verify the chosen settings at upload. Automated publishing
can later call the same release command and consume its ZIP, JSON result and
checksum; credentials and upload logic do not belong in the package builder.
