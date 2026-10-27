#!/usr/bin/env python3
"""Decode RXA1 diagnostic records, NOT playable PCM: IEC32 + A5/TID/cycle16.
Cycle-based rates assume no hidden full 16-bit timestamp wraps between beats.
Cross-check wall-time capture, overflow counters and ACR before conclusions.
"""
import argparse
from collections import Counter
import json
from pathlib import Path
import struct


def decode(data, clock_hz=125000000):
    if not data or len(data) % 8:
        raise ValueError("RXA1 records require nonempty multiple of 8 bytes")
    channels = {}
    last = None
    total_cycles = 0
    deltas = Counter()
    for raw, meta in struct.iter_unpack("<II", data):
        if meta >> 24 != 0xA5:
            raise ValueError("RXA1 metadata marker missing: not a trace or damaged alignment")
        tid, tick = meta >> 16 & 255, meta & 65535
        if last is not None:
            delta = (tick - last) & 65535
            total_cycles += delta
            deltas[delta] += 1
        last = tick
        c = channels.setdefault(tid, dict(count=0, invalid=0, nonzero_payload=0,
            parity_errors=0, preambles=Counter(), block_starts=[], cs=[],
            _cs=None, first_words=[]))
        if len(c["first_words"]) < 12:
            c["first_words"].append(f"{raw:08x}")
        pre = raw & 15
        c["preambles"][pre] += 1
        if pre == 1:
            c["block_starts"].append(c["count"])
            c["_cs"] = []
        if c["_cs"] is not None and len(c["_cs"]) < 192:
            c["_cs"].append(raw >> 30 & 1)
            if len(c["_cs"]) == 192:
                bits = c["_cs"]
                first32 = sum(v << i for i, v in enumerate(bits[:32]))
                c["cs"].append({"first32": f"{first32:08x}",
                               "non_audio": bool(first32 & 2),
                               "frequency_code": first32 >> 24 & 15})
        c["count"] += 1
        c["invalid"] += raw >> 28 & 1
        c["nonzero_payload"] += bool(raw & 0x0FFFFFF0)
        c["parity_errors"] += (raw >> 4).bit_count() & 1
    for c in channels.values():
        starts = c.pop("block_starts")
        c["block_frame_spacings"] = dict(Counter(b-a for a, b in zip(starts, starts[1:])))
        c["block_starts"] = len(starts)
        c["cs_blocks"] = len(c["cs"])
        c["cs"] = c["cs"][:8]
        del c["_cs"]
    return {"records": len(data)//8, "channels": channels,
            "cycle_sum_modulo16": total_cycles, "assumed_clock_hz": clock_hz,
            "record_rate_if_no_hidden_wraps": ((len(data)//8-1)*clock_hz/total_cycles
                                              if total_cycles else None),
            "common_cycle_deltas": deltas.most_common(12),
            "warning": "Raw diagnostics, not PCM; rates require wall-time/ACR/overflow cross-check"}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("trace", type=Path)
    p.add_argument("--clock-hz", type=int, default=125000000)
    p.add_argument("--json", type=Path)
    a = p.parse_args()
    result = decode(a.trace.read_bytes(), a.clock_hz)
    text = json.dumps(result, indent=2)
    if a.json:
        a.json.write_text(text+"\n")
    print(text)


if __name__ == "__main__":
    main()
