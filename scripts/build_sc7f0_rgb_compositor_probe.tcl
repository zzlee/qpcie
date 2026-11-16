# =============================================================================
# SC7F0-RGB-COMPOSITOR-2PPC capacity build.
#
# Creates a FRESH project (never reuses, never overwrites an existing build
# directory) for xczu4ev-fbvb900-2-e containing the new RGB compositor data plane
# at the real IP geometry:
#
#   v_hdmi_rx_ss_rgb          2 PPC, 48-bit VIDEO_OUT
#   sc7f0_rgb24_axis_pack     2 PPC RGB888 -> packed RGB24 16-byte DMA beats
#   sc7f0_rgb24_c2h_engine    packed RGB24 C2H DMA engine (channel-0 ABI)
#   video_req_cdc             capture 300 MHz -> PCIe 125 MHz, 128 -> 256 bit
#   sc7f0_overlay_writer      H2C RGBA -> PS DDR slots, AXI4 master on 300 MHz
#   sc7f0_rgb_compositor      2 x sc7f0_frmbuf_rd_rgb + sc7f0_alpha_blend_2ppc
#   sc7f0_hdmi_tx_mux         parameterised to 48-bit
#   v_hdmi_tx_ss_rgb          2 PPC, 48-bit VIDEO_IN
#
# Scope of this vehicle is documented in rtl/zu4ev_rgb_compositor_capacity_top.v:
# the PCIe hardcore/DMA requester, the MCU bridge, the upgrade path and the PS
# block design live outside it and are added from the published routed reports.
#
#   SC7F0_PROJECT_DIR=build/rgb-compositor-probe-<stamp> \
#   SC7F0_PROBE_STAGE=ip|synth|impl \
#     vivado -mode batch -source scripts/build_sc7f0_rgb_compositor_probe.tcl
#
# Nothing here deletes or rewrites another project, and no IP cache is used, so
# the generated OOC runs belong to this directory only.
# =============================================================================
set root [file normalize [file join [file dirname [info script]] ..]]
cd $root

set device_part "xczu4ev-fbvb900-2-e"
set project_name "sc7f0_rgb_compositor"
set stamp "unknown"
if {[info exists ::env(SC7F0_STAMP)]} { set stamp $::env(SC7F0_STAMP) }
set project_dir "./build/rgb-compositor-probe-$stamp"
if {[info exists ::env(SC7F0_PROJECT_DIR)]} { set project_dir $::env(SC7F0_PROJECT_DIR) }
set stage "synth"
if {[info exists ::env(SC7F0_PROBE_STAGE)]} { set stage $::env(SC7F0_PROBE_STAGE) }
if {$stage ni {ip synth impl}} { error "SC7F0_PROBE_STAGE must be ip, synth or impl" }

# A probe must never land on top of an existing round.
if {[file exists [file join $project_dir "$project_name.xpr"]]} {
    error "SC7F0_PROBE_REFUSES_EXISTING_PROJECT $project_dir already has $project_name.xpr; use a fresh SC7F0_STAMP"
}
file mkdir $project_dir
puts "SC7F0_RGB_PROBE_BEGIN dir=$project_dir part=$device_part stage=$stage"

create_project $project_name $project_dir -part $device_part -force
set_property target_language Verilog [current_project]
set_property default_lib work [current_project]
set_property ip_cache_permissions disable [current_project]

# -----------------------------------------------------------------------------
# RTL: only the new personality's sources. The legacy card top, the PS capture
# pipeline, the VCU/dualpath and the NV12 engine are not in this file list at
# all, which is the strongest possible statement that the new profile does not
# instantiate them.
# -----------------------------------------------------------------------------
set rgb_sources {
    rtl/sc7f0_reset_cdc.v
    rtl/sc7f0_dp_fifo.v
    rtl/sc7f0_axil_disabled.v
    rtl/sc7f0_hdmi_tx_mux.v
    rtl/sg_segment_walker.v
    rtl/video_req_cdc.v
    rtl/sc7f0_rgb24_axis_pack.v
    rtl/sc7f0_rgb24_c2h_engine.v
    rtl/sc7f0_alpha_blend_2ppc.v
    rtl/sc7f0_overlay_writer.v
    rtl/sc7f0_video_format_guard.v
    rtl/sc7f0_rgb_compositor.v
    rtl/zu4ev_rgb_compositor_capacity_top.v
}
foreach f $rgb_sources {
    if {![file exists $f]} { error "SC7F0_PROBE_MISSING_SOURCE $f" }
    add_files -norecurse $f
}
set_property top zu4ev_rgb_compositor_capacity_top [current_fileset]
set_property verilog_define {SC7F0_RGB_COMPOSITOR=1} [current_fileset]

# -----------------------------------------------------------------------------
# IP
# -----------------------------------------------------------------------------
source ./scripts/create_sc7f0_rgb_compositor_ip.tcl

# AXI4-Lite clock converter, identical configuration to the legacy build, because
# sc7f0_rgb_compositor instantiates axi_clock_converter_0 by name twice.
if {![llength [get_ips -quiet axi_clock_converter_0]]} {
    create_ip -name axi_clock_converter -vendor xilinx.com -library ip -version 2.1 \
        -module_name axi_clock_converter_0
}
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

create_sc7f0_frmbuf_rd_rgb_ip
create_sc7f0_hdmi_rx_ip_rgb
create_sc7f0_hdmi_tx_ip_rgb

update_compile_order -fileset sources_1
if {$stage eq "ip"} {
    puts "SC7F0_RGB_PROBE_IP_COMPLETE $project_dir"
    close_project
    exit 0
}

# -----------------------------------------------------------------------------
# Synthesis
# -----------------------------------------------------------------------------
set synth_directive ""
if {[info exists ::env(SC7F0_SYNTH_DIRECTIVE)]} { set synth_directive $::env(SC7F0_SYNTH_DIRECTIVE) }
if {$synth_directive ne ""} {
    set allowed [list_property_value STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE [get_runs synth_1]]
    if {[lsearch -exact $synth_directive $allowed] < 0} {
        error "SC7F0_SYNTH_DIRECTIVE='$synth_directive' is not legal; Vivado offers: $allowed"
    }
    set_property STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE $synth_directive [get_runs synth_1]
    puts "SC7F0_SYNTH_DIRECTIVE_SET $synth_directive"
}
set_property AUTO_INCREMENTAL_CHECKPOINT 0 [get_runs synth_1]
reset_runs synth_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1
set sp [get_property PROGRESS [get_runs synth_1]]
set ss [get_property STATUS [get_runs synth_1]]
puts "SC7F0_RGB_PROBE_SYNTH progress=$sp status=$ss"
if {$sp ne "100%"} {
    catch {file copy -force [file join [get_property DIRECTORY [get_runs synth_1]] runme.log] \
           [file join $project_dir synth-failure.log]}
    puts "SC7F0_RGB_PROBE_SYNTH_FAILED"
    close_project
    exit 2
}
open_run synth_1
report_utilization -hierarchical -hierarchical_depth 4 \
    -file $project_dir/utilization_synth_hierarchical.rpt
report_utilization -file $project_dir/utilization_synth.rpt
report_drc -file $project_dir/drc_synth.rpt
catch {report_power -file $project_dir/power_synth.rpt}
close_design

if {$stage ne "impl"} {
    puts "SC7F0_RGB_PROBE_SYNTH_COMPLETE $project_dir"
    close_project
    exit 0
}

# -----------------------------------------------------------------------------
# Implementation
# -----------------------------------------------------------------------------
set impl_run [get_runs impl_1]
foreach {envname prop allowed} {
    SC7F0_OPT_DIRECTIVE   STEPS.OPT_DESIGN.ARGS.DIRECTIVE \
        {Default Explore ExploreArea ExploreSequentialArea RuntimeOptimized}
    SC7F0_PLACE_DIRECTIVE STEPS.PLACE_DESIGN.ARGS.DIRECTIVE \
        {Default Explore ExtraTimingOpt ExtraNetDelay_high ExtraPostPlacementOpt EarlyBlockPlacement Quick}
    SC7F0_PHYS_OPT_DIRECTIVE STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE \
        {Default Explore ExploreWithHoldFix AggressiveExplore AlternateReplication AddRetime}
    SC7F0_ROUTE_DIRECTIVE STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE \
        {Default Explore NoTimingRelaxation MoreGlobalIterations HigherDelayCost}
} {
    if {[info exists ::env($envname)]} {
        set want [string trim $::env($envname)]
        set hit ""
        foreach a $allowed { if {$a eq $want} { set hit $a } }
        if {$hit eq ""} { error "$envname must be one of: $allowed" }
        set_property $prop $hit $impl_run
        puts "SC7F0_RGB_PROBE_DIRECTIVE $envname=$hit"
    }
}
reset_runs impl_1
launch_runs impl_1 -jobs 8
wait_on_run impl_1
set ip_ [get_property PROGRESS [get_runs impl_1]]
set is_ [get_property STATUS [get_runs impl_1]]
puts "SC7F0_RGB_PROBE_IMPL progress=$ip_ status=$is_"
if {[string first "ERROR" $is_] >= 0} {
    puts "SC7F0_RGB_PROBE_IMPL_FAILED $is_"
    close_project
    exit 3
}
open_run impl_1
report_utilization -hierarchical -hierarchical_depth 4 \
    -file $project_dir/utilization_routed_hierarchical.rpt
report_utilization -file $project_dir/utilization_routed.rpt
report_timing_summary -delay_type min_max -report_unconstrained \
    -file $project_dir/timing_summary.rpt
check_timing -verbose -file $project_dir/check-timing.rpt
report_drc -file $project_dir/drc.rpt
report_methodology -file $project_dir/methodology.rpt
report_cdc -details -file $project_dir/cdc.rpt
set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
set whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]
puts "SC7F0_RGB_PROBE_WNS $wns"
puts "SC7F0_RGB_PROBE_WHS $whs"
if {$wns < 0 || $whs < 0} { puts "SC7F0_RGB_PROBE_TIMING_FAILED" } else { puts "SC7F0_RGB_PROBE_TIMING_PASS" }
close_project
puts "SC7F0_RGB_PROBE_COMPLETE $project_dir"
exit 0
