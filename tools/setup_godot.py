#!/usr/bin/env python3
"""Download the pinned standalone Linux x86_64 Godot binary into ignored .tools/."""

import hashlib
from pathlib import Path
import platform
import tempfile
import urllib.request
import zipfile

VERSION = "4.7.2-stable"
NAME = "Godot_v%s_linux.x86_64" % VERSION
SHA256 = "cadd3204e728a35d3f13adb7fd0d7902636b79f6b95c40c265eb73b6c35329e4"
URL = "https://github.com/godotengine/godot-builds/releases/download/%s/%s.zip" % (VERSION, NAME)


def main():
    if platform.system() != "Linux" or platform.machine() not in ("x86_64", "AMD64"):
        raise SystemExit("This helper supports Linux x86_64; download the correct Godot build manually.")
    destination = Path(__file__).resolve().parents[1] / ".tools"
    destination.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="rm_aim_sim_godot_") as temp:
        archive = Path(temp) / "godot.zip"
        print("Downloading", URL, flush=True)
        urllib.request.urlretrieve(URL, archive)
        actual = hashlib.sha256(archive.read_bytes()).hexdigest()
        if actual != SHA256:
            raise SystemExit("SHA256 mismatch: " + actual)
        with zipfile.ZipFile(archive) as contents:
            (destination / "godot").write_bytes(contents.read(NAME))
        (destination / "godot").chmod(0o755)
    print("Ready:", destination / "godot")


if __name__ == "__main__":
    main()
