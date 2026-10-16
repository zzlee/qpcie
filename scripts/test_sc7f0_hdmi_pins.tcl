# Pure Tcl schematic pin-map regression. Mock XDC APIs; no Vivado required.
array set pins {}
proc get_ports {name} {return $name}
proc get_cells {args} {return {}}
proc get_clocks {args} {return {}}
proc create_clock {args} {}
proc set_false_path {args} {}
proc set_property {key value ports} {
    if {$key eq "PACKAGE_PIN"} {set ::pins($ports) $value}
}
source ./constraints/zu4ev_pcie_pinout.xdc
foreach {port expected} {
    hdmi_rx_clk_p B10 hdmi_rx_clk_n B9
    hdmi_dru_clk_p F10 hdmi_dru_clk_n F9
    hdmi_tx_clk_p D10 hdmi_tx_clk_n D9
    hdmi_tx_tmds_clk_p AH6 hdmi_tx_tmds_clk_n AJ6
    hdmi_rx_hpd_out B12 hdmi_rx_5v_det A12
    hdmi_rx_ddc_scl D14 hdmi_rx_ddc_sda C13
    hdmi_tx_hpd_in G14 hdmi_tx_refclk_rdy G13
    hdmi_tx_ddc_scl F12 hdmi_tx_ddc_sda E12
    {hdmi_rx_p[0]} D2 {hdmi_rx_n[0]} D1
    {hdmi_rx_p[1]} C4 {hdmi_rx_n[1]} C3
    {hdmi_rx_p[2]} B2 {hdmi_rx_n[2]} B1
    {hdmi_tx_p[0]} D6 {hdmi_tx_n[0]} D5
    {hdmi_tx_p[1]} C8 {hdmi_tx_n[1]} C7
    {hdmi_tx_p[2]} B6 {hdmi_tx_n[2]} B5
} {
    if {![info exists pins($port)] || $pins($port) ne $expected} {
        error "V11 sheet11 pin mismatch: $port should be $expected"
    }
}
puts "TB_PASS: SC7F0 V11 sheet11 HDMI clocks, controls and six GTH lane pairs"
