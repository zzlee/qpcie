# Read-only CDC inventory. Run from repository root after build_zu4ev.tcl.
# Optional arguments: routed checkpoint, output directory.
set dcp ./build/qpcie_zu4ev_proj/qpcie_zu4ev_card.runs/impl_1/zu4ev_pcie_card_top_routed.dcp
set out ./build/cdc-timing/baseline
if {$argc > 0} { set dcp [lindex $argv 0] }
if {$argc > 1} { set out [lindex $argv 1] }
file mkdir $out
open_checkpoint $dcp
check_timing -verbose -file $out/check-timing.rpt
report_clocks -file $out/clocks.rpt
report_clock_interaction -file $out/clock-interaction.rpt
set fh [open $out/crossings.tsv w]
puts $fh "source_clock\tdestination_clock\tslack_ns\tstartpoint\tendpoint"
foreach pair {{clk_pl_0 pcie_user_clk} {pcie_user_clk clk_pl_0}} {
    lassign $pair src dst
    set paths [get_timing_paths -from [get_clocks $src] -to [get_clocks $dst] -max_paths 30000 -nworst 1]
    puts "INVENTORY $src -> $dst: [llength $paths] endpoints"
    foreach path $paths {
        puts $fh "$src\t$dst\t[get_property SLACK $path]\t[get_property STARTPOINT_PIN $path]\t[get_property ENDPOINT_PIN $path]"
    }
    report_timing -from [get_clocks $src] -to [get_clocks $dst] -max_paths 20 -file $out/${src}-to-${dst}.rpt
}
close $fh
exit
