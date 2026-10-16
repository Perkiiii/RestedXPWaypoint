# Release workflow verification — 16 October 2026

TOC version remains **0.6.1**, interface **16001**, client flavour **camelot**.
No runtime code, artwork, dependency addon, TOC version, Git index or history
was changed by this release-tooling task. Existing working-tree changes and
untracked assets/tests remain in place.

## Audit and implementation

Reviewed repository/file inventory and Git status, the existing packager and its
uncommitted icon-list extension, TOC/load order, runtime dependency guards and
texture construction, artwork generation/source locations, test runner, README
and release-readiness evidence. Read installed dependency metadata and Waypoint
UI public API documentation without modifying either dependency.

The old script already offered safe explicit inclusion, BLP format checks,
version reading, manifests, ZIP CRC/source-byte checks, SHA-256 and exclusive
creation. These were retained and extended rather than adding another packager.
Its current uncommitted list already covered DefaultWaypoint, QuestAvailable
and QuestComplete; none of the current runtime artwork was missing. Its weakness
was future maintenance: a duplicate module list and fixed icon list, RC-only
output, no automated production regression gate and a hard-coded test version.

Changed by this task:

- `tools/package_release.py`: TOC-selected Lua files, source-convention-selected
  BLPs, RC/production CLI, mandatory production tests, changelog gate, text/link
  checks, exact ZIP policy, actual temporary extraction verification and cleanup.
- `tests/run.js`: version syntax check replaces the fixed 0.6.1 expectation;
  all other metadata/module-order checks and Lua suites remain intact.
- `tests/test_package_release.py`: 18 focused stdlib tests of inclusion/exclusion,
  newly mapped icons/modules, versions, bad/missing data, production gating,
  collisions, source changes and archive failures.
- `README.md`: installation guidance usable in both build types, standalone audio
  advice, current manual-navigation/startup limitations and accurate art credit.
  Removed broken links to excluded internal docs; developer commands now live
  in `RELEASING.md`.
- `CHANGELOG.md`, `ARTWORK.md`, `docs/RELEASING.md`: version process, recorded
  current changes without invented publication history, provenance gaps and
  exact release/manual CurseForge steps.
- `docs/STAGE6_RELEASE_READINESS.md`: added a historical-report notice pointing
  to the maintained guide, preserving its previous contents and local edits.

Local pre-edit copies of the three existing files substantially edited here
and initial Git status are under `.release/release-workflow-baseline/`. This is
a local recovery aid, not a commit or an off-machine backup. The first production
build was retained there after a README wording correction; use the final ZIP
below. Existing RCs were preserved.

## Automated results

- **25 Lua suites, 1,258 assertions, zero failures**, plus TOC metadata/order.
- **18 packaging tests passed**, including mandatory production failure gating.
- Python compilation and Git whitespace checks passed.
- Final RC: `.release/RestedXPWaypoint-0.6.1-RC-20261016-164934834656.zip`,
  **163,297 bytes**, structural checks passed (regressions not run by this RC).
- Final production: `.release/RestedXPWaypoint-0.6.1.zip`, **163,302 bytes**,
  mandatory regressions passed.
- Both archives contain **26 entries** under `RestedXPWaypoint/`: TOC, eight
  modules, thirteen BLPs, README, changelog, artwork notes and generated manifest.
- CRC, exact contents, extraction/source equality, manifest lengths/hashes and
  archive sidecars pass. A separate post-build comparison of every manifest entry
  against current source passed for both archives. Development/personal/dependency
  paths were absent. `.release/` outputs are ignored by Git.

Production SHA-256:

`4e2729f15554f59d819b252fb7741aa559f8767144d6f6d5c5d16147f1198576`

The build log is `.release/production-build.txt`; the manual initial regression
log is `.release/regression-tests.txt`. Generated logs are excluded from packages.

## Remaining manual checks

Test the extracted production build in WoW; no live client was exercised here.
Check rendering, settings/persistence, actual guides/native targets, missing
dependencies and manual navigation as described in `RELEASING.md`. Confirm art
redistribution permissions and choose the project license before uploading.
Configure Forever/1.60.1 compatibility and external dependencies manually on
CurseForge. Successful automated packaging does not resolve these manual steps.

The asset scanner deliberately supports current source conventions rather than
arbitrary Lua. New dynamic art construction requires a scanner/test review; no
dependency files, network services or third-party Python packages are required
by the build tool. No automatic publishing infrastructure was added.
