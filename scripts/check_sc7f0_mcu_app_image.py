#!/usr/bin/env python3
"""8KiB-staging application ELF/bin + SRAM gates, NOT MCU hardware acceptance.

Includes the byte-exact legacy v1.1.15 post-readback reset destination. This
shim is migration compatibility only, NOT a power-fail fix to the old writer.

Uses only Python stdlib and arm-none-eabi-objdump. This is deliberately not a
formal proof of every memory access/CFG or of exception/power-fail safety.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess

STAGE = 0x20001000
STAGE_END = 0x20003000
RAM_END = 0x20005000
FLASH_END = 0x20000
# From baseline BIN SHA256 1210310743961860cb22f6749b6c33ed11cb579fd2ae5207f3950bdc26788576.
LEGACY_RESET_BYTES = bytes.fromhex("bff34f8f034b044ada60bff34f8fc046fde7c04600ed00e00400fa05")


def require(condition, message):
    if not condition:
        raise ValueError(message)


class Elf32:
    def __init__(self, blob):
        self.blob = blob
        h = struct.unpack_from("<16sHHIIIIIHHHHHH", blob)
        require(h[0][:7] == b"\x7fELF\x01\x01\x01" and h[2] == 40 and h[1] == 2,
                "Expected linked little-endian ELF32 ARM image")
        self.entry = h[4]
        require(h[9] == 32 and h[11] == 40, "Unsupported ELF table widths")
        raw = [struct.unpack_from("<10I", blob, h[6] + i * 40) for i in range(h[12])]
        require(0 < h[13] < len(raw), "Invalid ELF section-name table")
        names = self.data(raw[h[13]])
        self.sections = {self.string(names, s[0]): s for s in raw}
        self.symbols = {}
        self.functions = []
        for s in raw:
            if s[1] != 2:  # SHT_SYMTAB
                continue
            require(s[9] == 16 and s[5] % 16 == 0 and s[6] < len(raw), "Invalid ELF symbols")
            strings = self.data(raw[s[6]])
            for off in range(s[4], s[4] + s[5], 16):
                name, value, size, info, _, _ = struct.unpack_from("<IIIBBH", blob, off)
                label = self.string(strings, name)
                if label:
                    self.symbols[label] = (value, size)
                if info & 15 == 2 and size:
                    self.functions.append((label, value & ~1, size))
        self.loads = [struct.unpack_from("<8I", blob, h[5] + i * 32)
                      for i in range(h[10])]

    def data(self, section):
        off, size = section[4:6]
        require(off + size <= len(self.blob), "Truncated ELF section")
        return self.blob[off:off + size]

    @staticmethod
    def string(table, offset):
        require(offset < len(table), "Invalid ELF string offset")
        end = table.find(b"\0", offset)
        require(end >= offset, "Unterminated ELF string")
        return table[offset:end].decode("ascii")

    def symbol(self, name):
        require(name in self.symbols, f"Missing linker symbol {name}")
        return self.symbols[name][0]

    def binary(self):
        parts = []
        for kind, off, _, physical, size, _, _, _ in self.loads:
            if kind != 1 or not size:
                continue
            require(physical + size <= FLASH_END and off + size <= len(self.blob),
                    "Unexpected non-Flash / truncated ELF load segment")
            parts.append((physical, self.blob[off:off + size]))
        require(parts and min(a for a, _ in parts) == 0, "ELF does not load from APROM base")
        out = bytearray(max(a + len(b) for a, b in parts))
        used = bytearray(len(out))
        for address, data in parts:
            require(not any(used[address:address + len(data)]), "Overlapping ELF loads")
            out[address:address + len(data)] = data
            used[address:address + len(data)] = b"\1" * len(data)
        return bytes(out)


def audit(elf_path, bin_path, variant, objdump="arm-none-eabi-objdump"):
    require(variant == "app", "Only the 8KiB-staging v1.1.18 application is supported")
    blob, image = Path(elf_path).read_bytes(), Path(bin_path).read_bytes()
    limit = 8192
    version = 0x12620112
    require(8 <= len(image) <= limit and len(image) % 4 == 0,
            f"Image must fit {variant} staging limit {limit} and be word aligned")
    elf = Elf32(blob)
    require(elf.binary() == image, "BIN differs from actual ELF Flash load contents")
    sp, pc = struct.unpack_from("<II", image)
    require(sp == RAM_END and pc & 1 and 8 <= pc & ~1 < len(image), "Invalid image reset vectors")
    require(pc == elf.entry, "ELF entry does not match reset vector")
    identity = elf.symbol("sc7f0_mcu_version")
    require(elf.symbols["sc7f0_mcu_version"][1] == 4 and 0 <= identity <= len(image) - 4,
            "Missing actual compiled Flash version word")
    require(struct.unpack_from("<I", image, identity)[0] == version,
            "Compiled variant identity differs from requested role")
    require(elf.symbol("sc7f0_legacy_reset_compat") & ~1 == 0x204 and
            image[0x204:0x220] == LEGACY_RESET_BYTES,
            "Legacy v1.1.15 reset destination changed; migration unsafe")
    require(elf.symbol("__HeapLimit") <= STAGE, "data/heap overlaps staging")
    require(STAGE_END <= elf.symbol("__StackLimit") < elf.symbol("__StackTop") == RAM_END,
            "Invalid stack / staging partition")
    stage = elf.sections.get(".upgrade_stage")
    require(stage and stage[1] == 8 and stage[3] == STAGE and stage[5] == STAGE_END - STAGE,
            "Missing exact 8KiB NOLOAD staging reservation")
    start, end = elf.symbol("__ramfunc_start__"), elf.symbol("__ramfunc_end__")
    require(0x20000000 <= elf.symbol("__data_start__") <= start < end <= elf.symbol("__data_end__") <= STAGE,
            "Writer not inside startup-copied data below staging")
    for prefix in ("writer_program_aprom", "wr_unlock", "wr_wait_done", "wr_fail_stop"):
        matches = [(n, a, z) for n, a, z in elf.functions if n.startswith(prefix)]
        require(matches and all(start <= a < a + z <= end for _, a, z in matches),
                f"{prefix} missing or outside copied SRAM writer")
    diag = elf.symbols.get("g_writer_failure")
    require(diag and diag[1] == 16 and end <= diag[0] < diag[0] + 16 <= STAGE,
            "Missing/non-SRAM writer failure record")
    dump = subprocess.check_output([objdump, "-d", "-j", ".data", str(elf_path)], text=True)
    branches = {"b", "bl", "blx", "cbz", "cbnz"}
    branches.update("b" + c for c in ("eq", "ne", "cs", "hs", "cc", "lo", "mi", "pl", "vs", "vc", "hi", "ls", "ge", "lt", "gt", "le"))
    calls, literal_words, loaded_pools = [], {}, set()
    for line in dump.splitlines():
        m = re.match(r"\s*([0-9a-f]+):\s+(?:[0-9a-f]{4,8}\s+)+([.a-z0-9]+)\s*(.*)", line)
        if not m:
            continue
        address, op, args = int(m[1], 16), m[2].split(".")[0], m[3]
        if not start <= address < end:
            continue
        if m[2] == ".word":
            value = int(args.split()[0], 16)
            literal_words[address] = value
        if op in branches:
            target = re.search(r"(?:^|,\s*)([0-9a-f]+)\s*(?:<|$)", args)
            require(target is not None, f"Indirect/unknown writer branch: {line.strip()}")
            target = int(target[1], 16)
            require(start <= target < end, f"Writer branch escapes SRAM: {line.strip()}")
            if op in ("bl", "blx"):
                calls.append({"at": hex(address), "target": hex(target)})
        if op == "bx":
            require(args.strip() == "lr", f"Indirect writer jump: {line.strip()}")
        require(op not in ("tbb", "tbh") and not (op in ("ldr", "mov") and args.startswith("pc,")),
                f"Unreviewed indirect PC write: {line.strip()}")
        if op == "ldr" and "[pc," in args:
            pool = re.search(r"\(([0-9a-f]+)\s*<", args)
            require(pool is not None and start <= int(pool[1], 16) <= end - 4,
                    f"Literal pool outside copied SRAM: {line.strip()}")
            loaded_pools.add(int(pool[1], 16))
    literals = []
    for address in sorted(loaded_pools):
        require(address in literal_words, f"Undecoded SRAM literal pool at {address:#x}")
        value = literal_words[address]
        require(value >= FLASH_END, f"Flash-range loaded literal at {address:#x}: {value:#x}")
        literals.append({"at": hex(address), "value": hex(value)})
    require(calls and literals, "No SRAM instructions decoded; refuse vacuous success")
    return {"static_pass": True, "variant": variant, "version": hex(version),
            "bytes": len(image), "limit": limit, "margin_bytes": limit - len(image),
            "bin_sha256": hashlib.sha256(image).hexdigest(),
            "elf_sha256": hashlib.sha256(blob).hexdigest(),
            "ramfunc": [hex(start), hex(end)], "heap_limit": hex(elf.symbol("__HeapLimit")),
            "stack": [hex(elf.symbol("__StackLimit")), hex(elf.symbol("__StackTop"))],
            "failure_record": hex(diag[0]), "sram_calls": calls, "sram_literal_words": literals,
            "legacy_reset_compat_sha256": hashlib.sha256(LEGACY_RESET_BYTES).hexdigest(),
            "scope": "ELF/load/vector/layout and direct branch/literal checks; not formal CFG/memory proof",
            "hardware_accepted": False, "external_rescue_verified": False,
            "power_fail_safe": False, "deployment_allowed": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--elf", required=True)
    parser.add_argument("--bin", required=True)
    parser.add_argument("--variant", choices=("app",), required=True)
    parser.add_argument("--objdump", default="arm-none-eabi-objdump")
    parser.add_argument("--out")
    args = parser.parse_args()
    try:
        result = audit(args.elf, args.bin, args.variant, args.objdump)
    except (ValueError, OSError, struct.error, subprocess.SubprocessError) as exc:
        result = {"static_pass": False, "error": str(exc), "deployment_allowed": False}
    output = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.out:
        Path(args.out).write_text(output)
    print(output, end="")
    return 0 if result["static_pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
