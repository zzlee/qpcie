# ==============================================================================
# Independent validation of the encoder-only VCU integration in zu4ev_ps_bd
# (Phase 1 Todo 1.1, interconnect slimming in Todo 1.2b).
#
#   source /opt/Xilinx/Vivado/2023.2/settings64.sh
#   vivado -mode batch -notrace -source scripts/check_sc7f0_vcu_bd.tcl          # default (xbar)
#   vivado -mode batch -notrace -source scripts/check_sc7f0_vcu_bd.tcl sc       # SmartConnect baseline
#
# Elaborates zu4ev_ps_bd with create_zu4ev_ps_bd 1 1 <style> in an in-memory
# project, so validate_bd_design runs and neither production project is touched.
# In-memory BD files land under cwd/.srcs, so change directory first.  Requires
# "SUCCESS: zu4ev_ps_bd created & validated successfully!" plus VCU_BD_PASS.
# ==============================================================================
set root [file normalize [file join [file dirname [info script]] ..]]
set style [expr {[llength $argv] ? [lindex $argv 0] : ""}]
set scratch /tmp/opencode/sc7f0-vcu/bd-check-$style
file mkdir $scratch
cd $scratch
create_project -in_memory -part xczu4ev-fbvb900-2-e
source $root/scripts/create_zu4ev_ps_bd.tcl
if {$style eq ""} { set style [vcu_ic_default] }
puts "CHECK_VCU_STYLE=$style"
create_zu4ev_ps_bd 1 1 $style

# ---------------------------------------------------------------- helpers ----
set failures 0

# Conditions are source text and must run in the caller's scope; a plain
# 'if {$cond}' would not execute the nested get_bd_* commands.
proc require {cond what} {
    global failures
    if {[catch {uplevel 1 [list expr $cond]} ok]} {
        incr failures
        puts "  FAIL    $what (evaluation error: $ok)"
        return
    }
    if {$ok} { puts "  ok    $what" } else { incr failures; puts "  FAIL    $what" }
}
proc cfg {cell key} { return [get_property CONFIG.$key [get_bd_cells $cell]] }
# get_bd_pins also matches scalar ports, and get_bd_nets then finds nothing, so
# resolve ports and cell pins separately.
proc objs {ref} {
    if {[string first "/" $ref] >= 0} { return [get_bd_pins $ref] }
    return [get_bd_ports $ref]
}
proc nets_for {ref} { return [lsort [get_bd_nets -of [objs $ref]]] }
proc net_of {ref} {
    set n [nets_for $ref]
    if {[llength $n] != 1} { return "" }
    return [get_property NAME [lindex $n 0]]
}
proc connected {a b} {
    set na [net_of $a]
    return [expr {$na ne "" && $na eq [net_of $b]}]
}
# Same-net test that also accepts get_bd_pins patterns (a protocol converter has
# one or two clock pins depending on its protocol pair).
proc same_net {a b} {
    set na [nets_for $a]
    set nb [nets_for $b]
    return [expr {$na ne {} && $na eq $nb}]
}
proc freq {ref} { return [get_property CONFIG.FREQ_HZ [objs $ref]] }
proc seg_str {space} {
    set out {}
    foreach s [get_bd_addr_segs -of $space] {
        lappend out "[get_property NAME $s]@[get_property OFFSET $s]+[get_property RANGE $s]"
    }
    return $out
}
proc seg_prop {space_name seg property} {
    foreach x [get_bd_addr_segs -of [get_bd_addr_spaces $space_name]] {
        if {[get_property NAME $x] eq $seg} { return [get_property $property $x] }
    }
    return ""
}
proc dw {ref} { return [get_property CONFIG.DATA_WIDTH [get_bd_intf_pins $ref]] }

# Memory-side interconnect cells for the style under test.  The dwidth
# converter's clock/reset pins follow its AXI interfaces, so they are matched by
# pattern (same as axil_vcu).
if {[string match "xbar*" $style]} {
    set enc_ic     xbar_vcu_enc
    set mcu_ic     dwc_vcu_mcu
    set enc_ic_clk xbar_vcu_enc/aclk
    set mcu_ic_clk dwc_vcu_mcu/*aclk*
    set mcu_si     S_AXI
    set mcu_mi     M_AXI
} else {
    set enc_ic     smc_vcu_enc
    set mcu_ic     smc_vcu_mcu
    set enc_ic_clk smc_vcu_enc/aclk
    set mcu_ic_clk smc_vcu_mcu/aclk
    set mcu_si     S00_AXI
    set mcu_mi     M00_AXI
}

# ------------------------------------------------------------------- VCU -----
puts "== VCU cell =="
require {[get_property VLNV [get_bd_cells vcu_0]] eq "xilinx.com:ip:vcu:1.2"} \
    "VLNV [get_property VLNV [get_bd_cells vcu_0]]"
require {[cfg vcu_0 ENABLE_ENCODER] eq "true"} "CONFIG.ENABLE_ENCODER = true"
require {[cfg vcu_0 ENABLE_DECODER] eq "false"} "CONFIG.ENABLE_DECODER = false"
require {[expr double([cfg vcu_0 PLL_CLK]) > 33.3 && double([cfg vcu_0 PLL_CLK]) < 33.4]} \
    "CONFIG.PLL_CLK = [cfg vcu_0 PLL_CLK] MHz"
require {[cfg vcu_0 PLL_BYPASS] eq "0"} "CONFIG.PLL_BYPASS = 0 (internal VCU PLL in use)"
require {[cfg vcu_0 AXI_ENC_CLK] == 150 && [cfg vcu_0 AXI_MCU_CLK] == 150} \
    "CONFIG.AXI_ENC_CLK/AXI_MCU_CLK = [cfg vcu_0 AXI_ENC_CLK]/[cfg vcu_0 AXI_MCU_CLK] MHz"
require {![llength [get_bd_intf_pins vcu_0/M_AXI_DEC0]]} "no decoder AXI interface elaborated"
puts "  info  ENC_FRAME_SIZE=[cfg vcu_0 ENC_FRAME_SIZE] ENC_FPS=[cfg vcu_0 ENC_FPS] ENC_COLOR_FORMAT=[cfg vcu_0 ENC_COLOR_FORMAT] ENC_COLOR_DEPTH=[cfg vcu_0 ENC_COLOR_DEPTH] ENC_BUFFER_EN=[cfg vcu_0 ENC_BUFFER_EN]"
puts "  info  ENC0/ENC1/MCU/LITE = [dw vcu_0/M_AXI_ENC0]/[dw vcu_0/M_AXI_ENC1]/[dw vcu_0/M_AXI_MCU]/[dw vcu_0/S_AXI_LITE]-bit, addr [get_property CONFIG.ADDR_WIDTH [get_bd_intf_pins vcu_0/M_AXI_ENC0]]/[get_property CONFIG.ADDR_WIDTH [get_bd_intf_pins vcu_0/S_AXI_LITE]]"

# ----------------------------------------------------------------- clocks ----
puts "== Clocks =="
require {[expr [cfg zynq_ultra_ps_e_0 PSU__FPGA_PL1_ENABLE] == 1]} "PSU__FPGA_PL1_ENABLE = 1"
require {[cfg zynq_ultra_ps_e_0 PSU__PL_CLK1_BUF] in {TRUE true 1}} "PSU__PL_CLK1_BUF = [cfg zynq_ultra_ps_e_0 PSU__PL_CLK1_BUF]"
puts "  info  PL1 requested=[cfg zynq_ultra_ps_e_0 PSU__CRL_APB__PL1_REF_CTRL__FREQMHZ]MHz actual=[cfg zynq_ultra_ps_e_0 PSU__CRL_APB__PL1_REF_CTRL__ACT_FREQMHZ]MHz"
require {[connected vcu_0/pll_ref_clk zynq_ultra_ps_e_0/pl_clk1]} "pll_ref_clk <- PS pl_clk1 ([net_of vcu_0/pll_ref_clk])"
set pll_ref_hz [freq vcu_0/pll_ref_clk]
require {[expr $pll_ref_hz > 33200000 && $pll_ref_hz < 33400000]} \
    "pll_ref_clk FREQ_HZ = $pll_ref_hz (nominal 33333333; the PS RPLL is 999.90005MHz, so /30 gives 33.330002MHz)"
require {[freq dp_mem_clk] == 150000000} "dp_mem_clk FREQ_HZ = [freq dp_mem_clk]"
foreach p [list vcu_0/m_axi_enc_aclk vcu_0/m_axi_mcu_aclk \
               zynq_ultra_ps_e_0/saxihp2_fpd_aclk zynq_ultra_ps_e_0/saxihp3_fpd_aclk \
               $enc_ic_clk $mcu_ic_clk vcu_rst_mem/slowest_sync_clk] {
    require {[connected $p dp_mem_clk] && [freq $p] == 150000000} "$p on 150MHz dp_mem_clk ([freq $p])"
}
foreach p {vcu_0/s_axi_lite_aclk ic_hpm1/*ACLK* vcu_rst_lite/slowest_sync_clk} {
    require {[same_net $p zynq_ultra_ps_e_0/pl_clk0]} "$p on PS pl_clk0"
}
require {[freq vcu_0/s_axi_lite_aclk] == 99990005} "s_axi_lite_aclk FREQ_HZ = [freq vcu_0/s_axi_lite_aclk]"

# ----------------------------------------------------------- memory ports ----
puts "== PS memory ports (HP2 / HP3) =="
puts "  info  PSU__USE__S_AXI_GP4=[cfg zynq_ultra_ps_e_0 PSU__USE__S_AXI_GP4] GP5=[cfg zynq_ultra_ps_e_0 PSU__USE__S_AXI_GP5] SAXIGP4/GP5 width=[cfg zynq_ultra_ps_e_0 PSU__SAXIGP4__DATA_WIDTH]/[cfg zynq_ultra_ps_e_0 PSU__SAXIGP5__DATA_WIDTH]"
require {[llength [get_bd_intf_pins zynq_ultra_ps_e_0/S_AXI_HP2_FPD]] == 1 &&
         [llength [get_bd_intf_pins zynq_ultra_ps_e_0/S_AXI_HP3_FPD]] == 1 &&
         [llength [get_bd_pins zynq_ultra_ps_e_0/saxihp2_fpd_aclk]] == 1 &&
         [llength [get_bd_pins zynq_ultra_ps_e_0/saxihp3_fpd_aclk]] == 1} "S_AXI_HP2_FPD and S_AXI_HP3_FPD elaborated with their AXI clocks"
require {[dw zynq_ultra_ps_e_0/S_AXI_HP2_FPD] == 128} "S_AXI_HP2_FPD width = [dw zynq_ultra_ps_e_0/S_AXI_HP2_FPD]"
require {[dw zynq_ultra_ps_e_0/S_AXI_HP3_FPD] == 128} "S_AXI_HP3_FPD width = [dw zynq_ultra_ps_e_0/S_AXI_HP3_FPD]"
require {[llength [get_bd_intf_nets -of [get_bd_intf_pins zynq_ultra_ps_e_0/S_AXI_HP2_FPD]]] == 1} "S_AXI_HP2_FPD driven once (encoder DBI)"
require {[llength [get_bd_intf_nets -of [get_bd_intf_pins zynq_ultra_ps_e_0/S_AXI_HP3_FPD]]] == 1} "S_AXI_HP3_FPD driven once (MCU)"
require {[llength [get_bd_intf_ports S_AXI_HP2_FPD]] == 0 && [llength [get_bd_intf_ports S_AXI_HP3_FPD]] == 0} \
    "HP2/HP3 stay inside the BD (no new wrapper AXI ports)"
foreach si {S00_AXI S01_AXI} {
    require {[llength [get_bd_intf_nets -of [get_bd_intf_pins $enc_ic/$si]]] == 1} "$enc_ic/$si connected"
}
puts "  info  $enc_ic S00/S01/M00 = [dw $enc_ic/S00_AXI]/[dw $enc_ic/S01_AXI]/[dw $enc_ic/M00_AXI]-bit, id [get_property CONFIG.ID_WIDTH [get_bd_intf_pins $enc_ic/M00_AXI]]"
puts "  info  $mcu_ic $mcu_si/$mcu_mi = [dw $mcu_ic/$mcu_si]/[dw $mcu_ic/$mcu_mi]-bit (32->128 width conversion)"
require {[dw $mcu_ic/$mcu_si] == 32 && [dw $mcu_ic/$mcu_mi] == 128} "MCU path width-converted 32 -> 128"

# ---------------------------------------------------- interconnect slimming --
# The whole point of Todo 1.2b: the video merge must not be a SmartConnect, and
# the MCU path must not be an interconnect at all - it is a 1:1 upsizing.
puts "== Memory interconnect (style: $style) =="
if {[string match "xbar*" $style]} {
    require {[get_property VLNV [get_bd_cells $enc_ic]] eq "xilinx.com:ip:axi_crossbar:2.1"} \
        "$enc_ic is axi_crossbar 2.1 ([get_property VLNV [get_bd_cells $enc_ic]])"
    require {[get_property VLNV [get_bd_cells $mcu_ic]] eq "xilinx.com:ip:axi_dwidth_converter:2.1"} \
        "$mcu_ic is axi_dwidth_converter 2.1 ([get_property VLNV [get_bd_cells $mcu_ic]])"
    set sc_left [get_bd_cells -quiet -filter {VLNV =~ "xilinx.com:ip:smartconnect:*"}]
    set sc_names {}
    if {[llength $sc_left]} { set sc_names [get_property NAME $sc_left] }
    require {![llength $sc_left]} \
        "no smartconnect left in the BD (${sc_names}: interconnect slimming in effect)"
    require {[cfg $enc_ic NUM_SI] == 2 && [cfg $enc_ic NUM_MI] == 1} \
        "$enc_ic = [cfg $enc_ic NUM_SI] SI / [cfg $enc_ic NUM_MI] MI, [cfg $enc_ic ADDR_RANGES] address ranges"
    require {[dw $enc_ic/S00_AXI] == 128 && [dw $enc_ic/S01_AXI] == 128 && [dw $enc_ic/M00_AXI] == 128} \
        "DBI merge stays 128-bit end to end"
    # axi_crossbar routes B/R with the ID bits at the S01_BASE_ID position, so a
    # 4-bit ID would cost the VCU its own MSB; 5 bits keeps all 16 encoder IDs
    # and puts the source tag above them (HP2 accepts 6).
    require {[get_property CONFIG.ID_WIDTH [get_bd_intf_pins $enc_ic/M00_AXI]] >
             [get_property CONFIG.ID_WIDTH [get_bd_intf_pins vcu_0/M_AXI_ENC0]]} \
        "$enc_ic MI ID width [get_property CONFIG.ID_WIDTH [get_bd_intf_pins $enc_ic/M00_AXI]] > VCU's [get_property CONFIG.ID_WIDTH [get_bd_intf_pins vcu_0/M_AXI_ENC0]] (source tag does not eat a VCU ID bit)"
    require {[get_property CONFIG.ID_WIDTH [get_bd_intf_pins $enc_ic/M00_AXI]] <=
             [get_property CONFIG.ID_WIDTH [get_bd_intf_pins zynq_ultra_ps_e_0/S_AXI_HP2_FPD]]} \
        "$enc_ic MI ID width fits S_AXI_HP2_FPD ([get_property CONFIG.ID_WIDTH [get_bd_intf_pins zynq_ultra_ps_e_0/S_AXI_HP2_FPD]])"
    require {[cfg $enc_ic ADDR_WIDTH] == 44} "$enc_ic ADDR_WIDTH = [cfg $enc_ic ADDR_WIDTH] (VCU master width, HP2's 49 is not needed)"
    require {[get_property CONFIG.SI_DATA_WIDTH [get_bd_cells $mcu_ic]] == 32 &&
             [get_property CONFIG.MI_DATA_WIDTH [get_bd_cells $mcu_ic]] == 128 &&
             [get_property CONFIG.SI_ID_WIDTH [get_bd_cells $mcu_ic]] == 3} \
        "$mcu_ic = [get_property CONFIG.SI_DATA_WIDTH [get_bd_cells $mcu_ic]]->[get_property CONFIG.MI_DATA_WIDTH [get_bd_cells $mcu_ic]]-bit, SI_ID_WIDTH [get_property CONFIG.SI_ID_WIDTH [get_bd_cells $mcu_ic]]"
    require {[cfg $mcu_ic ACLK_ASYNC] == 0} "$mcu_ic is single-clock (ACLK_ASYNC = [cfg $mcu_ic ACLK_ASYNC])"
    if {$style eq "xbar8"} {
        require {[cfg $enc_ic S00_READ_ACCEPTANCE] == 8 && [cfg $enc_ic M00_READ_ISSUING] == 8 &&
                 [cfg $enc_ic S01_WRITE_ACCEPTANCE] == 8 && [cfg $enc_ic M00_WRITE_ISSUING] == 8} \
            "$enc_ic queue depth pinned to 8 (S00_RD=[cfg $enc_ic S00_READ_ACCEPTANCE] M00_RD=[cfg $enc_ic M00_READ_ISSUING] S01_WR=[cfg $enc_ic S01_WRITE_ACCEPTANCE] M00_WR=[cfg $enc_ic M00_WRITE_ISSUING], propagated default would be 16)"
    } else {
        require {[cfg $enc_ic S00_READ_ACCEPTANCE] == 16 && [cfg $enc_ic M00_READ_ISSUING] == 16} \
            "$enc_ic keeps the propagated depth 16 (S00_RD=[cfg $enc_ic S00_READ_ACCEPTANCE] M00_RD=[cfg $enc_ic M00_READ_ISSUING]) - full outstanding-burst budget"
    }
} else {
    require {[get_property VLNV [get_bd_cells $enc_ic]] eq "xilinx.com:ip:smartconnect:1.0"} \
        "$enc_ic is the smartconnect baseline ([get_property VLNV [get_bd_cells $enc_ic]])"
    require {[get_property VLNV [get_bd_cells $mcu_ic]] eq "xilinx.com:ip:smartconnect:1.0"} \
        "$mcu_ic is the smartconnect baseline ([get_property VLNV [get_bd_cells $mcu_ic]])"
}

# -------------------------------------------------------------- AXI-Lite -----
puts "== VCU register (AXI-Lite) path =="
require {[expr [cfg zynq_ultra_ps_e_0 PSU__USE__M_AXI_GP2] == 0]} "M_AXI_HPM0_LPD disabled (PSU__USE__M_AXI_GP2 = 0)"
require {[get_property VLNV [get_bd_cells ic_hpm1]] eq "xilinx.com:ip:axi_interconnect:2.1"} "ic_hpm1 is axi_interconnect 2.1"
require {[llength [get_bd_intf_nets -of [get_bd_intf_pins ic_hpm1/S00_AXI]]] == 1} "ic_hpm1 S00_AXI connected to PS M_AXI_HPM1_FPD"
require {[llength [get_bd_intf_nets -of [get_bd_intf_pins ic_hpm1/M00_AXI]]] == 1} "ic_hpm1 M00_AXI connected to port M_AXI_HPM1_FPD"
require {[llength [get_bd_intf_nets -of [get_bd_intf_pins vcu_0/S_AXI_LITE]]] == 1} "vcu_0/S_AXI_LITE connected"

# ----------------------------------------------------------------- reset -----
puts "== Reset =="
foreach cell {vcu_rst_lite vcu_rst_mem} {
    require {[get_property VLNV [get_bd_cells $cell]] eq "xilinx.com:ip:proc_sys_reset:5.0"} "$cell is proc_sys_reset 5.0"
    require {[get_property CONFIG.C_AUX_RESET_HIGH [get_bd_cells $cell]] == 0} "$cell C_AUX_RESET_HIGH = 0 (pl_resetn0 is active low)"
    require {[connected $cell/aux_reset_in zynq_ultra_ps_e_0/pl_resetn0]} "$cell/aux_reset_in <- pl_resetn0"
    # ext_reset_in does NOT keep the proc_sys_reset default polarity (1 = active
    # high) in this design: validate_bd_design propagates the polarity of the
    # reset driving the cell - pl_resetn0, active low, on aux_reset_in - onto
    # both reset inputs, so every shipped output product carries
    # C_EXT_RESET_HIGH = 0 and the IP samples "not ext_reset_in"
    # (ACTIVE_LOW_EXT in proc_sys_reset_v5_0_vh_rfs.vhd).  xsim of the shipped
    # vcu_rst_lite netlist: ext_reset_in = 1 -> peripheral_aresetn = 1,
    # ext_reset_in = 0 -> peripheral_aresetn = 0.
    # So the gate is on the propagated polarity, not on the IP default: the
    # constant must sit at the opposite level of the active one.
    set pol [get_property CONFIG.C_EXT_RESET_HIGH [get_bd_cells $cell]]
    require {$pol == 0} "$cell C_EXT_RESET_HIGH = $pol (ext_reset_in is active LOW here, propagated from pl_resetn0)"
    require {[connected $cell/ext_reset_in vcu_rst_const/dout] && [cfg vcu_rst_const CONST_VAL] != $pol} "$cell/ext_reset_in tied inactive (constant [cfg vcu_rst_const CONST_VAL] != active level $pol)"
}
require {[connected vcu_0/vcu_resetn vcu_reset_slice/Dout]} "vcu_resetn <- vcu_reset_slice"
require {[connected vcu_reset_slice/Din zynq_ultra_ps_e_0/emio_gpio_o]} "vcu_reset_slice <- emio_gpio_o"
require {[connected $enc_ic/aresetn vcu_rst_mem/peripheral_aresetn]} "$enc_ic/aresetn <- vcu_rst_mem"
if {[string match "xbar*" $style]} {
    require {[same_net $mcu_ic/*aresetn* vcu_rst_mem/peripheral_aresetn]} "$mcu_ic reset <- vcu_rst_mem"
} else {
    require {[connected $mcu_ic/aresetn vcu_rst_mem/peripheral_aresetn]} "$mcu_ic/aresetn <- vcu_rst_mem"
}
require {[same_net ic_hpm1/M01_ARESETN vcu_rst_lite/peripheral_aresetn]} "ic_hpm1 reset <- vcu_rst_lite"

# ---------------------------------------------------------------- interrupt --
puts "== Interrupt =="
require {[llength [get_bd_ports pl_ps_irq0]] == 1 &&
         [get_property LEFT [get_bd_ports pl_ps_irq0]] == 4 &&
         [get_property RIGHT [get_bd_ports pl_ps_irq0]] == 0} "wrapper port pl_ps_irq0 stays 4:0"
require {[get_property LEFT [get_bd_pins zynq_ultra_ps_e_0/pl_ps_irq0]] == 5} "PS pl_ps_irq0 input widened to 5:0"
require {[expr [cfg zynq_ultra_ps_e_0 PSU__NUM_F2P0__INTR__INPUTS] == 6]} "PSU__NUM_F2P0__INTR__INPUTS = [cfg zynq_ultra_ps_e_0 PSU__NUM_F2P0__INTR__INPUTS]"
require {[cfg vcu_irq_cat NUM_PORTS] == 2 && [cfg vcu_irq_cat IN0_WIDTH] == 5 && [cfg vcu_irq_cat IN1_WIDTH] == 1} "vcu_irq_cat = {In0 5b, In1 1b}"
require {[connected vcu_irq_cat/In1 vcu_0/vcu_host_interrupt]} "vcu_host_interrupt -> vcu_irq_cat/In1 => pl_ps_irq0 bit 5 (GIC SPI 89+5 = 94)"
require {[connected vcu_irq_cat/In0 pl_ps_irq0]} "pl_ps_irq0 4:0 -> vcu_irq_cat/In0"
require {[connected vcu_irq_cat/dout zynq_ultra_ps_e_0/pl_ps_irq0]} "vcu_irq_cat/dout -> PS pl_ps_irq0 5:0"

# ------------------------------------------------------------- address map ---
puts "== Address map =="
puts "  [get_property NAME [get_bd_addr_spaces zynq_ultra_ps_e_0/Data]] : [seg_str [get_bd_addr_spaces zynq_ultra_ps_e_0/Data]]"
foreach s [get_bd_addr_spaces -of [get_bd_cells vcu_0]] {
    set n [get_property NAME $s]
    set m [seg_str $s]
    puts "  $n : $m"
    if {[string match "*EncData*" $n]} {
        require {[string match "*HP2_DDR*" $m] && ![string match "*HP3_DDR*" $m]} "$n reaches DDR only through S_AXI_HP2_FPD"
        require {[string match "*DDR_HIGH*" $m]} "$n is also mapped to the high DDR bank"
    }
    if {[string match "*Code*" $n]} {
        require {[string match "*HP3_DDR*" $m] && ![string match "*HP2_DDR*" $m]} "$n (MCU) reaches DDR only through S_AXI_HP3_FPD"
        require {[string match "*DDR_HIGH*" $m]} "$n is also mapped to the high DDR bank"
    }
}
set vcu_lite_off [seg_prop zynq_ultra_ps_e_0/Data SEG_vcu_0_Reg OFFSET]
set vcu_lite_rng [seg_prop zynq_ultra_ps_e_0/Data SEG_vcu_0_Reg RANGE]
require {$vcu_lite_off eq "0x00B0100000"} "VCU registers @ $vcu_lite_off + $vcu_lite_rng (encoder +0x0, slcr +0x40000, logicore +0x41000)"
require {$vcu_lite_rng ne "" && [expr 0x[string range $vcu_lite_rng 2 end] >= 0x42000]} "VCU register window covers slcr/logicore offsets"
require {[seg_prop zynq_ultra_ps_e_0/Data SEG_M_AXI_HPM1_FPD_Reg OFFSET] eq "0x00B0000000" &&
         [seg_prop zynq_ultra_ps_e_0/Data SEG_M_AXI_HPM1_FPD_Reg RANGE] eq "0x0000100000"} "HDMI CSR window unchanged = 0xB0000000 + [seg_prop zynq_ultra_ps_e_0/Data SEG_M_AXI_HPM1_FPD_Reg RANGE]"
require {[seg_prop zynq_ultra_ps_e_0/Data SEG_M_AXI_HPM0_FPD_Reg OFFSET] eq "0x00A0000000"} "BAR0 CSR window unchanged @ [seg_prop zynq_ultra_ps_e_0/Data SEG_M_AXI_HPM0_FPD_Reg OFFSET]"
# No address may be claimed twice in the shared PS master address space.
set ps_overlaps {}
set ps_segs [get_bd_addr_segs -of [get_bd_addr_spaces zynq_ultra_ps_e_0/Data]]
foreach a $ps_segs {
    foreach b $ps_segs {
        if {$a eq $b} { continue }
        if {[get_property OFFSET $a] eq [get_property OFFSET $b]} { lappend ps_overlaps "[get_property NAME $a]=[get_property OFFSET $a]" }
    }
}
require {$ps_overlaps eq {}} "no duplicate PS Data offsets ($ps_overlaps)"

# ------------------------------------------------------------- regression ----
puts "== Regression: HP0 / HP1 / HPM windows =="
require {[get_property CONFIG.DATA_WIDTH [get_bd_intf_ports S_AXI_HP0_FPD]] == 128 &&
         [get_property CONFIG.FREQ_HZ [get_bd_intf_ports S_AXI_HP0_FPD]] == 99990005} "S_AXI_HP0_FPD port 128-bit @ [get_property CONFIG.FREQ_HZ [get_bd_intf_ports S_AXI_HP0_FPD]]Hz"
require {[get_property CONFIG.DATA_WIDTH [get_bd_intf_ports S_AXI_HP1_FPD]] == 128 &&
         [get_property CONFIG.FREQ_HZ [get_bd_intf_ports S_AXI_HP1_FPD]] == 150000000} "S_AXI_HP1_FPD port 128-bit @ [get_property CONFIG.FREQ_HZ [get_bd_intf_ports S_AXI_HP1_FPD]]Hz"
require {[connected zynq_ultra_ps_e_0/saxihp1_fpd_aclk dp_mem_clk]} "saxihp1_fpd_aclk still on dp_mem_clk"
require {[get_property CONFIG.DATA_WIDTH [get_bd_intf_ports M_AXI_HPM1_FPD]] == 32 &&
         [get_property CONFIG.DATA_WIDTH [get_bd_intf_ports M_AXI_HPM0_FPD]] == 32} "M_AXI_HPM0/HPM1_FPD still 32-bit"
require {[string length [get_property LEFT [get_bd_ports pl_resetn0]]] == 0} "pl_resetn0 port unchanged"
require {[llength [get_bd_ports vcu_ref_clk]] == 0} "no extra clock port exported (pl_clk1 stays inside the BD)"
# The whole point of the internal topology: the generated wrapper keeps exactly
# the port set the R7 top level already connects.
set want_iports {M_AXI_HPM0_FPD M_AXI_HPM1_FPD S_AXI_HP0_FPD S_AXI_HP1_FPD}
set got_iports [lsort [get_property NAME [get_bd_intf_ports]]]
require {$got_iports eq [lsort $want_iports]} "wrapper interface ports unchanged: $got_iports"
set want_sports {dp_mem_clk pl_clk0 pl_ps_irq0 pl_resetn0}
set got_sports {}
foreach p [get_bd_ports] {
    if {[get_property TYPE $p] in {clk rst tri_rst intr}} { lappend got_sports [get_property NAME $p] }
}
set got_sports [lsort $got_sports]
require {$got_sports eq [lsort $want_sports]} "wrapper clk/reset/IRQ ports unchanged: $got_sports"

# --------------------------------------------------------------- ethernet ----
# Ethernet (GEM0) disabled per SC7F0 no-network card architecture
puts "== Ethernet (GEM0 disabled) =="
require {[expr [cfg zynq_ultra_ps_e_0 PSU__ENET0__PERIPHERAL__ENABLE] == 0]} \
    "PSU__ENET0__PERIPHERAL__ENABLE = 0"
require {[expr [cfg zynq_ultra_ps_e_0 PSU__ENET0__GRP_MDIO__ENABLE] == 0]} \
    "PSU__ENET0__GRP_MDIO__ENABLE = 0"
require {![string match "*Gem 0*" [cfg zynq_ultra_ps_e_0 PSU_MIO_TREE_PERIPHERALS]] &&
         ![string match "*MDIO 0*" [cfg zynq_ultra_ps_e_0 PSU_MIO_TREE_PERIPHERALS]]} \
    "MIO tree has no Gem 0 or MDIO 0"
require {[string match "*GEM0;FF0B0000;FF0BFFFF;0*" [cfg zynq_ultra_ps_e_0 PSU__PROTECTION__SLAVES]] &&
         [string match "*GEM0:NonSecure;0*" [cfg zynq_ultra_ps_e_0 PSU__PROTECTION__MASTERS]]} \
    "GEM0 is disabled in the PS protection master/slave lists"

# ------------------------------------------------------------------ listing --
puts "== BD objects =="
foreach c [get_bd_cells] { puts "  cell  [get_property NAME $c] ([get_property VLNV $c])" }
foreach p [get_bd_intf_ports] { puts "  iport [get_property NAME $p] mode=[get_property MODE $p]" }
foreach p [get_bd_ports] {
    if {[get_property TYPE $p] in {clk rst tri_rst intr}} {
        puts "  port  [get_property NAME $p] dir=[get_property DIR $p] type=[get_property TYPE $p] range=[get_property LEFT $p]:[get_property RIGHT $p] freq=[get_property CONFIG.FREQ_HZ $p]"
    }
}

if {$failures} {
    puts "VCU_BD_FAIL: $failures check(s) failed"
    error "VCU_BD_FAIL: $failures check(s) failed"
}
puts "VCU_BD_PASS: encoder-only VCU, memory IC style=$style ($enc_ic + $mcu_ic), control @ 0xB0100000, IRQ bit 5 (SPI 94), validate_bd_design SUCCESS"
close_project
exit 0
