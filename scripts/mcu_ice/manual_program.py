#!/usr/bin/env python3
"""Generate OpenOCD Tcl to program NUC100 APROM via DAP-driven FMC ISP.

No on-target code is executed (the stock flash algorithm hangs on this
link); the core stays halted while every ISP step goes through DAP
memory writes. Also safe against blank-vector lockup.

Usage: manual_program.py <firmware.bin> <out.tcl>
"""
import struct
import sys

FMC = 0x5000C000
ISPCON, ISPADR, ISPDAT, ISPCMD, ISPTRG = (FMC + o for o in (0x00, 0x04, 0x08, 0x0C, 0x10))
GCR_REGWRPROT = 0x50000100
PAGE = 0x200  # 512B

CMD_PROGRAM, CMD_ERASE = 0x21, 0x22

def main():
    blob = open(sys.argv[1], "rb").read()
    out = sys.argv[2]
    words = struct.unpack("<%dI" % (len(blob) // 4), blob)
    pages = sorted({(i * 4) // PAGE * PAGE for i in range(len(words))})

    L = []
    L.append("proc isp_poll {} {")
    L.append("    set t 2000")
    L.append("    while {1} {")
    L.append(f"        mem2array v 32 0x{ISPTRG:X} 1")
    L.append("        if {$v(0) == 0} { break }")
    L.append("        if {[incr t -1] == 0} { error \"ISPTRG stuck\" }")
    L.append("        sleep 1")
    L.append("    }")
    L.append("}")
    L.append(f"mww 0x{GCR_REGWRPROT:X} 0x59; mww 0x{GCR_REGWRPROT:X} 0x16; mww 0x{GCR_REGWRPROT:X} 0x88")
    L.append(f"mww 0x{ISPCON:X} 0x09")
    for p in pages:
        L.append(f"mww 0x{ISPADR:X} 0x{p:X}; mww 0x{ISPCMD:X} 0x{CMD_ERASE:X}; mww 0x{ISPTRG:X} 0x1; isp_poll")
        L.append(f"puts \"erased page 0x{p:X}\"")
    for i, w in enumerate(words):
        L.append(f"mww 0x{ISPADR:X} 0x{i*4:X}; mww 0x{ISPDAT:X} 0x{w:08X}; mww 0x{ISPCMD:X} 0x{CMD_PROGRAM:X}; mww 0x{ISPTRG:X} 0x1; isp_poll")
    L.append(f"mww 0x{ISPCON:X} 0x09")
    L.append('puts "MANUAL_PROGRAM_DONE"')
    open(out, "w").write("\n".join(L) + "\n")
    print(f"{len(words)} words, {len(pages)} pages -> {out}")

main()
