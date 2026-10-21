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

## 4. HDMI Physical Interface & Clocks (Bank 225/226 MGT & Bank 46 HD Bank)
# RX Reference Clock (Bank 226 MGTREFCLK1: B10/B9)
set_property PACKAGE_PIN B10 [get_ports hdmi_rx_clk_p]
set_property PACKAGE_PIN B9  [get_ports hdmi_rx_clk_n]
create_clock -period 3.367 -name hdmi_rx_clk_p [get_ports hdmi_rx_clk_p]

# DRU Reference Clock (sheet11: Bank 225 MGTREFCLK1: F10/F9)
set_property PACKAGE_PIN F10 [get_ports hdmi_dru_clk_p]
set_property PACKAGE_PIN F9  [get_ports hdmi_dru_clk_n]
create_clock -period 6.400 -name hdmi_dru_clk_p [get_ports hdmi_dru_clk_p]

# TX Reference Clock (Bank 226 MGTREFCLK0: D10/D9)
set_property PACKAGE_PIN D10 [get_ports hdmi_tx_clk_p]
set_property PACKAGE_PIN D9  [get_ports hdmi_tx_clk_n]
create_clock -period 3.367 -name hdmi_tx_clk_p [get_ports hdmi_tx_clk_p]

# TX TMDS Clock Out (Pins AH6/AJ6)
set_property PACKAGE_PIN AH6 [get_ports hdmi_tx_tmds_clk_p]
set_property PACKAGE_PIN AJ6 [get_ports hdmi_tx_tmds_clk_n]
set_property IOSTANDARD LVDS [get_ports hdmi_tx_tmds_clk_p]
set_property IOSTANDARD LVDS [get_ports hdmi_tx_tmds_clk_n]

# Sheet11 U11-10, Quad226: lane index is the board D0/D1/D2 order.
# Constrain the physical ports as well as the PHY CHANNEL_ENABLE sites.
set_property PACKAGE_PIN D2 [get_ports {hdmi_rx_p[0]}]
set_property PACKAGE_PIN D1 [get_ports {hdmi_rx_n[0]}]
set_property PACKAGE_PIN C4 [get_ports {hdmi_rx_p[1]}]
set_property PACKAGE_PIN C3 [get_ports {hdmi_rx_n[1]}]
set_property PACKAGE_PIN B2 [get_ports {hdmi_rx_p[2]}]
set_property PACKAGE_PIN B1 [get_ports {hdmi_rx_n[2]}]
set_property PACKAGE_PIN D6 [get_ports {hdmi_tx_p[0]}]
set_property PACKAGE_PIN D5 [get_ports {hdmi_tx_n[0]}]
set_property PACKAGE_PIN C8 [get_ports {hdmi_tx_p[1]}]
set_property PACKAGE_PIN C7 [get_ports {hdmi_tx_n[1]}]
set_property PACKAGE_PIN B6 [get_ports {hdmi_tx_p[2]}]
set_property PACKAGE_PIN B5 [get_ports {hdmi_tx_n[2]}]

# HDMI RX Control (Bank 46 HD Bank, 3.3V)
set_property PACKAGE_PIN B12 [get_ports hdmi_rx_hpd_out]
set_property IOSTANDARD LVCMOS33 [get_ports hdmi_rx_hpd_out]
set_property PACKAGE_PIN A12 [get_ports hdmi_rx_5v_det]
set_property IOSTANDARD LVCMOS33 [get_ports hdmi_rx_5v_det]
set_property PACKAGE_PIN D14 [get_ports hdmi_rx_ddc_scl]
set_property IOSTANDARD LVCMOS33 [get_ports hdmi_rx_ddc_scl]
set_property PACKAGE_PIN C13 [get_ports hdmi_rx_ddc_sda]
set_property IOSTANDARD LVCMOS33 [get_ports hdmi_rx_ddc_sda]

# HDMI TX Control (Bank 46 HD Bank, 3.3V)
set_property PACKAGE_PIN G14 [get_ports hdmi_tx_hpd_in]
set_property IOSTANDARD LVCMOS33 [get_ports hdmi_tx_hpd_in]
set_property PACKAGE_PIN G13 [get_ports hdmi_tx_refclk_rdy]
set_property IOSTANDARD LVCMOS33 [get_ports hdmi_tx_refclk_rdy]
set_property PACKAGE_PIN F12 [get_ports hdmi_tx_ddc_scl]
set_property IOSTANDARD LVCMOS33 [get_ports hdmi_tx_ddc_scl]
set_property PACKAGE_PIN E12 [get_ports hdmi_tx_ddc_sda]
set_property IOSTANDARD LVCMOS33 [get_ports hdmi_tx_ddc_sda]

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

# Do not blanket-false-path the PCIe/HDMI clock groups. IP/XPM constraints
# cover their actual CDC structures; report the remaining crossings for review.



## 7. 300MHz Si5341B Clock for Multimedia IPs (Bank 64 LVDS)
set_property PACKAGE_PIN AD17 [get_ports pl_clk_300m_p]
set_property PACKAGE_PIN AE17 [get_ports pl_clk_300m_n]
set_property IOSTANDARD LVDS [get_ports pl_clk_300m_p]
set_property IOSTANDARD LVDS [get_ports pl_clk_300m_n]
create_clock -period 3.333 -name pl_clk_300m [get_ports pl_clk_300m_p]

## 8. Diagnostic Probing CDC Max Delay Constraints
set_max_delay -datapath_only 10.0 -from [get_cells -hierarchical -filter {NAME =~ *u_meter*/*snapshot_test_reg[*]}] -to [get_cells -hierarchical -filter {NAME =~ *u_meter*/*measured_freq_hz_reg[*] || NAME =~ *u_meter*/*raw_cycle_count_reg[*]}]
set_max_delay -datapath_only 10.0 -from [get_cells -hierarchical -filter {NAME =~ *u_hdmi_probe/*beat_ch*_cnt_reg[*] || NAME =~ *u_hdmi_probe/*vid_*_cnt_reg[*]}] -to [get_cells -hierarchical -filter {NAME =~ *u_hdmi_probe/reg_probe_*_reg[*]}]
