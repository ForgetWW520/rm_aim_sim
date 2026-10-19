#!/usr/bin/env python3
"""Fetch pinned BSD-3-Clause chassis meshes and convert STL to portable GLB.

No ROS dependency is used. The imported geometry is decorative; scoring geometry
is configured independently in the simulator. Git blob hashes verify upstream bytes.
"""

import hashlib
import json
from pathlib import Path
import struct
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
REVISION = "a4b31828bf964e491d3ba5a731d12c1213562feb"
SOURCE = "https://raw.githubusercontent.com/rm-controls/rm_description/" + REVISION
FILES = {
    "LICENSE": "f733c9516cee5c13df0f38cac86f976399490272",
    "meshes/standard/base.stl": "816c19ba73b1b7c09eefacce30c4fa35c6b9710a",
    "meshes/hero/base.stl": "7b6162b023e47db739b9243a23ad621c60f6c7ee",
    "meshes/sentry/base_link.stl": "fd37d9eb909ba23e64bceeb06f7d669e2d5b3697",
}
NAMES = {"standard": "infantry", "hero": "hero", "sentry": "sentry"}


def read_stl(data):
    count = struct.unpack_from("<I", data, 80)[0]
    if len(data) != 84 + count * 50:
        raise ValueError("Expected binary STL")
    positions, normals = [], []
    for index in range(count):
        values = struct.unpack_from("<12fH", data, 84 + index * 50)
        normal = values[:3]
        # Original files use ROS x-forward/y-left/z-up; GLB uses Godot x-right/y-up/-z-forward.
        normals.extend((-normal[1], normal[2], -normal[0]) * 3)
        for offset in (3, 6, 9):
            x, y, z = values[offset:offset + 3]
            positions.extend((-y, z, -x))
    return positions, normals


def make_glb(data, name):
    positions, normals = read_stl(data)
    vertices = len(positions) // 3
    pos_data = struct.pack("<%df" % len(positions), *positions)
    norm_data = struct.pack("<%df" % len(normals), *normals)
    bounds_min = [min(positions[axis::3]) for axis in range(3)]
    bounds_max = [max(positions[axis::3]) for axis in range(3)]
    document = {
        "asset": {"version": "2.0", "generator": "rm_aim_sim STL converter",
                  "copyright": "Copyright (c) 2021, Qiayuan Liao; BSD-3-Clause"},
        "scene": 0, "scenes": [{"nodes": [0]}],
        "nodes": [{"name": name + "_chassis", "mesh": 0}],
        "buffers": [{"byteLength": len(pos_data) + len(norm_data)}],
        "bufferViews": [{"buffer": 0, "byteOffset": 0, "byteLength": len(pos_data)},
                        {"buffer": 0, "byteOffset": len(pos_data), "byteLength": len(norm_data)}],
        "accessors": [{"bufferView": 0, "componentType": 5126, "count": vertices,
                       "type": "VEC3", "min": bounds_min, "max": bounds_max},
                      {"bufferView": 1, "componentType": 5126, "count": vertices, "type": "VEC3"}],
        "materials": [{"name": "chassis_metal", "pbrMetallicRoughness": {
            "baseColorFactor": [0.24, 0.31, 0.38, 1.0], "metallicFactor": 0.55,
            "roughnessFactor": 0.65}, "doubleSided": True}],
        "meshes": [{"primitives": [{"attributes": {"POSITION": 0, "NORMAL": 1}, "material": 0}]}],
    }
    encoded = json.dumps(document, separators=(",", ":")).encode()
    encoded += b" " * ((-len(encoded)) % 4)
    binary = pos_data + norm_data
    binary += b"\x00" * ((-len(binary)) % 4)
    total = 12 + 8 + len(encoded) + 8 + len(binary)
    return (struct.pack("<III", 0x46546C67, 2, total)
            + struct.pack("<II", len(encoded), 0x4E4F534A) + encoded
            + struct.pack("<II", len(binary), 0x004E4942) + binary)


def main():
    output = ROOT / "assets" / "models"
    third_party = ROOT / "assets" / "third_party" / "rm_description"
    output.mkdir(parents=True, exist_ok=True)
    third_party.mkdir(parents=True, exist_ok=True)
    manifest = {"repository": "https://github.com/rm-controls/rm_description",
                "revision": REVISION, "license": "BSD-3-Clause", "files": []}
    for path, expected in FILES.items():
        request = urllib.request.Request(SOURCE + "/" + path,
                                         headers={"User-Agent": "rm_aim_sim-model-fetcher"})
        with urllib.request.urlopen(request, timeout=45) as response:
            data = response.read(16 * 1024 * 1024)
        digest = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
        if digest != expected:
            raise ValueError("Upstream content hash mismatch: " + path)
        record = {"path": path, "git_blob_sha1": digest,
                  "sha256": hashlib.sha256(data).hexdigest(), "url": SOURCE + "/" + path}
        if path == "LICENSE":
            (third_party / "LICENSE").write_bytes(data)
        else:
            name = NAMES[Path(path).parts[1]]
            converted = make_glb(data, name)
            destination = output / (name + ".glb")
            destination.write_bytes(converted)
            record["converted_file"] = str(destination.relative_to(ROOT))
            record["converted_sha256"] = hashlib.sha256(converted).hexdigest()
            print(name, "triangles=", struct.unpack_from("<I", data, 80)[0],
                  "GLB bytes=", len(converted))
        manifest["files"].append(record)
    (third_party / "sources.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
