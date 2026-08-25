# ==============================================================================
# Xilinx Artix-7 XC7A50T-CSG325-2 PCIe Card Constraints
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
# 4. User Telemetry Status LEDs & HDMI HPD Pin (commented out - unknown CSG325 pins)
# ------------------------------------------------------------------------------
# set_property PACKAGE_PIN W10 [get_ports user_led_dma_active]
# set_property IOSTANDARD LVCMOS33 [get_ports user_led_dma_active]

# set_property PACKAGE_PIN V10 [get_ports user_led_pcie_link_up]
# set_property IOSTANDARD LVCMOS33 [get_ports user_led_pcie_link_up]

# set_property PACKAGE_PIN Y11 [get_ports hdmi_hpd_out]
# set_property IOSTANDARD LVCMOS33 [get_ports hdmi_hpd_out]

# ------------------------------------------------------------------------------
# 5. Video-domain reset synchronizer
# ------------------------------------------------------------------------------
# PCIe user_reset and MMCM LOCKED asynchronously assert the first video-domain
# reset synchronizer capture stage. Deassertion propagates through two further
# synchronous stages, so recovery/removal timing is intentionally excluded only
# at the metastability-capture register CLR pin.
set_false_path -to [get_pins -quiet -hierarchical -filter \
    {REF_PIN_NAME == CLR && NAME =~ *video_reset_meta_reg*}]

# BAR0 video_pipeline_reset originates in the 125 MHz PCIe domain and is
# sampled by the first stage of an ASYNC_REG synchronizer at 150 MHz.
set_false_path -to [get_pins -quiet -hierarchical -regexp \
    {.*video_pipeline_reset_sync_reg\[0\]/D}]

# The 150 MHz video domain and the PCIe user-clock domain exchange data
# exclusively through proper CDC primitives (xpm_cdc_handshake,
# xpm_fifo_async, video_req_cdc gray-pointer FIFO, ASYNC_REG 2FF stages).
# Declare the two trees asynchronous so their crossings are not analyzed
# as synchronous paths.
set_clock_groups -name async_video_vs_pcie -asynchronous \
    -group [get_clocks -include_generated_clocks clk150_mmcm] \
    -group [get_clocks -include_generated_clocks userclk2]

# ------------------------------------------------------------------------------
# 6. Bitstream Configuration Properties
# ------------------------------------------------------------------------------
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 40 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]

set_property SEVERITY {Warning} [get_drc_checks NSTD-1]
set_property SEVERITY {Warning} [get_drc_checks UCIO-1]
