# ==============================================================================
# Xilinx Artix-7 XC7A50T-FGG484-2 PCIe Card Constraints
# Updated based on sc7xx_e382 Hardware Pinout Schema
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. System Clock Constraints (100 MHz PCIe Reference Clock)
# ------------------------------------------------------------------------------
create_clock -period 10.000 -name sys_clk [get_ports sys_clk_p]

# ------------------------------------------------------------------------------
# 2. PCIe Reference Clock & Reset Pins (sc7xx_e382: D6/D5, V11)
# ------------------------------------------------------------------------------
set_property PACKAGE_PIN D6 [get_ports sys_clk_p]
set_property PACKAGE_PIN D5 [get_ports sys_clk_n]

set_property PACKAGE_PIN V11 [get_ports sys_rst_n]
set_property IOSTANDARD LVCMOS33 [get_ports sys_rst_n]
set_property PULLUP true [get_ports sys_rst_n]
set_false_path -from [get_ports sys_rst_n]

# ------------------------------------------------------------------------------
# 3. PCIe Transceiver GTP Serial Lanes (sc7xx_e382 Pinout)
# ------------------------------------------------------------------------------
# Lane 0 (GTPE2_CHANNEL_X0Y3)
set_property PACKAGE_PIN G4 [get_ports {pci_exp_rxp[0]}]
set_property PACKAGE_PIN G3 [get_ports {pci_exp_rxn[0]}]
set_property PACKAGE_PIN B2 [get_ports {pci_exp_txp[0]}]
set_property PACKAGE_PIN B1 [get_ports {pci_exp_txn[0]}]

# Lane 1 (GTPE2_CHANNEL_X0Y2)
set_property PACKAGE_PIN C4 [get_ports {pci_exp_rxp[1]}]
set_property PACKAGE_PIN C3 [get_ports {pci_exp_rxn[1]}]
set_property PACKAGE_PIN D2 [get_ports {pci_exp_txp[1]}]
set_property PACKAGE_PIN D1 [get_ports {pci_exp_txn[1]}]

# Lane 2 (GTPE2_CHANNEL_X0Y1)
set_property PACKAGE_PIN A4 [get_ports {pci_exp_rxp[2]}]
set_property PACKAGE_PIN A3 [get_ports {pci_exp_rxn[2]}]
set_property PACKAGE_PIN F2 [get_ports {pci_exp_txp[2]}]
set_property PACKAGE_PIN F1 [get_ports {pci_exp_txn[2]}]

# Lane 3 (GTPE2_CHANNEL_X0Y0)
set_property PACKAGE_PIN E4 [get_ports {pci_exp_rxp[3]}]
set_property PACKAGE_PIN E3 [get_ports {pci_exp_rxn[3]}]
set_property PACKAGE_PIN H2 [get_ports {pci_exp_txp[3]}]
set_property PACKAGE_PIN H1 [get_ports {pci_exp_txn[3]}]

# ------------------------------------------------------------------------------
# 4. User Telemetry Status LEDs & HDMI HPD Pin
# ------------------------------------------------------------------------------
set_property PACKAGE_PIN W10 [get_ports user_led_dma_active]
set_property IOSTANDARD LVCMOS33 [get_ports user_led_dma_active]

set_property PACKAGE_PIN V10 [get_ports user_led_pcie_link_up]
set_property IOSTANDARD LVCMOS33 [get_ports user_led_pcie_link_up]

set_property PACKAGE_PIN Y11 [get_ports hdmi_hpd_out]
set_property IOSTANDARD LVCMOS33 [get_ports hdmi_hpd_out]

# ------------------------------------------------------------------------------
# 5. Bitstream Configuration Properties
# ------------------------------------------------------------------------------
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 40 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 1 [current_design]

set_property SEVERITY {Warning} [get_drc_checks NSTD-1]
set_property SEVERITY {Warning} [get_drc_checks UCIO-1]
