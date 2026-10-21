#!/usr/bin/env python3
"""Inspect IT6663 RXP0 raw timing counters through the MCU I2C proxy.

Exit 0: sampled lock/geometry checks pass; 2: invalid/unlocked snapshot;
1: transport/response error. This does not establish HDMI RX or DMA success.
Register decoding follows the local vendor IT6664_hdmi2_rx.c implementation.
No standard-mode substitution, clock-rate inference, or bank writes are used.
Requires checked proxy replies (MCU v1.1.14+); legacy replies fail closed.
"""

import argparse
from datetime import datetime, timezone
import json
import math
import re
import shlex
import subprocess
import sys


TIMING_SIZE = 19  # 0x98 .. 0xAA inclusive
STATUS_REGS = {"bank": 0x0F, "r13": 0x13, "r14": 0x14, "r19": 0x19}
FIELDS = {**{f"before_{key}": 1 for key in STATUS_REGS},
          "timing_first": TIMING_SIZE, "timing_second": TIMING_SIZE,
          **{f"after_{key}": 1 for key in STATUS_REGS}}


class ReadError(RuntimeError):
    """Transport failure or malformed response; never a no-signal reading."""


def parse_response(text):
    result = {}
    for line in text.splitlines():
        parts = line.split()
        if not parts:
            continue
        name = parts[0]
        if name not in FIELDS or name in result:
            raise ReadError(f"unexpected or duplicate response field: {name}")
        expected = FIELDS[name] + 1  # data followed by THIS transaction's status
        if len(parts[1:]) != expected:
            raise ReadError(f"{name}: expected {expected} bytes including status, got {len(parts)-1}")
        if any(not re.fullmatch(r"0x[0-9a-fA-F]{2}", x) for x in parts[1:]):
            raise ReadError(f"{name}: malformed byte response")
        values = [int(x, 16) for x in parts[1:]]
        if values[-1]:
            reason = {1: "SI timeout", 2: "unexpected state or NACK",
                      3: "STOP timeout", 4: "invalid proxy request",
                      255: "unchecked/legacy proxy reply (requires MCU v1.1.14+)"}.get(values[-1], "unknown error")
            raise ReadError(f"{name}: downstream I2C status=0x{values[-1]:02x}: {reason}")
        result[name] = values[:-1]
    missing = FIELDS.keys() - result.keys()
    if missing:
        raise ReadError(f"missing response fields: {', '.join(sorted(missing))}")
    return result


def read_snapshot(host, timeout):
    # Each proxy transaction writes a read command, not chip configuration.
    # set -e propagates Linux I2C errors. Request one EXTRA byte for the
    # downstream status, in the SAME transfer as the data. Old MCU firmware
    # returns FF for the extra byte and is rejected, never silently accepted.
    commands = ["set -eu"]
    for name, size in FIELDS.items():
        reg = 0x98 if name.startswith("timing_") else STATUS_REGS[name.split("_", 1)[1]]
        commands.append(f"printf '{name} '")
        commands.append(f"i2ctransfer -y 0 w3@0x33 0x71 {size} 0x{reg:02x} r{size+1}@0x33")
    remote = "sudo -n /home/rd/sc7f0ctl exec " + shlex.quote("; ".join(commands))
    try:
        proc = subprocess.run(
            ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", host, remote],
            capture_output=True, text=True, timeout=timeout,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise ReadError(f"SSH/card read failed: {exc}") from exc
    if proc.returncode != 0:
        raise ReadError(f"SSH/card read exit {proc.returncode}: {proc.stderr.strip()} {proc.stdout.strip()}")
    # Treat warnings as errors too: do not silently accept partial I2C failure.
    if proc.stderr.strip():
        raise ReadError(f"SSH/card diagnostic: {proc.stderr.strip()}")
    return parse_response(proc.stdout)


def decode_timing(raw):
    if len(raw) != TIMING_SIZE or any(not isinstance(x, int) or not 0 <= x <= 255 for x in raw):
        raise ValueError("expected exactly 19 timing bytes")
    def reg(address):
        return raw[address - 0x98]
    def size(low):
        return reg(low) | ((reg(low + 1) & 0x3F) << 8)
    t = {
        "interlaced": bool(reg(0x98) & 0x02),
        "h_total": size(0x9B), "h_active": size(0x9D),
        "h_front_porch": reg(0xA0) | ((reg(0xA1) & 0xF0) << 4),
        "h_sync_width": reg(0x9F) | ((reg(0xA1) & 0x01) << 8),
        "v_total": size(0xA2), "v_active": size(0xA4),
        "v_front_porch": reg(0xA7) | ((reg(0xA8) & 0xF0) << 4),
        "v_sync_width": reg(0xA6) | ((reg(0xA8) & 0x01) << 8),
        "h_sync_positive": bool(reg(0xAA) & 0x20),
        "v_sync_positive": bool(reg(0xAA) & 0x40),
    }
    for axis in ("h", "v"):
        # Keep negative results visible; do not clamp impossible timing to 0.
        t[f"{axis}_back_porch"] = (t[f"{axis}_total"] - t[f"{axis}_active"]
                                      - t[f"{axis}_front_porch"] - t[f"{axis}_sync_width"])
    return t


def decode_status(data, prefix):
    r13, r14, r19 = (data[f"{prefix}_{r}"][0] for r in ("r13", "r14", "r19"))
    return {
        "bank": data[f"{prefix}_bank"][0] & 3,
        "cable_5v": bool(r13 & 0x01),
        # Vendor AutoEQ (IT6664_hdmi2_rx.c:1905) and TX polling
        # (IT6664_hdmi2_tx.c:194) use bit 4. One vendor IRQ path uses
        # bit 3 instead; retain raw r13 and do not treat bit 3 alone as lock.
        "clock_stable": bool(r13 & 0x10),
        "symbol_lock": (r14 & 0x38) == 0x38,
        "scdt_lock": bool(r19 & 0x80),
        "hdmi_mode": bool(r14 & 0x40),
        "scrambled": bool(r14 & 0x80),
    }


def analyze_snapshot(data):
    before, after = (decode_status(data, p) for p in ("before", "after"))
    timing = decode_timing(data["timing_second"])
    reasons = []
    if before["bank"] != 0 or after["bank"] != 0:
        reasons.append("register bank is not 0")
    if before != after:
        reasons.append("status changed during sampling")
    if data["timing_first"] != data["timing_second"]:
        reasons.append("timing counters changed between reads")
    for key in ("cable_5v", "clock_stable", "symbol_lock", "scdt_lock"):
        if not before[key] or not after[key]:
            reasons.append(f"{key} not asserted at both status reads")
    for axis in ("h", "v"):
        if (timing[f"{axis}_active"] <= 0 or timing[f"{axis}_sync_width"] <= 0
                or timing[f"{axis}_back_porch"] < 0):
            reasons.append(f"invalid {axis.upper()} geometry")
    return {"timing_valid": not reasons, "invalid_reasons": reasons,
            "status_before": before, "status_after": after,
            "raw_timing": timing, "raw_bytes": data,
            "pixel_clock_hz": None, "frame_rate_hz": None,
            "note": "Raw counter units only; no color/deep-color scaling. Sequential reads, not a hardware-atomic snapshot."}


def format_report(report):
    status, timing = report["status_after"], report["raw_timing"]
    lines = ["SC7F0 IT6663 RXP0 diagnostic", f"Host: {report['host']}",
             f"Time (reader UTC): {report['timestamp']}"]
    for prefix in ("before", "after"):
        raw = report["raw_bytes"]
        lines.append(prefix + ": " + " ".join(
            f"{key}=0x{raw[f'{prefix}_{key}'][0]:02x}" for key in STATUS_REGS))
    lines.append("Link: " + " ".join(f"{k}={int(status[k])}" for k in
                                     ("cable_5v", "clock_stable", "symbol_lock", "scdt_lock")))
    lines.append(f"Protocol bits: HDMI={int(status['hdmi_mode'])} scrambled={int(status['scrambled'])} (not a measured HDMI version/rate)")
    lines.append("Timing valid (sampled lock + raw geometry): " + ("YES" if report["timing_valid"] else "NO"))
    lines.extend("  INVALID: " + reason for reason in report["invalid_reasons"])
    lines.append("Raw timing registers (INVALID when checks fail; may be stale):")
    for key in ("timing_first", "timing_second"):
        lines.append(f"  {key} 0x98..0xAA: " + " ".join(f"{x:02x}" for x in report["raw_bytes"][key]))
    for axis in ("h", "v"):
        lines.append(f"  {axis.upper()}: " + " ".join(
            f"{key}={timing[f'{axis}_{key}']}" for key in
            ("active", "total", "front_porch", "sync_width", "back_porch")))
    lines.append(f"  Interlaced={int(timing['interlaced'])} sync polarity H={'+' if timing['h_sync_positive'] else '-'} V={'+' if timing['v_sync_positive'] else '-'} (raw)")
    lines.extend(["Pixel clock / frame rate / VIC: UNKNOWN (not measured)", report["note"],
                  "Passing these checks does not prove Xilinx RX lock, frame capture, or signal integrity."])
    return "\n".join(lines)


def positive_timeout(value):
    number = float(value)
    if not math.isfinite(number) or number <= 0:
        raise argparse.ArgumentTypeError("timeout must be finite and positive")
    return number


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="rd@sc7f0-test.local", help="SSH target")
    parser.add_argument("--timeout", type=positive_timeout, default=30.0, help="SSH/card deadline in seconds")
    parser.add_argument("--json", action="store_true", help="Print raw and decoded diagnostic as JSON")
    args = parser.parse_args(argv)
    if args.host.startswith("-"):
        parser.error("host must not start with '-'")
    try:
        report = analyze_snapshot(read_snapshot(args.host, args.timeout))
    except (ReadError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    report.update(host=args.host, timestamp=datetime.now(timezone.utc).isoformat(),
                  proxy_protocol="data+status-v1", downstream_i2c_status_checked=True)
    print(json.dumps(report, indent=2) if args.json else format_report(report))
    return 0 if report["timing_valid"] else 2


if __name__ == "__main__":
    sys.exit(main())
