# ==============================================================================
# Vivado TCL Build Script for SC7F0 N1 HDMI2 V11 (ZU4EV PCIe Video & Audio DMA Card)
# Target Device: AMD/Xilinx Zynq UltraScale+ (xczu4ev-fbvb900-2-e)
# Top-Level RTL: zu4ev_pcie_card_top.v
# PCIe IP Core: pcie4_uscale_plus_0 (Gen3 x4, 256-bit, Tandem PCIe)
# Distinct Identification: Vendor ID 0x12AB, Device ID 0xE380
# ==============================================================================

set project_name "qpcie_zu4ev_card"
set project_dir  "./build/qpcie_zu4ev_proj"
set device_part  "xczu4ev-fbvb900-2-e"

puts "================================================================="
puts " Starting Vivado Build for ZU4EV SC7F0 (zu4ev_pcie_card_top.v)"
puts " Target Part : $device_part"
puts " PCIe Core   : pcie4_uscale_plus_0 (Gen3 x4, 256-bit, Tandem PCIe)"
puts " Distinct ID : Vendor 0x12AB / Device 0xE380"
puts "================================================================="

file mkdir $project_dir
create_project $project_name $project_dir -part $device_part -force

set_property target_language Verilog [current_project]
set_property default_lib work [current_project]

# 1. Add RTL Sources & Dynamic Git Hash
set git_raw [string toupper [exec git rev-parse --short=8 HEAD]]
set date_raw [clock format [clock seconds] -format "%Y%m%d"]
set git_commit_hex "32'h$git_raw"
set build_date_hex "32'h$date_raw"

puts "   (GIT AUTO-INJECT) Commit Hash: 0x$git_raw, Build Date: $date_raw"

add_files [glob ./rtl/*.v]
set_property top zu4ev_pcie_card_top [current_fileset]

set verilog_defs [list GIT_COMMIT_HASH_DEF=$git_commit_hex BUILD_TIMESTAMP_DEF=$build_date_hex]
set_property verilog_define $verilog_defs [current_fileset]

# 2. Add Constraints
add_files -fileset constrs_1 ./constraints/zu4ev_pcie_pinout.xdc

# 2.1 Generate ZU4EV Processing System Subsystem (zu4ev_ps_bd)
puts "Generating ZU4EV Processing System Subsystem (zu4ev_ps_bd)..."
source ./scripts/create_zu4ev_ps_bd.tcl
create_zu4ev_ps_bd
generate_target all [get_files zu4ev_ps_bd.bd]
set bd_wrapper [make_wrapper -files [get_files zu4ev_ps_bd.bd] -top]
add_files -norecurse $bd_wrapper

# 3. Generate UltraScale+ PCIe Core with Tandem PCIe (Gen3 x4, 256-bit, Quad 223)
puts "Generating UltraScale+ PCIe IP Core (pcie4_uscale_plus_0 - Gen3 x4, 256-bit, Tandem PCIe)..."
create_ip -name pcie4_uscale_plus -vendor xilinx.com -library ip -version 1.3 -module_name pcie4_uscale_plus_0

set_property -dict [list \
  CONFIG.mode_selection {Advanced} \
  CONFIG.en_gt_selection {true} \
  CONFIG.select_quad {GTH_Quad_223} \
  CONFIG.pcie_blk_locn {X0Y1} \
  CONFIG.mcap_enablement {None} \
  CONFIG.PL_LINK_CAP_MAX_LINK_SPEED {8.0_GT/s} \
  CONFIG.PL_LINK_CAP_MAX_LINK_WIDTH {X4} \
  CONFIG.axisten_if_width {256_bit} \
  CONFIG.AXISTEN_IF_CQ_ALIGNMENT_MODE {DWORD_Aligned} \
  CONFIG.AXISTEN_IF_RQ_ALIGNMENT_MODE {DWORD_Aligned} \
  CONFIG.PL_DISABLE_LANE_REVERSAL {FALSE} \
  CONFIG.vendor_id {12AB} \
  CONFIG.PF0_DEVICE_ID {E380} \
  CONFIG.PF0_SUBSYSTEM_VENDOR_ID {12AB} \
  CONFIG.PF0_SUBSYSTEM_ID {0007} \
  CONFIG.pf0_bar0_64bit {false} \
  CONFIG.pf0_bar0_scale {Megabytes} \
  CONFIG.pf0_bar0_size {1} \
  CONFIG.pf0_bar1_enabled {true} \
  CONFIG.pf0_bar1_64bit {false} \
  CONFIG.pf0_bar1_scale {Kilobytes} \
  CONFIG.pf0_bar1_size {64} \
  CONFIG.pf0_msi_enabled {true} \
] [get_ips pcie4_uscale_plus_0]

generate_target all [get_ips pcie4_uscale_plus_0]

# 4. Generate Video Test Pattern Generator IP Core (v_tpg_0)
puts "Generating Video TPG IP Core (v_tpg_0 - 4 PPC 4K60)..."
create_ip -name v_tpg -vendor xilinx.com -library ip -version 8.2 -module_name v_tpg_0

set_property -dict [list \
  CONFIG.SAMPLES_PER_CLOCK {4} \
  CONFIG.MAX_DATA_WIDTH {8} \
  CONFIG.MAX_COLS {4096} \
  CONFIG.MAX_ROWS {2160} \
] [get_ips v_tpg_0]

generate_target all [get_ips v_tpg_0]

# 5. Generate AXI Crossbar IP Core (axi_crossbar_0 - 1x3)
puts "Generating AXI Crossbar IP Core (axi_crossbar_0 - 1x3)..."
create_ip -name axi_crossbar -vendor xilinx.com -library ip -version 2.1 -module_name axi_crossbar_0

set_property -dict [list \
  CONFIG.NUM_SI {1} \
  CONFIG.NUM_MI {3} \
  CONFIG.PROTOCOL {AXI4LITE} \
  CONFIG.DATA_WIDTH {32} \
  CONFIG.ADDR_WIDTH {32} \
  CONFIG.M00_A00_BASE_ADDR {0x0000000000000000} \
  CONFIG.M00_A00_ADDR_WIDTH {12} \
  CONFIG.M01_A00_BASE_ADDR {0x0000000000001000} \
  CONFIG.M01_A00_ADDR_WIDTH {12} \
  CONFIG.M02_A00_BASE_ADDR {0x0000000000002000} \
  CONFIG.M02_A00_ADDR_WIDTH {12} \
] [get_ips axi_crossbar_0]

generate_target all [get_ips axi_crossbar_0]

# 6. Generate Video PHY Controller IP Core (vid_phy_controller_0 - Quad 226 HDMI RX/TX)
puts "Generating Video PHY Controller IP Core (vid_phy_controller_0)..."
create_ip -name vid_phy_controller -vendor xilinx.com -library ip -version 2.2 -module_name vid_phy_controller_0

set_property -dict [list \
  CONFIG.Adv_Clk_Mode {true} \
  CONFIG.CHANNEL_ENABLE {X0Y12 X0Y13 X0Y14} \
  CONFIG.CHANNEL_SITE {X0Y12} \
  CONFIG.C_INPUT_PIXELS_PER_CLOCK {4} \
  CONFIG.C_INT_HDMI_VER_CMPTBLE {3} \
  CONFIG.C_NIDRU {true} \
  CONFIG.C_NIDRU_REFCLK_SEL {3} \
  CONFIG.C_RX_PLL_SELECTION {0} \
  CONFIG.C_RX_REFCLK_SEL {1} \
  CONFIG.C_Rx_Protocol {HDMI} \
  CONFIG.C_TX_PLL_SELECTION {6} \
  CONFIG.C_TX_REFCLK_SEL {0} \
  CONFIG.C_Tx_Protocol {HDMI} \
  CONFIG.C_Txrefclk_Rdy_Invert {true} \
  CONFIG.C_Use_Oddr_for_Tmds_Clkout {true} \
  CONFIG.Rx_GT_Line_Rate {5.94} \
  CONFIG.Rx_GT_Ref_Clock_Freq {297} \
  CONFIG.Tx_GT_Line_Rate {5.94} \
  CONFIG.Tx_GT_Ref_Clock_Freq {297} \
] [get_ips vid_phy_controller_0]

generate_target all [get_ips vid_phy_controller_0]

# 7. Generate HDMI RX Subsystem IP Core (v_hdmi_rx_ss_0 - 4 PPC)
puts "Generating HDMI RX Subsystem IP Core (v_hdmi_rx_ss_0 - 4 PPC)..."
create_ip -name v_hdmi_rx_ss -vendor xilinx.com -library ip -version 3.2 -module_name v_hdmi_rx_ss_0

set_property -dict [list \
  CONFIG.C_INPUT_PIXELS_PER_CLOCK {4} \
  CONFIG.C_MAX_BITS_PER_COMPONENT {8} \
  CONFIG.C_VID_INTERFACE {0} \
  CONFIG.C_INCLUDE_LOW_RESO_VID {true} \
  CONFIG.C_INCLUDE_YUV420_SUP {true} \
  CONFIG.C_HDMI_FAST_SWITCH {true} \
  CONFIG.C_EXDES_TX_PLL_SELECTION {6} \
  CONFIG.C_EXDES_RX_PLL_SELECTION {0} \
  CONFIG.C_EXDES_NIDRU {true} \
] [get_ips v_hdmi_rx_ss_0]

generate_target all [get_ips v_hdmi_rx_ss_0]

# 8. Generate HDMI TX Subsystem IP Core (v_hdmi_tx_ss_0 - 4 PPC)
puts "Generating HDMI TX Subsystem IP Core (v_hdmi_tx_ss_0 - 4 PPC)..."
create_ip -name v_hdmi_tx_ss -vendor xilinx.com -library ip -version 3.2 -module_name v_hdmi_tx_ss_0

set_property -dict [list \
  CONFIG.C_INPUT_PIXELS_PER_CLOCK {4} \
  CONFIG.C_MAX_BITS_PER_COMPONENT {8} \
  CONFIG.C_VID_INTERFACE {0} \
  CONFIG.C_INCLUDE_LOW_RESO_VID {true} \
  CONFIG.C_INCLUDE_YUV420_SUP {true} \
  CONFIG.C_HDMI_FAST_SWITCH {true} \
  CONFIG.C_EXDES_TX_PLL_SELECTION {6} \
  CONFIG.C_EXDES_RX_PLL_SELECTION {0} \
] [get_ips v_hdmi_tx_ss_0]

generate_target all [get_ips v_hdmi_tx_ss_0]

# 9. Update Compile Order
update_compile_order -fileset sources_1

# IP cache disable
config_ip_cache -disable_cache

puts "Starting Synthesis (synth_1)..."
launch_runs synth_1 -jobs 8
wait_on_run synth_1

if {[get_property PROGRESS [get_runs synth_1]] != "100%" ||
    [string first "ERROR" [get_property STATUS [get_runs synth_1]]] >= 0} {
    puts "ERROR: Synthesis failed for ZU4EV top module!"
    exit 1
}

puts "Starting Implementation & Bitstream Generation (impl_1)..."
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

if {[get_property PROGRESS [get_runs impl_1]] != "100%" ||
    [string first "ERROR" [get_property STATUS [get_runs impl_1]]] >= 0} {
    puts "ERROR: Implementation failed for ZU4EV top module!"
    exit 1
}

open_run impl_1
set impl_dir [get_property DIRECTORY [get_runs impl_1]]
puts "================================================================="
puts " SUCCESS: ZU4EV Tandem PCIe Bitstreams Built (12AB:E380)!"
puts " Output Bitstreams in $impl_dir:"
foreach f [glob -nocomplain "$impl_dir/*.bit"] {
    set size [file size $f]
    puts "  [file tail $f] : $size bytes"
}
puts "================================================================="

report_timing_summary -file $project_dir/timing_summary.rpt
close_project
exit 0
