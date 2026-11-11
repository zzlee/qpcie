# Standalone 4PPC vendor-recommended 256-bit framebuffer + PS128 converter.
if {$argc != 1} {error "NEW_DIRECTORY"}
set root [file normalize [file join [file dirname [info script]] ..]]
cd $root
set out [file normalize [lindex $argv 0]]
if {[file exists $out]} {error "Refusing existing width probe"}
create_project capture_width_probe $out -part xczu4ev-fbvb900-2-e
source scripts/create_sc7f0_frmbuf_ip.tcl
create_sc7f0_frmbuf_ip
set_property CONFIG.AXIMM_DATA_WIDTH 256 [get_ips sc7f0_frmbuf_wr]
generate_target all [get_ips sc7f0_frmbuf_wr]
# The production IP creator now includes the 256-to-128 converter.
puts "CAPTURE_WIDTH_PROBE_GENERATED: FB256 to PS128, not integrated/released hardware"
exit
