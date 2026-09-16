# build_zu4ev_example.tcl - Run Synthesis, Implementation, and Bitstream generation for ZU4EV PIO Example
set xpr_path "./build/zu4ev_example_proj/pcie4_zu4ev_ex/pcie4_zu4ev_ex.xpr"

if {![file exists $xpr_path]} {
    puts "Error: Project $xpr_path does not exist. Run scripts/generate_zu4ev_example.tcl first."
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

puts "Implementation and bitstream generation completed successfully!"
open_run impl_1
puts "Checking timing summary..."
report_timing_summary -file ./build/zu4ev_example_proj/timing_summary.rpt
puts "ZU4EV Example bitstream located at: [get_property DIRECTORY [get_runs impl_1]]/xilinx_pcie4_uscale_ep.bit"
close_project
exit 0
