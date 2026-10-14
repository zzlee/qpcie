# IT68051 read-only diagnostics (2026-10-14)

Primary source: `/mnt/rd2share/20261014/toBill/IT68051 Programming Guide.release.v0.11_YUAN.pdf`.
Do not substitute the IT6664 register map. Its initialization chapter is marked
TBD; the guide does not supply a complete validated power-up recipe.

Path tested: PCIe BAR1 FRONT master (0x3000) -> IT68051 7-bit address 0x48.
The guide's 0x90 is the 8-bit write address, NOT a second slave address.

## Observations

ID registers 00..04: `54 49 05 68 B1` (vendor 0x4954, device 0x6805).
Repeated status reads and single-byte cross-checks:

| Register | Value | Guide interpretation |
| --- | --- | --- |
| 13 | 83 | Port0 5V=1, HDMI mode=1, RxCLK detect/valid/stable=0, IPLL lock=0, symbol lock=1 |
| 14 | F9 | Three channel symbol lock bits=1; SCDC ratio/scramble bits=1 |
| 19 | 20 | SCDT bit7=0, OLOCK bit4=0 |
| 98 | 00 | PxVideoStable bit3=0 |
| 23 | 00 | Port0 reset controls read zero |
| 35 | 02 | Main port selector bit0=0 (Port0) |
| 4B | A8 | Host EDID RAM access enable bit0=0; not proof DDC EDID is absent |

Raw timing snapshot 98..A7:
`00 10 80 30 11 06 00 58 B0 00 CA 08 70 08 0A 08`.
HDEW low/high at 9D/9E changed between burst and single-byte reads.
Do NOT report a valid resolution/fps from this unlocked, non-atomic snapshot.
HDEW uses 9D/9E, VDEW uses A4/A5 (not the old driver's 98..9B assumptions).

The symbol-lock bits and clock-lock bits disagree; report raw bits without
claiming a stable HDMI stream. GPIO SCDT=HIGH alone is not proof either: guide
1C8 defaults its output to tri-state and supports configurable pin functions.
Register 0D=0 is NOT a no-signal indication.

## Commands (persistent remote tool directory)

```sh
sudo ~/qpcie_dbg/qpcie_mcu_scan --bus front --slave 0x48 --offset 0x13 --len 8 --dump
sudo ~/qpcie_dbg/qpcie_mcu_scan --bus front --slave 0x48 --offset 0x98 --len 16 --dump
```

These transactions write only the register pointer then read bytes; no IT68051
configuration registers were changed. No OpenOCD sessions were used.

Next: check source output mode/EDID handshake, obtain the matching ITE reference
initialization if available, then validate receiver lock before enabling TTL
outputs. Guide 1C6/1C8 documents default tri-state controls; access to extended
blocks must be verified before touching them. Avoid speculative register writes.
