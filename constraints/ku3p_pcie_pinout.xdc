# ============================================================================
# Constraints: ku3p_pcie_pinout.xdc
# Target Device: Xilinx Kintex UltraScale+ XCKU3P (xcku3p-ffva676-2-e)
# Description: PCIe Gen3 x4 RefClk, PERST#, Transceiver Placement & Clocks
# ============================================================================

# ----------------------------------------------------------------------------
# 1. PCIe 100MHz Reference Clock Constraints (Bank 224 / GTH Quad 224)
# ----------------------------------------------------------------------------
set_property PACKAGE_PIN AB6 [get_ports sys_clk_p]
set_property PACKAGE_PIN AB5 [get_ports sys_clk_n]

create_clock -period 10.000 -name sys_clk [get_ports sys_clk_p]

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
set_clock_groups -asynchronous -group [get_clocks -of_objects [get_pins -hierarchical *pcie_user_clk*]] \
                               -group [get_clocks sys_clk]
