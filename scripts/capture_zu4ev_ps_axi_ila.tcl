# Run from the qpcie repository root while the masked diagnostic image is
# running and before issuing a single PS devmem read over UART.
# This script only observes JTAG/ILA: it neither programs nor resets the FPGA.
set probes_file [file normalize ./build/qpcie_zu4ev_proj/qpcie_zu4ev_card.runs/impl_1/zu4ev_pcie_card_top.ltx]
set csv_file [file normalize ./build/zu4ev_ps_axi_capture.csv]
if {![file exists $probes_file]} {error "No probe file: $probes_file"}

open_hw_manager
connect_hw_server -url localhost:3121
set target [lindex [get_hw_targets] 0]
if {$target eq ""} {error "No JTAG target"}
open_hw_target $target
set device [lindex [get_hw_devices xczu4_0] 0]
if {$device eq ""} {error "No xczu4 JTAG device"}
set_property PROBES.FILE $probes_file $device
refresh_hw_device $device
set ila [lindex [get_hw_ilas -of_objects $device] 0]
if {$ila eq ""} {error "ILA not found; confirm BOOT.BIN is 0807 and PL clock is active"}
puts "ILA: $ila"
puts "PROBES: [get_hw_probes -of_objects $ila]"
set trigger_probe [lindex [get_hw_probes -of_objects $ila -filter {NAME =~ *s_axil_ps_arvalid*}] 0]
if {$trigger_probe eq ""} {error "No PS ARVALID trigger found in the loaded LTX"}
set_property TRIGGER_COMPARE_VALUE {eq1'b1} $trigger_probe
run_hw_ila $ila
puts "ARMED: issue exactly one UART command: devmem 0xA0000000 32"
flush stdout
wait_on_hw_ila $ila
set data [upload_hw_ila_data $ila]
write_hw_ila_data -force -csv_file $csv_file $data
puts "CAPTURED: $csv_file"
close_hw_target $target
close_hw_manager
