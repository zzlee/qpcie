open_project build/qpcie_zu4ev_proj/qpcie_zu4ev_card.xpr
open_run impl_1
write_hw_platform -fixed -include_bit -force ./hw_platform/sc7f0_base.xsa
puts "=== XSA EXPORTED SUCCESSFULLY ==="
close_project
exit 0
