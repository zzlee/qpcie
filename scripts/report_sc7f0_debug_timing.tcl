# Read-only design review after build_zu4ev.tcl. Does not waive CDC paths or
# change constraints. Positive mailbox paths do NOT imply whole-design closure.
open_project ./build/qpcie_zu4ev_proj/qpcie_zu4ev_card.xpr
open_run impl_1
set out ./build/debug-channel
file mkdir $out
set regs [filter [all_registers] {NAME =~ *u_debug_mailbox*}]
if {[llength $regs] == 0} { error "No debug mailbox registers in this implementation" }
puts "DEBUG_REGISTER_COUNT=[llength $regs]"
report_timing -from $regs -max_paths 20 -file $out/mailbox-from.rpt
report_timing -to $regs -max_paths 20 -file $out/mailbox-to.rpt
report_timing -from $regs -delay_type min -max_paths 20 -file $out/mailbox-hold-from.rpt
report_timing -to $regs -delay_type min -max_paths 20 -file $out/mailbox-hold-to.rpt
report_clock_interaction -file $out/clock-interaction.rpt
report_cdc -details -file $out/cdc.rpt
exit
