# test_mcu_nuc100_slave — minimal NUC100 APROM I2C slave (U2, M2_710)

Target: `NUC100LE3AN` APROM on `M2 710 N1 HDMI 4KP60 V21` Sheet3.
Keeps `test_mcu_minimal` behavior (HXT 12.288 MHz → `PB.12 CLKO` → FPGA E10,
`PB.10 HPD=H`, `PB.15 RSTn_PCIe=H`) and adds a 16-byte EEPROM-like slave at
7-bit `0x2A` for `PCIe → FPGA I2C master → MCU` control.

## Register map (offset + auto-increment, wrap 0x0F)

| Off | Name | Attr | Reset | Notes |
|-----|------|------|-------|-------|
| 0x00 | MAGIC | RO | 0x2A | slave presence |
| 0x01 | VER | RO | 0x01 | fw version |
| 0x02 | STATUS | RO live | — | b0=PA.4 INT raw, b1=PA.5 SCDT raw, b2=HPD, b3=RSTn |
| 0x03 | CTRL | RW | 0x03 | b0→PB.10 HPD, b1→PB.15 RSTn |
| 0x04-0x0F | SCRATCH | RW | 0x00 | loopback test |

Protocol: `W[offset] + W[data...]` / `W[offset] + Sr + R[n]`.
Writes to 0x00/0x01/0x02 are ignored (pointer still advances).

## Build

```bash
make -C test_mcu_nuc100_slave clean all        # I2C0 PA.8/PA.9, 0x2A
make -C test_mcu_nuc100_slave clean all I2CSEL=I2C1  # I2C1 PA.10/PA.11 variant
```

Outputs `mcu_nuc100_slave_i2c0.bin` (default) or `..._i2c1.bin`.

## Flash (Nu-Link2 + OpenOCD, backup first!)

```bash
./scripts/mcu_ice/mcu_read.sh backup.bin   # if supported on this chip
./scripts/mcu_ice/mcu_write.sh test_mcu_nuc100_slave/mcu_nuc100_slave_i2c0.bin
```

## Host-side test (after FPGA MCU-bus master exists)

```bash
i2cdetect -y <fpga-mcu-bus>     # expect 0x2A (+ 0x60 ATECC on same bus)
i2cget -y <bus> 0x2a 0x00        # expect 0x2a
i2cset -y <bus> 0x2a 0x04 0x5a
i2cget -y <bus> 0x2a 0x04        # expect 0x5a
i2cget -y <bus> 0x2a 0x02        # STATUS live bits
```

## Open items

- Which NUC100 I2C peripheral is wired to `SDA_MCU/SCL_MCU` (I2C0 vs I2C1):
  PDF text layer loses net-to-pin mapping; confirm visually on Sheet3 before
  flashing, or flash I2C0 build, scan, and if NACK try the I2C1 build.
- FPGA `sda/scl_mcu` pins + BAR1 offset for the second `i2c_master_axi`
  (next step; current `a50t_pcie_card_top.v` only has FRONT bus).
- `i2c_master_axi.v` has no SCL clock-stretch wait; if NACKs appear under
  interrupt latency, add stretch support on the FPGA master.
