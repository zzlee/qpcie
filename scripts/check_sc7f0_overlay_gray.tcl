# =============================================================================
# scripts/check_sc7f0_overlay_gray.tcl
#
# Routed re-check of constraints/sc7f0_overlay_gray.xdc: the three 32-bit Gray
# status counters of the SC7F0-RGB overlay writer
# (rtl/sc7f0_overlay_writer.v: u_frames, u_beats, u_errf; mem_clk 300 MHz ->
# pcie_user_clk 125 MHz).
#
# It is sourced by scripts/build_zu4ev.tcl from
# scripts/report_sc7f0_implementation_evidence.tcl's report stage, i.e. AFTER
# open_run impl_1, on the implemented design of THIS round.  It is not a pre-route
# promise: every number below is measured on the implemented netlist, and an absent,
# partial or overridden exception is an error, never a pass.
#
# Why these crossings need a named exception, and why this check sits next to the
# vendor's own, is written out in the header of the XDC file.  In one line: the
# vendor's scoped constraint sizes itself from a clock on a PORT of the IP instance,
# which a manually instantiated XPM does not have, so it falls back to 1000 ns, far
# looser than the 3.333 ns source period it is supposed to bound.
#
# Nothing here re-checks what constraints/sc7f0_capture_gray.xdc covers: that file
# names u_ps_capture/u_tap only and cannot be claimed for the writer, and this file
# does not touch it either.
# =============================================================================
set ovw_gray_period 3.333
set ovw_gray_checked 0

foreach ovw_name {u_frames u_beats u_errf} {
    set ovw_pat_src [format {.*u_overlay_writer/%s/src_gray_ff_reg\[[0-9]+\]} $ovw_name]
    set ovw_pat_dst [format {.*u_overlay_writer/%s/dest_graysync_ff_reg\[0\]\[[0-9]+\]} $ovw_name]
    set ovw_src [get_cells -hier -regexp $ovw_pat_src]
    set ovw_dst [get_cells -hier -regexp $ovw_pat_dst]
    if {[llength $ovw_src] != 32} {
        error "SC7F0_OVERLAY_GRAY_MISSING u_overlay_writer/$ovw_name: expected exactly 32 Gray source FFs, found [llength $ovw_src]. Either the RGB overlay writer is not in this build (then constraints/sc7f0_overlay_gray.xdc must not be mounted) or the crossing structure changed."
    }
    if {[llength $ovw_dst] != 32} {
        error "SC7F0_OVERLAY_GRAY_MISSING u_overlay_writer/$ovw_name: expected exactly 32 first-stage destination FFs, found [llength $ovw_dst]"
    }
    set ovw_paths [get_timing_paths -from $ovw_src -to $ovw_dst \
        -delay_type max -max_paths 32 -nworst 1]
    if {[llength $ovw_paths] != 32} {
        error "SC7F0_OVERLAY_GRAY_NOT_TIMED u_overlay_writer/$ovw_name: [llength $ovw_paths] of 32 Gray endpoints are timed. A crossing that reports no path is either falsely excepted or not connected, and neither may be graded as safe."
    }
    set ovw_bits {}
    foreach ovw_path $ovw_paths {
        set ovw_start [get_property STARTPOINT_PIN $ovw_path]
        set ovw_end   [get_property ENDPOINT_PIN   $ovw_path]
        # Vivado names the launching FF's clock pin as STARTPOINT_PIN.
        if {![regexp {src_gray_ff_reg\[([0-9]+)\]/C$} $ovw_start ovw_u1 ovw_sbit] ||
              ![regexp {dest_graysync_ff_reg\[0\]\[([0-9]+)\]/D$} $ovw_end ovw_u2 ovw_dbit] ||
              $ovw_sbit != $ovw_dbit} {
            error "SC7F0_OVERLAY_GRAY_MAPPING u_overlay_writer/$ovw_name: Gray bit mapping is not direct: $ovw_start -> $ovw_end"
        }
        if {[get_property LOGIC_LEVELS $ovw_path] != 0} {
            error "SC7F0_OVERLAY_GRAY_LOGIC u_overlay_writer/$ovw_name: combinational logic in a Gray sampling path: $ovw_start -> $ovw_end"
        }
        set ovw_req [get_property REQUIREMENT $ovw_path]
        if {$ovw_req eq "" ||
            [expr {abs(double($ovw_req) - $ovw_gray_period) > 0.001}]} {
            error "SC7F0_OVERLAY_GRAY_NOT_EFFECTIVE u_overlay_writer/$ovw_name: the max-delay in force at $ovw_end is '$ovw_req', expected $ovw_gray_period ns. A looser exception (the vendor fallback, or a clock-group false path) silently winning here is exactly what this check exists to catch."
        }
        lappend ovw_bits $ovw_dbit
    }
    if {[llength [lsort -unique $ovw_bits]] != 32} {
        error "SC7F0_OVERLAY_GRAY_DUPLICATE u_overlay_writer/$ovw_name: 32 timed endpoints do not cover 32 distinct bits"
    }
    incr ovw_gray_checked 32
    puts "SC7F0_OVERLAY_GRAY_ENDPOINTS_PASS $ovw_name: 32 direct bits, effective max-delay $ovw_gray_period ns"
}

# The bus-skew half.  report_bus_skew has no -from/-to in 2023.2 (verified with
# `help report_bus_skew`, and the reason scripts/check_sc7f0_named_constraints.tcl
# resolves a row by the constraint's own declaration), so this row is located in the
# project-wide report by the cells it names.  No row means the constraint was never
# measured, which is an error and not a clean result.
set ovw_skew [report_bus_skew -return_string]
set ovw_rows 0
foreach ovw_line [split $ovw_skew "\n"] {
    if {[string match "*u_overlay_writer*" $ovw_line]} {
        incr ovw_rows
        if {[string match "*VIOLATED*" $ovw_line]} {
            error "SC7F0_OVERLAY_GRAY_SKEW_VIOLATED: $ovw_line"
        }
    }
}
if {$ovw_rows == 0} {
    error "SC7F0_OVERLAY_GRAY_SKEW_UNMEASURED: report_bus_skew produced no row naming u_overlay_writer, so the set_bus_skew of constraints/sc7f0_overlay_gray.xdc was not measured on this design"
}
puts "SC7F0_OVERLAY_GRAY_CHECK_PASS endpoints=$ovw_gray_checked bus_skew_rows=$ovw_rows"
