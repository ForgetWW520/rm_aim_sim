"""Linux-only shared-memory mailbox client; no socket or network transport."""

import fcntl
import json
import os
from pathlib import Path
import re
import time
import uuid


def channel_path(channel):
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,80}", channel):
        raise ValueError("Invalid IPC channel")
    return Path("/dev/shm/rm_aim_sim_" + channel)


class LocalClient:
    def __init__(self, channel="default", timeout=8):
        self.directory = channel_path(channel)
        deadline = time.monotonic() + timeout
        while not self.directory.is_dir():
            if time.monotonic() > deadline:
                raise TimeoutError("Waiting for local simulator")
            time.sleep(.01)
        info = self.directory.stat()
        if info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise PermissionError("IPC directory must belong to this user with mode 0700")
        self.lock = (self.directory / "client.lock").open("a")
        try:
            fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except Exception:
            self.lock.close()
            raise
        self.last_publication = None
        self.state = None
        self.sequence = 0
        self.sequence_session = None
        self.token = uuid.uuid4().hex

    def read_json(self, name):
        try:
            return json.loads((self.directory / name).read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            return {}

    def write_json(self, name, value):
        temporary = self.directory / (name + ".client.tmp")
        temporary.write_text(json.dumps(value, allow_nan=False))
        temporary.replace(self.directory / name)

    def read_state(self, timeout=3):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            value = self.read_json("state.json")
            identity = (value.get("publisher_id"), value.get("publication"))
            if (value.get("protocol") == "rm_aim_sim/2" and identity != self.last_publication
                    and -.1 <= time.time() - value.get("wall_unix_sec", 0) <= .25):
                self.state = value
                self.last_publication = identity
                return value
            time.sleep(.002)
        raise TimeoutError("Waiting for local simulator state")

    def send(self, control=True, fire=False, yaw=0., pitch=0., **extra):
        state = self.state
        if state is None:
            raise RuntimeError("Read simulator state before sending a command")
        if self.sequence_session != state["session_id"]:
            self.sequence_session = state["session_id"]
            self.sequence = 0
        self.sequence = max(self.sequence, state["ipc"]["last_seq"] + 1)
        packet = {"protocol": "rm_aim_sim/2", "type": "command", "session_id": state["session_id"],
                  "publisher_id": state["publisher_id"], "seq": self.sequence,
                  "control": control, "fire": fire, "yaw": yaw, "pitch": pitch}
        packet.update(extra)
        self.write_json("command.json", packet)
        self.sequence += 1

    def request_frame(self):
        identity = self.token + "-" + str(time.monotonic_ns())
        self.write_json("request.json", {"publisher_id": self.state["publisher_id"], "request_id": identity})
        return identity

    def receive_frame(self, identity, timeout=5):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            metadata = self.read_json("frame.json")
            if metadata.get("request_id") == identity:
                assert metadata["publisher_id"] == self.state["publisher_id"]
                filename = "frame-" + identity + ".raw"
                assert metadata["frame_file"] == filename
                image = (self.directory / filename).read_bytes()
                assert len(image) == metadata["image_bytes"]
                channels = {"rgb8": 3, "rgba8": 4}[metadata["encoding"]]
                assert len(image) == metadata["camera"]["width"] * metadata["camera"]["height"] * channels
                return metadata, image
            time.sleep(.002)
        raise TimeoutError("Waiting for local simulator frame")

    def close(self):
        if self.state is not None:
            self.send(control=False)
        self.lock.close()
