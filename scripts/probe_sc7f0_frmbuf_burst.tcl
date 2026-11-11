# Standalone official-IP performance configuration, not a card build.
if {$argc != 2} {error "NEW_DIRECTORY BURST_LENGTH"}
set root [file normalize [file join [file dirname [info script]] ..]]
cd $root
lassign $argv out burst
set out [file normalize $out]
if {[file exists $out]} {error "Refusing existing probe"}
create_project frmbuf_burst_probe $out -part xczu4ev-fbvb900-2-e
source scripts/create_sc7f0_frmbuf_ip.tcl
create_sc7f0_frmbuf_ip
set_property CONFIG.AXIMM_BURST_LENGTH $burst [get_ips sc7f0_frmbuf_wr]
generate_target all [get_ips sc7f0_frmbuf_wr]
puts "FRMBUF_BURST_PROBE_GENERATED $burst; no full-card acceptance"
exit
