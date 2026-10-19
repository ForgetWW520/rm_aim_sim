#!/usr/bin/env python3
"""Verify documented Python/C++ clients against an isolated graphical simulator."""

import argparse
import json
import math
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from local_ipc import LocalClient, channel_path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True, type=Path)
    parser.add_argument("--cpp-binary", required=True, type=Path)
    args = parser.parse_args()
    binary = args.cpp_binary.resolve()
    channel = "examples_" + uuid.uuid4().hex
    mailbox = channel_path(channel)
    process = None
    with tempfile.TemporaryDirectory(prefix="rm_client_examples_") as directory:
        temp = Path(directory)
        config = (ROOT / "configs/default.cfg").read_text().replace(
            'channel="default"', 'channel="' + channel + '"')
        (temp / "scenario.cfg").write_text(config)
        log_path = temp / "godot.log"
        try:
            with log_path.open("w") as log:
                process = subprocess.Popen([str(args.godot.resolve()), "--path", str(ROOT),
                    "--max-fps", "60", "--position", "2400,1400", "--", "--remote",
                    "--config=" + str(temp / "scenario.cfg")], cwd=ROOT,
                    stdout=log, stderr=subprocess.STDOUT)
                deadline = time.monotonic() + 20
                while not (mailbox / "state.json").exists():
                    assert process.poll() is None and time.monotonic() < deadline, log_path.read_text()
                    time.sleep(.02)

                def run(command, success=True):
                    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=25)
                    assert (result.returncode == 0) == success, result.stdout + result.stderr
                    return result

                # Both clients must honor the same exclusive lock before touching control or requests.
                owner = LocalClient(channel)
                try:
                    owner.read_state()
                    rejected = run([str(binary), "--channel=" + channel, "--no-display"], success=False)
                    assert "client.lock" in rejected.stderr, rejected.stderr
                    rejected = run([sys.executable, "tools/camera_demo.py", "--channel=" + channel,
                                    "--no-display", "--frames=1"], success=False)
                    assert "Camera input stopped" in rejected.stderr, rejected.stderr
                finally:
                    owner.close()
                print("PASS: Python/C++ clients reject an already-owned channel", flush=True)

                result = run([sys.executable, "tools/camera_demo.py", "--channel=" + channel,
                              "--no-display", "--frames=12", "--duration=10"])
                reports = [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]
                assert reports[-1]["type"] == "camera_demo_result" and reports[-1]["frames"] == 12, reports
                assert reports[0]["image_bytes"] in (1440 * 1080 * 3, 1440 * 1080 * 4), reports
                print("PASS: Python receives 12 actual raw camera frames", flush=True)

                result = run([str(binary), "--channel=" + channel, "--no-display", "--frames=12", "--duration=10"])
                reports = [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]
                assert reports[-1]["type"] == "cpp_camera_result" and reports[-1]["frames"] == 12, reports
                assert reports[0]["width"] == 1440 and reports[0]["height"] == 1080, reports
                print("PASS: C++ receives and converts 12 real frames into owned BGR images", flush=True)

                result = run([str(binary), "--channel=" + channel, "--no-display", "--control",
                              "--yaw=5", "--pitch=3", "--duration=2"])
                reports = [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]
                assert any(r.get("last_seq", -1) >= 0 for r in reports), reports
                owner = LocalClient(channel)
                try:
                    state = owner.read_state()
                    assert state["ipc"]["received"] > 0, state["ipc"]
                    assert abs(state["gimbal"]["yaw"] - math.radians(5)) < .005, state["gimbal"]
                    assert abs(state["gimbal"]["pitch"] - math.radians(3)) < .005, state["gimbal"]
                    assert state["stats"]["fired"] == state["stats"]["pending"] == 0, state["stats"]
                finally:
                    owner.close()
                print("PASS: C++ seq consumed -> actual pose read back; both examples never fire; locks released", flush=True)
                assert process.poll() is None, log_path.read_text()
        finally:
            if process is not None and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            if mailbox.exists():
                shutil.rmtree(mailbox)
            contents = log_path.read_text() if log_path.exists() else ""
            if "SCRIPT ERROR" in contents or "ERROR:" in contents:
                raise AssertionError(contents)


if __name__ == "__main__":
    main()
