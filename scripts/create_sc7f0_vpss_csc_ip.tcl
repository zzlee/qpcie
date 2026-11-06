# Official CSC-only VPSS with RGB/YUV444/422/420 support; no scaler/VCU.
proc create_sc7f0_vpss_csc_ip {} {
    create_ip -name v_proc_ss -vendor xilinx.com -library ip -version 2.3 \
        -module_name sc7f0_vpss_csc
    set_property -dict [list \
        CONFIG.C_TOPOLOGY {3} \
        CONFIG.C_SAMPLES_PER_CLK {4} \
        CONFIG.C_MAX_COLS {4096} CONFIG.C_MAX_ROWS {2160} \
        CONFIG.C_MAX_DATA_WIDTH {8} \
        CONFIG.C_COLORSPACE_SUPPORT {0} \
    ] [get_ips sc7f0_vpss_csc]
    generate_target all [get_ips sc7f0_vpss_csc]
}
