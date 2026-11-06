# Update zu4ev_ps_bd in build/dual-video-26110301-vcu-r1 and re-export hardware.xsa
set root [file normalize [file join [file dirname [info script]] ..]]
cd $root

set prj "$root/build/dual-video-26110301-vcu-r1/qpcie_zu4ev_card.xpr"
open_project $prj

open_bd_design [get_files zu4ev_ps_bd.bd]

set ps [get_bd_cells zynq_ultra_ps_e_0]

set_property -dict [list \
  CONFIG.PSU__ENET0__FIFO__ENABLE {0} \
  CONFIG.PSU__ENET0__GRP_MDIO__ENABLE {0} \
  CONFIG.PSU__ENET0__PERIPHERAL__ENABLE {0} \
  CONFIG.PSU_MIO_TREE_PERIPHERALS {#############SD 0#SD 0#SD 0#SD 0#SD 0#SD 0#SD 0#SD 0#SD 0#SD 0#SD 0###############UART 0#UART 0#I2C 1#I2C 1####SD 1#SD 1#SD 1#SD 1#SD 1#SD 1#SD 1#USB 0#USB 0#USB 0#USB 0#USB 0#USB 0#USB 0#USB 0#USB 0#USB 0#USB 0#USB 0#USB 1#USB 1#USB 1#USB 1#USB 1#USB 1#USB 1#USB 1#USB 1#USB 1#USB 1#USB 1##} \
  CONFIG.PSU_MIO_TREE_SIGNALS {#############sdio0_data_out[0]#sdio0_data_out[1]#sdio0_data_out[2]#sdio0_data_out[3]#sdio0_data_out[4]#sdio0_data_out[5]#sdio0_data_out[6]#sdio0_data_out[7]#sdio0_cmd_out#sdio0_clk_out#sdio0_bus_pow###############rxd#txd#scl_out#sda_out####sdio1_cd_n#sdio1_data_out[0]#sdio1_data_out[1]#sdio1_data_out[2]#sdio1_data_out[3]#sdio1_cmd_out#sdio1_clk_out#ulpi_clk_in#ulpi_dir#ulpi_tx_data[2]#ulpi_nxt#ulpi_tx_data[0]#ulpi_tx_data[1]#ulpi_stp#ulpi_tx_data[3]#ulpi_tx_data[4]#ulpi_tx_data[5]#ulpi_tx_data[6]#ulpi_tx_data[7]#ulpi_clk_in#ulpi_dir#ulpi_tx_data[2]#ulpi_nxt#ulpi_tx_data[0]#ulpi_tx_data[1]#ulpi_stp#ulpi_tx_data[3]#ulpi_tx_data[4]#ulpi_tx_data[5]#ulpi_tx_data[6]#ulpi_tx_data[7]##} \
] $ps

# Update protection registers
set prot_masters [get_property CONFIG.PSU__PROTECTION__MASTERS $ps]
regsub {GEM0:NonSecure;1} $prot_masters {GEM0:NonSecure;0} prot_masters
set prot_slaves [get_property CONFIG.PSU__PROTECTION__SLAVES $ps]
regsub {LPD;GEM0;FF0B0000;FF0BFFFF;1} $prot_slaves {LPD;GEM0;FF0B0000;FF0BFFFF;0} prot_slaves

set_property -dict [list \
  CONFIG.PSU__PROTECTION__MASTERS $prot_masters \
  CONFIG.PSU__PROTECTION__SLAVES $prot_slaves \
] $ps

validate_bd_design
save_bd_design

generate_target all [get_files zu4ev_ps_bd.bd]

# Re-export hardware.xsa
set out_xsa "$root/build/dual-video-26110301-vcu-r1/hardware.xsa"
write_hw_platform -fixed -include_bit -force $out_xsa

puts "SUCCESS: Re-exported $out_xsa"
