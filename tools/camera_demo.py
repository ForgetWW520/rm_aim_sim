#!/usr/bin/env python3
"""Read real camera frames without aiming or firing; OpenCV display is optional."""

import argparse
import json
import math
import time

from local_ipc import LocalClient


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--channel", default="default")
    parser.add_argument("--no-display", action="store_true", help="stdlib-only frame transport check")
    parser.add_argument("--duration", type=float, default=0, help="wall seconds; 0 runs until interrupted")
    parser.add_argument("--frames", type=int, default=0, help="stop after this many frames; 0 is unlimited")
    parser.add_argument("--timeout", type=float, default=5, help="state/frame wait timeout in seconds")
    args = parser.parse_args()
    if (not math.isfinite(args.duration) or args.duration < 0 or args.frames < 0
            or not math.isfinite(args.timeout) or args.timeout <= 0):
        parser.error("duration/frames must be nonnegative and timeout must be finite and positive")
    cv2 = np = None
    if not args.no_display:
        try:
            import cv2
            import numpy as np
        except ImportError:
            parser.error("display requires numpy and opencv-python; alternatively use --no-display")

    client = None
    count = 0
    begin = time.monotonic()
    next_report = begin
    try:
        client = LocalClient(args.channel, timeout=args.timeout)
        while not args.duration or time.monotonic() - begin < args.duration:
            state = client.read_state(timeout=args.timeout)
            identity = client.request_frame()
            # Copy the preceding frame before requesting the next: a new request acknowledges it.
            frame, pixels = client.receive_frame(identity, timeout=args.timeout)
            if frame["session_id"] != state["session_id"]:
                continue
            camera = frame["camera"]
            width, height = camera["width"], camera["height"]
            channels = {"rgb8": 3, "rgba8": 4}[frame["encoding"]]
            count += 1
            if cv2 is not None:
                rgb = np.frombuffer(pixels, dtype=np.uint8).reshape(height, width, channels)
                conversion = cv2.COLOR_RGB2BGR if channels == 3 else cv2.COLOR_RGBA2BGR
                bgr = cv2.cvtColor(rgb, conversion)
                # Feed bgr, frame['sim_time'] and frame['gimbal'] to your detector/solver here.
                cv2.imshow("rm_aim_sim camera (no control / no fire)", bgr)
                if cv2.waitKey(1) & 0xff in (27, ord("q")):
                    break
            if time.monotonic() >= next_report:
                print(json.dumps({"type": "camera_demo", "frames": count,
                    "width": width, "height": height, "encoding": frame["encoding"],
                    "image_bytes": len(pixels), "sim_time": frame["sim_time"],
                    "session_id": frame["session_id"]}), flush=True)
                next_report = time.monotonic() + 1
            if args.frames and count >= args.frames:
                break
    except KeyboardInterrupt:
        pass
    except (TimeoutError, OSError, ValueError, AssertionError, KeyError) as error:
        parser.exit(1, "Camera input stopped: %s. Use graphical mode, check channel; restart client after server restart.\n" % error)
    finally:
        if client is not None:
            try:
                client.close()
            except OSError:
                pass
        if cv2 is not None:
            cv2.destroyAllWindows()
    print(json.dumps({"type": "camera_demo_result", "frames": count,
        "wall_seconds": time.monotonic() - begin, "control": False, "fire": False}), flush=True)


if __name__ == "__main__":
    main()
