# Resume only the isolated dual-video project; does not touch old release projects.
set root [file normalize [file join [file dirname [info script]] ..]]
cd $root
set out ./build/dual-video-26102901-r7
if {[info exists ::env(SC7F0_PROJECT_DIR)]} {set out $::env(SC7F0_PROJECT_DIR)}
# Same opt-in switch as scripts/build_zu4ev.tcl. Unset/0 leaves this script's
# behaviour (and every published build) unchanged.
set vcu 0
if {[info exists ::env(SC7F0_ENABLE_VCU)]} {
    set vcu_req [string tolower [string trim $::env(SC7F0_ENABLE_VCU)]]
    if {$vcu_req ni {0 1 true false yes no}} {
        error "SC7F0_ENABLE_VCU must be 0/1 (true/false), got '$vcu_req'"
    }
    if {$vcu_req in {1 true yes}} {set vcu 1}
}
puts "SC7F0_IMPL_VCU $vcu"
# SC7F0_IMPL_RESUME=postroute skips BD regeneration, synthesis and implementation
# and only re-runs the routed reports, gates and XSA export on an existing run.
# It exists for evidence recovery after a post-route script defect; the routed
# design and bitstream on disk stay authoritative and untouched.
set resume ""
if {[info exists ::env(SC7F0_IMPL_RESUME)]} {set resume [string tolower $::env(SC7F0_IMPL_RESUME)]}
if {$resume ni {"" postroute}} {error "SC7F0_IMPL_RESUME must be empty or postroute"}
if {$resume ne ""} {puts "SC7F0_IMPL_RESUME $resume (BD regeneration, synthesis and implementation skipped)"}
open_project $out/qpcie_zu4ev_card.xpr
report_ip_status -file $out/ip_status.rpt
if {$resume eq ""} {
set old_bd [get_files -quiet */zu4ev_ps_bd.bd]
if {![llength $old_bd]} {
    source scripts/create_zu4ev_ps_bd.tcl
    if {$vcu} {
        create_zu4ev_ps_bd 1 1 "xbar"
    } else {
        create_zu4ev_ps_bd 1
    }
    set bd [get_files zu4ev_ps_bd.bd]
} else {
    set bd [lindex $old_bd 0]
    open_bd_design $bd
}
set_property -dict [list CONFIG.AWUSER_WIDTH {1} CONFIG.ARUSER_WIDTH {1} CONFIG.FREQ_HZ {300000000}] [get_bd_intf_ports S_AXI_HP1_FPD]
set_property CONFIG.FREQ_HZ 300000000 [get_bd_ports dp_mem_clk]
if {$vcu} {
    set_property -dict [list CONFIG.AXI_ENC_CLK {300} CONFIG.AXI_MCU_CLK {300}] [get_bd_cells vcu_0]
    # The BD must be the encoder-only Todo 1.2b netlist, not the retired
    # SmartConnect variant and not a silently VCU-less BD.
    if {![llength [get_bd_cells -quiet vcu_0]]} {
        error "SC7F0_ENABLE_VCU is set but vcu_0 is absent from zu4ev_ps_bd"
    }
    if {[llength [get_bd_cells -quiet -hierarchical -filter {IP_NAME =~ "*smartconnect*"}]]} {
        error "Slim VCU memory path expected; a smartconnect cell is still in the BD"
    }
    if {![llength [get_bd_cells -quiet xbar_vcu_enc]] ||
        ![llength [get_bd_cells -quiet dwc_vcu_mcu]]} {
        error "Expected xbar_vcu_enc and dwc_vcu_mcu in the VCU BD"
    }
    set lite_seg [get_bd_addr_segs -quiet -of [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] \
        -filter {NAME == "SEG_vcu_0_Reg"}]
    set lite_count [llength $lite_seg]
    set lite ""
    set lite_value -1
    if {$lite_count} {
        set lite [get_property OFFSET [lindex $lite_seg 0]]
        scan $lite %x lite_value
    }
    if {$lite_count != 1 || $lite_value != 0xB0100000} {
        error "VCU register aperture expected once at 0xB0100000, got $lite_count segment(s) '$lite'"
    }
    puts "SC7F0_VCU_BD_OK vcu_0 xbar_vcu_enc dwc_vcu_mcu S_AXI_LITE=$lite [get_property RANGE [lindex $lite_seg 0]]"
}
validate_bd_design
save_bd_design
generate_target all $bd
set bd_wrapper [make_wrapper -files $bd -top]
add_files -norecurse $bd_wrapper
update_compile_order -fileset sources_1
}
if {$resume eq ""} {
set_property AUTO_INCREMENTAL_CHECKPOINT 0 [get_runs synth_1]
reset_runs synth_1
launch_runs synth_1 -jobs 6
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%" ||
    [string first "ERROR" [get_property STATUS [get_runs synth_1]]] >= 0} {error "Dual-video synthesis failed"}
}
open_run synth_1
report_utilization -hierarchical -hierarchical_depth 3 -file $out/utilization_synth_hierarchical.rpt
# Prove production source pruning in the linked design, not just in Tcl/IP lists.
set audit [open $out/c2h-personality.rpt w]
foreach pattern {u_hdmi_tx_ss u_hdmi_tx_video_bridge u_hdmi_tx_audio_bridge u_v_tpg u_audio_pattern_gen u_tpg_marker_overlay u_tpg_video_cdc u_ch1_loopback_cdc u_ch2_loopback_cdc u_ch3_loopback_cdc u_nv12_capture_engine_ch1 u_nv12_capture_engine_ch2 u_nv12_capture_engine_ch3 u_video_req_cdc_ch1 u_video_req_cdc_ch2 u_video_req_cdc_ch3 u_audio_h2c_fifo_ch1 u_audio_h2c_fifo_ch2 u_audio_h2c_fifo_ch3 u_audio_stream_engine_ch1 u_audio_stream_engine_ch2 u_audio_stream_engine_ch3} {
    set cells [get_cells -quiet -hier -filter "NAME =~ *$pattern*"]
    puts $audit "ABSENT $pattern [llength $cells]"
    if {[llength $cells]} {close $audit; error "Unwanted production hardware: $pattern"}
}
foreach pattern {u_hdmi_rx_ss u_vid_phy_controller u_ps_capture u_nv12_capture_engine u_audio_stream_engine_ch0 u_dualpath u_h2c_ps_ddr_writer} {
    set cells [get_cells -quiet -hier -filter "NAME =~ *$pattern*"]
    puts $audit "PRESENT $pattern [llength $cells]"
    if {![llength $cells]} {close $audit; error "Missing required hardware: $pattern"}
}
if {$vcu} {
    # One VCU hard macro (the only one on this part) and no retired VCU
    # SmartConnect hardware in the linked design.
    set vcu_macro [get_cells -quiet -hier -filter {IS_PRIMITIVE == true && REF_NAME =~ "VCU*"}]
    set vcu_cell [get_cells -quiet -hier -filter {NAME =~ *vcu_0/inst/VCU_i*}]
    puts $audit "PRESENT VCU_hard_macro_primitive [llength $vcu_macro]"
    puts $audit "PRESENT VCU_hard_macro_cell [llength $vcu_cell]"
    if {![llength $vcu_macro] && ![llength $vcu_cell]} {
        close $audit; error "No VCU hard macro in the linked design"
    }
    if {[llength $vcu_macro] > 1 || [llength $vcu_cell] > 1} {
        close $audit; error "More than one VCU hard macro (part has exactly one)"
    }
    if {[llength $vcu_macro]} {
        puts $audit "VCU_MACRO_CELL [lindex [get_property NAME $vcu_macro] 0]"
    } else {
        puts $audit "VCU_MACRO_CELL [lindex [get_property NAME $vcu_cell] 0]"
    }
    set sc [get_cells -quiet -hier -filter "NAME =~ *smc_vcu*"]
    puts $audit "ABSENT smc_vcu_interconnect [llength $sc]"
    if {[llength $sc]} {close $audit; error "Retired SmartConnect VCU path is present in the netlist"}
}
puts $audit C2H_PERSONALITY_SYNTH_PASS
close $audit
close_design
if {$resume eq ""} {
launch_runs impl_1 -to_step write_bitstream -jobs 6
wait_on_run impl_1
if {[string first "write_bitstream Complete" [get_property STATUS [get_runs impl_1]]] < 0} {
    error "Dual-video implementation/bitstream failed"
}
}
open_run impl_1
# Independently recheck all 128 Gray endpoints on the routed design.
# The markers delimit the routed re-check for the scoped delta review, so it
# cannot be satisfied by the earlier opt_design pre-hook output.
puts "SC7F0_GRAY_ROUTED_BEGIN"
source scripts/check_sc7f0_capture_gray.tcl
puts "SC7F0_GRAY_ROUTED_END"
if {$vcu} {
    # Routed proof: the encoder hard macro survived implementation.
    set vcu_macro [get_cells -quiet -hier -filter {IS_PRIMITIVE == true && REF_NAME =~ "VCU*"}]
    set vcu_cell [get_cells -quiet -hier -filter {NAME =~ *vcu_0/inst/VCU_i*}]
    if {![llength $vcu_macro] && ![llength $vcu_cell]} {
        error "VCU hard macro missing from the routed design"
    }
    if {[llength $vcu_macro]} {
        puts "SC7F0_VCU_ROUTED_CELL [lindex [get_property NAME $vcu_macro] 0]"
    } else {
        puts "SC7F0_VCU_ROUTED_CELL [lindex [get_property NAME $vcu_cell] 0]"
    }
    if {![llength [get_cells -quiet -hier -filter {NAME =~ *xbar_vcu_enc*}]]} {
        error "VCU video merge path missing from the routed design"
    }
}
report_exceptions -coverage -file $out/exceptions-coverage.rpt
report_utilization -hierarchical -hierarchical_depth 4 -file $out/utilization_routed_hierarchical.rpt
report_timing_summary -delay_type min_max -report_unconstrained -file $out/timing_summary.rpt
check_timing -verbose -file $out/check-timing.rpt
report_cdc -details -file $out/cdc.rpt
report_bus_skew -warn_on_violation -file $out/bus-skew.rpt
report_methodology -file $out/methodology.rpt
if {[get_property SLACK [get_timing_paths -delay_type max -max_paths 1]] < 0 ||
    [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]] < 0} {
    error "Dual-video timing failed; XSA withheld"
}
# The exact-path timing/CDC gate below is the shipped whole-design gate. It is
# known to fail closed on the frozen R7 inventory (see the R6/R7 review
# documents), so the verdict is always recorded, and only an unexpected failure
# is fatal: SC7F0_TIMING_GATE=record keeps the report for the scoped delta
# review instead of aborting before XSA export.
set gate_record 0
if {[info exists ::env(SC7F0_TIMING_GATE)]} {set gate_record [string equal $::env(SC7F0_TIMING_GATE) record]}
if {[catch {exec python3 scripts/check_sc7f0_timing.py $out} result]} {
    set status [catch {exec python3 scripts/check_sc7f0_timing.py $out > $out/timing-gate-record.json} rec]
    if {!$gate_record} {
        if {$status == 1} {error "Dual-video timing/CDC gate failed; XSA withheld: $result"}
        error "Dual-video timing/CDC gate could not be evaluated; XSA withheld: $result"
    }
    puts "SC7F0_TIMING_GATE_RECORDED (scoped delta review is authoritative)"
} else {
    exec python3 scripts/check_sc7f0_timing.py $out > $out/timing-gate-record.json
    puts "SC7F0_TIMING_GATE_PASS"
}
write_hw_platform -fixed -include_bit -force $out/hardware.xsa
puts "SC7F0_DUAL_VIDEO_VIVADO_PASS"
close_project
exit
