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
# The 150 MHz video domain, HDMI RX domains, and the PCIe user-clock domain
# exchange data exclusively through proper CDC primitives (xpm_fifo_async, etc.).
create_clock -period 6.734 -name tm0_pclk [get_ports tm0_pclk]
create_clock -period 81.380 -name tm0_i2s_sck [get_ports tm0_i2s_sck]

# ICAPE2 is limited to 100 MHz; the SPI controller divides userclk2 by two.
create_generated_clock -name icap_clk -source [get_pins u_spi_flash/icap_clk_div_reg/C] \
    -divide_by 2 [get_pins u_spi_flash/icap_clk_div_reg/Q]

set_clock_groups -name async_video_vs_pcie -asynchronous \
    -group [get_clocks -include_generated_clocks clk150_mmcm] \
    -group [get_clocks -include_generated_clocks userclk2] \
    -group [get_clocks -include_generated_clocks tm0_pclk] \
    -group [get_clocks -include_generated_clocks tm0_i2s_sck]

# ------------------------------------------------------------------------------
# 6. Front-End I2C Bus (IT68051 @ 0x48, TLV320ADC3101 @ 0x18)
# ------------------------------------------------------------------------------
set_property PACKAGE_PIN U12 [get_ports scl_front]
set_property IOSTANDARD LVCMOS33 [get_ports scl_front]
set_property PULLUP true [get_ports scl_front]

set_property PACKAGE_PIN T12 [get_ports sda_front]
set_property IOSTANDARD LVCMOS33 [get_ports sda_front]
set_property PULLUP true [get_ports sda_front]

# ------------------------------------------------------------------------------
# 6b. MCU I2C Bus (NUC100 I2C0 slave @ 0x2A, ATECC508A)
# Sheet3: PA.8/SDA0->SDA_MCU, PA.9/SCL0->SCL_MCU; 4.7K pulls R31/R32 on board.
# FPGA Bank14 pair IO_L10P/N (N18/P18), VCCO_14 = 3.3V.
# ------------------------------------------------------------------------------
set_property PACKAGE_PIN P18 [get_ports scl_mcu]
set_property IOSTANDARD LVCMOS33 [get_ports scl_mcu]
set_property PULLUP true [get_ports scl_mcu]

set_property PACKAGE_PIN N18 [get_ports sda_mcu]
set_property IOSTANDARD LVCMOS33 [get_ports sda_mcu]
set_property PULLUP true [get_ports sda_mcu]

# ------------------------------------------------------------------------------
# 7. Macronix MX25L12835F SPI Flash (Bank 14 User Runtime Access)
# Note: SCLK is driven via internal STARTUPE2 primitive to CCLK_0 (Pin E8).
# ------------------------------------------------------------------------------
set_property PACKAGE_PIN L15 [get_ports spi_fcs_b]
set_property IOSTANDARD LVCMOS33 [get_ports spi_fcs_b]

set_property PACKAGE_PIN K16 [get_ports spi_d00_mosi]
set_property IOSTANDARD LVCMOS33 [get_ports spi_d00_mosi]

set_property PACKAGE_PIN L17 [get_ports spi_d01_din]
set_property IOSTANDARD LVCMOS33 [get_ports spi_d01_din]

set_property PACKAGE_PIN J15 [get_ports spi_d02_wp_n]
set_property IOSTANDARD LVCMOS33 [get_ports spi_d02_wp_n]

set_property PACKAGE_PIN J16 [get_ports spi_d03_hld_n]
set_property IOSTANDARD LVCMOS33 [get_ports spi_d03_hld_n]

# ------------------------------------------------------------------------------
# 8. Front-End Reset Output (IT68051 active-low reset via SU8 AND gate)
# ------------------------------------------------------------------------------
set_property PACKAGE_PIN V12 [get_ports rstn_gpio_f]
set_property IOSTANDARD LVCMOS33 [get_ports rstn_gpio_f]

# ------------------------------------------------------------------------------
# 8b. IT68051 HDMI Receiver Interface (Banks 15 & 34, LVCMOS33)
# ------------------------------------------------------------------------------
# Clock & Sync (Bank 15)
set_property PACKAGE_PIN E13 [get_ports tm0_pclk]
set_property IOSTANDARD LVCMOS33 [get_ports tm0_pclk]

set_property PACKAGE_PIN D18 [get_ports tm0_de]
set_property IOSTANDARD LVCMOS33 [get_ports tm0_de]

set_property PACKAGE_PIN B17 [get_ports tm0_vs]
set_property IOSTANDARD LVCMOS33 [get_ports tm0_vs]

set_property PACKAGE_PIN E17 [get_ports tm0_hs]
set_property IOSTANDARD LVCMOS33 [get_ports tm0_hs]

set_property PACKAGE_PIN F15 [get_ports int_68051]
set_property IOSTANDARD LVCMOS33 [get_ports int_68051]

# Port A Pixel Data (Bank 15 - Blue [9:0])
set_property PACKAGE_PIN D8  [get_ports {tm0_a_b[0]}]
set_property PACKAGE_PIN C8  [get_ports {tm0_a_b[1]}]
set_property PACKAGE_PIN D9  [get_ports {tm0_a_b[2]}]
set_property PACKAGE_PIN C9  [get_ports {tm0_a_b[3]}]
set_property PACKAGE_PIN B9  [get_ports {tm0_a_b[4]}]
set_property PACKAGE_PIN A9  [get_ports {tm0_a_b[5]}]
set_property PACKAGE_PIN C11 [get_ports {tm0_a_b[6]}]
set_property PACKAGE_PIN B11 [get_ports {tm0_a_b[7]}]
set_property PACKAGE_PIN B10 [get_ports {tm0_a_b[8]}]
set_property PACKAGE_PIN A10 [get_ports {tm0_a_b[9]}]
set_property IOSTANDARD LVCMOS33 [get_ports {tm0_a_b[*]}]

# Port A Pixel Data (Bank 15 - Green [9:0])
set_property PACKAGE_PIN D11 [get_ports {tm0_a_g[0]}]
set_property PACKAGE_PIN C12 [get_ports {tm0_a_g[1]}]
set_property PACKAGE_PIN B12 [get_ports {tm0_a_g[2]}]
set_property PACKAGE_PIN A12 [get_ports {tm0_a_g[3]}]
set_property PACKAGE_PIN A13 [get_ports {tm0_a_g[4]}]
set_property PACKAGE_PIN A14 [get_ports {tm0_a_g[5]}]
set_property PACKAGE_PIN C14 [get_ports {tm0_a_g[6]}]
set_property PACKAGE_PIN B15 [get_ports {tm0_a_g[7]}]
set_property PACKAGE_PIN B14 [get_ports {tm0_a_g[8]}]
set_property PACKAGE_PIN A15 [get_ports {tm0_a_g[9]}]
set_property IOSTANDARD LVCMOS33 [get_ports {tm0_a_g[*]}]

# Port A Pixel Data (Bank 15 - Red [9:0])
set_property PACKAGE_PIN D13 [get_ports {tm0_a_r[0]}]
set_property PACKAGE_PIN C13 [get_ports {tm0_a_r[1]}]
set_property PACKAGE_PIN D14 [get_ports {tm0_a_r[2]}]
set_property PACKAGE_PIN E15 [get_ports {tm0_a_r[3]}]
set_property PACKAGE_PIN D15 [get_ports {tm0_a_r[4]}]
set_property PACKAGE_PIN E16 [get_ports {tm0_a_r[5]}]
set_property PACKAGE_PIN D16 [get_ports {tm0_a_r[6]}]
set_property PACKAGE_PIN B16 [get_ports {tm0_a_r[7]}]
set_property PACKAGE_PIN A17 [get_ports {tm0_a_r[8]}]
set_property PACKAGE_PIN C16 [get_ports {tm0_a_r[9]}]
set_property IOSTANDARD LVCMOS33 [get_ports {tm0_a_r[*]}]

# Port B Pixel Data (Bank 34 - Blue [9:0])
set_property PACKAGE_PIN K6 [get_ports {tm0_b_b[0]}]
set_property PACKAGE_PIN K5 [get_ports {tm0_b_b[1]}]
set_property PACKAGE_PIN J5 [get_ports {tm0_b_b[2]}]
set_property PACKAGE_PIN J4 [get_ports {tm0_b_b[3]}]
set_property PACKAGE_PIN K2 [get_ports {tm0_b_b[4]}]
set_property PACKAGE_PIN K1 [get_ports {tm0_b_b[5]}]
set_property PACKAGE_PIN K3 [get_ports {tm0_b_b[6]}]
set_property PACKAGE_PIN L2 [get_ports {tm0_b_b[7]}]
set_property PACKAGE_PIN L4 [get_ports {tm0_b_b[8]}]
set_property PACKAGE_PIN L3 [get_ports {tm0_b_b[9]}]
set_property IOSTANDARD LVCMOS33 [get_ports {tm0_b_b[*]}]

# Port B Pixel Data (Bank 34 - Green [9:0])
set_property PACKAGE_PIN L5 [get_ports {tm0_b_g[0]}]
set_property PACKAGE_PIN M5 [get_ports {tm0_b_g[1]}]
set_property PACKAGE_PIN M2 [get_ports {tm0_b_g[2]}]
set_property PACKAGE_PIN M1 [get_ports {tm0_b_g[3]}]
set_property PACKAGE_PIN M6 [get_ports {tm0_b_g[4]}]
set_property PACKAGE_PIN N6 [get_ports {tm0_b_g[5]}]
set_property PACKAGE_PIN N1 [get_ports {tm0_b_g[6]}]
set_property PACKAGE_PIN P1 [get_ports {tm0_b_g[7]}]
set_property PACKAGE_PIN M4 [get_ports {tm0_b_g[8]}]
set_property PACKAGE_PIN N4 [get_ports {tm0_b_g[9]}]
set_property IOSTANDARD LVCMOS33 [get_ports {tm0_b_g[*]}]

# Port B Pixel Data (Bank 34 - Red [9:0])
set_property PACKAGE_PIN N3 [get_ports {tm0_b_r[0]}]
set_property PACKAGE_PIN N2 [get_ports {tm0_b_r[1]}]
set_property PACKAGE_PIN P4 [get_ports {tm0_b_r[2]}]
set_property PACKAGE_PIN P3 [get_ports {tm0_b_r[3]}]
set_property PACKAGE_PIN V3 [get_ports {tm0_b_r[4]}]
set_property PACKAGE_PIN V2 [get_ports {tm0_b_r[5]}]
set_property PACKAGE_PIN T4 [get_ports {tm0_b_r[6]}]
set_property PACKAGE_PIN T3 [get_ports {tm0_b_r[7]}]
set_property PACKAGE_PIN U4 [get_ports {tm0_b_r[8]}]
set_property PACKAGE_PIN V4 [get_ports {tm0_b_r[9]}]
set_property IOSTANDARD LVCMOS33 [get_ports {tm0_b_r[*]}]

# I2S Audio (Bank 34)
set_property PACKAGE_PIN R2 [get_ports tm0_i2s_mck]
set_property PACKAGE_PIN R3 [get_ports tm0_i2s_sck]
set_property PACKAGE_PIN P6 [get_ports tm0_i2s_ws]
set_property PACKAGE_PIN P5 [get_ports tm0_i2s_d0]
set_property PACKAGE_PIN U6 [get_ports {tm0_i2s_d[1]}]
set_property PACKAGE_PIN U5 [get_ports {tm0_i2s_d[2]}]
set_property PACKAGE_PIN R5 [get_ports {tm0_i2s_d[3]}]
set_property PACKAGE_PIN T5 [get_ports {tm0_i2s_d[4]}]
set_property PACKAGE_PIN R7 [get_ports {tm0_i2s_d[5]}]
set_property IOSTANDARD LVCMOS33 [get_ports tm0_i2s_mck]
set_property IOSTANDARD LVCMOS33 [get_ports tm0_i2s_sck]
set_property IOSTANDARD LVCMOS33 [get_ports tm0_i2s_ws]
set_property IOSTANDARD LVCMOS33 [get_ports tm0_i2s_d0]
set_property IOSTANDARD LVCMOS33 [get_ports {tm0_i2s_d[*]}]

# ------------------------------------------------------------------------------
# 9. Bitstream Configuration Properties
# ------------------------------------------------------------------------------
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 40 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN Pullup [current_design]
set_property BITSTREAM.STARTUP.STARTUPCLK CCLK [current_design]

set_property SEVERITY {Warning} [get_drc_checks NSTD-1]
set_property SEVERITY {Warning} [get_drc_checks UCIO-1]
