# Full Tcl: executed after XDC import, before opt_design and after route.
# Reject absent/partially covered or overridden Gray constraints.
set capture_gray_source [get_cells -hier -regexp {.*u_ps_capture/u_tap/gray_q_reg\[[0-9]+\]}]
if {[llength $capture_gray_source] != 64} {error "Expected exactly 64 Gray source FFs"}
foreach tail {u_tap/u_source_time u_regs/u_time} {
    set expression [format {.*u_ps_capture/%s/stage0_reg\[[0-9]+\]} $tail]
    set dest [get_cells -hier -regexp $expression]
    if {[llength $dest] != 64} {error "Expected 64 Gray stage0 FFs: $tail"}
    set paths [get_timing_paths -from $capture_gray_source -to $dest -delay_type max -max_paths 64 -nworst 1]
    if {[llength $paths] != 64} {error "Missing timed Gray endpoints: $tail"}
    set bits {}
    foreach path $paths {
        set start [get_property STARTPOINT_PIN $path]
        set end [get_property ENDPOINT_PIN $path]
        # Vivado timing-path STARTPOINT_PIN names the launching FF clock pin.
        if {![regexp {gray_q_reg\[([0-9]+)\]/C$} $start unused sbit] ||
            ![regexp {stage0_reg\[([0-9]+)\]/D$} $end unused dbit] || $sbit != $dbit} {
            error "Gray bit mapping is not direct: $start -> $end"
        }
        if {[get_property LOGIC_LEVELS $path] != 0} {
            error "Combinational logic in Gray sampling path: $start -> $end"
        }
        if {abs([get_property REQUIREMENT $path] - 6.000) > 0.001} {
            error "Gray max-delay not effective at $end: [get_property REQUIREMENT $path]"
        }
        lappend bits $dbit
    }
    if {[llength [lsort -unique $bits]] != 64} {error "Duplicate Gray endpoints: $tail"}
    puts "SC7F0_GRAY_ENDPOINTS_PASS $tail: 64 direct bits, effective max-delay 6.000 ns"
}
puts "SC7F0_CAPTURE_GRAY_CONSTRAINTS_PASS"
