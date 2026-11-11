# R7 scoped acceptance. Preserves the original debug-profile rejection and
# exports an XSA only after the R7 full-profile gate passes before and after.
if {$argc != 4} {error "candidate evidence safety NEW_ACCEPTANCE_DIR"}
set root [file normalize [file join [file dirname [info script]] ..]]
cd $root
lassign $argv candidate evidence safety out
foreach var {candidate evidence safety out} {set $var [file normalize [set $var]]}
if {[file exists $out]} {error "Refusing existing acceptance directory $out"}
file mkdir $out
set command [list python3 scripts/check_sc7f0_r7_profile.py $candidate --evidence $evidence \
    --safety $safety \
    --baseline-cdc /home/zzlee/qpcie/build/sc7f0-audio-doorbell-26102702-r1/fpga/cdc.rpt \
    --baseline-ip /home/zzlee/qpcie/build/qpcie_zu4ev_hdmi_proj/qpcie_zu4ev_card.srcs/sources_1/ip]
if {[catch {exec {*}$command > $out/full-profile-review.json} reason]} {
    error "R7 scoped full-profile rejection; no XSA: $reason"
}
open_project $candidate/qpcie_zu4ev_card.xpr
set generic [get_property GENERIC [get_filesets sources_1]]
if {[lsearch -exact $generic "C_VERSION=32'h26102901"] < 0} {error "Not the frozen R7 generic: $generic"}
set defines [get_property VERILOG_DEFINE [get_filesets sources_1]]
if {[lsearch -exact $defines SC7F0_C2H_ONLY=1] < 0} {error "Not the C2H production personality: $defines"}
open_run impl_1
write_hw_platform -fixed -include_bit -force $out/hardware.xsa
# Recheck all live/snapshot inputs after project open and export.
exec {*}$command > $out/full-profile-review-after-export.json
set f [open $out/export.complete w]
puts $f "R7 scoped full-profile export complete. Original debug gate remains rejected."
puts $f "Matching kernel/rootfs/package and real-card acceptance are still required."
close $f
puts "SC7F0_REVIEWED_R7_XSA_EXPORTED $out"
