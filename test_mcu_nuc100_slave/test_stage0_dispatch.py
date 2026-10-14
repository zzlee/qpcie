#!/usr/bin/env python3
"""Static artifact regression; not a substitute for on-board IRQ testing."""
import pathlib
import re
import struct
import subprocess
import zlib

root = pathlib.Path(__file__).resolve().parent
app = (root / "app.bin").read_bytes()
stage = (root / "stage0.bin").read_bytes()
bundle = (root / "aprom_bundle.bin").read_bytes()
hdr = struct.unpack_from("<16I", app)
assert hdr[0] == 0x41505032 and hdr[2] == len(app)
assert hdr[3] == zlib.crc32(app[64:])
assert len(stage) <= 0x800
assert bundle[:len(stage)] == stage and bundle[0x800:] == app
for target in hdr[4:7]:
    assert target & 1 and 0x840 <= (target & ~1) < 0x800 + len(app)

nm = subprocess.check_output(
    ["arm-none-eabi-nm", str(root / "stage0.elf")], text=True)
assert "s_i2c0h" not in nm and "s_i2c1h" not in nm
dump = subprocess.check_output(
    ["arm-none-eabi-objdump", "-d", str(root / "stage0.elf")], text=True)

def body(name):
    return re.search(r"<" + name + r">:\n(.*?)(?:\n\n|\Z)",
                     dump, re.S).group(1)

# Cortex-M0: mov r3,#128; lsl r3,#4 forms 0x800; load flash handler.
for name, offset in (("I2C0_IRQHandler", 20), ("I2C1_IRQHandler", 24)):
    irq = body(name)
    assert "#128" in irq and "lsls" in irq and "#4" in irq
    assert f"[r3, #{offset}]" in irq and "blx\tr3" in irq
handoff = body("app_enter")
assert "msr\tMSP, r0" in handoff and "bx\tr1" in handoff
assert not re.search(r"\b(push|pop|ldr|str|bl)\b", handoff)
print("PASS: flash IRQ dispatch, stack handoff, header CRC, bundle layout")
