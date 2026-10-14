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

## VER03 firmware and TTL output inspection

VER03 firmware has now been built (not yet programmed). It preloads PB.10 LOW
before selecting push-pull output, defaults CTRL=02, and reports VER=03. The
host tool accepts VER02 and VER03. Legacy PB.15 and clock setup are unchanged.
Generated `test_mcu_nuc100_slave/mcu_nuc100_slave_ver03.bin`: 2624 bytes,
SHA256 `4f20812807ffc23a072e68b566f8dcdf99df6e80da2e07c0b7bb209f0eae9118`.

Guide page35 documents selector 0F[2:0]. Tool `--bank 1` preserves/restores
the original selector and verifies restoration. Read bank1 C0..CF:
`00 00 00 00 00 7F FF 7F 1F 89 89 99 FF FF FF FF`.
Original selector 00 was restored and receiver remained locked (13=BF,19=BA).

- 1C0=00: single-pixel mode, TTL output clock disabled, LVDS disabled.
- 1C1=00: DDR and embedded-sync controls disabled.
- 1C6=FF: dual-pixel data and video-control IO tri-stated.
- 1C8=1F: auxiliary SCDT/EVODD/3DR pin tri-state controls set.
- Block0 6B=40: output-depth bits[1:0]=00 (8-bit setting); this is not a
  measurement of the HDMI source's bit depth.

Only selector 0F was changed temporarily; no output or clock registers were
written. Receiver lock is established, but TTL-to-FPGA traffic is not.

Next hardware step: add input-only PL telemetry for TM0_PCLK(E13), DE(D18),
HS(E17), VS(B17), with proper CDC/reset handling. Then configure TTL per guide
for the board's 60-bit dual-pixel interface, verify readback, and observe actual
PCLK/DE/frame counts before connecting the capture engine. Keep TPG selectable.
No DMA claim until a captured host buffer has been checked.

## VER03 on-board verification

User programmed VER03 via Windows Nu-Link. PCIe MMIO initially returned
invalid data (including flash JEDEC FFFFFF); remove/rescan restored JEDEC
C22018 and MCU access. Do not interpret the initial NACKs as MCU failure.

- MCU MAGIC=2A, VER=03, CTRL=02, STATUS=0B before a host CTRL write.
- Scratch write/read A5 passed on MCU bus; FRONT read saw the same A5.
- IT68051 currently 13=BD,19=30,98=00: clock/IPLL locked, but HDMI-mode
  bit1=0 and video/SCDT are NOT stable. Timing values vary; no resolution
  claim for this session. This differs from the earlier locked BF/BA/08.
- A one-second HPD-low pulse (CTRL03 then CTRL02) did not restore video lock.
- TTL settings remain 1C0=00,1C6=FF; bank selector restored after reads.

Next recheck: physically unplug/replug the HDMI source, then repeat status
and timing reads before modifying TTL registers. No MCU reset/OpenOCD or
IT68051 initialization writes were performed in this verification session.
