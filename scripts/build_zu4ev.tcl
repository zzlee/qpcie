# ==============================================================================
# Vivado TCL Build Script for SC7F0 N1 HDMI2 V11 (ZU4EV PCIe Video & Audio DMA Card)
# Target Device: AMD/Xilinx Zynq UltraScale+ (xczu4ev-fbvb900-2-e)
# Top-Level RTL: zu4ev_pcie_card_top.v
# PCIe IP Core: pcie4_uscale_plus_0 (Gen3 x4, 256-bit, Tandem PCIe)
# Distinct Identification: Vendor ID 0x12AB, Device ID 0xE380
# ==============================================================================

set project_name "qpcie_zu4ev_card"
set project_dir  "./build/qpcie_zu4ev_proj"
set device_part  "xczu4ev-fbvb900-2-e"
# Debug-first is the default. The preserved full AV profile is unvalidated and
# must undergo a new hardware revision/PHY bring-up before future publication.
set profile "debug"
if {[info exists ::env(SC7F0_PROFILE)]} {set profile $::env(SC7F0_PROFILE)}
if {$profile ni {debug full rgb_compositor}} {error "SC7F0_PROFILE must be debug, full or rgb_compositor"}
set debug_profile [expr {$profile eq "debug"}]
# Keep experimental AV outputs separate from the validated debug04 project/XSA.
if {!$debug_profile} {set project_dir "./build/qpcie_zu4ev_hdmi_proj"}
if {[info exists ::env(SC7F0_PROJECT_DIR)]} {set project_dir $::env(SC7F0_PROJECT_DIR)}
set build_stage "bitstream"
if {[info exists ::env(SC7F0_BUILD_STAGE)]} {set build_stage $::env(SC7F0_BUILD_STAGE)}
if {$build_stage ni {ip synth bitstream}} {error "SC7F0_BUILD_STAGE must be ip, synth or bitstream"}
# Encoder-only VCU is opt-in per hardware revision. Unset or 0 keeps the shipped
# BD call (and therefore every published bitstream) exactly as it was; 1 adds
# the slimmed encoder subsystem to the full-profile PS block design.
set vcu_enable 0
if {[info exists ::env(SC7F0_ENABLE_VCU)]} {
    set vcu_req [string tolower [string trim $::env(SC7F0_ENABLE_VCU)]]
    if {$vcu_req ni {0 1 true false yes no}} {
        error "SC7F0_ENABLE_VCU must be 0/1 (true/false), got '$vcu_req'"
    }
    if {$vcu_req in {1 true yes}} {set vcu_enable 1}
}
# The HDMI TX display branch (PS DDR -> v_frmbuf_rd -> v_hdmi_tx_ss -> connector)
# is an additive personality, opt-in exactly like the VCU: unset or 0 keeps every
# published build byte-identical. It does NOT replace the C2H capture path -
# SC7F0_C2H_ONLY stays defined, so the legacy PCIe H2C -> TX video bridge and the
# PCIe TX audio bridge stay out of the netlist and only the official IP chain
# (sc7f0_frmbuf_rd -> sc7f0_hdmi_tx_mux -> v_hdmi_tx_ss_0) is added. The AMD/Xilinx
# DRM drivers (hdmi-modules xlnx_drm_hdmi + phy-vphy, in-kernel xlnx,pl-disp and
# xlnx,axi-frmbuf-rd-v2.2) own this hardware; no private kernel ABI is created.
set display_enable 0
if {[info exists ::env(SC7F0_DISPLAY_TX)]} {
    set disp_req [string tolower [string trim $::env(SC7F0_DISPLAY_TX)]]
    if {$disp_req ni {0 1 true false yes no}} {
        error "SC7F0_DISPLAY_TX must be 0/1 (true/false), got '$disp_req'"
    }
    if {$disp_req in {1 true yes}} {set display_enable 1}
}
# SC7F0-RGB-COMPOSITOR-2PPC (plan A).  A third, independent personality:
#   * the whole video path is 2 pixel/clock (VPHY, HDMI RX SS, HDMI TX SS),
#   * the host receives packed RGB24 (byte R,G,B; 11520 B/line at 3840 px;
#     24883200 B/frame; 1.492992 GB/s) instead of the legacy host NV12 word,
#   * two independent official v_frmbuf_rd readers composite a base plane and an
#     RGBA32 overlay plane (33177600 B/frame, 1.990656 GB/s each) in PS DDR,
#   * the overlay plane is written by a new native-256 RC -> 128-bit 300 MHz
#     path on the PS HP3 port that the removed VCU encoder frees up.
# Everything shared stays: the PCIe core and DMA, the CSR / mailbox ABI, the
# original H2C upgrade path on 100 MHz, the PS, the MCU I2C proxies and the
# Video PHY with its three RX and three TX TMDS lanes.  The first capacity build
# also keeps the PS capture pipeline, its VPSS CSC and v_frmbuf_wr.
set rgb_enable 0
if {[info exists ::env(SC7F0_RGB_COMPOSITOR)]} {
    set rgb_req [string tolower [string trim $::env(SC7F0_RGB_COMPOSITOR)]]
    if {$rgb_req ni {0 1 true false yes no}} {
        error "SC7F0_RGB_COMPOSITOR must be 0/1 (true/false), got '$rgb_req'"
    }
    if {$rgb_req in {1 true yes}} {set rgb_enable 1}
}
if {$rgb_enable && $debug_profile} {
    error "SC7F0_RGB_COMPOSITOR requires SC7F0_PROFILE=rgb_compositor (the debug profile has no HDMI PHY, GT, PS DDR path or TX pins)"
}
if {$rgb_enable && $display_enable} {
    error "SC7F0_RGB_COMPOSITOR and SC7F0_DISPLAY_TX are separate TX personalities; the compositor replaces the single-plane display branch"
}
if {$rgb_enable} {
    # The VCU is the whole reason HP2/HP3 and the encoder IRQ slots are free for
    # the overlay plane, and this profile removes the encoder by construction.
    # Default project location only: an explicit SC7F0_PROJECT_DIR (always set by
    # the capacity-build runner) still wins, because that is how the scratch-disk
    # override is honoured for every profile.
    if {![info exists ::env(SC7F0_PROJECT_DIR)]} {
        set project_dir "./build/qpcie_zu4ev_rgb_proj"
    }
}
# The VCU memory clock (dp_mem_clk) and the PS HP2/HP3/LPD ports it needs only
# exist in the full profile, so a debug-profile request is a configuration bug.
if {$vcu_enable && $debug_profile} {
    error "SC7F0_ENABLE_VCU requires SC7F0_PROFILE=full (debug profile has no dp_mem_clk)"
}
# Same rule, and the PS block design must see the same switch or the two new PL
# interrupt sources would be elaborated with no interrupt parent.
if {$display_enable && $debug_profile} {
    error "SC7F0_DISPLAY_TX requires SC7F0_PROFILE=full (debug profile has no HDMI PHY, GT or TX pins)"
}
puts " SC7F0 profile: $profile"
puts " SC7F0 VCU:     $vcu_enable"
puts " SC7F0 display: $display_enable"
puts " SC7F0 rgbcomp: $rgb_enable"
exec python3 ./scripts/generate_sc7f0_csr_cdc.py --check

puts "================================================================="
puts " Starting Vivado Build for ZU4EV SC7F0 (zu4ev_pcie_card_top.v)"
puts " Target Part : $device_part"
puts " PCIe Core   : pcie4_uscale_plus_0 (Gen3 x4, 256-bit, Tandem PCIe)"
puts " Distinct ID : Vendor 0x12AB / Device 0xE380"
puts "================================================================="

file mkdir $project_dir
create_project $project_name $project_dir -part $device_part -force

set_property target_language Verilog [current_project]
set_property default_lib work [current_project]

# 1. Add RTL Sources & Dynamic Git Hash
# The identity may be pinned by the caller (scripts/build_sc7f0_dual_video_hw.sh
# and the release entry point always pin it) so the project-creation stage and
# the re-synthesis stage in scripts/impl_sc7f0_dual_video.tcl cannot disagree.
# All three overrides arrive together, or none of them and the historical
# create-time behaviour is kept for archived builds.
set pinned 0
if {[info exists ::env(SC7F0_GIT_HASH)] || [info exists ::env(SC7F0_BUILD_DATE)]} {
    # Name discipline: this loop variable lives in the GLOBAL scope of the sourced
    # file, and scripts/check_sc7f0_named_constraints.tcl refuses to run over any
    # scalar named t/e/s/d/c/u/x/... in its caller's scope (it creates its record
    # arrays at level 0 of the caller, and `array set` over a scalar would make
    # every item report a measurement failure).  Round
    # rgb-fullimpl-26111331-20261113T194329Z lost its whole Layer B manifest to
    # exactly that: this loop used to be `foreach e {...}`.  Renamed, not widened.
    foreach sc7f0_identity_env {SC7F0_VERSION SC7F0_GIT_HASH SC7F0_BUILD_DATE} {
        if {![info exists ::env($sc7f0_identity_env)] ||
            [string trim $::env($sc7f0_identity_env)] eq ""} {
            error "pinned build identity needs $sc7f0_identity_env together with SC7F0_GIT_HASH/SC7F0_BUILD_DATE"
        }
    }
    set pinned 1
}
if {$pinned} {
    set git_raw [string toupper [string trim $::env(SC7F0_GIT_HASH)]]
    set date_raw [string trim $::env(SC7F0_BUILD_DATE)]
    if {![regexp {^[0-9A-F]{8}$} $git_raw]} {error "SC7F0_GIT_HASH must be 8 hex digits, got '$git_raw'"}
    if {![regexp {^20[0-9]{2}(0[1-9]|1[0-2])(0[1-9]|[12][0-9]|3[01])$} $date_raw]} {
        error "SC7F0_BUILD_DATE must be YYYYMMDD, got '$date_raw'"
    }
    puts "   (GIT PINNED-BY-CALLER) Commit Hash: 0x$git_raw, Build Date: $date_raw"
} else {
    set git_raw [string toupper [exec git rev-parse --short=8 HEAD]]
    set date_raw [clock format [clock seconds] -format "%Y%m%d"]
    puts "   (GIT AUTO-INJECT) Commit Hash: 0x$git_raw, Build Date: $date_raw"
}
set git_commit_hex "32'h$git_raw"
set build_date_hex "32'h$date_raw"

add_files [glob ./rtl/*.v]
set_property top zu4ev_pcie_card_top [current_fileset]
# Full HDMI bring-up is a new hardware revision; debug04 remains unchanged.
if {!$debug_profile} {
    set hw_version 26102901
    if {[info exists ::env(SC7F0_VERSION)]} {set hw_version $::env(SC7F0_VERSION)}
    if {![regexp {^[0-9A-Fa-f]{8}$} $hw_version]} {error "Invalid SC7F0_VERSION"}
    set_property generic "C_VERSION=32'h$hw_version" [current_fileset]
    # The identity pin is honoured in both stages; SC7F0_ENABLE_VCU is refused
    # above for the debug profile, so a pinned identity can never be dropped.
    if {$pinned && [string toupper $hw_version] ne $git_raw} {
        # Not an error: C_VERSION and the GIT hash are different numbers. This
        # line only records that both came from the same pinned caller.
        puts " SC7F0 pinned identity: C_VERSION=32'h$hw_version GIT=32'h$git_raw DATE=32'h$date_raw"
    }
}

set verilog_defs [list GIT_COMMIT_HASH_DEF=$git_commit_hex BUILD_TIMESTAMP_DEF=$build_date_hex]
if {$debug_profile} {
    lappend verilog_defs SC7F0_DEBUG_ONLY=1
} else {
    # Production SC7F0 has only raw video, packet video and raw audio C2H.
    lappend verilog_defs SC7F0_C2H_ONLY=1
}
if {$display_enable} {
    lappend verilog_defs SC7F0_DISPLAY_TX=1
}
# SC7F0_TX_VIDEO_PRESENT is the shared guard for "a PS-DDR framebuffer source
# feeds v_hdmi_tx_ss", true for both TX personalities, so the HP1 read merge
# stage and the irq/status declarations exist in exactly one place instead of
# being duplicated per personality.
if {$display_enable || $rgb_enable} {
    lappend verilog_defs SC7F0_TX_VIDEO_PRESENT=1
}
if {$rgb_enable} {
    lappend verilog_defs SC7F0_RGB_COMPOSITOR=1
}
set_property verilog_define $verilog_defs [current_fileset]
set_property XPM_LIBRARIES {XPM_CDC XPM_FIFO XPM_MEMORY} [current_project]

# 2. Add only constraints for physically present ports in this profile.
if {$debug_profile} {
    add_files -fileset constrs_1 ./constraints/zu4ev_debug_pinout.xdc
} else {
    add_files -fileset constrs_1 ./constraints/zu4ev_pcie_pinout.xdc
    add_files -fileset constrs_1 ./constraints/sc7f0_capture_gray.xdc
    set_property USED_IN_SYNTHESIS false [get_files sc7f0_capture_gray.xdc]
    set_property PROCESSING_ORDER LATE [get_files sc7f0_capture_gray.xdc]
    # Named async IO exceptions, one port and one first-stage chain at a time
    # (see the file header). LATE + implementation-only, like the Gray file, so
    # the exception cannot be mistaken for a synthesis-time structural change.
    add_files -fileset constrs_1 ./constraints/sc7f0_async_io.xdc
    set_property USED_IN_SYNTHESIS false [get_files sc7f0_async_io.xdc]
    set_property PROCESSING_ORDER LATE [get_files sc7f0_async_io.xdc]
    # TX TMDS clock pads are profile-split, and the split is made HERE because a
    # mounted .xdc cannot carry the guard (the managed reader drops if/concat with a
    # warning only - see the block below).  The two capture-only false paths now live
    # in their own static file and are mounted for the capture personality only; the
    # RGB compositor profile gets no false path on those pads at all and instead gets
    # a forwarded-clock model from the PRE hook (scripts/
    # apply_sc7f0_tx_tmds_clock_forward.tcl), which errors out if a false path is
    # present on either pad.
    # The mount is split three ways, not two, and the third branch is the reason.
    # constraints/sc7f0_tx_tmds_clk_capture_only.xdc declares itself capture-only and
    # says a TX personality must re-review it, so mounting it for a profile that
    # DRIVES the TMDS clock (SC7F0_DISPLAY_TX builds v_hdmi_tx_ss + VPHY and owns
    # those pads) was never covered by the capture-only approval - the inherited
    # `else` reached it.  That case is now an explicit stop instead of a silent
    # waiver: a display-TX round must first get its own forwarded-clock review.
    if {$rgb_enable} {
        puts " SC7F0 TX TMDS clock: no false path mounted on hdmi_tx_tmds_clk_p/_n (TX-live profile); forwarded clock applied by the PRE hook"
    } elseif {$display_enable} {
        error "SC7F0_TX_TMDS_CLK_TX_PERSONALITY_UNREVIEWED: SC7F0_DISPLAY_TX drives the TMDS clock pads hdmi_tx_tmds_clk_p/_n, so the capture-only exception file constraints/sc7f0_tx_tmds_clk_capture_only.xdc (2 set_false_path -to rows, self-declared capture-personality-only) must not be mounted for it, and no forwarded-clock model has been reviewed for this profile either. The capture-only approval does not transfer to a TX personality: run scripts/apply_sc7f0_tx_tmds_clock_forward.tcl under review for this profile, or re-review the two false paths explicitly, before building SC7F0_DISPLAY_TX."
    } else {
        add_files -fileset constrs_1 ./constraints/sc7f0_tx_tmds_clk_capture_only.xdc
        set_property USED_IN_SYNTHESIS false [get_files sc7f0_tx_tmds_clk_capture_only.xdc]
        set_property PROCESSING_ORDER LATE [get_files sc7f0_tx_tmds_clk_capture_only.xdc]
        puts " SC7F0 TX TMDS clock: legacy capture-only exception file mounted (2 false paths, capture personality, unchanged behaviour)"
    }
    # Tcl control flow works in XDC (the restricted interpreter blocks file and network
    # access, not if/foreach); the rule here is that a run hook carries the flows that
    # need reports and files, while an XDC stays declarative plus its own endpoint guard.
    # CORRECTED, and the correction is measured rather than theorised: the
    # sentence above about if/foreach is wrong for the managed read_xdc reader.
    # Round rgb-fullimpl-26111333-20261113T204036Z, logs/build_full26111333.log
    #   :3796,:3797  [Designutils 20-1307] Command 'if' is not supported (in
    #                constraints/sc7f0_overlay_gray.xdc - its guard was skipped)
    #   :3800-:3802  [Designutils 20-1307] 'if' and 'concat' not supported
    #   :3803        [Common 17-1548] can't read "sc7f0_ovs_dst": no such variable
    #                (constraints/sc7f0_overlay_sync.xdc:104 - those three max
    #                delays were therefore never applied in that round)
    # A mounted .xdc may contain only declarative, reader-supported commands; a
    # control-flow construct is dropped with a CRITICAL WARNING and the run keeps
    # going, and a failed apply line becomes "no constraint" instead of a stop.
    # Whether the vendor's scoped xpm_cdc_gray constraint file attaches to a
    # hand-instantiated XPM, and where it sizes itself from, is still not established here;
    # what is established is that our own exceptions do apply and are measured.
    # Guarded / conditional application therefore lives in the full-Tcl PRE hook,
    # where `error` really aborts the implementation.
    set_property STEPS.OPT_DESIGN.TCL.PRE [file normalize scripts/impl_pre_opt_sc7f0.tcl] [get_runs impl_1]
    # The RGB overlay writer's three 32-bit Gray status counters (frames_done,
    # bytes written, dropped frames) cross mem_clk 300 MHz -> pcie_user_clk 125 MHz
    # inside rtl/sc7f0_overlay_writer.v as u_frames / u_beats / u_errf, and the three
    # hand-rolled single-bit synchronisers of the same path (writer epoch_sync_l[0]
    # and poison_sync[0], ingress sync0) cross pcie_user_clk 125 MHz ->
    # capture_clk_300m 300 MHz.  Neither set is mounted as a .xdc any more: their
    # guards need control flow, the managed reader drops control flow, and a dropped
    # guard leaves either no exception at all or - if -from/-to resolve empty - a
    # device-wide exception that silently un-times the rest of the design while
    # reporting a clean route.  scripts/apply_sc7f0_overlay_cdc.tcl (reached from
    # STEPS.OPT_DESIGN.TCL.PRE = scripts/impl_pre_opt_sc7f0.tcl, which still runs
    # scripts/check_sc7f0_capture_gray.tcl first, unchanged) applies both sets under
    # real 3x32 / 1+1+1 object guards, with the same 3.333 ns numbers, before
    # opt_design; scripts/check_sc7f0_overlay_gray.tcl and
    # scripts/check_sc7f0_overlay_sync.tcl then re-measure them on the routed netlist
    # and fail closed.  No false path, clock group, multicycle or lowered clock is
    # introduced anywhere here, and no review verdict is written.
    if {$rgb_enable} {
        puts " SC7F0 overlay crossings: applied by the full-Tcl implementation PRE hook (no .xdc mount, guards are live)"
    }
}

# 2.1 Generate ZU4EV Processing System Subsystem (zu4ev_ps_bd)
puts "Generating ZU4EV Processing System Subsystem (zu4ev_ps_bd)..."
source ./scripts/create_zu4ev_ps_bd.tcl
if {$vcu_enable} {
    # Slim memory interconnect (axi_crossbar + axi_dwidth_converter), the style
    # measured for Todo 1.2b. Without this branch the call below stays the
    # original two-argument form, so the VCU-off build is bit-for-bit identical.
    create_zu4ev_ps_bd [expr {!$debug_profile}] 1 "xbar" $display_enable $rgb_enable
} else {
    create_zu4ev_ps_bd [expr {!$debug_profile}] 0 "" $display_enable $rgb_enable
}
generate_target all [get_files zu4ev_ps_bd.bd]
set bd_wrapper [make_wrapper -files [get_files zu4ev_ps_bd.bd] -top]
add_files -norecurse $bd_wrapper

# 3. Generate UltraScale+ PCIe Core with Tandem PCIe (Gen3 x4, 256-bit, Quad 223)
puts "Generating UltraScale+ PCIe IP Core (pcie4_uscale_plus_0 - Gen3 x4, 256-bit, Tandem PCIe)..."
create_ip -name pcie4_uscale_plus -vendor xilinx.com -library ip -version 1.3 -module_name pcie4_uscale_plus_0

set_property -dict [list \
  CONFIG.mode_selection {Advanced} \
  CONFIG.en_gt_selection {true} \
  CONFIG.select_quad {GTH_Quad_223} \
  CONFIG.pcie_blk_locn {X0Y1} \
  CONFIG.mcap_enablement {None} \
  CONFIG.PL_LINK_CAP_MAX_LINK_SPEED {8.0_GT/s} \
  CONFIG.PL_LINK_CAP_MAX_LINK_WIDTH {X4} \
  CONFIG.axisten_if_width {256_bit} \
  CONFIG.AXISTEN_IF_CQ_ALIGNMENT_MODE {DWORD_Aligned} \
  CONFIG.AXISTEN_IF_RQ_ALIGNMENT_MODE {DWORD_Aligned} \
  CONFIG.axisten_if_enable_client_tag {true} \
  CONFIG.AXISTEN_IF_RC_STRADDLE {false} \
  CONFIG.PL_DISABLE_LANE_REVERSAL {FALSE} \
  CONFIG.vendor_id {12AB} \
  CONFIG.PF0_DEVICE_ID {E380} \
  CONFIG.PF0_SUBSYSTEM_VENDOR_ID {12AB} \
  CONFIG.PF0_SUBSYSTEM_ID {0007} \
  CONFIG.pf0_bar0_64bit {false} \
  CONFIG.pf0_bar0_scale {Megabytes} \
  CONFIG.pf0_bar0_size {1} \
  CONFIG.pf0_bar1_enabled {true} \
  CONFIG.pf0_bar1_64bit {false} \
  CONFIG.pf0_bar1_scale {Kilobytes} \
  CONFIG.pf0_bar1_size {64} \
  CONFIG.pf0_msi_enabled {true} \
] [get_ips pcie4_uscale_plus_0]

# The RQ encoder/RC decoder own tag allocation (0, 1, 2..17, 0x20) and
# parse one unstraddled RC completion at a time. PG213's default core tag
# management overwrites the RQ tag; its RC straddle mode can put two
# completions into a beat. Either default silently breaks H2C routing.
foreach {property expected} {
    CONFIG.axisten_if_enable_client_tag true
    CONFIG.AXISTEN_IF_RC_STRADDLE false
} {
    set actual [get_property $property [get_ips pcie4_uscale_plus_0]]
    if {![string equal -nocase $actual $expected]} {
        error "PCIe IP $property=$actual, expected $expected for rq_tx_encoder/rc_rx_decoder"
    }
}

generate_target all [get_ips pcie4_uscale_plus_0]

# Debug-only TPG. No generated TPG IP in the production RX-only card.
if {$debug_profile} {
# 4. Generate Video Test Pattern Generator IP Core (v_tpg_0)
puts "Generating Video TPG IP Core (v_tpg_0 - 4 PPC 4K60)..."
create_ip -name v_tpg -vendor xilinx.com -library ip -version 8.2 -module_name v_tpg_0

set_property -dict [list \
  CONFIG.SAMPLES_PER_CLOCK {4} \
  CONFIG.MAX_DATA_WIDTH {8} \
  CONFIG.MAX_COLS {4096} \
  CONFIG.MAX_ROWS {2160} \
] [get_ips v_tpg_0]

generate_target all [get_ips v_tpg_0]
}

# 5. Generate AXI Crossbar IP Core (axi_crossbar_0 - 1x4)
puts "Generating AXI Crossbar IP Core (axi_crossbar_0 - 1x4)..."
create_ip -name axi_crossbar -vendor xilinx.com -library ip -version 2.1 -module_name axi_crossbar_0

set_property -dict [list \
  CONFIG.NUM_SI {1} \
  CONFIG.NUM_MI {4} \
  CONFIG.PROTOCOL {AXI4LITE} \
  CONFIG.DATA_WIDTH {32} \
  CONFIG.ADDR_WIDTH {32} \
  CONFIG.M00_A00_BASE_ADDR {0x0000000000000000} \
  CONFIG.M00_A00_ADDR_WIDTH {12} \
  CONFIG.M01_A00_BASE_ADDR {0x0000000000001000} \
  CONFIG.M01_A00_ADDR_WIDTH {12} \
  CONFIG.M02_A00_BASE_ADDR {0x0000000000002000} \
  CONFIG.M02_A00_ADDR_WIDTH {12} \
  CONFIG.M03_A00_BASE_ADDR {0x0000000000003000} \
  CONFIG.M03_A00_ADDR_WIDTH {12} \
] [get_ips axi_crossbar_0]

generate_target all [get_ips axi_crossbar_0]

# 5.1 Generate AXI Clock Converter IP Core (axi_clock_converter_0)
puts "Generating AXI Clock Converter IP Core (axi_clock_converter_0)..."
create_ip -name axi_clock_converter -vendor xilinx.com -library ip -version 2.1 -module_name axi_clock_converter_0
set_property -dict [list \
  CONFIG.PROTOCOL {AXI4LITE} \
  CONFIG.DATA_WIDTH {32} \
  CONFIG.ADDR_WIDTH {32} \
  CONFIG.ID_WIDTH {0} \
  CONFIG.AWUSER_WIDTH {0} \
  CONFIG.ARUSER_WIDTH {0} \
  CONFIG.WUSER_WIDTH {0} \
  CONFIG.RUSER_WIDTH {0} \
  CONFIG.BUSER_WIDTH {0} \
] [get_ips axi_clock_converter_0]
generate_target all [get_ips axi_clock_converter_0]

# PS HPM0_FPD is full AXI4 (16-bit transaction IDs), not AXI4-Lite.
# Preserve AXI4 ID, burst, and last semantics when reaching the shared
# PS/PCIe AXI-Lite BAR0 crossbar; tying RID/BID to zero wedges PS requests.
create_ip -name axi_protocol_converter -vendor xilinx.com -library ip -version 2.1 -module_name axi_protocol_converter_0
set_property -dict [list \
  CONFIG.SI_PROTOCOL {AXI4} \
  CONFIG.MI_PROTOCOL {AXI4LITE} \
  CONFIG.ADDR_WIDTH {32} \
  CONFIG.DATA_WIDTH {32} \
  CONFIG.ID_WIDTH {16} \
] [get_ips axi_protocol_converter_0]
generate_target all [get_ips axi_protocol_converter_0]

# 5.2 Generate AXI Crossbar IP Core for BAR0 / PS Arbiter (axi_crossbar_1 - 2x3)
# M00 (0x000-0xFFF): axil_reg_space (DMA regs, PS+PCIe shared)
# M01 (0x1000-0x1FFF): zzlab_env_ctrl (version/platform, PS+PCIe shared)
# M02 (0x2000-0x3FFF): dedicated debug BRAM mailbox
puts "Generating AXI Crossbar IP Core (axi_crossbar_1 - 2x3)..."
source ./scripts/create_bar0_crossbar.tcl
create_qpcie_bar0_crossbar

# 5.3 Generate AXI-Stream Clock Converter IP Core (axis_clock_converter_0 - 128-bit)
puts "Generating AXI-Stream Clock Converter IP Core (axis_clock_converter_0)..."
create_ip -name axis_clock_converter -vendor xilinx.com -library ip -version 1.1 -module_name axis_clock_converter_0
set_property -dict [list \
  CONFIG.TDATA_NUM_BYTES {16} \
  CONFIG.HAS_TKEEP {1} \
  CONFIG.HAS_TLAST {1} \
  CONFIG.TUSER_WIDTH {85} \
] [get_ips axis_clock_converter_0]
generate_target all [get_ips axis_clock_converter_0]

# 5.4 Generate Processor System Reset IP Core (proc_sys_reset_0)
puts "Generating Processor System Reset IP Core (proc_sys_reset_0)..."
create_ip -name proc_sys_reset -vendor xilinx.com -library ip -version 5.0 -module_name proc_sys_reset_0
generate_target all [get_ips proc_sys_reset_0]

# No ILA in this design: reclaim the former 4096-sample capture memory.
# Management/debug mailbox is retained; it is unrelated to on-chip ILA.

if {!$debug_profile} {
# PS HPM1 control aperture. All three IP register banks run on pl_clk0.
source ./scripts/create_sc7f0_hdmi_crossbar.tcl
create_sc7f0_hdmi_crossbar [expr {$rgb_enable ? 2 : 0}]
if {!$rgb_enable} {
# 6. Generate Video PHY Controller IP Core (vid_phy_controller_0 - Quad 226 HDMI RX/TX)
puts "Generating Video PHY Controller IP Core (vid_phy_controller_0)..."
create_ip -name vid_phy_controller -vendor xilinx.com -library ip -version 2.2 -module_name vid_phy_controller_0

set_property -dict [list \
  CONFIG.Adv_Clk_Mode {true} \
  CONFIG.CHANNEL_ENABLE {X0Y12 X0Y13 X0Y14} \
  CONFIG.CHANNEL_SITE {X0Y12} \
  CONFIG.C_INPUT_PIXELS_PER_CLOCK {4} \
  CONFIG.C_INT_HDMI_VER_CMPTBLE {3} \
  CONFIG.C_NIDRU {true} \
  CONFIG.C_NIDRU_REFCLK_SEL {3} \
  CONFIG.C_RX_PLL_SELECTION {0} \
  CONFIG.C_RX_REFCLK_SEL {1} \
  CONFIG.C_Rx_Protocol {HDMI} \
  CONFIG.C_TX_PLL_SELECTION {6} \
  CONFIG.C_TX_REFCLK_SEL {0} \
  CONFIG.C_Tx_Protocol {HDMI} \
  CONFIG.C_Txrefclk_Rdy_Invert {true} \
  CONFIG.C_Use_Oddr_for_Tmds_Clkout {true} \
  CONFIG.Rx_GT_Line_Rate {5.94} \
  CONFIG.Rx_GT_Ref_Clock_Freq {297} \
  CONFIG.Tx_GT_Line_Rate {5.94} \
  CONFIG.Tx_GT_Ref_Clock_Freq {297} \
] [get_ips vid_phy_controller_0]

generate_target all [get_ips vid_phy_controller_0]

# 7. Generate HDMI RX Subsystem IP Core (v_hdmi_rx_ss_0 - 4 PPC)
puts "Generating HDMI RX Subsystem IP Core (v_hdmi_rx_ss_0 - 4 PPC)..."
create_ip -name v_hdmi_rx_ss -vendor xilinx.com -library ip -version 3.2 -module_name v_hdmi_rx_ss_0

set_property -dict [list \
  CONFIG.C_INPUT_PIXELS_PER_CLOCK {4} \
  CONFIG.C_MAX_BITS_PER_COMPONENT {8} \
  CONFIG.C_VID_INTERFACE {0} \
  CONFIG.C_INCLUDE_LOW_RESO_VID {true} \
  CONFIG.C_INCLUDE_YUV420_SUP {true} \
  CONFIG.C_HDMI_FAST_SWITCH {true} \
  CONFIG.C_EXDES_TX_PLL_SELECTION {6} \
  CONFIG.C_EXDES_RX_PLL_SELECTION {0} \
  CONFIG.C_EXDES_NIDRU {true} \
] [get_ips v_hdmi_rx_ss_0]

generate_target all [get_ips v_hdmi_rx_ss_0]
}

# SC7F0-RGB-COMPOSITOR-2PPC geometry.  Separate generated modules on purpose:
# the published 4 PPC names are frozen, so the 2 PPC personality gets
# vid_phy_controller_rgb / v_hdmi_rx_ss_rgb / v_hdmi_tx_ss_rgb and
# sc7f0_frmbuf_rd_rgb (2 PPC RGBA8888, native 128-bit AXIMM, no width
# converter).  scripts/create_sc7f0_rgb_compositor_ip.tcl reads every geometry
# back out of the IP and errors out instead of building a wrong shape.
if {$rgb_enable} {
    source ./scripts/create_sc7f0_rgb_compositor_ip.tcl
    create_sc7f0_vid_phy_ip_rgb
    create_sc7f0_hdmi_rx_ip_rgb
    create_sc7f0_hdmi_tx_ip_rgb
    create_sc7f0_frmbuf_rd_rgb_ip
}

# No HDMI TX subsystem: shared PHY RX/TX clocking is intentionally retained.
# Its former control aperture is a bounded DECERR responder.

# Official PS V4L2 capture pipeline, independent of the raw PCIe branch.
source scripts/create_sc7f0_frmbuf_ip.tcl
create_sc7f0_frmbuf_ip
source scripts/create_sc7f0_vpss_csc_ip.tcl
create_sc7f0_vpss_csc_ip

# Display branch IP, only when the personality asks for it. The two procs and
# their geometry guards live in their own files and were previously sourced by
# nobody; the module names are fixed because rtl/zu4ev_pcie_card_top.v and
# rtl/sc7f0_display_pipeline.v instantiate exactly those names.
if {$display_enable} {
    source ./scripts/create_sc7f0_hdmi_tx_ip.tcl
    create_sc7f0_hdmi_tx_ip
    source ./scripts/create_sc7f0_frmbuf_rd_ip.tcl
    # Native RGB8/BGR8 (96-bit AXIS, 3 components) plus NV12 for the later
    # capture -> PS DDR -> TX step. Alpha stays off: v_frmbuf_rd 2.5 has no
    # HAS_ARGB8 and any alpha format forces NUM_VIDEO_COMPONENTS=4, i.e. a
    # 128-bit AXIS that neither the 96-bit VIDEO_IN of v_hdmi_tx_ss_0 nor
    # rtl/sc7f0_hdmi_tx_mux.v can accept.
    create_sc7f0_frmbuf_rd_ip 0
}
}

# 9. Update Compile Order
update_compile_order -fileset sources_1
if {$build_stage eq "ip"} {
    puts "IP_GENERATION_COMPLETE: $project_dir (not a bitstream or release)"
    close_project
    exit 0
}

# IP cache disable
config_ip_cache -disable_cache

puts "Starting Synthesis (synth_1)..."
launch_runs synth_1 -jobs 16
wait_on_run synth_1

if {[get_property PROGRESS [get_runs synth_1]] != "100%" ||
    [string first "ERROR" [get_property STATUS [get_runs synth_1]]] >= 0} {
    puts "ERROR: Synthesis failed for ZU4EV top module!"
    exit 1
}

if {$build_stage eq "synth"} {
    puts "SYNTHESIS_COMPLETE: $project_dir (not a bitstream or release)"
    close_project
    exit 0
}
# Implementation effort knobs, all opt-in: unset keeps the published default
# flow (Vivado Implementation Defaults, Default directives) exactly as every
# archived round ran it.  Same proc, same legal-value vocabulary and same
# SC7F0_TIMING_TUNED read-back line as scripts/impl_sc7f0_dual_video.tcl:430-470,
# because that flow already measured that the 300 MHz capture group here is a
# placement/routing-margin problem (route ~70-78 % of an 8-13 level path), not a
# logic-depth problem - docs/sc7f0_coherent_release_26111204.md:30,36 records the
# combination PLACE=Explore PHYS_OPT=AggressiveExplore ROUTE=Explore
# POST_ROUTE_PHYS_OPT=AggressiveExplore taking that group to 0 failing endpoints
# on this part.  Nothing here relaxes a requirement: the clocks, the exceptions
# and the WNS>=0/TNS=0/hold gate are untouched.
proc sc7f0_set_directive {run step prop allowed env} {
    if {![info exists ::env($env)]} {return}
    set d [string tolower [string trim $::env($env)]]
    set hit ""
    foreach a $allowed {
        if {[string tolower $a] eq $d} {set hit $a}
    }
    if {$hit eq ""} {
        error "$env must be one of: $allowed (got '$::env($env)')"
    }
    set_property $prop $hit $run
    puts "SC7F0_TIMING_TUNED $step $prop = $hit readback=[get_property $prop $run]"
}
set sc7f0_impl_run [get_runs impl_1]
sc7f0_set_directive $sc7f0_impl_run opt_design      STEPS.OPT_DESIGN.ARGS.DIRECTIVE \
    {Default Explore ExploreArea ExploreSequentialArea ExploreWithRemap RuntimeOptimized} SC7F0_OPT_DIRECTIVE
sc7f0_set_directive $sc7f0_impl_run place_design    STEPS.PLACE_DESIGN.ARGS.DIRECTIVE \
    {Default Explore ExtraTimingOpt ExtraNetDelay_high ExtraNetDelay_low ExtraPostPlacementOpt EarlyBlockPlacement Quick} SC7F0_PLACE_DIRECTIVE
sc7f0_set_directive $sc7f0_impl_run phys_opt_design STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE \
    {Default Explore ExploreWithHoldFix AggressiveExplore AlternateReplication AggressiveFanoutOpt AddRetime AlternateFlowWithRetiming} SC7F0_PHYS_OPT_DIRECTIVE
sc7f0_set_directive $sc7f0_impl_run route_design    STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE \
    {Default Explore NoTimingRelaxation MoreGlobalIterations HigherDelayCost AdvancedSkewModeling AlternateCLBRouting} SC7F0_ROUTE_DIRECTIVE
if {[info exists ::env(SC7F0_POST_ROUTE_PHYS_OPT)] && $::env(SC7F0_POST_ROUTE_PHYS_OPT) ne ""} {
    set sc7f0_prpo [string tolower [string trim $::env(SC7F0_POST_ROUTE_PHYS_OPT)]]
    set sc7f0_prpo_ok ""
    foreach a {Default Explore AggressiveExplore AddRetime ExploreWithAggressiveHoldFix} {
        if {[string tolower $a] eq $sc7f0_prpo} {set sc7f0_prpo_ok $a}
    }
    if {$sc7f0_prpo_ok eq ""} {
        error "SC7F0_POST_ROUTE_PHYS_OPT must be one of: Default Explore AggressiveExplore AddRetime ExploreWithAggressiveHoldFix (got '$::env(SC7F0_POST_ROUTE_PHYS_OPT)')"
    }
    set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true $sc7f0_impl_run
    set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.DIRECTIVE $sc7f0_prpo_ok $sc7f0_impl_run
    puts "SC7F0_TIMING_TUNED post_route_phys_opt_design DIRECTIVE = $sc7f0_prpo_ok"
}

puts "Starting Implementation & Bitstream Generation (impl_1)..."
launch_runs impl_1 -to_step write_bitstream -jobs 16
wait_on_run impl_1

if {[get_property PROGRESS [get_runs impl_1]] != "100%" ||
    [string first "ERROR" [get_property STATUS [get_runs impl_1]]] >= 0} {
    puts "ERROR: Implementation failed for ZU4EV top module!"
    exit 1
}

open_run impl_1
set impl_dir [get_property DIRECTORY [get_runs impl_1]]
set probes_out "$impl_dir/zu4ev_pcie_card_top.ltx"
if {[llength [get_debug_cores -quiet]]} {
    write_debug_probes -force $probes_out
    puts " Debug probes: $probes_out"
} else {
    puts " No ILA/debug cores; no LTX export required."
}
puts "================================================================="
puts " SUCCESS: ZU4EV Tandem PCIe Bitstreams Built (12AB:E380)!"
puts " Output Bitstreams in $impl_dir:"
foreach f [glob -nocomplain "$impl_dir/*.bit"] {
    set size [file size $f]
    puts "  [file tail $f] : $size bytes"
}
puts "================================================================="

# Layer A + Layer B evidence chain, one producer for every profile that reaches
# this entry: scripts/report_sc7f0_implementation_evidence.tcl writes DRC, the
# exception audit (coverage / all / ignored / scope_override / summary), io,
# clock-interaction, clock-networks, the user-disabled-arc list, the hierarchical
# utilization report, and the routed timing_summary / check-timing / cdc /
# methodology / bus-skew set that used to be written inline here, and then sources
# scripts/check_sc7f0_named_constraints.tcl to write the Layer B coverage manifest
# bound to this round's cdc.rpt.  One producer, so no report is taken twice and no
# flag drifts between the two paths.
#
# It replaces nothing that used to work: this flow used to write the six reports
# above and nothing else, so check_sc7f0_timing.py below answered every RGB round
# with "missing DRC report" plus six "Layer B evidence report ... was never
# produced", and no RGB route could produce named-exception coverage at all (the
# only producer lived in scripts/impl_sc7f0_dual_video.tcl:571-598, and its driver
# scripts/build_sc7f0_dual_video_hw.sh:119 pins SC7F0_PROFILE=full).  The legacy
# full-profile script is deliberately left exactly as it was, so old rounds and new
# rounds keep the same reference order.
set ::env(SC7F0_REPORT_DIR) [file normalize $project_dir]
source ./scripts/report_sc7f0_implementation_evidence.tcl
if {$rgb_enable} {
    # Routed re-check of the writer's Gray crossings, on this round's netlist.  It
    # errors out (no XSA) if the named max-delay is not what is really in force.
    source ./scripts/check_sc7f0_overlay_gray.tcl
    # Same discipline for the three hand-rolled 125 -> 300 MHz single-bit
    # synchronisers named by constraints/sc7f0_overlay_sync.xdc (writer
    # epoch_sync_l[0]/poison_sync[0], ingress sync0): the crossing must still be
    # TIMED (so a false path or a clock group cannot satisfy it), its observed
    # source/destination clocks must really be pcie_user_clk -> capture_clk_300m,
    # and the requirement in force must really be 3.333 ns.  It approves no CDC
    # policy and adds no Layer B ledger entry: the three rows this exception owns
    # in scripts/check_sc7f0_named_constraints.tcl's max_delay_table are
    # measurement producers only, scripts/gates/*.json carries no REVIEWED_SAFE
    # entry for them, and adding those rows also required the hook's stub fixture
    # to answer 3.333 for the named pairs (scripts/tests/fixtures/
    # named_constraints_stub.tcl) - registering an item without its measurement
    # fixture is how six test_sc7f0_evidence_hook cases failed in an earlier
    # attempt at this, which is why the fixture and the rows land together.
    #
    # Round H runs the r2 revision of that re-check, and the reason is measured
    # rather than stylistic: the earlier revision grades EVERY path that ends at a
    # first-stage cell against pcie_user_clk, but `get_timing_paths -to <cell>`
    # also answers with the recovery/removal arcs of that flop's asynchronous
    # preset and clear pins.  Round G died exactly there, after bitgen, with
    #   logs/build_full26111402.log: FULL_TCL_ERROR=SC7F0_OVERLAY_SYNC_SOURCE_DOMAIN
    #     epoch: a launch into the first stage starts in 'capture_clk_300m'
    #     (u_dp_mem_reset/u_final/arststages_ff_reg[3]/C), expected pcie_user_clk
    #   -> SC7F0_FULL_TCL_FAILED, runner exit non-zero, no XSA exported.
    # That startpoint is a 300 MHz reset-synchroniser leg arriving at the epoch
    # flop's clear pin; it is not a data launch and grading it as one is a check
    # that fails on valid hardware.  scripts/check_sc7f0_overlay_sync_r2.tcl keeps
    # every assertion fail-closed but separates the two classes (data launches from
    # the D pin's own exhaustive fan-in; control/reset arcs reported, still required
    # to stay TIMED, never graded against the 125 MHz domain), and it now also
    # ASSERTS the ASYNC_REG value that scripts/apply_sc7f0_overlay_cdc.tcl writes on
    # the four synchroniser flops, and grades the three writer Gray words on the
    # bound/actual/skew/violation quadruple of the tool's own bus-skew report.
    # Same hook order, same requirements, same gate: nothing here widens an
    # exception, and scripts/gates/*.json still carries no REVIEWED_SAFE entry.
    source ./scripts/check_sc7f0_overlay_sync_r2.tcl
}
# A generated .bit is NOT a release. Refuse XSA export on an invalid
# whole-design clock/CDC/setup/hold/skew model, even if BRAM timing passes.
# This applies to the full HDMI profile as well: the added RX/TX/PHY clock
# domains are exactly where an unreviewed crossing would be most dangerous.
if {[catch {exec python3 ./scripts/check_sc7f0_timing.py $project_dir} gate_result]} {
    puts "ERROR: $profile-profile timing gate failed; XSA NOT exported."
    puts $gate_result
    exit 2
}
puts $gate_result

set xsa_out "./hw_platform/sc7f0_base.xsa"
if {!$debug_profile} {
    set xsa_out "./hw_platform/sc7f0_hdmi.xsa"
}
if {$vcu_enable} {
    set xsa_out "./hw_platform/sc7f0_hdmi_vcu.xsa"
}
if {$display_enable} {
    set xsa_out "./hw_platform/sc7f0_hdmi_display.xsa"
}
if {$rgb_enable} {
    set xsa_out "./hw_platform/sc7f0_rgb_compositor.xsa"
}
if {[info exists ::env(SC7F0_XSA_OUT)]} {set xsa_out $::env(SC7F0_XSA_OUT)}
file mkdir [file dirname $xsa_out]
puts "Exporting updated Hardware Platform XSA ($xsa_out)..."
write_hw_platform -fixed -include_bit -force $xsa_out
puts " SUCCESS: Hardware Platform XSA exported to $xsa_out"

close_project
exit 0
