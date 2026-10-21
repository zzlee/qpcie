# ==============================================================================
# Build SC7F0 HDMI 07 with Hardware Probing Registers (C_VERSION=32'h26102007)
# ==============================================================================

set project_dir ./build/qpcie_zu4ev_hdmi_proj
open_project $project_dir/qpcie_zu4ev_card.xpr

puts "=== Step 1: Adding sc7f0_hdmi_probe.v to sources ==="
if {[get_files -quiet */rtl/sc7f0_hdmi_probe.v] eq ""} {
    add_files -norecurse ./rtl/sc7f0_hdmi_probe.v
}

puts "=== Step 2: Setting C_VERSION=32'h26102007 ==="
set_property generic {C_VERSION=32'h26102007} [current_fileset]

update_compile_order -fileset sources_1

puts "=== Step 3: Resetting top-level synthesis run ==="
reset_runs synth_1

puts "=== Step 4: Launching synthesis with 16 jobs ==="
launch_runs synth_1 -jobs 16
wait_on_run synth_1

if {[get_property PROGRESS [get_runs synth_1]] != "100%" || [string first "ERROR" [get_property STATUS [get_runs synth_1]]] >= 0} {
    error "Synthesis failed! See synth_1 run log."
}
puts "SYNTHESIS_PASS: C_VERSION 0x26102007"

puts "=== Step 5: Launching implementation & bitstream generation with 16 jobs ==="
reset_runs impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 16
wait_on_run impl_1

set impl_status [get_property STATUS [get_runs impl_1]]
if {[get_property PROGRESS [get_runs impl_1]] != "100%" || [string first "ERROR" $impl_status] >= 0 || [string first "write_bitstream Complete" $impl_status] < 0} {
    puts "ERROR: Implementation or write_bitstream failed: $impl_status"
    error "Implementation/bitstream failed!"
}
puts "BITSTREAM_SUCCESS: C_VERSION 0x26102007 generated"

open_run impl_1
set impl_dir [get_property DIRECTORY [get_runs impl_1]]
foreach f [glob -nocomplain "$impl_dir/*.bit"] {
    puts " Bitstream: $f ([file size $f] bytes)"
}

puts "=== Step 6: Generating reports ==="
report_timing_summary -delay_type min_max -report_unconstrained -file $project_dir/timing_summary.rpt
check_timing -verbose -file $project_dir/check-timing.rpt
report_cdc -details -file $project_dir/cdc.rpt

puts "=== Step 7: Exporting Hardware Platform XSA ==="
set xsa_out "./hw_platform/sc7f0_hdmi.xsa"
file mkdir [file dirname $xsa_out]
write_hw_platform -fixed -include_bit -force $xsa_out
puts "XSA_SUCCESS: Exported $xsa_out"

file copy -force $xsa_out "./hw_platform/sc7f0-hdmi07.xsa"
puts "XSA_COPIED: ./hw_platform/sc7f0-hdmi07.xsa"

close_project
puts "ALL_DONE_HDMI07"
exit 0
