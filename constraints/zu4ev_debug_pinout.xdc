## SC7F0 N1 HDMI2 V11 debug-first profile. Physical assignments are the
## PCIe/LED subset of zu4ev_pcie_pinout.xdc (V11 schematic, sheets 11/36).
## No HDMI/DRU/300MHz ports, no fabricated GT clocks, no async clock groups.
set_property PACKAGE_PIN R8 [get_ports sys_clk_p]
set_property PACKAGE_PIN R7 [get_ports sys_clk_n]
set_property PACKAGE_PIN K11 [get_ports sys_rst_n]
set_property IOSTANDARD LVCMOS33 [get_ports sys_rst_n]
set_property PULLUP true [get_ports sys_rst_n]
set_property PACKAGE_PIN G15 [get_ports user_led_pcie_link_up]
set_property PACKAGE_PIN F16 [get_ports user_led_dma_active]
set_property IOSTANDARD LVCMOS33 [get_ports {user_led_pcie_link_up user_led_dma_active}]
set_property LOC PCIE40E4_X0Y1 [get_cells -hierarchical -filter {NAME =~ *pcie_4_0_pipe_inst/pcie_4_0_e4_inst}]
create_clock -period 10.000 -name sys_clk [get_ports sys_clk_p]
# PERST# is an asynchronous external reset; PCIe IP handles its release.
set_false_path -from [get_ports sys_rst_n]
# LEDs are human-visible asynchronous indicators, not clocked interfaces.
set_false_path -to [get_ports {user_led_pcie_link_up user_led_dma_active}]
