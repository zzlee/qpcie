#!/usr/bin/env python3
"""Preview real HDMI on the PCIe HOST, never the Zynq PS video subdevice.

Examples (run in the test machine's desktop terminal):
  python3 scripts/sc7f0_hdmi_preview.py
  python3 scripts/sc7f0_hdmi_preview.py --sink fake --frames 120 --timeout 15
  python3 scripts/sc7f0_hdmi_preview.py --sink wayland --timeout 30
  python3 scripts/sc7f0_hdmi_preview.py --format NV12 --sink wayland --native-size --fullscreen
Native-size mode sends the captured format directly to the sink, with no
videoconvert or videoscale. The legacy windowed mode scales to at most 1080p.
No TPG fallback; a negotiated pipeline without buffers is NOT a successful test.
"""
import argparse
import math
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import sys


def locked_mode(text):
    if "Status: Signal Locked" not in text:
        raise ValueError("HDMI is not locked")
    resolution = re.search(r"Resolution:\s*(\d+)x(\d+)([pi])", text)
    color = re.search(r"Color:\s*fmt=0x([0-9a-fA-F]+)", text)
    if not resolution or not color:
        raise ValueError("HDMI resolution/color telemetry unavailable")
    width, height = map(int, resolution.group(1, 2))
    if resolution.group(3) != "p":
        raise ValueError("interlaced capture is unsupported")
    fmt = int(color.group(1), 16)
    encoding, depth = (fmt >> 24) & 15, (fmt >> 20) & 15
    if depth != 8 or encoding not in (0, 1):
        raise ValueError("only RGB8 or YUV444/8 input is currently supported")
    return width, height, "RGB" if encoding == 0 else "NV12"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", default="/dev/video0")
    parser.add_argument("--sink", choices=("auto", "wayland", "x11", "fake"), default="auto")
    parser.add_argument("--format", choices=("auto", "RGB", "NV12", "NV16"), default="auto",
                        help="capture format; RGB input to NV12/NV16 requires FPGA rev04+")
    parser.add_argument("--native-size", action="store_true",
                        help="keep capture resolution/format; no CPU conversion or scaling")
    parser.add_argument("--fullscreen", action="store_true",
                        help="request fullscreen on the current Wayland desktop")
    parser.add_argument("--frames", type=int, default=0, help="0: continuous preview")
    parser.add_argument("--timeout", type=float, default=0, help="seconds; 0: no deadline")
    args = parser.parse_args()
    if args.frames < 0 or not math.isfinite(args.timeout) or args.timeout < 0:
        parser.error("frames and timeout must be non-negative")
    if args.fullscreen and args.sink != "wayland":
        parser.error("--fullscreen requires --sink wayland")
    try:
        node = Path(args.device).resolve().name
        status = (Path("/sys/class/video4linux") / node / "device/hdmi_status").read_text()
        width, height, fmt = locked_mode(status)
        if args.format != "auto":
            if args.format == "RGB" and fmt != "RGB":
                raise ValueError("YUV input to RGB conversion is not implemented")
            fmt = args.format
    except (OSError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    sinks = {"auto": "autovideosink", "wayland": "waylandsink",
             "x11": "ximagesink", "fake": "fakesink"}
    env = os.environ.copy()
    if args.sink == "wayland" and not env.get("WAYLAND_DISPLAY"):
        env["WAYLAND_DISPLAY"] = "wayland-0"
    pipeline = ["gst-launch-1.0", "-e", "-v", "v4l2src", f"device={args.device}",
                "io-mode=mmap", "extra-controls=c,qpcie_video_input_source=2,qpcie_frame_pacer_enable=0",
                *([f"num-buffers={args.frames}"] if args.frames else []),
                "!", f"video/x-raw,format={fmt},width={width},height={height},framerate=60/1",
                "!", "queue", "max-size-buffers=2", "max-size-bytes=0", "max-size-time=0",
                "leaky=downstream"]
    if args.sink != "fake" and not args.native_size:
        pipeline += ["!", "videoconvert", "!", "videoscale", "!",
                     f"video/x-raw,width={min(width,1920)},height={min(height,1080)}"]
    sink = sinks[args.sink] + (" fullscreen=true" if args.fullscreen else "")
    pipeline += ["!", "fpsdisplaysink", f"video-sink={sink}",
                 "text-overlay=false", "sync=false"]
    print(f"Locked HDMI: {width}x{height} {fmt}; force HDMI, pacer off", flush=True)
    print(shlex.join(pipeline), flush=True)
    try:
        proc = subprocess.Popen(pipeline, env=env, start_new_session=True)
    except OSError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    interrupted = False
    try:
        return proc.wait(timeout=args.timeout or None)
    except subprocess.TimeoutExpired:
        print("Deadline reached; ending preview (not a frame-success assertion)", file=sys.stderr)
        interrupted = True
    except KeyboardInterrupt:
        interrupted = True
    finally:
        if interrupted and proc.poll() is None:
            os.killpg(proc.pid, signal.SIGINT)
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
    return 124 if args.timeout else 130


if __name__ == "__main__":
    sys.exit(main())
