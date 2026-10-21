set project_dir ./build/qpcie_zu4ev_hdmi_proj
open_project $project_dir/qpcie_zu4ev_card.xpr
open_bd_design [get_files zu4ev_ps_bd.bd]
set hrst [get_bd_cells hdmi_control_reset]
set_property -dict [list CONFIG.C_EXT_RESET_HIGH {0} CONFIG.C_AUX_RESET_HIGH {1}] $hrst
validate_bd_design
save_bd_design
generate_target all [get_files zu4ev_ps_bd.bd]
close_project
exit 0
