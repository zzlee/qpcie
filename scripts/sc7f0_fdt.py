"""Minimal flattened-device-tree reader (no dtc needed).

Split out of build/dt-inspect.py, which is the ad-hoc diagnostic that decoded the
26102902 first-boot failure.  The gates in scripts/check_sc7f0_memory_layout.py
import this so a release can be audited on a workstation that has no
device-tree compiler installed.

Big-endian FDT header:
  0x00 magic 0xd00dfeed     0x04 totalsize
  0x08 off_dt_struct         0x0c off_dt_strings
  0x10 off_mem_rsvmap        0x14 version
"""
from __future__ import annotations

import struct

FDT_BEGIN_NODE, FDT_END_NODE, FDT_PROP, FDT_NOP, FDT_END = 1, 2, 3, 4, 9
MAGIC = 0xD00DFEED


def blobs(data: bytes):
    """Yield plausible FDT blobs embedded in a file (a FIT image holds several)."""
    pos = 0
    while True:
        pos = data.find(struct.pack('>I', MAGIC), pos)
        if pos < 0:
            return
        totalsize = struct.unpack('>I', data[pos + 4:pos + 8])[0]
        off_struct = struct.unpack('>I', data[pos + 8:pos + 12])[0]
        off_strings = struct.unpack('>I', data[pos + 12:pos + 16])[0]
        if 32 < totalsize <= len(data) - pos and off_struct < totalsize and off_strings < totalsize:
            yield data[pos:pos + totalsize]
        pos += 4


def walk(blob: bytes) -> dict[str, dict[str, bytes]]:
    """Return {node path: {property name: raw value}} for one FDT blob."""
    _magic, totalsize, off_struct, off_strings, _rsv, _ver = struct.unpack('>6I', blob[:24])
    totalsize = min(totalsize, len(blob))
    strings = blob[off_strings:totalsize]
    pos, stack, nodes = off_struct, [], {}

    def name(offset: int) -> str:
        end = strings.find(b'\0', offset)
        return strings[offset:end].decode('utf-8', 'replace')

    while pos < totalsize - 4:
        token = struct.unpack('>I', blob[pos:pos + 4])[0]
        pos += 4
        if token == FDT_BEGIN_NODE:
            end = blob.index(b'\0', pos)
            stack.append(blob[pos:end].decode('utf-8', 'replace'))
            pos = (end + 4) & ~3
            nodes.setdefault('/'.join(stack), {})
        elif token == FDT_END_NODE:
            stack.pop()
        elif token == FDT_PROP:
            length, nameoff = struct.unpack('>2I', blob[pos:pos + 8])
            pos += 8
            nodes['/'.join(stack)][name(nameoff)] = blob[pos:pos + length]
            pos += (length + 3) & ~3
        elif token == FDT_NOP:
            continue
        elif token == FDT_END:
            break
        else:
            break
    return nodes


def largest_tree(data: bytes) -> dict[str, dict[str, bytes]]:
    """Return the node set of the biggest plausible FDT in a file (the real DTB)."""
    trees = [walk(blob) for blob in blobs(data)]
    trees = [t for t in trees if '' in t and len(t) > 50]
    if not trees:
        raise ValueError('no flattened device tree found')
    return max(trees, key=len)


def cells(value: bytes) -> list[int]:
    return [struct.unpack('>I', value[i:i + 4])[0] for i in range(0, len(value) - 3, 4)]


def text(value: bytes) -> str:
    return value.rstrip(b'\0').decode('utf-8', 'replace')
