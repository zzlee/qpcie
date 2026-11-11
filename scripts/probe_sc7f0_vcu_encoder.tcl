# Encoder-only VCU configuration/interface probe, not integrated card hardware.
if {$argc != 1} {error "NEW_OUTPUT_DIRECTORY"}
set out [file normalize [lindex $argv 0]]
if {[file exists $out]} {error "Refusing existing VCU probe"}
create_project vcu_encoder_probe $out -part xczu4ev-fbvb900-2-e
create_ip -name vcu -vendor xilinx.com -library ip -version 1.2 -module_name sc7f0_vcu
set_property -dict [list CONFIG.ENABLE_ENCODER {true} CONFIG.ENABLE_DECODER {false}] [get_ips sc7f0_vcu]
generate_target all [get_ips sc7f0_vcu]
report_ip_status -file $out/ip-status.rpt
set fp [open $out/config.rpt w]
foreach key {ENABLE_ENCODER ENABLE_DECODER PLL_BYPASS PLL_CLK CORE_CLK MCU_CLK ENC_CLK AXI_ENC_CLK AXI_MCU_CLK ENC_FRAME_SIZE ENC_FPS} {
    puts $fp "$key=[get_property CONFIG.$key [get_ips sc7f0_vcu]]"
}
close $fp
puts "VCU_ENCODER_INTERFACE_PROBE_GENERATED: no card instance/DT/runtime/zero-copy claim"
exit
