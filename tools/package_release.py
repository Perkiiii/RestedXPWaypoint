"""Verified RC/production ZIP builder; Python standard library only.

Default: python tools/package_release.py (RC, structural checks only).
Production: python tools/package_release.py --kind release (tests mandatory).
TOC selects root Lua modules; narrow source conventions select local BLPs.
Never copies directories recursively, edits source, or modifies Git state.
"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import struct
import subprocess
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent
FOLDER = "RestedXPWaypoint"
TOC = "RestedXPWaypoint_Camelot.toc"
DOCUMENTS = ("README.md", "CHANGELOG.md", "ARTWORK.md")
VERSION = r"(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)"
PERSONAL_MODULES = {"restedxpwaypoint.lua", "rxpwaypointbridge.lua"}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def read_source(root, name):
    path = root / name
    if not path.resolve().is_relative_to(root.resolve()):
        raise ValueError("Source escapes repository (possibly a symlink): " + name)
    if not path.is_file():
        raise ValueError("Required package source is missing: " + name)
    return path.read_bytes()


def parse_toc(data):
    metadata, modules = {}, []
    for line in data.decode("utf-8-sig").splitlines():
        line = line.strip()
        if line.startswith("##") and ":" in line:
            key, value = line[2:].split(":", 1)
            if key.strip() in metadata:
                raise ValueError("Duplicate TOC metadata: " + key.strip())
            metadata[key.strip()] = value.strip()
        elif line and not line.startswith("#"):
            # Only root Lua modules; XML/nested paths require policy review.
            if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*\.lua", line) or line.casefold() in PERSONAL_MODULES:
                raise ValueError("Unsafe/unsupported TOC module: " + line)
            modules.append(line)
    for key, expected in {"Interface": "16001", "Title": "RestedXP Waypoint",
                          "SavedVariables": "RXPWDB",
                          "OptionalDeps": "RXPGuides, WaypointUI"}.items():
        if metadata.get(key) != expected:
            raise ValueError("Unexpected or missing TOC metadata: " + key)
    version = metadata.get("Version", "")
    if not re.fullmatch(VERSION, version):
        raise ValueError("TOC Version must be MAJOR.MINOR.PATCH without leading zeros")
    if not modules or len({m.casefold() for m in modules}) != len(modules):
        raise ValueError("TOC must contain unique Lua modules")
    return version, modules


def required_assets(sources):
    """Recognize literal Art paths and this addon's current icon conventions.

    OWN_ICON_PATH uses SERVICE_ICONS, QUEST_GOLD_ICONS and DEFAULT_ICON.
    No filesystem globbing; unrelated art is excluded. This isn't a Lua parser:
    new dynamic path constructions require explicit review of this function.
    External Waypoint UI/client textures are never bundled.
    """
    assets = set()
    for name, text in sources.items():
        text = re.sub(r"--\[\[.*?\]\]", "", text, flags=re.S)
        text = re.sub(r"--[^\n]*", "", text)
        for value in re.findall(r'"([^"\n]*)"', text):
            value = value.replace("\\\\", "/")
            if value.startswith("/Art/"):
                relative = value[1:]
                if relative == "Art/Icons/":
                    if name != "WaypointAdapter.lua":
                        raise ValueError("Unrecognized dynamic local art path in " + name)
                    continue
                if not re.fullmatch(r"Art/(?:Icons/)?[A-Za-z0-9_]+(?:\.blp)?", relative):
                    raise ValueError("Unsupported local art reference in " + name + ": " + relative)
                assets.add(relative if relative.endswith(".blp") else relative + ".blp")
        if name == "WaypointAdapter.lua":
            for table in ("SERVICE_ICONS", "QUEST_GOLD_ICONS"):
                match = re.search(r"local\s+" + table + r"\s*=\s*\{([^{}]*)\}", text, re.S)
                if not match:
                    raise ValueError("Cannot resolve local art table: " + table)
                values = re.findall(r'=\s*"([A-Za-z0-9_]+)"', match[1])
                remainder = re.sub(r'[A-Za-z_][A-Za-z0-9_]*\s*=\s*"[A-Za-z0-9_]+"\s*,?', "", match[1])
                if not values or remainder.strip():
                    raise ValueError("Unsupported local art table entries: " + table)
                assets.update("Art/Icons/" + value + ".blp" for value in values)
            match = re.search(r'local\s+DEFAULT_ICON\s*=\s*"([A-Za-z0-9_]+)"', text)
            if not match:
                raise ValueError("Cannot resolve DEFAULT_ICON")
            assets.add("Art/Icons/" + match[1] + ".blp")
    if "Art/Logo.blp" not in assets:
        raise ValueError("Settings logo reference was not resolved; review asset scanner")
    return sorted(assets)


def validate_texture(name, data):
    size = 128 if name == "Art/Logo.blp" else 64
    if len(data) < 1172:
        raise ValueError("Truncated BLP texture: " + name)
    width, height = struct.unpack_from("<II", data, 12)
    offset = struct.unpack_from("<I", data, 20)[0]
    length = struct.unpack_from("<I", data, 84)[0]
    if (data[:4] != b"BLP2" or data[8:12] != bytes((3, 8, 8, 0))
            or (width, height) != (size, size) or length != size * size * 4
            or offset < 1172 or offset + length != len(data)):
        raise ValueError("Unexpected BLP2 raw BGRA texture: " + name)


def validate_text(name, data):
    text = data.decode("utf-8-sig")
    patterns = (r"\b[A-Za-z]:[\\/]", r"/(?:Users|home)/[^/\s]+/",
                r"(?m)^\\\\[A-Za-z0-9_.-]+\\[A-Za-z0-9_$.-]+\\", r"-----BEGIN .*PRIVATE KEY-----",
                r"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})",
                r"(?im)^\s*(?:SET\s+accountName\b|(?:_G\.)?RXPWDB\s*=\s*\{)")
    if any(re.search(pattern, text) for pattern in patterns):
        raise ValueError("Possible machine path, credential or personal state in " + name)
    return text


def collect_sources(root):
    toc = read_source(root, TOC)
    version, modules = parse_toc(toc)
    files = {TOC: toc}
    sources = {}
    for name in modules:
        files[name] = read_source(root, name)
        sources[name] = validate_text(name, files[name])
    for name in required_assets(sources):
        files[name] = read_source(root, name)
        validate_texture(name, files[name])
    for name in DOCUMENTS:
        files[name] = read_source(root, name)
    for name, data in files.items():
        if not name.endswith(".blp"):
            validate_text(name, data)
    for name in DOCUMENTS:
        for link in re.findall(r"\]\(([^)]+)\)", files[name].decode("utf-8")):
            if ":" not in link and not link.startswith("#") and link.split("#")[0] not in files:
                raise ValueError("Packaged documentation has a missing link: " + name + " -> " + link)
    return version, files


def run_checks(root):
    commands = ([sys.executable, "-m", "unittest", "discover", "-s", "tests", "-p", "test_package_release.py"],
                ["node", "tests/run.js"])
    for command in commands:
        print("Checking: " + " ".join(command), flush=True)
        try:
            subprocess.run(command, cwd=root, check=True)
        except FileNotFoundError as exc:
            raise ValueError("Required test tool missing: " + command[0]) from exc
        except subprocess.CalledProcessError as exc:
            raise ValueError("Release check failed: " + " ".join(command)
                             + ". Fix failures (fengari setup: npm ci --prefix tests).") from exc


def validate_changelog(data, version):
    match = re.search(r"^## \[" + re.escape(version) + r"\][^\n]*\n(.*?)(?=^## |\Z)",
                      data.decode("utf-8"), re.M | re.S)
    if not match or not re.search(r"^[-*] \S", match[1], re.M):
        raise ValueError("CHANGELOG.md needs a nonempty section for TOC version " + version)


def verify_archive(output, payload):
    with zipfile.ZipFile(output) as archive, tempfile.TemporaryDirectory(prefix="rxpw-release-") as temp:
        names = archive.namelist()
        if (len(names) != len(set(names)) or set(names) != set(payload)
                or any(not n.startswith(FOLDER + "/") or ".." in PurePosixPath(n).parts
                       or "\\" in n for n in names) or archive.testzip() is not None):
            raise ValueError("ZIP integrity, folder structure or exact entry policy failed")
        archive.extractall(temp)
        for name, data in payload.items():
            if (Path(temp) / name).read_bytes() != data:
                raise ValueError("Extracted ZIP entry differs from source: " + name)
        manifest = json.loads(archive.read(FOLDER + "/RELEASE_MANIFEST.json"))
        for entry in manifest["files"]:
            data = archive.read(entry["path"])
            if len(data) != entry["bytes"] or digest(data) != entry["sha256"]:
                raise ValueError("Manifest hash/length mismatch: " + entry["path"])


def build(root=ROOT, kind="rc", test=False):
    if kind not in ("rc", "release"):
        raise ValueError("Unknown build kind: " + kind)
    version, files = collect_sources(root)
    checked = kind == "release" or test
    if kind == "release":
        validate_changelog(files["CHANGELOG.md"], version)
    if checked:
        run_checks(root)
        if (version, files) != collect_sources(root):
            raise ValueError("Packaged sources changed during tests; rerun the build")
    payload = {f"{FOLDER}/{name}": data for name, data in files.items()}
    manifest = {"version": version, "kind": kind, "regression_checks_passed": checked,
                "files": [{"path": name, "bytes": len(data), "sha256": digest(data)}
                          for name, data in sorted(payload.items())]}
    payload[FOLDER + "/RELEASE_MANIFEST.json"] = (json.dumps(manifest, indent=2) + "\n").encode("utf-8")
    folder = root / ".release"
    folder.mkdir(exist_ok=True)
    if folder.resolve() != root.resolve() / ".release":
        raise ValueError(".release must be a directory inside this checkout, not a symlink")
    suffix = "" if kind == "release" else "-RC-" + datetime.now().strftime("%Y%m%d")
    output = folder / f"{FOLDER}-{version}{suffix}.zip"
    if kind == "rc" and output.exists():
        output = folder / f"{FOLDER}-{version}{suffix}-{datetime.now():%H%M%S%f}.zip"
    if output.exists() or output.with_suffix(".zip.sha256").exists():
        raise ValueError("Refusing to overwrite an existing release/checksum: " + str(output)
                         + ". Keep it elsewhere or deliberately remove it before rebuilding.")
    created = sidecar_created = False
    try:
        with zipfile.ZipFile(output, "x", compression=zipfile.ZIP_DEFLATED) as archive:
            created = True
            for name, data in sorted(payload.items()):
                archive.writestr(name, data)
        verify_archive(output, payload)
        for name, data in files.items():
            if read_source(root, name) != data:
                raise ValueError("Source changed while packaging: " + name)
        checksum = digest(output.read_bytes())
        with output.with_suffix(".zip.sha256").open("x", encoding="ascii") as sidecar:
            sidecar_created = True
            sidecar.write(f"{checksum}  {output.name}\n")
    except Exception:
        if created:
            output.unlink()
        if sidecar_created:
            output.with_suffix(".zip.sha256").unlink()
        raise
    return {"archive": str(output), "version": version, "kind": kind,
            "regression_checks_passed": checked, "entries": len(payload),
            "source_files": len(files), "bytes": output.stat().st_size, "sha256": checksum}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kind", choices=("rc", "release"), default="rc")
    parser.add_argument("--test", action="store_true", help="also run tests for an RC; mandatory for release")
    args = parser.parse_args()
    try:
        print(json.dumps(build(kind=args.kind, test=args.test), indent=2))
    except (ValueError, OSError, UnicodeError, zipfile.BadZipFile) as exc:
        parser.exit(1, "Release failed: " + str(exc) + "\n")


if __name__ == "__main__":
    main()
