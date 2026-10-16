# Artifact export only: this script never opens a hardware server or flashes a board.
set root [file normalize [file join [file dirname [info script]] ..]]
set project_dir [file join $root build qpcie_a50t_proj]
set source_fd [open [file join $root rtl a50t_pcie_card_top.v] r]
set top_source [read $source_fd]
close $source_fd
if {![regexp {\.C_VERSION\(32'h([0-9A-Fa-f]{8})\)} $top_source -> version]} {
    error "Cannot read A50T C_VERSION; refusing artifact export."
}
set release_dir [file join $root build release-a50t-hdmi-$version]
open_project [file join $project_dir qpcie_a50t_card.xpr]
if {[get_property NEEDS_REFRESH [get_runs impl_1]]} {
    error "Implementation is stale; rebuild before exporting artifacts."
}
open_run impl_1
if {[scan $version %x] >= 0x26101602} {
    set hdmi_clock [get_clocks -quiet tm0_pclk]
    if {[llength $hdmi_clock] != 1 || abs([get_property PERIOD $hdmi_clock] - 3.333) > 0.001} {
        error "Native 4K candidate requires a 300 MHz HDMI input clock constraint."
    }
}
set icap_clock [get_clocks -quiet icap_clk]
if {[llength $icap_clock] != 1 || abs([get_property PERIOD $icap_clock] - 16.0) > 0.001} {
    error "Expected a constrained 62.5 MHz ICAP clock; refusing artifact export."
}
file mkdir $release_dir
if {[scan $version %x] >= 0x26101603} {
    set input_regs [get_cells -hier -filter {NAME =~ *u_hdmi_parallel_input* && REF_NAME =~ FD*}]
    if {[llength $input_regs] < 50} {
        error "Expected at least 48 HDMI data + DE/VS input registers; refusing artifact export."
    }
    set audit [open [file join $release_dir hdmi_input_registers.rpt] w]
    foreach cell $input_regs {
        set loc [get_property LOC $cell]
        puts $audit "$cell LOC=$loc BEL=[get_property BEL $cell]"
        if {![string match ILOGIC_* $loc]} {
            close $audit
            error "HDMI input register $cell is not in an IOB; refusing artifact export."
        }
    }
    close $audit
    puts "HDMI_INPUT_GATE: [llength $input_regs] registers in ILOGIC"
}
report_timing_summary -file [file join $release_dir timing_summary.rpt]
report_utilization -file [file join $release_dir utilization.rpt]
report_pulse_width -file [file join $release_dir pulse_width.rpt]
report_bus_skew -file [file join $release_dir bus_skew.rpt]
set fd [open [file join $release_dir bus_skew.rpt] r]
set bus_skew [read $fd]
close $fd
if {[regexp {Slack \(VIOLATED\)} $bus_skew]} {
    error "Bus-skew timing failed; no release export."
}
# Setup/hold path queries alone miss primitive minimum-period checks (ICAP).
# Fail closed unless the report's design summary also passes pulse-width timing.
set fd [open [file join $release_dir timing_summary.rpt] r]
set summary [read $fd]
close $fd
source [file join $root scripts a50t_timing_gate.tcl]
if {[catch {a50t_validate_timing_summary $summary} timing]} {
    puts "ERROR: $timing"
    exit 1
}
puts "TIMING_GATE: $timing"
foreach delay {max min} {
    set bad [get_timing_paths -quiet -delay_type $delay -slack_lesser_than 0 -max_paths 1]
    if {[llength $bad]} {
        puts "ERROR: $delay timing slack [get_property SLACK [lindex $bad 0]] ns; do not release this bitstream."
        exit 1
    }
}
set bit [file join $project_dir qpcie_a50t_card.runs impl_1 a50t_pcie_card_top.bit]
file copy -force $bit [file join $release_dir a50t_pcie_card_top.bit]
# SPIx4 matches BITSTREAM.CONFIG.SPI_BUSWIDTH and program_flash_a50t.tcl.
write_cfgmem -format bin -size 16 -interface SPIx4 -loadbit "up 0x00000000 $bit" \
    -file [file join $release_dir a50t_pcie_card_top_spix4.bin] -force
write_hw_platform -fixed -include_bit -force [file join $release_dir a50t_pcie_card_top.xsa]
puts "RELEASE_EXPORTED: $release_dir (not flashed)"
close_project
exit
