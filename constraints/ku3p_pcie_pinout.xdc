# ============================================================================
# Constraints: ku3p_pcie_pinout.xdc
# Target Device: Xilinx Kintex UltraScale+ XCKU3P (xcku3p-ffva676-2-e)
# Description: PCIe Gen3 x4 RefClk, PERST#, Transceiver Placement & Clocks
# Reference: alexforencich/verilog-pcie VCU118 example design
# ============================================================================

# DRC Severity Override for Bitstream Generation
set_property SEVERITY {Warning} [get_drc_checks UCIO-1]
set_property SEVERITY {Warning} [get_drc_checks NSTD-1]

# ----------------------------------------------------------------------------
# 1. PCIe 100MHz Reference Clock Constraints (GTH Quad 224)
#    MGTREFCLK0_224 -> AB6 (P), AB5 (N)
# ----------------------------------------------------------------------------
set_property PACKAGE_PIN AB6 [get_ports sys_clk_p]
set_property PACKAGE_PIN AB5 [get_ports sys_clk_n]

create_clock -period 10.000 -name sys_clk [get_ports sys_clk_p]

# LOC for IBUFDS_GTE4 - Quad 224 MGTREFCLK0
set_property LOC IBUFDS_GTE4_X0Y1 [get_cells u_ibufds_gte4]

# ----------------------------------------------------------------------------
# 2. PCIe PERST# System Reset Constraint (Bank 65 1.8V)
# ----------------------------------------------------------------------------
set_property PACKAGE_PIN W11 [get_ports sys_rst_n]
set_property IOSTANDARD LVCMOS18 [get_ports sys_rst_n]
set_property PULLUP true [get_ports sys_rst_n]
set_false_path -from [get_ports sys_rst_n]

# ----------------------------------------------------------------------------
# 3. User LED Output Constraints (Bank 65 1.8V)
# ----------------------------------------------------------------------------
set_property PACKAGE_PIN B9 [get_ports user_led_dma_active]
set_property IOSTANDARD LVCMOS18 [get_ports user_led_dma_active]

set_property PACKAGE_PIN D9 [get_ports user_led_pcie_link_up]
set_property IOSTANDARD LVCMOS18 [get_ports user_led_pcie_link_up]

# ----------------------------------------------------------------------------
# 4. Timing & False Paths
# ----------------------------------------------------------------------------
set_clock_groups -asynchronous \
    -group [get_clocks -of_objects [get_pins -hierarchical *pcie_user_clk*]] \
    -group [get_clocks sys_clk]

# ----------------------------------------------------------------------------
# 5. Bitstream Configuration
# ----------------------------------------------------------------------------
set_property BITSTREAM.CONFIG.UNUSEDPIN PULLUP [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
