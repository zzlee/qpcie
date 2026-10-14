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

## Confirmed HPD polarity fix (2026-10-14)

Schematic sheet4: PB.10/HPD0_CTRL drives the gate of M1 (2N7002KW).
M1 pulls RX_HPD0 to ground when its gate is HIGH; SR3 (1k) pulls that node
to HDMI +5V when M1 is off. Thus PB.10 HIGH deasserts cable HPD, not asserts it.
The old firmware's "HPD asserted" comment for CTRL=03 was incorrect.

After unplugging: reg13 changed 83 -> 82 (5V detection drops), but no lock.
After replugging: reg13 returned to 83, still unlocked.
Then host wrote NUC100 CTRL=02 (PB.10 LOW, bit1 preserved). No IT68051
configuration writes or OpenOCD sessions were needed. Receiver immediately
locked. Three subsequent snapshots matched:

- 13=BF: 5V, HDMI, RxCLK detect/valid/stable, IPLL lock, symbol lock all set.
- 19=BA: SCDT and OPLL lock set.
- 98=08: progressive, PxVideoStable=1. Color-depth code is zero; do not
  interpret it as a valid 8/10/12-bit depth without additional evidence.
- 9D/9E=00/0F -> active width 3840.
- A4/A5=70/08 -> active height 2160.
- 9B/9C=30/11 -> horizontal total 4400.
- A2/A3=CA/08 -> vertical total 2250.

Source reports 3840x2160p60; frame rate was not independently measured here.
Video lock does not establish HDCP state or that TTL output/capture/DMA works.

Current board remains at CTRL=02. Firmware VER02 still defaults to CTRL=03,
so a MCU reset/power cycle reintroduces the HPD problem. Until the startup
firmware is corrected, restore with:

```sh
sudo ~/qpcie_dbg/qpcie_mcu_scan --set-ctrl 0x02
```

Do not use CTRL bit0=1 to mean "HPD on": it is a raw GPIO level.
