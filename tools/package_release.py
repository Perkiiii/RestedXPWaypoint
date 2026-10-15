"""Create and verify a local RC ZIP from an explicit runtime allowlist.

Run from any directory: python tools/package_release.py
No dependency addons, tests, developer tools or personal SavedVariables are copied.
Uses only the Python standard library; never stages or changes Git history.
"""
import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path
import re
import struct
import zipfile


ROOT = Path(__file__).resolve().parent.parent
FOLDER = "RestedXPWaypoint"
TOC = "RestedXPWaypoint_Camelot.toc"
MODULES = ["Core.lua", "LabelResolver.lua", "RXPAdapter.lua",
           "NavigationResolver.lua", "WaypointAdapter.lua", "Sync.lua",
           "Preview.lua", "SettingsPanel.lua"]
ICONS = ["Bags", "ClassTrainer", "FlightMaster", "FoodAndDrink", "Grind",
         "Innkeeper", "ProfessionTrainer", "Repair", "StableMaster"]


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    toc = (ROOT / TOC).read_text(encoding="utf-8")
    modules = [line.strip() for line in toc.splitlines()
               if line.strip() and not line.lstrip().startswith("#")]
    if modules != MODULES:
        raise ValueError("TOC module order changed; review the package allowlist")
    for expected in ("## Interface: 16001", "## Title: RestedXP Waypoint",
                     "## SavedVariables: RXPWDB", "## OptionalDeps: RXPGuides, WaypointUI"):
        if expected not in toc.splitlines():
            raise ValueError("Missing TOC metadata: " + expected)
    match = re.search(r"^## Version: (\d+\.\d+\.\d+)$", toc, re.M)
    if not match:
        raise ValueError("Expected a development semantic version in TOC")
    version = match.group(1)
    files = [TOC, *MODULES, "README.md", "Art/Logo.blp",
             *(f"Art/Icons/{icon}.blp" for icon in ICONS)]
    payload = {f"{FOLDER}/{name}": (ROOT / name).read_bytes() for name in files}
    for name, data in payload.items():
        if name.endswith(".blp"):
            width, height = struct.unpack_from("<II", data, 12)
            size = 128 if name.endswith("/Logo.blp") else 64
            offset = struct.unpack_from("<I", data, 20)[0]
            length = struct.unpack_from("<I", data, 84)[0]
            if (data[:4] != b"BLP2" or data[8:12] != bytes((3, 8, 8, 0))
                    or (width, height) != (size, size) or length != size * size * 4
                    or offset + length != len(data)):
                raise ValueError("Unexpected BLP2 raw BGRA texture: " + name)
        elif name.endswith(".lua"):
            if re.search(r"[A-Za-z]:[\\/]", data.decode("utf-8")):
                raise ValueError("Absolute drive path in runtime source: " + name)
    manifest = {"version": version, "kind": "local-release-candidate",
                "files": [{"path": name, "bytes": len(data), "sha256": digest(data)}
                          for name, data in sorted(payload.items())]}
    manifest_name = f"{FOLDER}/RELEASE_MANIFEST.json"
    payload[manifest_name] = (json.dumps(manifest, indent=2) + "\n").encode("utf-8")
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    output = ROOT / ".release" / f"{FOLDER}-{version}-RC-{stamp}.zip"
    output.parent.mkdir(exist_ok=True)
    # Exclusive creation: a previous candidate can never be overwritten.
    with zipfile.ZipFile(output, "x", compression=zipfile.ZIP_DEFLATED) as archive:
        for name, data in sorted(payload.items()):
            archive.writestr(name, data)
    with zipfile.ZipFile(output) as archive:
        if archive.testzip() is not None or set(archive.namelist()) != set(payload):
            raise ValueError("ZIP integrity or entry allowlist verification failed")
        for name, data in payload.items():
            if archive.read(name) != data:
                raise ValueError("ZIP entry differs from source: " + name)
    checksum = digest(output.read_bytes())
    output.with_suffix(".zip.sha256").write_text(
        f"{checksum}  {output.name}\n", encoding="ascii")
    print(json.dumps({"archive": str(output), "entries": len(payload),
                      "source_files": len(files), "bytes": output.stat().st_size,
                      "sha256": checksum}, indent=2))


if __name__ == "__main__":
    main()
