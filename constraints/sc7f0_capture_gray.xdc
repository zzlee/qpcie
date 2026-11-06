# Source-registered 150 MHz Gray timestamp to RX/CSR stage0 only.
# XDC deliberately contains no if/foreach: Vivado ignores those commands here.
# Exact 64+64 endpoint and effective 6 ns checks run in the implementation hook.
# 6 ns is below the source period (6.666 ns); no blanket clock-group false path.
set capture_gray_src [get_cells -hier -regexp {.*u_ps_capture/u_tap/gray_q_reg\[[0-9]+\]}]
set capture_gray_rx [get_cells -hier -regexp {.*u_ps_capture/u_tap/u_source_time/stage0_reg\[[0-9]+\]}]
set capture_gray_csr [get_cells -hier -regexp {.*u_ps_capture/u_regs/u_time/stage0_reg\[[0-9]+\]}]
set_max_delay -datapath_only 6.000 -from $capture_gray_src -to $capture_gray_rx
set_bus_skew 6.000 -from $capture_gray_src -to $capture_gray_rx
set_max_delay -datapath_only 6.000 -from $capture_gray_src -to $capture_gray_csr
set_bus_skew 6.000 -from $capture_gray_src -to $capture_gray_csr
