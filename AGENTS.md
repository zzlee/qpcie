# AGENTS.md - Developer & AI Agent Operations Manual

This document provides exact instructions for building, flashing, and testing the **QPCIe Artix-7 A50T Multi-Channel Video & Audio PCIe DMA Card**.

---

## 💳 Hardware & Core Specifications

- **Target FPGA**: AMD/Xilinx Artix-7 A50T (`xc7a50t-csg325-2` / `xc7a50t-fgg484-2`)
- **PCI Device Identification**: Vendor ID `0x12AB`, Device ID `0xE380`
- **PCIe Interface**: 7-Series Integrated PCIe Block (`pcie_7x_0`), Gen2 x4, 128-bit AXI-Stream
- **On-Board SPI Flash**: Macronix 128Mb SPI Flash (`MX25L12872F` / `mx25l12872f-spi-x1_x2_x4`)

---

## 🛠️ FPGA Bitstream Build & SPI Flash Flashing Workflow

### 1. Build FPGA Bitstream (Vivado Batch Mode)
To compile native RTL sources (`a50t_pcie_card_top.v`, `pcie_7x_axi_bridge.v`, `cq_rx_decoder.v`, etc.) into a bitstream:

```bash
cd /home/zzlee/qpcie
./scripts/build_a50t.sh
```
- Output Bitstream: `./build/qpcie_a50t_proj/qpcie_a50t_card.runs/impl_1/a50t_pcie_card_top.bit`

---

### 2. Standard Automated SPI Flash Flashing (Recommended)
Always use the automated script **`./scripts/flash_a50t.sh`** to flash the SPI Flash memory:

```bash
cd /home/zzlee/qpcie
./scripts/flash_a50t.sh
```

**What `flash_a50t.sh` does automatically:**
1. Invokes Vivado batch TCL script [`scripts/program_flash_a50t.tcl`](file:///home/zzlee/qpcie/scripts/program_flash_a50t.tcl).
2. Converts the compiled `.bit` bitstream to SPI binary format (`./build/a50t_pcie_card_top_spix1.bin`).
3. Connects to JTAG Hardware Server / Probe.
4. Program & verify Macronix `MX25L12872F` SPI Flash with 100% checksum verification.

---

## 🐧 Driver Build, Load & Verification

### 1. Compile Driver
```bash
cd /home/zzlee/qpcie/driver
make clean && make
```

### 2. Load Driver & Check Diagnostics
```bash
sudo insmod custom_pcie_av.ko
dmesg | tail -n 25
```

---

## 📐 RTL Architectural Design Guidelines

1. **BAR0 vs BAR1 Hardware Demuxing**:
   - Use `m_axis_rx_tuser[9:2]` One-Hot BAR Hit indicators from 7-Series PCIe core (`pg054`).
   - `m_axis_rx_tuser[2]` = BAR0 Hit (DMA Registers `axil_reg_space.v`).
   - `m_axis_rx_tuser[3]` = BAR1 Hit (User IP Cores / EDID / TPG).

2. **4-DW MWr (64-bit Address Memory Write) Handling**:
   - On 64-bit hosts (e.g., Jetson Orin NX), `iowrite32` generates 4-DW MWr TLPs.
   - Beat 0 contains 64-bit Address (`AddrHigh`, `AddrLow`).
   - Beat 1 contains the 32-bit Write Payload Data in `m_axis_rx_tdata[31:0]`.
   - `pcie_7x_axi_bridge.v` buffers Beat 0 address and packs Beat 1 payload into `cq_tdata[127:96]`.

3. **CQ RX Decoder State Machine**:
   - `cq_rx_decoder.v` must transition back to `IDLE` state as soon as AXI `rvalid` or `bvalid` is asserted, resetting `s_axis_cq_tready = 1` for continuous, back-to-back MMIO requests.
