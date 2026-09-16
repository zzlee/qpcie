## ==============================================================================
## Vivado Physical Constraints for SC7F0 N1 HDMI2 V11 (ZU4EV PCIe AV DMA Card)
## Target Device: AMD/Xilinx Zynq UltraScale+ (xczu4ev-fbvb900-2-e)
## ==============================================================================

## 1. PCIe Reference Clock (100 MHz differential via U7 SI53102-A3-GMR)
set_property PACKAGE_PIN R8 [get_ports sys_clk_p]
set_property PACKAGE_PIN R7 [get_ports sys_clk_n]

## 2. PCIe PERST# Fundamental Reset (Slot Pin A11 -> Pin K11, Bank 46 HD Bank)
set_property PACKAGE_PIN K11 [get_ports sys_rst_n]
set_property IOSTANDARD LVCMOS33 [get_ports sys_rst_n]
set_property PULLUP true [get_ports sys_rst_n]

## 3. On-Board Status LEDs (Bank 45 HD Bank, 3.3V)
set_property PACKAGE_PIN G15 [get_ports user_led_pcie_link_up]
set_property IOSTANDARD LVCMOS33 [get_ports user_led_pcie_link_up]
set_property PACKAGE_PIN F16 [get_ports user_led_dma_active]
set_property IOSTANDARD LVCMOS33 [get_ports user_led_dma_active]

## 4. HDMI HPD Output (Bank 46 HD Bank, 3.3V)
set_property PACKAGE_PIN B12 [get_ports hdmi_hpd_out]
set_property IOSTANDARD LVCMOS33 [get_ports hdmi_hpd_out]

## 5. PCIe Dedicated GTH Transceiver Quad 223 (Bank 223)
## Physical PCB Wiring on SC7F0:
## Lane 0: GT3 (R4/R3, P2/P1)
## Lane 1: GT2 (T6/T5, T2/T1)
## Lane 2: GT1 (V6/V5, U4/U3)
## Lane 3: GT0 (W4/W3, W1/V1)
## UltraScale+ GTH differential I/O are dedicated MGT pins placed automatically by Vivado.
## Target PCIe Hard Block: PCIE40E4_X0Y1 adjacent to Quad 223
set_property LOC PCIE40E4_X0Y1 [get_cells -hierarchical -filter {NAME =~ *pcie_4_0_pipe_inst/pcie_4_0_e4_inst}]

## 6. Timing Constraints
create_clock -period 10.000 -name sys_clk [get_ports sys_clk_p]
set_false_path -from [get_ports sys_rst_n]

## 7. Tandem PCIe Stage 1 Pblock Constraints
## UltraScale+ Tandem Stage 1 requires PCIe refclk IBUFDS_GTE4 to be in Stage1_Main
set_property HD.TANDEM_IP_PBLOCK Stage1_Main [get_cells u_ibufds_gte4]

## sys_rst_n (PERST#) is located in Bank 46 HDIO (Site IOB_X0Y157)
## We define the dedicated Stage1_IO Pblock to house the PERST# reset buffer
create_pblock pblock_sys_rst
set_property HD.TANDEM_IP_PBLOCK Stage1_IO [get_pblocks pblock_sys_rst]
add_cells_to_pblock [get_pblocks pblock_sys_rst] [get_cells -hierarchical -filter {NAME =~ *sys_rst_n_IBUF_inst* || NAME =~ *sys_reset_n_ibuf*}]
resize_pblock [get_pblocks pblock_sys_rst] -add {IOB_X0Y156:IOB_X0Y167}

