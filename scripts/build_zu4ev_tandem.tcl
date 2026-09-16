# build_zu4ev_tandem.tcl - Run Synthesis, Implementation, and Tandem Bitstream generation
set xpr_path "./build/zu4ev_tandem_proj/pcie4_tandem_ex/pcie4_tandem_ex.xpr"

if {![file exists $xpr_path]} {
    puts "Error: Project $xpr_path does not exist."
    exit 1
}

open_project $xpr_path

puts "Resetting previous runs..."
reset_run synth_1
reset_run impl_1

puts "Launching synthesis..."
launch_runs synth_1 -jobs 4
wait_on_run synth_1

if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    puts "ERROR: Synthesis failed!"
    exit 1
}
puts "Synthesis completed successfully."

puts "Launching implementation & bitstream generation..."
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1

if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    puts "ERROR: Implementation failed!"
    exit 1
}

puts "Tandem Implementation and bitstream generation completed successfully!"
open_run impl_1
puts "Checking timing summary..."
report_timing_summary -file ./build/zu4ev_tandem_proj/timing_summary.rpt

set impl_dir [get_property DIRECTORY [get_runs impl_1]]
puts "Generated bitstreams in $impl_dir:"
foreach f [glob -nocomplain "$impl_dir/*.bit"] {
    set size [file size $f]
    puts "  [file tail $f] : $size bytes"
}

close_project
exit 0
