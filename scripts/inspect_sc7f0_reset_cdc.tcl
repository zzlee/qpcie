# Read-only structural evidence on rejected R5; does NOT waive or export it.
set root [file normalize [file join [file dirname [info script]] ..]]
cd $root
if {![info exists ::env(SC7F0_RESET_REVIEW_OUT)]} {error "output directory required"}
set out $::env(SC7F0_RESET_REVIEW_OUT)
open_checkpoint build/dual-video-26102803-r5/qpcie_zu4ev_card.runs/impl_1/zu4ev_pcie_card_top_routed.dcp
set output [open $out/reset-cones.rpt w]
set targets {
    {u_capture_reset/arststages_ff_reg[0]/PRE}
    {u_dma_top/u_video_fifo_reset/arststages_ff_reg[0]/PRE}
    {u_dma_top/u_video_req_cdc/u_rd_reset/arststages_ff_reg[0]/PRE}
    {u_dma_top/u_video_req_cdc/u_wr_reset/arststages_ff_reg[0]/PRE}
    {u_dp_mem_reset/arststages_ff_reg[0]/PRE}
    {u_dualpath/u_packet_commands/u_read_reset/arststages_ff_reg[0]/PRE}
    {u_dualpath/u_packet_commands/u_reset/arststages_ff_reg[0]/PRE}
    {u_dualpath/u_packet_completions/u_read_reset/arststages_ff_reg[0]/PRE}
    {u_dualpath/u_packet_completions/u_reset/arststages_ff_reg[0]/PRE}
    {u_dualpath/u_packet_reset/arststages_ff_reg[0]/PRE}
    {u_dualpath/u_tx_cdc/u_headers/u_read_reset/arststages_ff_reg[0]/PRE}
    {u_dualpath/u_tx_cdc/u_headers/u_reset/arststages_ff_reg[0]/PRE}
    {u_dualpath/u_tx_cdc/u_reset/arststages_ff_reg[0]/PRE}
    {u_hdmi_rx_video_cdc_fifo/u_reset/arststages_ff_reg[0]/PRE}
    {u_ps_capture/u_regs/u_config/u_read_reset/arststages_ff_reg[0]/PRE}
    {u_ps_capture/u_regs/u_config/u_reset/arststages_ff_reg[0]/PRE}
    {u_ps_capture/u_regs/u_csc_reset/arststages_ff_reg[0]/PRE}
    {u_ps_capture/u_regs/u_metadata/u_read_reset/arststages_ff_reg[0]/PRE}
    {u_ps_capture/u_regs/u_metadata/u_reset/arststages_ff_reg[0]/PRE}
    {u_ps_capture/u_regs/u_writer_reset/arststages_ff_reg[0]/PRE}
    {u_ps_capture/u_tap/u_headers/u_read_reset/arststages_ff_reg[0]/PRE}
    {u_ps_capture/u_tap/u_headers/u_reset/arststages_ff_reg[0]/PRE}
    {u_ps_capture/u_tap/u_pixels/u_read_reset/arststages_ff_reg[0]/PRE}
    {u_ps_capture/u_tap/u_pixels/u_reset/arststages_ff_reg[0]/PRE}
    {u_rx_video_reset/arststages_ff_reg[0]/PRE}
}
proc connected_net {pin} {
    set nets [get_nets -quiet -of_objects [get_pins -quiet $pin]]
    if {[llength $nets] != 1} {error "Expected one net: $pin -> $nets"}
    return [get_property NAME $nets]
}
set checked 0
foreach target $targets {
    set prefix [file dirname [file dirname $target]]
    puts $output "\nRESET_ENTRY $target"
    set reference_clock ""
    set preset [connected_net $target]
    if {[llength [get_cells -quiet ${prefix}/arststages_ff_reg*]] != 4} {
        error "Expected exactly four reset stages: $prefix"
    }
    for {set bit 0} {$bit < 4} {incr bit} {
        set name [format {%s/arststages_ff_reg[%d]} $prefix $bit]
        set cell [get_cells -quiet $name]
        if {[llength $cell] != 1} {error "Missing reset stage $name"}
        set ref [get_property REF_NAME $cell]
        set async [get_property ASYNC_REG $cell]
        puts $output "STAGE $bit $name REF=$ref ASYNC_REG=$async"
        if {$ref ne "FDPE" || ![string is boolean -strict $async] || !$async} {
            error "Unexpected reset primitive/attribute: $name $ref $async"
        }
        set clk [connected_net $name/C]
        if {$bit == 0} {set reference_clock $clk}
        if {$clk ne $reference_clock || [connected_net $name/PRE] ne $preset} {
            error "Reset stages do not share clock/preset: $name"
        }
        set ce_drivers [get_cells -quiet -of_objects [get_pins -quiet -of_objects [get_nets [connected_net $name/CE]] -filter {DIRECTION == OUT}]]
        if {[llength $ce_drivers] != 1 || [get_property REF_NAME $ce_drivers] ne "VCC"} {
            error "Reset release stage CE is not constant enabled: $name"
        }
        set dnet [connected_net $name/D]
        if {$bit > 0} {
            set previous [format {%s/arststages_ff_reg[%d]/Q} $prefix [expr {$bit-1}]]
            if {$dnet ne [connected_net $previous]} {error "Reset release chain has intervening logic: $name"}
        }
        set drivers [get_pins -quiet -of_objects [get_nets $dnet] -filter {DIRECTION == OUT}]
        if {$bit == 0} {
            set owners [get_cells -quiet -of_objects $drivers]
            if {[llength $owners] != 1 || [get_property REF_NAME $owners] ne "GND"} {
                error "Active-high reset stage0 D is not constant zero: $name"
            }
        }
        foreach driver $drivers {
            set owner [get_cells -quiet -of_objects $driver]
            puts $output "D_DRIVER $bit $driver REF=[get_property REF_NAME $owner]"
        }
    }
    puts $output "COMMON_CLOCK $reference_clock"
    puts $output "COMMON_PRESET $preset"
    set cone [all_fanin -flat -only_cells -to [get_pins $target]]
    puts $output "ASSERT_CONE_CELLS [llength $cone]"
    foreach cell $cone {
        set ref [get_property REF_NAME $cell]
        if {[string match LUT* $ref]} {
            puts $output "ASSERT_LUT $cell REF=$ref INIT=[get_property INIT $cell]"
        }
    }
    set starts [all_fanin -flat -startpoints_only -to [get_pins $target]]
    foreach start $starts {puts $output "ASSERT_START $start"}
    incr checked
}
puts $output "\nSTRUCTURAL_CHAINS_CHECKED $checked"
puts $output "NOT_SIGNOFF: assertion-source semantics, pulse widths, FIFO reset ownership and source simulations still require review"
close $output
puts "SC7F0_RESET_CHAIN_INSPECTION_COMPLETE $checked unique four-stage chains; not signoff"
close_design
exit 0
