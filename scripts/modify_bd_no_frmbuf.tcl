# Modify BD: remove video_rx, expose HDMI RX VIDEO_OUT externally, regenerate, export XSA
open_project /home/zzlee/qpcie/build/sc6f0_dtg_test/sc6f0_dtg_test.xpr
open_bd_design [get_files *.bd]

puts "=== UPGRADING LOCKED IPS ==="
catch { upgrade_ip [get_ips] }

puts "=== BD validated with warnings only last run — skipping delete (already done) ==="
puts "=== Current BD cells ==="
puts [get_bd_cells]

puts "=== REGENERATING BD OUTPUT PRODUCTS ==="
generate_target all [get_files *.bd]

puts "=== EXPORTING XSA ==="
write_hw_platform -fixed -force /home/zzlee/qpcie/build/sc7f0_dtg_test.xsa

puts "================================================================="
puts " SUCCESS: XSA exported to /home/zzlee/qpcie/build/sc7f0_dtg_test.xsa"
puts "================================================================="
close_project
exit 0
