# Functional test of actual official IP, reusing separately generated probe IPs.
set root [file normalize [file join [file dirname [info script]] ..]]
cd $root
foreach name {SC7F0_OFFICIAL_SIM_OUT SC7F0_FRMBUF_XCI SC7F0_CSC_XCI} {
    if {![info exists ::env($name)]} {error "Set $name"}
}
set out [file normalize $::env(SC7F0_OFFICIAL_SIM_OUT)]
if {[file exists $out]} {error "Refusing to overwrite simulation project $out"}
create_project official_capture_sim $out -part xczu4ev-fbvb900-2-e
read_ip $::env(SC7F0_FRMBUF_XCI)
read_ip $::env(SC7F0_CSC_XCI)
add_files -fileset sim_1 tb/sc7f0_official_capture_tb.sv
set_property top sc7f0_official_capture_tb [get_filesets sim_1]
update_compile_order -fileset sim_1
launch_simulation
run all
if {[get_value -radix unsigned /sc7f0_official_capture_tb/test_pass] ne "1"} {
    error "Official capture simulation failed; PASS not reached"
}
puts "OFFICIAL_CAPTURE_SIM_GATE_PASS"
exit
