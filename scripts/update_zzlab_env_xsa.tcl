open_project /home/zzlee/qpcie/build/sc6f0_dtg_test/sc6f0_dtg_test.xpr
open_bd_design [get_files *.bd]

puts "=== RESETTING BD TARGETS ==="
catch { reset_target all [get_files *.bd] }

puts "=== REGENERATING BD TARGETS ==="
generate_target all [get_files *.bd]

puts "=== EXPORTING UPDATED XSA ==="
write_hw_platform -fixed -force /home/zzlee/qpcie/build/sc7f0_dtg_test.xsa

puts "================================================================="
puts " SUCCESS: Updated XSA exported to /home/zzlee/qpcie/build/sc7f0_dtg_test.xsa"
puts "================================================================="
close_project
exit 0
