"""Offline DRM presentation cadence, excluding the disable ACK and partial windows."""
import argparse
import bisect
import json
import re
from pathlib import Path


def measure(text):
    events = [(int(seq), round(float(t) * 1e6)) for seq, t in re.findall(
        r'flip id=[^-\s] seq=(\d+) drm_time=(\d+\.\d+)', text)]
    if len(events) < 2:
        raise ValueError('insufficient presentations')
    ts = [t for _, t in events]
    gaps = [b - a for a, b in zip(ts, ts[1:])]
    delta = [(b[0] - a[0]) % (1 << 32) for a, b in zip(events, events[1:])]
    if min(gaps) <= 0 or min(delta) < 1:
        raise ValueError('non-increasing presentation time or frame sequence')
    streak = longest = 0
    for step in delta:
        streak = streak + 1 if step >= 2 else 0
        longest = max(longest, streak)
    rates = {}
    for sec in (1, 5, 10):
        # Half-open interval (t-width,t], ending at every presentation after warmup.
        counts = [(i+1 - bisect.bisect_right(ts, t - sec * 1000000)) / sec
                  for i, t in enumerate(ts) if t - ts[0] >= sec * 1000000]
        if counts:
            rates[sec] = [min(counts), max(counts)]
    return dict(unique=len(ts), duration_s=(ts[-1]-ts[0])/1e6,
                unique_hz=(len(ts)-1)*1e6/(ts[-1]-ts[0]),
                missed_sofs=sum(delta)-len(delta), multi_sof_intervals=sum(x>1 for x in delta),
                longest_consecutive_multi_sof_intervals=longest, max_interval_ms=max(gaps)/1000,
                rolling_hz_min_max=rates)


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('log', type=Path)
    print(json.dumps(measure(ap.parse_args().log.read_text()), indent=2))
