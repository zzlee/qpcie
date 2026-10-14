#!/usr/bin/env python3
"""Combine stage0.bin (padded with 0xFF to 0x800) + app.bin for one Nu-Link
APROM image. Usage: bundle_aprom.py stage0.bin app.bin aprom_bundle.bin
Padding is 0xFF (erased state); stage0 CRC ranges cover app vectors/code
only, never the stage0 region itself.
"""
import sys

_, stage0_path, app_path, out_path = sys.argv

with open(stage0_path, "rb") as f:
    stage0 = f.read()
with open(app_path, "rb") as f:
    app = f.read()

assert len(stage0) <= 0x800, "stage0 overflow"
assert len(app) <= 0x1F800, "app overflow"

bundle = stage0 + b"\xFF" * (0x800 - len(stage0)) + app
with open(out_path, "wb") as f:
    f.write(bundle)
print("bundle: stage0=%d app=%d total=%d" % (len(stage0), len(app), len(bundle)))
