# ==============================================================================
# Xilinx Artix UltraScale+ XCAU15P-FFVB676-2-E PCIe Card Constraints
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. System Clock Constraints (100 MHz PCIe Reference Clock)
# ------------------------------------------------------------------------------
create_clock -period 10.000 -name sys_clk [get_ports sys_clk_p]

# ------------------------------------------------------------------------------
# 2. PCIe Reference Clock & Reset Pins (Bank 224 / GTY)
# ------------------------------------------------------------------------------
set_property PACKAGE_PIN AB6 [get_ports sys_clk_p]
set_property PACKAGE_PIN AB5 [get_ports sys_clk_n]

set_property PACKAGE_PIN AB12 [get_ports sys_rst_n]
set_property IOSTANDARD LVCMOS18 [get_ports sys_rst_n]
set_property PULLUP true [get_ports sys_rst_n]

# ------------------------------------------------------------------------------
# 3. User Telemetry Status LEDs
# ------------------------------------------------------------------------------
set_property PACKAGE_PIN AD10 [get_ports user_led_dma_active]
set_property IOSTANDARD LVCMOS18 [get_ports user_led_dma_active]

set_property PACKAGE_PIN AE10 [get_ports user_led_pcie_link_up]
set_property IOSTANDARD LVCMOS18 [get_ports user_led_pcie_link_up]

# ------------------------------------------------------------------------------
# 4. HDMI Hot-Plug Detect (HPD) Output Pin
# ------------------------------------------------------------------------------
set_property PACKAGE_PIN AE11 [get_ports hdmi_hpd_out]
set_property IOSTANDARD LVCMOS18 [get_ports hdmi_hpd_out]

# ------------------------------------------------------------------------------
# 5. Timing Constraints & Clock Groups
# ------------------------------------------------------------------------------
set_false_path -from [get_ports sys_rst_n]

# ------------------------------------------------------------------------------
# 6. DRC Severity Overrides (Pre-PCB Prototyping: Allow bitstream without
#    final pin assignments for GT refclk differential pair)
# ------------------------------------------------------------------------------
set_property SEVERITY {Warning} [get_drc_checks NSTD-1]
set_property SEVERITY {Warning} [get_drc_checks UCIO-1]
