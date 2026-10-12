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

New bitstream must include M05 MCU master (`C_VERSION >= 0x26101205`):
`./scripts/build_a50t.sh`, `./scripts/flash_a50t.sh`, reload driver.

```bash
./test_app/qpcie_mcu_scan --scan   # expect 0x2A (+ 0x60 ATECC)
./test_app/qpcie_mcu_scan --dump   # MAGIC=0x2A VER=0x01
./test_app/qpcie_mcu_scan --loopback
i2cdetect -y <mcu-bus>             # via qpcie-mcu-i2c adapter (driver path)
```

## Open items

- ~~Which NUC100 I2C peripheral is wired to `SDA_MCU/SCL_MCU`~~ — confirmed
  `PA.8/SDA0→SDA_MCU (FPGA N18)`, `PA.9/SCL0→SCL_MCU (FPGA P18)`:
  flash the default `mcu_nuc100_slave_i2c0.bin`. (`PA.10/11→FRONT`, untouched.)
- `i2c_master_axi.v` has no SCL clock-stretch wait; if NACKs appear under
  interrupt latency, add stretch support on the FPGA master.
