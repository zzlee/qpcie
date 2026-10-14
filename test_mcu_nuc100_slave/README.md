# test_mcu_nuc100_slave — NUC100 APROM firmware set (U2, M2_710)

Target: `NUC100LE3AN` APROM on `M2 710 N1 HDMI 4KP60 V21` Sheet3.
See `docs/mcu-aprom-update.md` for the PCIe update protocol, memory map,
and the one-time Nu-Link transition bundle.

Binaries (`make -C test_mcu_nuc100_slave clean all`):
`stage0.bin` (dispatcher @0x0) + `app.bin` = `mcu_nuc100_slave.bin`
(APROM app @0x0800, VER04) + `ldrom.bin` (console/writer @0x100000);
`aprom_bundle.bin` = stage0 padded to 0x800 + app (single Nu-Link image).
Retains the legacy HXT/CLKO and PB.15 setup, corrects `PB.10 HPD0_CTRL=LOW`,
and adds a 16-byte EEPROM-like slave at
7-bit `0x2A` on **both** I2C peripherals for `PCIe → FPGA I2C master → MCU`:
`I2C0 PA.8/PA.9 → MCU bus` (FPGA N18/P18) and `I2C1 PA.10/PA.11 → FRONT bus`
(FPGA T12/U12). Shared register file, per-bus offset pointers.

## Register map (offset + auto-increment, wrap 0x0F)

| Off | Name | Attr | Reset | Notes |
|-----|------|------|-------|-------|
| 0x00 | MAGIC | RO | 0x2A | slave presence |
| 0x01 | VER | RO | 0x03 | fw version (HPD startup fix) |
| 0x02 | STATUS | RO live | — | b0=PA.12 INT raw, b1=PA.13 SCDT raw, b2=PB.10 latch, b3=PB.15 latch |
| 0x03 | CTRL | RW | 0x02 | raw GPIO b0→PB.10, b1→PB.15 |
| 0x04-0x0F | SCRATCH | RW | 0x00 | loopback test |

Protocol: `W[offset] + W[data...]` / `W[offset] + Sr + R[n]`.
Writes to 0x00/0x01/0x02 are ignored (pointer still advances).

**HPD is inverted by M1 (sheet4):** CTRL bit0=1 drives PB.10 HIGH and
pulls cable HPD LOW; bit0=0 releases HPD to the +5V_HDMI0 pullup SR3.
VER02 booted CTRL=03 and held HPD low. VER03 boots CTRL=02 and preloads
the latch before enabling push-pull output. CTRL ABI remains raw GPIO;
STATUS bit2 is NOT the cable HPD level. See
`docs/it68051-readonly-diagnostics.md` for the on-board lock evidence.

## Build

```bash
make -C test_mcu_nuc100_slave clean all
```

Outputs `mcu_nuc100_slave.bin` (dual I2C0+I2C1).

## Flash (Nu-Link2 + OpenOCD, backup first!)

```bash
./scripts/mcu_ice/mcu_read.sh backup.bin   # if supported on this chip
./scripts/mcu_ice/mcu_write.sh test_mcu_nuc100_slave/mcu_nuc100_slave.bin
```

## Host-side test (after FPGA MCU-bus master exists)

Use the tested A50T bitstream `C_VERSION=0x26101303` (includes the
byte-gap/repeated-START fix and M05 MCU master):
`./scripts/build_a50t.sh`, `./scripts/flash_a50t.sh`, reload driver.

```bash
./test_app/qpcie_mcu_scan --scan   # expect 0x2A (+ 0x60 ATECC)
./test_app/qpcie_mcu_scan --dump   # MAGIC=0x2A VER=0x03 CTRL=0x02
./test_app/qpcie_mcu_scan --loopback
i2cdetect -y <mcu-bus>             # via qpcie-mcu-i2c adapter (driver path)
```

## Open items

- ~~Which NUC100 I2C peripheral is wired to `SDA_MCU/SCL_MCU`~~ — confirmed
  `PA.8/SDA0→SDA_MCU (FPGA N18)`, `PA.9/SCL0→SCL_MCU (FPGA P18)`:
  current `mcu_nuc100_slave.bin` answers on both MCU and FRONT buses.
- `i2c_master_axi.v` has no SCL clock-stretch wait; if NACKs appear under
  interrupt latency, add stretch support on the FPGA master.
