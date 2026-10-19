#!/usr/bin/env python3
"""Exercise the simulator's local shared-memory control/feedback contract using Python stdlib."""

import argparse
import json
import math
from local_ipc import LocalClient
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--channel", default="default")
    parser.add_argument("--yaw", type=float, default=0, help="degrees; positive left")
    parser.add_argument("--pitch", type=float, default=0, help="degrees; positive down")
    parser.add_argument("--fire", action="store_true")
    parser.add_argument("--duration", type=float, default=5)
    args = parser.parse_args()
    if not all(math.isfinite(n) for n in (args.yaw, args.pitch, args.duration)) or args.duration <= 0:
        parser.error("angles must be finite and duration must be positive")
    client = LocalClient(args.channel)
    next_print = 0
    print("Waiting for local state; enable 本机自瞄控制 in the simulator.")
    stop_at = time.monotonic() + args.duration
    try:
        while time.monotonic() < stop_at:
            state = client.read_state()
            client.send(fire=args.fire, yaw=math.radians(args.yaw), pitch=math.radians(args.pitch))
            if time.monotonic() >= next_print:
                stats = state["stats"]
                print("t=%.2f yaw=%.2f pitch=%.2f fired=%d hit=%d resolved=%d rate=%.1f%% remote=%s" % (
                    state["sim_time"], math.degrees(state["gimbal"]["yaw"]),
                    math.degrees(state["gimbal"]["pitch"]), stats["fired"], stats["hit"],
                    stats["resolved"], stats["hit_rate"] * 100, state["ipc"]["enabled"]))
                next_print = time.monotonic() + 0.5
    finally:
        client.close()


if __name__ == "__main__":
    main()
