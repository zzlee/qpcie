open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target
set dev [lindex [get_hw_devices xc7a50t_0] 0]
if {$dev == ""} {
    set dev [lindex [get_hw_devices] 0]
}
current_hw_device $dev
refresh_hw_device $dev
puts "Triggering boot_hw_device..."
boot_hw_device $dev
puts "boot_hw_device triggered successfully!"
close_hw_target
disconnect_hw_server
close_hw_manager
