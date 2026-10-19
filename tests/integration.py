#!/usr/bin/env python3
"""Launch a real headless simulator and verify shared memory -> muzzle -> hit -> telemetry."""

import argparse
import json
import math
import os
from pathlib import Path
import sys
import uuid
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from local_ipc import LocalClient, channel_path


def static_angle(state):
    origin = state["gimbal"]["origin"]
    armor = min(state["truth"]["armors"],
                key=lambda a: sum((a["center"][i] - origin[i]) ** 2 for i in range(3)))
    delta = [armor["center"][i] - origin[i] for i in range(3)]
    yaw = math.atan2(delta[1], delta[0])
    horizontal = math.hypot(delta[0], delta[1])
    weapon = state["weapon"]
    elevation = 0
    for _ in range(8):
        d = horizontal - weapon["barrel_length"] * math.cos(elevation)
        h = delta[2] - weapon["barrel_length"] * math.sin(elevation)
        v, g = weapon["speed"], weapon["gravity"]
        elevation = math.atan((v*v - math.sqrt(v**4 - g*(g*d*d + 2*h*v*v))) / (g*d))
    return yaw, -elevation


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True)
    args = parser.parse_args()
    channel = "test_" + uuid.uuid4().hex
    with tempfile.TemporaryDirectory(prefix="rm_aim_sim_integration_") as temp_dir:
        temp = Path(temp_dir)
        config = (ROOT / "configs/default.cfg").read_text()
        config = config.replace('channel="default"', 'channel="' + channel + '"')
        (temp / "test.cfg").write_text(config)
        log = (temp / "godot.log").open("w+")
        process = subprocess.Popen([args.godot, "--headless", "--path", str(ROOT), "--",
                                    "--remote", "--config=" + str(temp / "test.cfg")],
                                   stdout=log, stderr=subprocess.STDOUT)
        client = LocalClient(channel)
        state = None

        def read_state(deadline):
            if process.poll() is not None:
                raise AssertionError("Godot exited: " + str(process.returncode))
            return client.read_state(timeout=max(.1, deadline - time.monotonic()))

        def send(control=True, fire=False, **extra):
            command = {"control": control, "fire": fire, "yaw": yaw, "pitch": pitch}
            command.update(extra)
            client.send(**command)

        try:
            state = read_state(time.monotonic() + 8)
            assert state["ipc"]["enabled"], state
            assert state["truth"]["center"][0] == 4.0, state["truth"]
            assert state["health"]["current"] == state["health"]["maximum"] == 350
            assert state["weapon"]["damage"] == 20
            yaw, pitch = static_angle(state)
            end = time.monotonic() + 0.7
            while time.monotonic() < end:
                send()
                state = read_state(end + 1)
            assert abs(state["gimbal"]["yaw"] - yaw) < 0.005
            assert abs(state["gimbal"]["pitch"] - pitch) < 0.005
            assert state["stats"]["fired"] == 0, "aiming must not fire"
            print("PASS: command -> actual gimbal state feedback")
            end = time.monotonic() + 1.2
            while time.monotonic() < end:
                send(fire=True)
                state = read_state(end + 1)
            assert state["stats"]["fired"] >= 8, state["stats"]
            assert state["stats"]["hit"] >= 5, state["stats"]
            print("PASS: fire -> delayed muzzle release -> ballistic hit -> statistics")
            # Stop transmitting while fire is held: watchdog must disable and cancel queued shots.
            end = time.monotonic() + 0.7
            while time.monotonic() < end:
                state = read_state(end + 1)
            assert "超时" in state["ipc"]["status"], state["ipc"]
            fired_after_timeout = state["stats"]["fired"]
            end = time.monotonic() + 0.4
            while time.monotonic() < end:
                state = read_state(end + 1)
            assert state["stats"]["fired"] == fired_after_timeout
            assert state["stats"]["pending"] == 0
            assert state["stats"]["in_flight"] == 0
            assert state["stats"]["hit"] == fired_after_timeout, state["stats"]
            assert state["health"]["current"] == max(0, 350 - 20 * state["stats"]["hit"])
            assert state["stats"]["damage"] == 350 - state["health"]["current"]
            print("PASS: lost connection stops firing; every launched bullet resolves once")
            rejected_before = state["ipc"]["rejected"]
            for malformed in [{"session_id": "previous-round"}, {"seq": 0}, {"pitch": "bad-number"}]:
                send(fire=True, **malformed)
                state = read_state(time.monotonic() + 1)

            end = time.monotonic() + 0.15
            while time.monotonic() < end:
                state = read_state(end + 1)
            assert state["ipc"]["rejected"] >= rejected_before + 3
            assert state["stats"]["fired"] == fired_after_timeout
            print("PASS: stale session, duplicate sequence and malformed command rejected")
            session = state["session_id"]
            end = time.monotonic() + 1.0
            while time.monotonic() < end:
                send(fire=True)
                state = read_state(end + 1)
            send(control=False)
            end = time.monotonic() + 0.5
            while time.monotonic() < end:
                state = read_state(end + 1)
            assert state["session_id"] == session
            assert state["health"]["current"] == 0 and not state["health"]["alive"]
            assert state["stats"]["damage"] == 350 and state["stats"]["kills"] == 1
            assert state["camera"]["armors"] == []
            assert len(state["truth"]["armors"]) == 4
            assert state["stats"]["fired"] == state["stats"]["resolved"]
            print("PASS: Shared-memory feedback reports damage, death and absent lightbar observations")
            print("FINAL", json.dumps(state["stats"]))
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            log.flush()
            log.seek(0)
            contents = log.read()
            log.close()
            client.close()
            shutil.rmtree(channel_path(channel), ignore_errors=True)
            if "SCRIPT ERROR" in contents or "ERROR:" in contents:
                raise AssertionError(contents)


if __name__ == "__main__":
    main()
