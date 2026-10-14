#!/usr/bin/env python3
"""Fill app header len + CRC32 in app.bin (image linked for 0x0800).
Usage: patch_app_hdr.py app.bin
Header @ file offset 0x0 (64 bytes): magic, ver, len, crc, entry, i2c0h,
i2c1h, sp, data_lma, data_vma, data_len, bss_vma, bss_len, resv[3].
len = ROUNDUP4(filesize); CRC over file[0x40:len] (everything after header).
Gaps are objcopy zeros and get programmed as zero words, so both sides agree.
"""
import struct
import sys
import zlib

BIN = sys.argv[1]
HDR_LEN = 64

with open(BIN, "r+b") as f:
    img = bytearray(f.read())

magic, ver, _, _ = struct.unpack_from("<IIII", img, 0)
assert magic == 0x41505032, "app magic missing (linker .app_header?)"

length = (len(img) + 3) & ~3
img.extend(b"\x00" * (length - len(img)))
crc = zlib.crc32(bytes(img[HDR_LEN:length])) & 0xFFFFFFFF
struct.pack_into("<II", img, 8, length, crc)

with open(BIN, "wb") as f:
    f.write(img)
print("app header: len=%d crc=%08X" % (length, crc))
