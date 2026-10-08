hsi::open_hw_design /home/zzlee/qpcie/hw_platform/sc7f0_base.xsa
hsi::set_repo_path /opt/Xilinx/Vitis/2023.2/data/system-device-tree-xlnx
hsi::create_sw_design dt_design -os device_tree -proc psu_cortexa53_0
hsi::generate_target -dir /home/zzlee/qpcie/build/dts_from_xsa
puts "=== DT GENERATED SUCCESSFULLY ==="
exit 0
