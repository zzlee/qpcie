source [file join [file dirname [info script]] .. scripts a50t_timing_gate.tcl]
set good "  0.067 0.000 0 77947 0.032 0.000 0 77947 0.250 0.000 0 29331"
set result [a50t_validate_timing_summary $good]
if {[dict get $result WNS] != 0.067 || [dict get $result WPWS] != 0.250} {
    error "Incorrect timing summary decode"
}
foreach bad [list \
    "0.067 0.000 0 77947 0.032 0.000 0 77947 -2.000 -2.000 1 29331" \
    "-0.001 -0.001 1 77947 0.032 0.000 0 77947 0.250 0.000 0 29331" \
    "0.067 0.000 0 77947 -0.001 -0.001 1 77947 0.250 0.000 0 29331" \
    "missing report"] {
    if {![catch {a50t_validate_timing_summary $bad}]} {
        error "Invalid timing was accepted: $bad"
    }
}
puts "TB_PASS: timing gate rejects ICAP pulse-width, setup, hold and missing-report failures"
