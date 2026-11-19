# =============================================================================
# scripts/impl_pre_opt_sc7f0.tcl
#
# One implementation PRE hook, because STEPS.OPT_DESIGN.TCL.PRE holds exactly one
# script.  It preserves what used to be mounted directly and adds the guarded
# application of the RGB overlay crossings:
#
#   1. scripts/check_sc7f0_capture_gray.tcl - byte-for-byte the previous value of
#      STEPS.OPT_DESIGN.TCL.PRE (scripts/build_zu4ev.tcl used to name that file
#      itself).  It checks the 64+64 u_ps_capture Gray endpoints against the
#      6.000 ns exception that constraints/sc7f0_capture_gray.xdc applies with
#      reader-supported static commands only.  It is not modified, not reordered
#      and not skipped for any profile.
#   2. scripts/apply_sc7f0_overlay_cdc.tcl - SC7F0-RGB only.  Applies the overlay
#      writer Gray counters and the three 125 -> 300 MHz synchroniser max delays
#      under real guards, and verifies the engine took them.  This moved out of
#      the managed XDC reader after round
#      rgb-fullimpl-26111333-20261113T204036Z proved that reader drops `if`,
#      `concat` and everything similar with a CRITICAL WARNING and keeps going
#      (logs/build_full26111333.log:3796-3804), i.e. a guard written in XDC is not
#      a guard and a failed apply line is silently "no constraint".
#   3. scripts/apply_sc7f0_tx_io_first_stage.tcl - SC7F0-RGB only, added for
#      round 26111401.  Names the three HDMI TX input first stages that the TX
#      subsystem owns (DDC glitch filters + HPD capture chain).  Candidate E
#      failed Layer B on exactly those three unclaimed loads
#      (E/evidence-r3-finaldcp/reports/named-constraint-evidence.json,
#      E/logs/runner_post_r3.log:218-260) because constraints/sc7f0_async_io.xdc
#      :60-71 was written for the capture-only personality, where the TX SS is
#      not built.  Profile-conditional, so it cannot live in the managed reader:
#      a row whose -to resolves empty is not absent, it is a port-wide false path.
#
#   4. scripts/apply_sc7f0_tx_tmds_clock_forward.tcl - SC7F0-RGB only, added for the
#      TX-live round.  hdmi_tx_tmds_clk_p/_n are the VPHY forwarded TMDS clock
#      (MMCM CLKOUT1 -> OSERDESE3 in ODDR mode -> OBUFTDS -> the differential pad
#      pair), not asynchronous data, so they are now MODELLED with
#      create_generated_clock -divide_by 1 anchored on the real forwarder CLK pin
#      instead of being excepted as data.  The two legacy `set_false_path -to` lines
#      are physically gone from constraints/sc7f0_async_io.xdc and are mounted only
#      for the capture profile from constraints/
#      sc7f0_tx_tmds_clk_capture_only.xdc (scripts/build_zu4ev.tcl); this helper
#      refuses to run while such a false path exists on either pad, so the RGB
#      profile cannot silently keep both.  No set_output_delay, no clock group, no
#      lowered period, no invented board number.
#
# Every half runs after XDC import and before opt_design, so every exception and
# clock definition is in force for placement and routing; every one of them `error`s
# out, which stops the run instead of degrading to a warning.
# =============================================================================
# Path discipline: an implementation step runs with its working directory set to
# the run directory, and STEPS.OPT_DESIGN.TCL.PRE is stored as the absolute path
# of THIS file, so a relative "source ./scripts/..." here would look inside the
# run directory.  Resolve siblings from the directory this file actually lives in.
set sc7f0_impl_pre_dir [file normalize [file dirname [info script]]]
if {![file isdirectory $sc7f0_impl_pre_dir]} {
    error "SC7F0_IMPL_PRE_BAD_DIR [file dirname [info script]]"
}
source [file join $sc7f0_impl_pre_dir check_sc7f0_capture_gray.tcl]
if {[info exists ::env(SC7F0_RGB_COMPOSITOR)] &&
    [string tolower [string trim $::env(SC7F0_RGB_COMPOSITOR)]] in {1 true yes}} {
    if {[llength [get_cells -quiet -hier -regexp {.*u_overlay_writer/.*}]] > 0} {
        source [file join $sc7f0_impl_pre_dir apply_sc7f0_overlay_cdc.tcl]
    } else {
        set arm_src [get_cells -quiet -hier -regexp {.*u_overlay_ingress/arm_toggle_reg}]
        set arm_dst [get_pins -quiet -hier -regexp {.*u_overlay_ingress/sync0_reg/D}]
        if {[llength $arm_src] > 0 && [llength $arm_dst] > 0} {
            set_max_delay -datapath_only 3.333 -from $arm_src -to $arm_dst
        }
        puts "SC7F0_OVERLAY_CDC_APPLY_SKIPPED direct pull-mode overlay active (no u_overlay_writer; ingress arm CDC applied)"
    }
    source [file join $sc7f0_impl_pre_dir apply_sc7f0_tx_io_first_stage.tcl]
    source [file join $sc7f0_impl_pre_dir apply_sc7f0_tx_tmds_clock_forward.tcl]
} else {
    puts "SC7F0_OVERLAY_CDC_APPLY_SKIPPED profile without SC7F0_RGB_COMPOSITOR"
    puts "SC7F0_TX_IO_FIRST_STAGE_APPLY_SKIPPED profile without SC7F0_RGB_COMPOSITOR"
    puts "SC7F0_TX_TMDSCLOCK_FORWARD_APPLY_SKIPPED profile without SC7F0_RGB_COMPOSITOR (capture personality keeps constraints/sc7f0_tx_tmds_clk_capture_only.xdc)"
}
