# tclsh harness: run scripts/check_sc7f0_named_constraints.tcl against stubbed
# Vivado commands so its control flow, object handling and JSON writer can be
# validated without a design.  Not part of the build; driven by
# scripts/tests/test_sc7f0_evidence_hook.py and
# scripts/tests/test_sc7f0_two_layer_gates.py.
#
# The mocks model the two things the real tool does that a naive stub gets
# wrong, and which caused round 26111202 T1:
#
#   * a collection answers a property query with ONE VALUE PER OBJECT; a stub
#     that answers a single value for a three-object collection hides the length
#     mismatch the hook now reports,
#   * `all_fanout` returns pins, and `all_fanout -only_cells` returns cells; the
#     pin -> cell step is a documented query and is what the pad-closure count
#     depends on.
#
# SC7F0_STUB_SCENARIO selects a counterexample (see the test module):
#   clean                  every query answers (default)
#   pad_zero_sequential    fanout yields endpoints but no cells        (T1)
#   newline_error          a query fails with raw LF / CR / quote / slash (T2)
#   no_return_string       -return_string unsupported, scratch fallback (T3)
#   bus_skew_root_missing  the named bus skew root is absent           (T4)
#   bus_skew_bad_signature report_bus_skew only accepts -from (as 26111202)
#   empty_design_state     no report carries a Design State header      (T5)
#   placed_design_state    reports say Placed                            (T5)
#   zero_objects           every object query resolves to nothing
#   clock_pin_load         the pad's first stage lands on an async pin
#   real_routed_shape      property queries answer exactly as the routed 26111202
#                          checkpoint did, including one unset value on one object
#   short_property_result  a collection answer is shorter than the collection
#   coverage_no_header     report_exceptions -coverage has no column header
#   coverage_blank_from    the exception's -from side names no pins
set scenario {clean}
if {[info exists ::env(SC7F0_STUB_SCENARIO)]} {set scenario $::env(SC7F0_STUB_SCENARIO)}
set fixture_dir [file normalize [file dirname [file normalize [info script]]]]

# The report directory is the temp directory the test created; falling back to
# the OS temp dir keeps a manual run from writing into the repository.
if {[info exists ::env(SC7F0_REPORT_DIR)] && $::env(SC7F0_REPORT_DIR) ne ""} {
    set dir [file normalize $::env(SC7F0_REPORT_DIR)]
} else {
    set tmp {}
    if {[info exists ::env(TMPDIR)]} {set tmp $::env(TMPDIR)}
    if {$tmp eq ""} {set tmp /tmp}
    set dir [file join $tmp sc7f0-hook-stub-[pid]]
}
file mkdir $dir
set ::env(SC7F0_REPORT_DIR) $dir

proc write {name text} {
    set fh [open [file join $::dir $name] w]
    puts $fh $text
    close $fh
}

# ---------------------------------------------------------------------------
# reports the hook reads (round binding + design state)
# ---------------------------------------------------------------------------
write cdc.rpt "CDC-3 Info 1 x\n"
# Verbatim column header and rows taken from a real 2023.2 report_exceptions
# -coverage table, so the hook's column parser sees the alignment the tool
# actually produces instead of a stub that happens to have nine tokens.
set coverage_header {Position  Type                     Setup            Hold             From       Through    To         Endpoints  From (%)  Through (%)  To (%)}
set coverage_row {217       Max Delay Datapath Only  max_dpo=6        -                64 cells              64 cells   64         100.00                 33.33}
set coverage_row_blank_from {221       False Path               false            false                                  2 ports    2                                 100.00}
# One internal async entry, as the tool really prints it (shape copied from
# build/vcu-release-26111202-r1/fpga/project/exceptions-coverage.rpt row 6/7, the
# probe crossings of a future round answer with 1 cell on each side).
set coverage_row_probe {245       False Path               false            false            1 cell                1 cell     1          100.00                 100.00}
# An output-direction exception: `set_false_path -to <port>` has no -from column at
# all (shape copied from exceptions-coverage.rpt rows 3/4 of round 26111202).
set coverage_row_pad {248       False Path               false            false                                  1 port     1                                 100.00}

write exceptions-coverage.rpt "$coverage_header\n$coverage_row\n$coverage_row_blank_from\n"
write exceptions-ignored.rpt "Positions fully ignored: 0\n"
write exceptions-scope-override.rpt "Positions overridden: 0\n"
write clock_networks.rpt "aclk_dpram 0\n"
write io.rpt "Port  Direction  Site\nhdmi_tx_hpd_in  IN  IOB_X0Y180\n"
set state {Physopt postRoute}
if {$scenario eq {empty_design_state}} {set state {}}
if {$scenario eq {placed_design_state}} {set state {Placed}}
set header ""
if {$state ne ""} {set header "| Design State      : $state\n"}
write timing_summary.rpt "| Tool Version : Vivado v.2023.2 (lin64)\n$header"
write check-timing.rpt "1. checking no_clock (0)\n$header"
write bus-skew.rpt [read [open [file join $fixture_dir bus_skew_report_excerpt.rpt] r]]

# ---------------------------------------------------------------------------
# the fake design
# ---------------------------------------------------------------------------
array set mock_pin_owner {pad_in_5v/IBUF/O u_hdmi_probe/det5v_sync_reg[0]}
# sc7f0_pad_drivers resolves port -> net -> pins on that net -> cells.  The stub
# answers every get_nets with netA and every get_pins of a non-register object with
# `<net>/pad`, so the driver cell has to hang off THAT name: without it an output pad
# has no measurable driver, which is exactly the quantity the pad exception is graded
# on (the real routed checkpoint measures 1 driver cell per pad - see the async_out_*
# records replayed from round 26111202).
set mock_pin_owner(netA/pad) u_pad_io/OBUFT_inst
set mock_pad_ports {hdmi_rx_5v_det hdmi_rx_ddc_scl hdmi_rx_ddc_sda hdmi_tx_hpd_in \
                   hdmi_tx_ddc_scl hdmi_tx_ddc_sda hdmi_tx_refclk_rdy \
                   hdmi_rx_hpd_out hdmi_tx_tmds_clk_p hdmi_tx_tmds_clk_n \
                   user_led_dma_active user_led_pcie_link_up}
set mock_first_stage {u_hdmi_probe/det5v_sync_reg[0] u_hdmi_probe/det5v_sync_reg[1]}
set mock_pin_roles {D D}
if {$scenario eq {clock_pin_load}} {set mock_pin_roles {D S}}

# The six internal async entries of round 26111202's fix: a register in the source
# clock and a 3-FF chain in pl_clk0.  The stub names both halves so the hook's
# regexp queries resolve, and so get_clocks below can answer the two domains apart
# (answering clk_pl_0 for everything, as it did before, is exactly the shape that
# let a foreign level reach a pl_clk0 chain unnoticed).
set probe_src {rxss_tlast_src rxss_tuser_src rxss_tvalid_src
               phy_ch0_tvalid_src phy_ch1_tvalid_src phy_ch2_tvalid_src}
set probe_dst {rxss_tlast_sync rxss_tuser_sync rxss_tvalid_sync
               phy_ch0_tvalid_sync phy_ch1_tvalid_sync phy_ch2_tvalid_sync}

proc zero_objects {} {expr {$::scenario eq {zero_objects}}}

proc probe_stage_zero {obj} {
    # Is this object the first stage of one of the six reviewed probe chains?
    if {![regexp {u_hdmi_probe/(\w+)_reg\[0\]$} $obj unused stem]} {return 0}
    return [expr {[lsearch -exact $::probe_dst $stem] >= 0}]
}

proc probe_source_cell {obj} {
    if {![regexp {u_hdmi_probe/(\w+)_reg$} $obj unused stem]} {return 0}
    return [expr {[lsearch -exact $::probe_src $stem] >= 0}]
}

proc replicate {objects value} {
    set out {}
    foreach obj $objects {lappend out $value}
    return $out
}

proc error_with_newline {} {
    return "ERROR: bad option \"-coverage\" (unknown)\n\tparse failed \\ \$end of line\rthen \x07bell"
}

# Vivado answers a property query with one value per object, and Tcl reads a lone
# empty value as the empty string.  Both halves of that were measured on the
# routed checkpoint (build/hook-repair-26111203-r1/probe/object-model.txt):
#   get_property ASYNC_REG {scl_sync_reg[0] scl_sync_reg[1]}  ->  {} 1
#   get_property ASYNC_REG  scl_sync_reg[0]                   ->  ""
# A stub that always answered a list would hide the false "query error" the hook
# used to raise on the single-object case.
proc mock_answer {objects values} {
    if {[llength $objects] == 1 && [llength $values] == 1 && [lindex $values 0] eq ""} {
        return ""
    }
    return $values
}

proc get_property {args} {
    # Last argument is the object collection, exactly as the hook calls it.  The
    # answer is always parallel to the collection.
    set prop [lindex $args 0]
    set objects [lindex $args end]
    switch -- $prop {
        REF_NAME    {return [replicate $objects FDRE]}
        NAME        {return $objects}
        ASYNC_REG   {
            if {$::scenario eq {short_property_result}} {return 1}
            set out {}
            foreach obj $objects {
                # stage 0 of the real synchroniser chains carries ASYNC_REG,
                # stage 1 of the ddc chains does not
                if {$::scenario eq {real_routed_shape} &&
                    [string match {*ddc_*_sync_reg\[0\]} $obj]} {
                    lappend out {}
                } elseif {$::scenario eq {probe_no_async_reg} &&
                          [probe_stage_zero $obj]} {
                    # the chain the internal entry reviews lost its attribute
                    lappend out {}
                } else {
                    lappend out 1
                }
            }
            return [mock_answer $objects $out]
        }
        REF_PIN_NAME {
            # the pin role is the last path element of a pin name
            set out {}
            foreach obj $objects {
                set parts [split $obj /]
                set role [lindex $parts end]
                # an output pad's endpoint pin carries no REF_PIN_NAME on the
                # real design either
                if {$::scenario eq {real_routed_shape} && $role ne {D}} {
                    lappend out {}
                } else {
                    lappend out $role
                }
            }
            return [mock_answer $objects $out]
        }
        DIRECTION   {return [replicate $objects IN]}
        IOSTANDARD  {return [replicate $objects LVCMOS33]}
        REQUIREMENT {return $::mock_requirement}
        SLACK       {return 4.235}
        default     {return ""}
    }
}
proc current_design {} {return {}}
proc get_runs {args} {error "no project in a stub run"}

proc get_cells {args} {
    if {$::scenario eq {zero_objects}} {return {}}
    if {[lsearch -exact $args -of_objects] >= 0} {
        # pin -> owning cell, the documented form
        set idx [lsearch -exact $args -of_objects]
        set objects [lindex $args [expr {$idx + 1}]]
        set out {}
        foreach obj $objects {
            if {[info exists ::mock_pin_owner($obj)]} {lappend out $::mock_pin_owner($obj)}
        }
        return $out
    }
    # Answer with cells whose names carry the requested family, so the hook's
    # per-item REQUIREMENT comparison measures something instead of always
    # matching the first entry of the table.
    set pattern [lindex $args end]
    if {[string match *snapshot_test_reg* $pattern]} {
        return [list {u_hdmi_probe/u_meter_rx_clk/snapshot_test_reg[0]}]
    }
    if {[string match *aclk_dpram_reg* $pattern]} {
        return [list {u_hdmi_rx_ss/inst/PIX_FIFO_INST/aclk_dpram_reg_0_31_0_13/RAMA}]
    }
    if {[string match *gray_q_reg* $pattern]} {
        return [list {u_ps_capture/u_tap/gray_q_reg[0]}]
    }
    # The six internal async entries: the hook asks for the source register
    # ("..._src_reg"), the first stage ("..._sync_reg[0]") and the later stages
    # ("..._sync_reg[12]").  Answer with names that keep the stem, so the clock
    # and timing mocks below can tell the two domains apart.
    set stages {}
    if {[regexp {u_hdmi_probe/(\w+)_reg\\?\[([0-9]*)\\?\]} $pattern unused stem stages]} {
        # a query naming chain stages, e.g. ..._sync_reg\[12\]
    } elseif {[regexp {u_hdmi_probe/(\w+)_reg$} $pattern unused stem]} {
        # a query naming one whole register, e.g. the source capture flop
    } else {
        set stem {}
    }
    if {$stem ne "" && ([lsearch -exact $::probe_src $stem] >= 0
                        || [lsearch -exact $::probe_dst $stem] >= 0)} {
        if {$stages eq ""} {return "u_hdmi_probe/${stem}_reg"}
        set out {}
        foreach s [split $stages {}] {lappend out "u_hdmi_probe/${stem}_reg\[$s\]"}
        return $out
    }
    return $::mock_first_stage
}
proc get_pins {args} {
    if {[lsearch -exact $args -of_objects] >= 0} {
        set idx [lsearch -exact $args -of_objects]
        set objects [lindex $args [expr {$idx + 1}]]
        set out {}
        foreach obj $objects {
            # output pins are only asked for cells; ports and nets answer with
            # their own pins
            if {[string match *reg* $obj] || [string match *cell* $obj]} {
                lappend out "${obj}/O"
            } else {
                lappend out "${obj}/pad"
            }
        }
        return $out
    }
    return [list pad_pin]
}
proc get_ports {args} {
    if {$::scenario eq {zero_objects}} {return {}}
    # the hook asks for a whole port list at once
    set wanted [lindex $args end]
    set out {}
    foreach port $::mock_pad_ports {
        foreach want $wanted {if {$port eq $want} {lappend out $port}}
    }
    return $out
}
proc get_nets {args} {return [list netA]}
proc get_clocks {args} {
    if {$::scenario eq {zero_objects}} {return {}}
    set objects [lindex $args end]
    # A source register is clocked by the clock report_cdc named for its launch
    # flop; the chain it feeds is in pl_clk0.  Answering clk_pl_0 for both, which
    # is what this stub did before, is the very shape that hid the 26111202 CDC-10
    # crossings, so the two domains are answered apart here.
    foreach obj $objects {
        if {[probe_source_cell $obj]} {
            if {$::scenario eq {probe_source_wrong_clock}} {return [list clk_pl_0]}
            if {[string match *phy_ch* $obj]} {return [list phy_rxoutclk]}
            return [list clkout2]
        }
    }
    return [list clk_pl_0]
}
# The requirement the timing engine applied, per from/to pair: the mock answers
# the way the tool does (one REQUIREMENT per path), so max_delay_effective is a
# measurement and not a guess.
set mock_requirement 6.000
proc get_timing_paths {args} {
    if {$::scenario eq {zero_objects}} {return {}}
    set text [join $args { }]
    set ::mock_requirement 6.000
    if {[string match *snapshot_test_reg* $text]} {set ::mock_requirement 10.000}
    if {[string match *aclk_dpram_reg* $text]} {set ::mock_requirement 15.000}
    if {[string match *_src_reg* $text]} {set ::mock_requirement 6.734}
    # The internal chain stages [0] -> [1]/[2] stay analysed unless the exception
    # grew past the named entry (probe_chain_excepted stands for -from <clock>,
    # the drift this measurement exists to catch), and the feed-in of a source
    # register is an ordinary same-domain path unless it was excepted away.
    if {$::scenario eq {probe_chain_excepted}
        && ([string match {*_sync_reg\[1\]*} $text]
            || [string match {*_sync_reg\[2\]*} $text])} {return {}}
    if {$::scenario eq {probe_upstream_untimed} && [string match *_src_reg* $text]
        && [lsearch -exact $args {-to}] >= 0 && [lsearch -exact $args {-from}] < 0} {
        return {}
    }
    return [list pathA pathB]
}

proc all_fanout {args} {
    # all_fanout takes <from> positionally; the harness fails if the hook ever
    # writes -from again, because the real tool errors on that and the old code
    # swallowed the error.
    if {[lsearch -exact $args {-from}] >= 0} {error "all_fanout has no -from"}
    if {$::scenario eq {zero_objects}} {return {}}
    set only_cells [expr {[lsearch -exact $args {-only_cells}] >= 0}]
    set from [lindex $args end]
    if {$only_cells} {
        # T1 counterexample: the endpoints exist, the cell query comes back empty
        if {$::scenario eq {pad_zero_sequential}} {return {}}
        if {$::scenario eq {real_routed_shape}} {
            # the real design names the cell after the pad it serves
            return [list "u_hdmi_probe/${from}_sync_reg\[0\]" \
                        "u_hdmi_probe/${from}_sync_reg\[1\]"]
        }
        return [list {u_hdmi_probe/det5v_sync_reg[0]} {u_hdmi_probe/det5v_sync_reg[1]}]
    }
    set pins {}
    set roles $::mock_pin_roles
    if {$::scenario eq {real_routed_shape} && [string match {*hpd_out*} $from]} {
        # an output pad terminates in an OBUF pin, which carries no REF_PIN_NAME
        set roles {O}
    }
    foreach role $roles {lappend pins "${from}/$role"}
    return $pins
}

proc report_exceptions {args} {
    # Records how the hook asked, so the test can prove the scratch-free path was
    # used (T3) instead of trusting a comment.
    lappend ::exception_calls [join $args { }]
    set coverage [expr {[lsearch -exact $args {-coverage}] >= 0}]
    set ignored [expr {[lsearch -exact $args {-ignored}] >= 0}]
    set overridden [expr {[lsearch -exact $args {-scope_override}] >= 0}]
    if {$::scenario eq {newline_error} && $coverage} {error [error_with_newline]}
    if {$::scenario eq {no_return_string}} {
        if {[lsearch -exact $args {-return_string}] >= 0} {
            error "ERROR: [Common 17-170] Unknown option '-return_string'"
        }
        set file ""
        for {set i 0} {$i < [llength $args]} {incr i} {
            if {[lindex $args $i] eq {-file}} {set file [lindex $args [expr {$i + 1}]]}
        }
        if {$file eq ""} {error "no -file and no -return_string"}
        set fh [open $file w]
        puts $fh [exception_text $coverage $ignored $overridden]
        close $fh
        return ""
    }
    if {[lsearch -exact $args {-return_string}] < 0} {error "-return_string expected"}
    return [exception_text $coverage $ignored $overridden]
}

proc exception_text {coverage ignored overridden} {
    # Does this query name one of the six internal async entries?  The hook always
    # asks with -from <source register> -to <chain[0]>, so the query itself tells
    # the stub which exception the tool would report.
    set query {}
    if {[info exists ::exception_calls] && [llength $::exception_calls]} {
        set query [lindex $::exception_calls end]
    }
    set probe [expr {[string match *u_hdmi_probe/*_src_reg* $query]
                     && [string match *u_hdmi_probe/*_sync_reg* $query]
                     && $::scenario ne {probe_exception_not_false_path}}]
    # An output-direction query names the pad and nothing else (the hook asks with
    # -to <port> only), which is what `set_false_path -to <port>` declares.
    set padout [expr {$query ne "" && [string match {*-to*} $query]
                      && ![string match {*-from*} $query]
                      && ([string match *hdmi_rx_ddc* $query]
                          || [string match *hdmi_rx_hpd_out* $query]
                          || [string match *user_led* $query]
                          || [string match *hdmi_tx_tmds* $query])}]
    if {$ignored} {return "Positions fully ignored: 0\n"}
    if {$overridden} {return "Positions overridden: 0\n"}
    if {$coverage} {
        if {$::scenario eq {coverage_blank_from}} {
            # an exception whose -from side names no pins: the From column, and
            # therefore From (%), is blank
            return "$::coverage_header\n$::coverage_row_blank_from"
        }
        if {$padout && $::scenario eq {output_exception_missing}} {
            # the named output-direction constraint is not in this design
            return "$::coverage_header\n"
        }
        if {$::scenario eq {coverage_no_header}} {
            return $::coverage_row
        }
        if {$probe} {
            # one False Path row, 1 cell on each side, 100 % from and to
            return "$::coverage_header\n$::coverage_row_probe"
        }
        if {$padout} {
            return "$::coverage_header\n$::coverage_row_pad"
        }
        return "$::coverage_header\n$::coverage_row"
    }
    if {$probe} {
        return {245       set_false_path -name probe_rxss_tvalid_src_to_probe -from ... -to ...}
    }
    if {$padout} {
        if {$::scenario eq {output_exception_missing}} {return ""}
        return {248       set_false_path -to [get_ports hdmi_rx_ddc_scl]}
    }
    return {217       set_max_delay -datapath_only 6.000 ...   max_dpo=6}
}

proc report_bus_skew {args} {
    if {$::scenario eq {bus_skew_bad_signature}} {
        if {[lsearch -exact $args {-from}] < 0} {
            error "ERROR: [Common 17-170] Unknown option, please type 'report_bus_skew -help'"
        }
    }
    if {$::scenario eq {no_return_string}} {
        if {[lsearch -exact $args {-return_string}] >= 0} {
            error "ERROR: [Common 17-170] Unknown option '-return_string'"
        }
        set file ""
        for {set i 0} {$i < [llength $args]} {incr i} {
            if {[lindex $args $i] eq {-file}} {set file [lindex $args [expr {$i + 1}]]}
        }
        if {$file eq ""} {error "no -file and no -return_string"}
        file rename -force [file join $::dir bus-skew.rpt] $file
        return ""
    }
    if {[lsearch -exact $args {-return_string}] < 0} {error "-return_string expected"}
    set text [read [open [file join $::dir bus-skew.rpt] r]]
    if {$::scenario eq {bus_skew_root_missing}} {
        return "Bus Skew Report\n\n1. Bus Skew Report Summary\n\n(no constraints)\n"
    }
    return $text
}

# ---------------------------------------------------------------------------
# run the hook
# ---------------------------------------------------------------------------
set exception_calls {}
set code [read [open [file join [file normalize [file join $fixture_dir .. .. ..]] \
                    scripts/check_sc7f0_named_constraints.tcl] r]]
set hook_error {}
if {[catch {uplevel #0 $code} err]} {
    if {![string match "named constraint coverage failed:*" $err]} {
        puts "HARNESS_FAIL: $err"
        exit 1
    }
    set hook_error $err
    puts "HARNESS_EXPECTED_COVERAGE_FAILURE"
}
set json_file [file join $dir named-constraint-evidence.json]
if {![file exists $json_file]} {puts "HARNESS_FAIL: no manifest"; exit 1}
# T3: nothing may be written next to the process' working directory.
foreach pattern [list .tmp-exceptions-*.rpt .tmp-bus-skew.rpt hook-scratch] {
    foreach stray [glob -nocomplain -directory [pwd] $pattern] {
        puts "HARNESS_SCRATCH_IN_CWD $stray"
    }
}
puts "HARNESS_SCENARIO $scenario"
puts "HARNESS_MANIFEST_OK [file size $json_file] bytes"
puts "HARNESS_EXCEPTION_CALLS [llength $exception_calls]"
if {$hook_error ne ""} {puts "HARNESS_ERROR [string range $hook_error 0 200]"}
exit 0
