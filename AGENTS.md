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
./scripts/build_a50t.sh
```
- Output Bitstream: `./build/qpcie_a50t_proj/qpcie_a50t_card.runs/impl_1/a50t_pcie_card_top.bit`

---

### 2. Standard Automated SPI Flash Flashing (Recommended)
Always use the automated script **`./scripts/flash_a50t.sh`** to flash the SPI Flash memory:

```bash
./scripts/flash_a50t.sh
```

**What `flash_a50t.sh` does automatically:**
1. Invokes Vivado batch TCL script [`scripts/program_flash_a50t.tcl`](file:///home/zzlee/qpcie/scripts/program_flash_a50t.tcl).
2. Converts the compiled `.bit` bitstream to SPI binary format (`./build/a50t_pcie_card_top_spix1.bin`).
3. Connects to JTAG Hardware Server / Probe.
4. Program & verify Macronix `MX25L12872F` SPI Flash with 100% checksum verification.

---

## 🤖 Agent/User Hardware Validation Handoff Workflow

When a task changes FPGA RTL plus host software, split responsibilities as follows:

**AI agent responsibilities:**
1. Modify RTL, Linux driver, and user-mode test applications as requested.
2. Build the A50T bitstream with:
   ```bash
   ./scripts/build_a50t.sh
   ```
3. Compile the driver with:
   ```bash
   cd ./driver && make clean && make
   ```
4. Compile test applications with:
   ```bash
   cd ./test_app && make clean && make all
   ```
5. Commit and push the verified source changes.

**User responsibilities:**
1. Flash the generated bitstream to the FPGA/SPI flash.
2. Rebuild and reload the driver on the real target system.
3. Run the relevant test applications on hardware.
4. Report hardware results/logs back to the agent for the next debug loop.

---

## 🐧 Driver Build, Load & Verification On Real Hardware

### 1. Compile Driver
```bash
cd ./driver && make clean && make
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

---

## 🏷️ Vivado Design Modification Rules & Hardware Versioning (`C_VERSION`)

> [!IMPORTANT]
> **Mandatory Rule for any Vivado Modification**:
> Whenever Vivado Block Design (BD), RTL, or IP configurations are modified, **ALWAYS verify and increment/update the `C_VERSION` parameter before regenerating targets and re-exporting the XSA / bitstream.**

1. **`C_VERSION` Format Specification (`0xYYMMDDpp`)**:
   - Format: `32'hYYMMDDpp`
   - `YY`: 2-digit Year (e.g., `26` for 2026).
   - `MM`: 2-digit Month (e.g., `09` for September).
   - `DD`: 2-digit Day (e.g., `30` for 30th).
   - `pp`: 2-digit Patch / revision count for that date (e.g., `01`, `02`, `03`...).
   - Example: `32'h26093001`

2. **Standard Parameters (`zzlab_env.v` / `zzlab_env_0`)**:
   - `C_VERSION`: Current date + patch number (`32'hYYMMDDpp`).
   - `C_PLATFORM`: `"PCIE"`.
   - `C_BOARD_VERSION`: Maintain target board hardware revision (e.g., `32'h00000101`).

3. **Mandatory Post-Modification Workflow**:
   1. Check & bump `C_VERSION` in `zzlab_env.v` (or corresponding top/wrapper).
   2. Reset and regenerate BD targets (`reset_target all`, `generate_target all`).
   3. Export updated XSA (`write_hw_platform -fixed -force <path>.xsa`).
   4. Update PetaLinux hardware description (`petalinux-config --get-hw-description=<xsa> --silentconfig`).
   5. Recompile PetaLinux images / repackage `BOOT.BIN` and update release artifacts.

