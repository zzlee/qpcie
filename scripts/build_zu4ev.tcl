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
# Debug-first is the default. The preserved full AV profile is unvalidated and
# must undergo a new hardware revision/PHY bring-up before future publication.
set profile "debug"
if {[info exists ::env(SC7F0_PROFILE)]} {set profile $::env(SC7F0_PROFILE)}
if {$profile ni {debug full}} {error "SC7F0_PROFILE must be debug or full"}
set debug_profile [expr {$profile eq "debug"}]
# Keep experimental AV outputs separate from the validated debug04 project/XSA.
if {!$debug_profile} {set project_dir "./build/qpcie_zu4ev_hdmi_proj"}
if {[info exists ::env(SC7F0_PROJECT_DIR)]} {set project_dir $::env(SC7F0_PROJECT_DIR)}
set build_stage "bitstream"
if {[info exists ::env(SC7F0_BUILD_STAGE)]} {set build_stage $::env(SC7F0_BUILD_STAGE)}
if {$build_stage ni {ip synth bitstream}} {error "SC7F0_BUILD_STAGE must be ip, synth or bitstream"}
# Encoder-only VCU is opt-in per hardware revision. Unset or 0 keeps the shipped
# BD call (and therefore every published bitstream) exactly as it was; 1 adds
# the slimmed encoder subsystem to the full-profile PS block design.
set vcu_enable 0
if {[info exists ::env(SC7F0_ENABLE_VCU)]} {
    set vcu_req [string tolower [string trim $::env(SC7F0_ENABLE_VCU)]]
    if {$vcu_req ni {0 1 true false yes no}} {
        error "SC7F0_ENABLE_VCU must be 0/1 (true/false), got '$vcu_req'"
    }
    if {$vcu_req in {1 true yes}} {set vcu_enable 1}
}
# The VCU memory clock (dp_mem_clk) and the PS HP2/HP3/LPD ports it needs only
# exist in the full profile, so a debug-profile request is a configuration bug.
if {$vcu_enable && $debug_profile} {
    error "SC7F0_ENABLE_VCU requires SC7F0_PROFILE=full (debug profile has no dp_mem_clk)"
}
puts " SC7F0 profile: $profile"
puts " SC7F0 VCU:     $vcu_enable"
exec python3 ./scripts/generate_sc7f0_csr_cdc.py --check

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
# The identity may be pinned by the caller (scripts/build_sc7f0_dual_video_hw.sh
# and the release entry point always pin it) so the project-creation stage and
# the re-synthesis stage in scripts/impl_sc7f0_dual_video.tcl cannot disagree.
# All three overrides arrive together, or none of them and the historical
# create-time behaviour is kept for archived builds.
set pinned 0
if {[info exists ::env(SC7F0_GIT_HASH)] || [info exists ::env(SC7F0_BUILD_DATE)]} {
    foreach e {SC7F0_VERSION SC7F0_GIT_HASH SC7F0_BUILD_DATE} {
        if {![info exists ::env($e)] || [string trim $::env($e)] eq ""} {
            error "pinned build identity needs $e together with SC7F0_GIT_HASH/SC7F0_BUILD_DATE"
        }
    }
    set pinned 1
}
if {$pinned} {
    set git_raw [string toupper [string trim $::env(SC7F0_GIT_HASH)]]
    set date_raw [string trim $::env(SC7F0_BUILD_DATE)]
    if {![regexp {^[0-9A-F]{8}$} $git_raw]} {error "SC7F0_GIT_HASH must be 8 hex digits, got '$git_raw'"}
    if {![regexp {^20[0-9]{2}(0[1-9]|1[0-2])(0[1-9]|[12][0-9]|3[01])$} $date_raw]} {
        error "SC7F0_BUILD_DATE must be YYYYMMDD, got '$date_raw'"
    }
    puts "   (GIT PINNED-BY-CALLER) Commit Hash: 0x$git_raw, Build Date: $date_raw"
} else {
    set git_raw [string toupper [exec git rev-parse --short=8 HEAD]]
    set date_raw [clock format [clock seconds] -format "%Y%m%d"]
    puts "   (GIT AUTO-INJECT) Commit Hash: 0x$git_raw, Build Date: $date_raw"
}
set git_commit_hex "32'h$git_raw"
set build_date_hex "32'h$date_raw"

add_files [glob ./rtl/*.v]
set_property top zu4ev_pcie_card_top [current_fileset]
# Full HDMI bring-up is a new hardware revision; debug04 remains unchanged.
if {!$debug_profile} {
    set hw_version 26102901
    if {[info exists ::env(SC7F0_VERSION)]} {set hw_version $::env(SC7F0_VERSION)}
    if {![regexp {^[0-9A-Fa-f]{8}$} $hw_version]} {error "Invalid SC7F0_VERSION"}
    set_property generic "C_VERSION=32'h$hw_version" [current_fileset]
    # The identity pin is honoured in both stages; SC7F0_ENABLE_VCU is refused
    # above for the debug profile, so a pinned identity can never be dropped.
    if {$pinned && [string toupper $hw_version] ne $git_raw} {
        # Not an error: C_VERSION and the GIT hash are different numbers. This
        # line only records that both came from the same pinned caller.
        puts " SC7F0 pinned identity: C_VERSION=32'h$hw_version GIT=32'h$git_raw DATE=32'h$date_raw"
    }
}

set verilog_defs [list GIT_COMMIT_HASH_DEF=$git_commit_hex BUILD_TIMESTAMP_DEF=$build_date_hex]
if {$debug_profile} {
    lappend verilog_defs SC7F0_DEBUG_ONLY=1
} else {
    # Production SC7F0 has only raw video, packet video and raw audio C2H.
    lappend verilog_defs SC7F0_C2H_ONLY=1
}
set_property verilog_define $verilog_defs [current_fileset]
set_property XPM_LIBRARIES {XPM_CDC XPM_FIFO XPM_MEMORY} [current_project]

# 2. Add only constraints for physically present ports in this profile.
if {$debug_profile} {
    add_files -fileset constrs_1 ./constraints/zu4ev_debug_pinout.xdc
} else {
    add_files -fileset constrs_1 ./constraints/zu4ev_pcie_pinout.xdc
    add_files -fileset constrs_1 ./constraints/sc7f0_capture_gray.xdc
    set_property USED_IN_SYNTHESIS false [get_files sc7f0_capture_gray.xdc]
    set_property PROCESSING_ORDER LATE [get_files sc7f0_capture_gray.xdc]
    # Named async IO exceptions, one port and one first-stage chain at a time
    # (see the file header). LATE + implementation-only, like the Gray file, so
    # the exception cannot be mistaken for a synthesis-time structural change.
    add_files -fileset constrs_1 ./constraints/sc7f0_async_io.xdc
    set_property USED_IN_SYNTHESIS false [get_files sc7f0_async_io.xdc]
    set_property PROCESSING_ORDER LATE [get_files sc7f0_async_io.xdc]
    # Full Tcl belongs in a run hook, not XDC (where if/foreach are ignored).
    set_property STEPS.OPT_DESIGN.TCL.PRE [file normalize scripts/check_sc7f0_capture_gray.tcl] [get_runs impl_1]
}

# 2.1 Generate ZU4EV Processing System Subsystem (zu4ev_ps_bd)
puts "Generating ZU4EV Processing System Subsystem (zu4ev_ps_bd)..."
source ./scripts/create_zu4ev_ps_bd.tcl
if {$vcu_enable} {
    # Slim memory interconnect (axi_crossbar + axi_dwidth_converter), the style
    # measured for Todo 1.2b. Without this branch the call below stays the
    # original two-argument form, so the VCU-off build is bit-for-bit identical.
    create_zu4ev_ps_bd [expr {!$debug_profile}] 1 "xbar"
} else {
    create_zu4ev_ps_bd [expr {!$debug_profile}]
}
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
  CONFIG.axisten_if_enable_client_tag {true} \
  CONFIG.AXISTEN_IF_RC_STRADDLE {false} \
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

# The RQ encoder/RC decoder own tag allocation (0, 1, 2..17, 0x20) and
# parse one unstraddled RC completion at a time. PG213's default core tag
# management overwrites the RQ tag; its RC straddle mode can put two
# completions into a beat. Either default silently breaks H2C routing.
foreach {property expected} {
    CONFIG.axisten_if_enable_client_tag true
    CONFIG.AXISTEN_IF_RC_STRADDLE false
} {
    set actual [get_property $property [get_ips pcie4_uscale_plus_0]]
    if {![string equal -nocase $actual $expected]} {
        error "PCIe IP $property=$actual, expected $expected for rq_tx_encoder/rc_rx_decoder"
    }
}

generate_target all [get_ips pcie4_uscale_plus_0]

# Debug-only TPG. No generated TPG IP in the production RX-only card.
if {$debug_profile} {
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
}

# 5. Generate AXI Crossbar IP Core (axi_crossbar_0 - 1x4)
puts "Generating AXI Crossbar IP Core (axi_crossbar_0 - 1x4)..."
create_ip -name axi_crossbar -vendor xilinx.com -library ip -version 2.1 -module_name axi_crossbar_0

set_property -dict [list \
  CONFIG.NUM_SI {1} \
  CONFIG.NUM_MI {4} \
  CONFIG.PROTOCOL {AXI4LITE} \
  CONFIG.DATA_WIDTH {32} \
  CONFIG.ADDR_WIDTH {32} \
  CONFIG.M00_A00_BASE_ADDR {0x0000000000000000} \
  CONFIG.M00_A00_ADDR_WIDTH {12} \
  CONFIG.M01_A00_BASE_ADDR {0x0000000000001000} \
  CONFIG.M01_A00_ADDR_WIDTH {12} \
  CONFIG.M02_A00_BASE_ADDR {0x0000000000002000} \
  CONFIG.M02_A00_ADDR_WIDTH {12} \
  CONFIG.M03_A00_BASE_ADDR {0x0000000000003000} \
  CONFIG.M03_A00_ADDR_WIDTH {12} \
] [get_ips axi_crossbar_0]

generate_target all [get_ips axi_crossbar_0]

# 5.1 Generate AXI Clock Converter IP Core (axi_clock_converter_0)
puts "Generating AXI Clock Converter IP Core (axi_clock_converter_0)..."
create_ip -name axi_clock_converter -vendor xilinx.com -library ip -version 2.1 -module_name axi_clock_converter_0
set_property -dict [list \
  CONFIG.PROTOCOL {AXI4LITE} \
  CONFIG.DATA_WIDTH {32} \
  CONFIG.ADDR_WIDTH {32} \
  CONFIG.ID_WIDTH {0} \
  CONFIG.AWUSER_WIDTH {0} \
  CONFIG.ARUSER_WIDTH {0} \
  CONFIG.WUSER_WIDTH {0} \
  CONFIG.RUSER_WIDTH {0} \
  CONFIG.BUSER_WIDTH {0} \
] [get_ips axi_clock_converter_0]
generate_target all [get_ips axi_clock_converter_0]

# PS HPM0_FPD is full AXI4 (16-bit transaction IDs), not AXI4-Lite.
# Preserve AXI4 ID, burst, and last semantics when reaching the shared
# PS/PCIe AXI-Lite BAR0 crossbar; tying RID/BID to zero wedges PS requests.
create_ip -name axi_protocol_converter -vendor xilinx.com -library ip -version 2.1 -module_name axi_protocol_converter_0
set_property -dict [list \
  CONFIG.SI_PROTOCOL {AXI4} \
  CONFIG.MI_PROTOCOL {AXI4LITE} \
  CONFIG.ADDR_WIDTH {32} \
  CONFIG.DATA_WIDTH {32} \
  CONFIG.ID_WIDTH {16} \
] [get_ips axi_protocol_converter_0]
generate_target all [get_ips axi_protocol_converter_0]

# 5.2 Generate AXI Crossbar IP Core for BAR0 / PS Arbiter (axi_crossbar_1 - 2x3)
# M00 (0x000-0xFFF): axil_reg_space (DMA regs, PS+PCIe shared)
# M01 (0x1000-0x1FFF): zzlab_env_ctrl (version/platform, PS+PCIe shared)
# M02 (0x2000-0x3FFF): dedicated debug BRAM mailbox
puts "Generating AXI Crossbar IP Core (axi_crossbar_1 - 2x3)..."
source ./scripts/create_bar0_crossbar.tcl
create_qpcie_bar0_crossbar

# 5.3 Generate AXI-Stream Clock Converter IP Core (axis_clock_converter_0 - 128-bit)
puts "Generating AXI-Stream Clock Converter IP Core (axis_clock_converter_0)..."
create_ip -name axis_clock_converter -vendor xilinx.com -library ip -version 1.1 -module_name axis_clock_converter_0
set_property -dict [list \
  CONFIG.TDATA_NUM_BYTES {16} \
  CONFIG.HAS_TKEEP {1} \
  CONFIG.HAS_TLAST {1} \
  CONFIG.TUSER_WIDTH {85} \
] [get_ips axis_clock_converter_0]
generate_target all [get_ips axis_clock_converter_0]

# 5.4 Generate Processor System Reset IP Core (proc_sys_reset_0)
puts "Generating Processor System Reset IP Core (proc_sys_reset_0)..."
create_ip -name proc_sys_reset -vendor xilinx.com -library ip -version 5.0 -module_name proc_sys_reset_0
generate_target all [get_ips proc_sys_reset_0]

# No ILA in this design: reclaim the former 4096-sample capture memory.
# Management/debug mailbox is retained; it is unrelated to on-chip ILA.

if {!$debug_profile} {
# PS HPM1 control aperture. All three IP register banks run on pl_clk0.
source ./scripts/create_sc7f0_hdmi_crossbar.tcl
create_sc7f0_hdmi_crossbar
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

# No HDMI TX subsystem: shared PHY RX/TX clocking is intentionally retained.
# Its former control aperture is a bounded DECERR responder.

# Official PS V4L2 capture pipeline, independent of the raw PCIe branch.
source scripts/create_sc7f0_frmbuf_ip.tcl
create_sc7f0_frmbuf_ip
source scripts/create_sc7f0_vpss_csc_ip.tcl
create_sc7f0_vpss_csc_ip
}

# 9. Update Compile Order
update_compile_order -fileset sources_1
if {$build_stage eq "ip"} {
    puts "IP_GENERATION_COMPLETE: $project_dir (not a bitstream or release)"
    close_project
    exit 0
}

# IP cache disable
config_ip_cache -disable_cache

puts "Starting Synthesis (synth_1)..."
launch_runs synth_1 -jobs 16
wait_on_run synth_1

if {[get_property PROGRESS [get_runs synth_1]] != "100%" ||
    [string first "ERROR" [get_property STATUS [get_runs synth_1]]] >= 0} {
    puts "ERROR: Synthesis failed for ZU4EV top module!"
    exit 1
}

if {$build_stage eq "synth"} {
    puts "SYNTHESIS_COMPLETE: $project_dir (not a bitstream or release)"
    close_project
    exit 0
}
puts "Starting Implementation & Bitstream Generation (impl_1)..."
launch_runs impl_1 -to_step write_bitstream -jobs 16
wait_on_run impl_1

if {[get_property PROGRESS [get_runs impl_1]] != "100%" ||
    [string first "ERROR" [get_property STATUS [get_runs impl_1]]] >= 0} {
    puts "ERROR: Implementation failed for ZU4EV top module!"
    exit 1
}

open_run impl_1
set impl_dir [get_property DIRECTORY [get_runs impl_1]]
set probes_out "$impl_dir/zu4ev_pcie_card_top.ltx"
if {[llength [get_debug_cores -quiet]]} {
    write_debug_probes -force $probes_out
    puts " Debug probes: $probes_out"
} else {
    puts " No ILA/debug cores; no LTX export required."
}
puts "================================================================="
puts " SUCCESS: ZU4EV Tandem PCIe Bitstreams Built (12AB:E380)!"
puts " Output Bitstreams in $impl_dir:"
foreach f [glob -nocomplain "$impl_dir/*.bit"] {
    set size [file size $f]
    puts "  [file tail $f] : $size bytes"
}
puts "================================================================="

report_timing_summary -delay_type min_max -report_unconstrained -file $project_dir/timing_summary.rpt
check_timing -verbose -file $project_dir/check-timing.rpt
report_cdc -details -file $project_dir/cdc.rpt
report_methodology -file $project_dir/methodology.rpt
report_bus_skew -file $project_dir/bus-skew.rpt
report_clock_interaction -file $project_dir/clock-interaction.rpt
# A generated .bit is NOT a release. Refuse XSA export on an invalid
# whole-design clock/CDC/setup/hold/skew model, even if BRAM timing passes.
# This applies to the full HDMI profile as well: the added RX/TX/PHY clock
# domains are exactly where an unreviewed crossing would be most dangerous.
if {[catch {exec python3 ./scripts/check_sc7f0_timing.py $project_dir} gate_result]} {
    puts "ERROR: $profile-profile timing gate failed; XSA NOT exported."
    puts $gate_result
    exit 2
}
puts $gate_result

set xsa_out "./hw_platform/sc7f0_base.xsa"
if {!$debug_profile} {
    set xsa_out "./hw_platform/sc7f0_hdmi.xsa"
}
if {$vcu_enable} {
    set xsa_out "./hw_platform/sc7f0_hdmi_vcu.xsa"
}
if {[info exists ::env(SC7F0_XSA_OUT)]} {set xsa_out $::env(SC7F0_XSA_OUT)}
file mkdir [file dirname $xsa_out]
puts "Exporting updated Hardware Platform XSA ($xsa_out)..."
write_hw_platform -fixed -include_bit -force $xsa_out
puts " SUCCESS: Hardware Platform XSA exported to $xsa_out"

close_project
exit 0
