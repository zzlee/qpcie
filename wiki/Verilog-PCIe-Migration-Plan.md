# Verilog-PCIe Migration Plan

This document outlines the plan to migrate the existing custom PCIe RTL modules in the `rtl/` directory to use the robust and open-source `alexforencich/verilog-pcie` library.

## Objectives

*   **Replace custom TLP handlers:** Replace `cq_rx_decoder.v`, `rc_rx_decoder.v`, `cc_tx_encoder.v`, and `rq_tx_encoder.v` with the robust TLP handling modules provided by `verilog-pcie`.
*   **Replace custom DMA engines:** Replace the custom Scatter-Gather and C2H/H2C DMA engines (`c2h_dma_engine.v`, `h2c_dma_engine.v`, `sg_dma_engine.v`) with the high-performance DMA IP cores from `verilog-pcie`.
*   **Standardize AXI interfaces:** Leverage standard AXI-Stream and AXI-Lite interfaces provided by the `verilog-pcie` library to simplify the integration with the existing video and audio stream engines.

## Phase 1: Preparation & Submodule Integration

1.  **Add Submodule:** Add the `alexforencich/verilog-pcie` repository as a Git submodule in an `ext/` or `lib/` directory.
2.  **Analyze Interfaces:** Thoroughly analyze the `verilog-pcie` module interfaces (e.g., `pcie_axil_master`, `dma_if_pcie`, `pcie_us_if`) to ensure they can be mapped to the existing Xilinx PCIe IP core interfaces used in `a50t_pcie_card_top.v` and `ku3p_pcie_card_top.v`.

## Phase 2: RTL Replacement (Incremental)

1.  **Top-Level Integration (`custom_pcie_dma_top.v`):**
    *   Refactor `custom_pcie_dma_top.v` to instantiate the top-level `verilog-pcie` DMA and AXI-Lite bridge modules.
    *   Map the AXI-Stream interfaces (Video, Audio) to the `verilog-pcie` DMA interfaces.
2.  **Register Space (`axil_reg_space.v`):**
    *   Ensure the existing `axil_reg_space.v` connects seamlessly to the AXI-Lite master interface exposed by `verilog-pcie` for BAR0 access.
3.  **Bridge Layer (`pcie_7x_axi_bridge.v`):**
    *   Replace `pcie_7x_axi_bridge.v` with the appropriate `verilog-pcie` interface wrapper for the Xilinx 7-Series PCIe core.

## Phase 3: Software / Driver Adaptation

1.  **Descriptor Format:** Modify the Linux driver (`driver/custom_pcie_av.c`, etc.) to generate Scatter-Gather descriptors that match the format expected by the `verilog-pcie` DMA engines.
2.  **Register Map:** Update any driver register offsets or status bits if the `verilog-pcie` DMA introduces its own control registers (e.g., DMA start, stop, status).

## Phase 4: Verification & Hardware Testing

1.  **Simulation:** Run exhaustive RTL simulations using the existing testbenches in `tb/` to verify the integration of `verilog-pcie` modules.
2.  **Hardware Flashing:** Build the bitstream for the A50T using `./scripts/build_a50t.sh` and flash the board using `./scripts/flash_a50t.sh`.
3.  **Test Applications:** Run `v4l2_test_app` and `alsa_test_app` (from `test_app/`) to validate video/audio capture using the new DMA datapath.
