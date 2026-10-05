# ==============================================================================
# Run Implementation & Tandem Bitstream Generation for ZU4EV SC7F0
# ==============================================================================

open_project ./build/qpcie_zu4ev_proj/qpcie_zu4ev_card.xpr

reset_run impl_1
set_property STEPS.OPT_DESIGN.TCL.PRE "" [get_runs impl_1]
set_property STEPS.PLACE_DESIGN.TCL.PRE "" [get_runs impl_1]

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

report_timing_summary -file ./build/qpcie_zu4ev_proj/timing_summary.rpt
close_project
exit 0
