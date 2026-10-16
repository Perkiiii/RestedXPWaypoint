"""Packaging policy and failure-path tests; no client or third-party modules."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock
import zipfile

SPEC = importlib.util.spec_from_file_location(
    "package_release", Path(__file__).resolve().parents[1] / "tools/package_release.py")
P = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(P)


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="rxpw-package-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.version, files = P.collect_sources(P.ROOT)
        self.source_count = len(files)
        for name, data in files.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)

    def edit(self, name, before, after):
        path = self.root / name
        text = path.read_text(encoding="utf-8")
        self.assertIn(before, text)
        path.write_text(text.replace(before, after), encoding="utf-8")

    def payload(self, result):
        with zipfile.ZipFile(result["archive"]) as archive:
            return {n: archive.read(n) for n in archive.namelist()}

    def test_rc_contents_manifest_checksum_and_repeat_build(self):
        # Contaminants must stay out, including unrelated runtime-format art.
        for name in ("tests/leak.lua", "tools/source.png", "docs/internal.md",
                     ".git/config", ".vscode/settings.json", "WTF/Account/secret.lua",
                     "RestedXPWaypoint.lua", "client.log", "Art/Icons/Unused.blp",
                     "RXPGuides/main.lua", "WaypointUI/API.lua"):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"must not ship")
        with mock.patch.object(P, "run_checks") as checks:
            result = P.build(self.root)
            checks.assert_not_called()
        entries = self.payload(result)
        self.assertEqual(result["entries"], self.source_count + 1)
        manifest = json.loads(entries[P.FOLDER + "/RELEASE_MANIFEST.json"])
        self.assertFalse(manifest["regression_checks_passed"])
        _, files = P.collect_sources(self.root)
        self.assertEqual(set(entries), {P.FOLDER + "/" + n for n in files}
                         | {P.FOLDER + "/RELEASE_MANIFEST.json"})
        for entry in manifest["files"]:
            data = entries[entry["path"]]
            self.assertEqual(entry["sha256"], P.digest(data))
            self.assertEqual(entry["bytes"], len(data))
        output = Path(result["archive"])
        self.assertRegex(output.name, r"RestedXPWaypoint-\d+\.\d+\.\d+-RC-\d{8}\.zip")
        self.assertEqual(output.with_suffix(".zip.sha256").read_text().split()[0],
                         P.digest(output.read_bytes()))
        again = P.build(self.root)
        self.assertNotEqual(result["archive"], again["archive"])
        self.assertTrue(output.exists())

    def test_toc_version_is_authoritative(self):
        self.edit(P.TOC, "## Version: " + self.version, "## Version: 98.76.54")
        self.edit("CHANGELOG.md", "## [" + self.version + "]", "## [98.76.54]")
        with mock.patch.object(P, "run_checks") as checks:
            result = P.build(self.root, "release")
            checks.assert_called_once_with(self.root)
        self.assertEqual(Path(result["archive"]).name, "RestedXPWaypoint-98.76.54.zip")
        self.assertTrue(result["regression_checks_passed"])

    def test_toc_new_module_is_collected(self):
        with (self.root / P.TOC).open("a") as toc:
            toc.write("\nNewModule.lua\n")
        (self.root / "NewModule.lua").write_text("local addonName, RXPW = ...\n")
        self.assertIn("NewModule.lua", P.collect_sources(self.root)[1])

    def test_mapped_new_icon_is_discovered_without_packager_edit(self):
        self.edit("WaypointAdapter.lua", 'Vendor = "Bags"', 'Vendor = "NewVendor"')
        with self.assertRaisesRegex(ValueError, "NewVendor.blp"):
            P.collect_sources(self.root)
        shutil.copyfile(self.root / "Art/Icons/Bags.blp", self.root / "Art/Icons/NewVendor.blp")
        self.assertIn("Art/Icons/NewVendor.blp", P.collect_sources(self.root)[1])

    def test_missing_required_files_fail(self):
        for name in (P.TOC, "Sync.lua", "Art/Logo.blp", "Art/Icons/DefaultWaypoint.blp",
                     "Art/Icons/QuestAvailable.blp", "README.md"):
            with self.subTest(name=name):
                data = (self.root / name).read_bytes()
                (self.root / name).unlink()
                with self.assertRaisesRegex(ValueError, "missing"):
                    P.build(self.root)
                (self.root / name).write_bytes(data)

    def test_bad_versions_fail(self):
        original = (self.root / P.TOC).read_bytes()
        for version in ("1.0", "01.2.3", "1.2.03", "-1.2.3", "1.2.3-RC", "1.2.3/../../x"):
            with self.subTest(version=version):
                (self.root / P.TOC).write_bytes(original.replace(self.version.encode(), version.encode()))
                with self.assertRaisesRegex(ValueError, "Version"):
                    P.collect_sources(self.root)

    def test_bad_toc_paths_duplicates_and_metadata_fail(self):
        original = (self.root / P.TOC).read_bytes()
        for entry in ("../secret.lua", "tests/leak.lua", "C:/secret.lua", "file.xml",
                      "RestedXPWaypoint.lua", "RXPWaypointBridge.lua", "Core.lua", "core.lua"):
            with self.subTest(entry=entry):
                (self.root / P.TOC).write_bytes(original + b"\n" + entry.encode() + b"\n")
                with self.assertRaises(ValueError):
                    P.collect_sources(self.root)
        (self.root / P.TOC).write_bytes(original.replace(b"16001", b"99999"))
        with self.assertRaisesRegex(ValueError, "Interface"):
            P.collect_sources(self.root)
        (self.root / P.TOC).write_bytes(original + b"\n## Version: 0.6.1\n")
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            P.collect_sources(self.root)

    def test_corrupt_and_truncated_blp_fail(self):
        path = self.root / "Art/Icons/Bags.blp"
        data = path.read_bytes()
        for bad in (b"BLP2", b"BAD!" + data[4:], data[:-1]):
            with self.subTest(length=len(bad)):
                path.write_bytes(bad)
                with self.assertRaisesRegex(ValueError, "BLP"):
                    P.collect_sources(self.root)

    def test_obvious_machine_paths_and_personal_data_fail(self):
        for data in (b"-- E:\\Dev\\secret", b"-- /home/person/project/file",
                     b"RXPWDB = { player = 'private' }", b"-----BEGIN RSA PRIVATE KEY-----",
                     b"ghp_" + b"x" * 36):
            with self.subTest(data=data):
                with self.assertRaisesRegex(ValueError, "personal state"):
                    P.validate_text("fixture.lua", data)
        # Normal addon-relative escaped Lua paths are allowed.
        P.validate_text("fixture.lua", b'local p = "Interface\\\\AddOns\\\\WaypointUI\\\\Art"')

    def test_missing_packaged_document_link_fails(self):
        with (self.root / "README.md").open("a") as readme:
            readme.write("\n[internal](docs/internal.md)\n")
        with self.assertRaisesRegex(ValueError, "missing link"):
            P.build(self.root)

    def test_release_requires_changelog_but_rc_does_not_require_version_section(self):
        self.edit("CHANGELOG.md", "## [" + self.version + "]", "## [98.76.54]")
        with self.assertRaisesRegex(ValueError, "CHANGELOG"):
            P.build(self.root, "release")
        P.build(self.root)

    def test_release_regression_failure_produces_no_zip(self):
        with mock.patch.object(P, "run_checks", side_effect=ValueError("regressions failed")) as checks:
            with self.assertRaisesRegex(ValueError, "regressions failed"):
                P.build(self.root, "release", test=False)
            checks.assert_called_once()
        self.assertFalse((self.root / ".release").exists())

    def test_rc_test_option(self):
        with mock.patch.object(P, "run_checks") as checks:
            result = P.build(self.root, test=True)
            checks.assert_called_once()
        self.assertTrue(result["regression_checks_passed"])

    def test_both_regression_commands_and_missing_tool_errors(self):
        with contextlib.redirect_stdout(io.StringIO()), mock.patch.object(P.subprocess, "run") as run:
            P.run_checks(self.root)
            self.assertEqual(run.call_count, 2)
            self.assertEqual(run.call_args_list[1].args[0], ["node", "tests/run.js"])
        for error in (FileNotFoundError(), subprocess.CalledProcessError(1, "test")):
            with contextlib.redirect_stdout(io.StringIO()), mock.patch.object(P.subprocess, "run", side_effect=error):
                with self.assertRaises(ValueError):
                    P.run_checks(self.root)

    def test_release_is_never_overwritten(self):
        with mock.patch.object(P, "run_checks"):
            result = P.build(self.root, "release")
            original = Path(result["archive"]).read_bytes()
            with self.assertRaisesRegex(ValueError, "overwrite"):
                P.build(self.root, "release")
            self.assertEqual(Path(result["archive"]).read_bytes(), original)

    def test_source_change_during_checks_fails(self):
        def mutate(_):
            with (self.root / "Sync.lua").open("a") as source:
                source.write("\n-- changed during tests\n")
        with mock.patch.object(P, "run_checks", side_effect=mutate):
            with self.assertRaisesRegex(ValueError, "changed during tests"):
                P.build(self.root, "release")
        self.assertFalse((self.root / ".release").exists())

    def test_invalid_new_archive_is_removed(self):
        with mock.patch.object(P, "verify_archive", side_effect=ValueError("bad archive")):
            with self.assertRaisesRegex(ValueError, "bad archive"):
                P.build(self.root)
        self.assertEqual(list((self.root / ".release").iterdir()), [])

    def test_archive_extra_missing_or_changed_entry_is_rejected(self):
        result = P.build(self.root)
        payload = self.payload(result)
        path = Path(result["archive"])
        for change in ("extra", "missing", "bytes"):
            with self.subTest(change=change):
                bad = dict(payload)
                name = P.FOLDER + "/Sync.lua"
                if change == "extra":
                    bad[P.FOLDER + "/tests/leak.lua"] = b"bad"
                elif change == "missing":
                    del bad[name]
                else:
                    bad[name] = b"changed"
                with zipfile.ZipFile(path, "w") as archive:
                    for name, data in bad.items():
                        archive.writestr(name, data)
                with self.assertRaises(ValueError):
                    P.verify_archive(path, payload)


if __name__ == "__main__":
    unittest.main()
