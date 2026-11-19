# =============================================================================
# scripts/check_sc7f0_named_constraints.tcl
#
# Post-route evidence hook for Layer B of scripts/check_sc7f0_timing.py.
#
# Re-measures, on the routed netlist of THIS round, every named timing exception
# that scripts/gates/*.json claims, and writes the coverage manifest
#       $SC7F0_REPORT_DIR/named-constraint-evidence.json
# The manifest is bound to the round by the sha256 of cdc.rpt, so a manifest
# from an earlier round cannot be reused (the gate rejects a hash mismatch).
#
# API discipline.  Each line below was a real failure in an earlier probe round;
# see build/evidence-dcpio-26111106/query/summary.json ->
# tool_defects_found_and_fixed:
#   * Vivado 2023.2 embeds Tcl 8.5: no lmap, no dict-for shortcuts that need 8.6.
#   * all_fanout takes <from> positionally; there is no -from/-through.  An
#     earlier revision wrote `-from $net`, the catch swallowed the error and every
#     endpoint_count silently read 0 - a missing measurement that looked like a
#     clean one.  A failed query now always leaves a probe_error behind.
#   * get_property <bool> <collection> returns 1/0, not TRUE/FALSE.
#   * max_delay / false_path / bus_skew / clock_group are NOT Tcl objects, so
#     exceptions can only be enumerated through report_exceptions.
#   * report_exceptions without -coverage has no Type column and prints the
#     requirement as max_dpo=<value>; clock groups only show with -coverage.
#   * a bare newline inside [list ...] terminates the command.
# Every Vivado call is wrapped in catch, so a missing option is recorded as
# missing evidence (which fails the gate) instead of aborting hours of work.
#
# Round 26111202 (build/vcu-release-26111202-r1) exposed five further producer
# defects, listed as T1..T5 in docs/sc7f0_full_build_26111202.md 5.2.  They are
# fixed here and each fix is re-measured against that round's routed DCP in
# build/hook-repair-<round>/:
#   T1 pad closure enumerated 0 first-stage sequential cells while the same
#      manifest reported a non-zero endpoint_count for the same pad.  Cause:
#      `get_property REF_NAME $cells refs` - three arguments to a two argument
#      command - swallowed by catch, plus per-element get_cells on a stringified
#      endpoint, which resolves to nothing without raising an error.  Endpoints
#      are now resolved to cells with the two forms 2023.2 documents for it
#      (`all_fanout -endpoints_only -only_cells` and
#      `get_cells -of_objects <endpoint collection>`), always as whole-
#      collection queries, and an empty result is an explicit error code instead
#      of a clean-looking 0.
#   T2 a probe_error carrying a raw newline made the whole manifest unparseable,
#      so 30+ Layer B entries were mis-reported as "absent".  sc7f0_escape now
#      escapes quote, backslash and every control character, and the manifest
#      itself carries the verdict the hook reached, so a failing round still
#      leaves complete parseable evidence behind.
#   T3 the ignored / scope-override audit was read from the report directory but
#      never written there, so every entry said "missing ...".  The audit is now
#      taken with -return_string; a fallback writes under the ABSOLUTE report
#      directory, never the working directory, and nothing lands in the repo.
#   T4 report_bus_skew has no -from/-to in 2023.2 (verified with `help
#      report_bus_skew`).  The report is taken once with a supported signature
#      and the row for the named root is located by that constraint's own
#      -from/-to declaration; a missing row fails instead of reading as a
#      measurement that was never taken.
#   T5 design_state was written as "".  It is read back from the "Design State"
#      header of this round's reports (the same string
#      scripts/check_sc7f0_timing.py grades), cross-checked against the live
#      design object, and anything that is not a known post-route state fails.
# =============================================================================

if {![info exists ::env(SC7F0_REPORT_DIR)]} {
    error "SC7F0_REPORT_DIR must name the directory holding cdc.rpt / timing_summary.rpt"
}
# T3: every path derived below is anchored to the ABSOLUTE report directory.
# The previous revision read the exception audit out of the report directory
# while writing scratch relative to the working directory, so "missing
# .tmp-exceptions-ignored.rpt" was an artefact of where Vivado happened to run.
set out_dir [file normalize $::env(SC7F0_REPORT_DIR)]
if {![file isdirectory $out_dir]} {
    error "SC7F0_REPORT_DIR=$out_dir is not a directory"
}
set ::sc7f0_out_dir $out_dir
set ::sc7f0_scratch [file join $out_dir hook-scratch]
set ::sc7f0_start_cwd [file normalize [pwd]]
set ::sc7f0_section_errors 0
set evidence [file join $out_dir named-constraint-evidence.json]

# Global-scope name discipline (round 26111204).
# This hook is `source`d at level #0 of the calling Tcl session, so every array
# it creates here is created in the CALLER's scope, not in its own.  In the
# production flow the caller is scripts/impl_sc7f0_dual_video.tcl, whose top
# level runs `foreach a {Default Explore AggressiveExplore ...}` (line 379) to
# validate SC7F0_POST_ROUTE_PHYS_OPT, leaving a global SCALAR named `a` behind
# (= "AggressiveExplore", printed as SC7F0_TIMING_TUNED at
# build/vcu-release-26111204-r1/fpga/project-logs/impl-vivado.log:3284).  The
# hook's own per-item record array was also named `a`, and Tcl refuses
# `array set a {...}` once `a` is a scalar -> "can't set \"a(values)": variable
# isn't array".  That single collision aborted 18 of the 20 items of that round
# inside their own `catch`, i.e. a tool-name clash was recorded as 18 bogus
# "item query aborted" measurement failures.  The fix is the name, not a wider
# `catch`: the hook's global record arrays are named so they cannot collide, and
# the loop below fails loudly, naming the variable, if a caller ever reintroduces
# a scalar under one of these names.  Arrays used only INSIDE a `proc` are
# proc-local and are deliberately not listed: they cannot see the caller.
foreach sc7f0_global_name {rec drec crec sc7f0_async_prop loads pad drv it pp
                           t e s d c u x} {
    if {[info exists $sc7f0_global_name] && ![array exists $sc7f0_global_name]} {
        error "SC7F0_NAMED_EVIDENCE_SCOPE_CONFLICT $sc7f0_global_name exists as a scalar in the caller's scope; refusing to run, because array set on that name would abort every item and be recorded as a measurement failure"
    }
}

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
proc sc7f0_sha256 {file} {
    if {![file exists $file]} {return ""}
    if {[catch {exec sha256sum $file} digest]} {return ""}
    return [string trim [lindex [split $digest { }] 0]]
}

# JSON string escaping (T2).  A Vivado usage message that landed in probe_error
# carried a raw newline, which is illegal inside a JSON string: the whole
# manifest became unparseable and every Layer B entry downstream was reported as
# "absent from this round's coverage manifest" instead of what it really was.
proc sc7f0_escape {text} {
    regsub -all {\\} $text {\\\\} text
    regsub -all {"}  $text {\\"} text
    regsub -all {\n} $text {\\n} text
    regsub -all {\r} $text {\\r} text
    regsub -all {\t} $text {\\t} text
    # Any other control character becomes \uXXXX as well; a tool message can
    # contain form feed / vertical tab / BEL, and one raw byte below 0x20 is
    # enough to lose every section of the manifest.
    for {set code 1} {$code <= 31} {incr code} {
        if {$code == 8 || $code == 9 || $code == 10 || $code == 12 || $code == 13} {
            continue
        }
        regsub -all -- [format %c $code] $text [format {\\u%04x} $code] text
    }
    regsub -all -- \x7f $text {\\u007f} text
    return $text
}

# Scratch only ever lives under the absolute report directory (T3), and only if
# a -return_string query is unavailable.
proc sc7f0_scratch_file {name} {
    if {![file isdirectory $::sc7f0_scratch]} {file mkdir $::sc7f0_scratch}
    return [file join $::sc7f0_scratch $name]
}

proc sc7f0_text {file} {
    if {![file exists $file]} {return ""}
    set fh [open $file r]
    set text [read $fh]
    close $fh
    return $text
}

proc sc7f0_join {value} {
    if {[catch {join $value { }} text]} {set text $value}
    return $text
}

proc sc7f0_count {file pattern} {
    set text [sc7f0_text $file]
    if {$text eq ""} {return -1}
    set hits 0
    foreach line [split $text \n] {
        if {[regexp $pattern $line]} {incr hits}
    }
    return $hits
}

# Select cells, optionally narrowed to one reference pin name.
proc sc7f0_select {cell_re {pin_re {}}} {
    if {$cell_re eq ""} {return [get_cells -quiet -hier -regexp {.$nothing$}]}
    set cells [get_cells -quiet -hier -regexp $cell_re]
    if {$pin_re eq ""} {return $cells}
    if {[catch {get_pins -quiet -of_objects $cells -filter "REF_PIN_NAME =~ $pin_re"} pins]} {
        return {}
    }
    return $pins
}

# Clock names carried by an object ("-" = measured, no clock; "QUERY_ERROR" = the
# query itself failed, which the caller records as missing evidence).
proc sc7f0_clks {obj} {
    if {$obj eq "" || [llength $obj] == 0} {return "-"}
    set clocks {}
    if {[catch {get_clocks -quiet -of_objects $obj} clocks]} {return QUERY_ERROR}
    if {$clocks eq ""} {return "-"}
    set text {}
    if {[catch {join [lsort -unique [get_property NAME $clocks]] |} text]} {
        return QUERY_ERROR
    }
    return $text
}

proc sc7f0_names {objs} {
    if {$objs eq ""} {return {}}
    set names {}
    if {[catch {get_property NAME $objs} names]} {return {}}
    return $names
}

# get_property over a whole collection, keeping the answer parallel to it.
# A length mismatch is reported, never truncated: `catch` around a property query
# is exactly what hid T1, because a swallowed error and a genuine zero both look
# like an empty list.
proc sc7f0_prop {property objects} {
    array set r {values {} error {}}
    set n [llength $objects]
    if {$objects eq "" || $n == 0} {return [array get r]}
    if {[catch {get_property $property $objects} values]} {
        set r(error) "get_property $property failed"
        return [array get r]
    }
    # An unset property on a *single* object comes back as the empty string, and
    # Tcl reads "" as a zero-element list.  Measured on the routed 26111202
    # checkpoint (build/hook-repair-26111203-r1/probe/object-model.txt):
    #   get_property ASYNC_REG $scl_sync_reg_cells -> {} 1   (two values)
    #   get_property ASYNC_REG $scl_sync_reg_cells(0) -> ""  (one unset value)
    #   get_property REF_PIN_NAME <OBUF pin>          -> ""
    # Reading that as a length mismatch turned "this object simply has no such
    # property" into a false query error on three items.  One object always
    # yields exactly one value, empty meaning "not set"; a collection keeps its
    # empty elements, so a real short result still fails below.
    if {$n == 1 && $values eq ""} {set values [list {}]}
    if {[llength $values] != $n} {
        set r(error) "get_property $property returned [llength $values] value(s) for $n object(s)"
        return [array get r]
    }
    set r(values) $values
    return [array get r]
}

# Sequential-cell reference families, matched on the REF_NAME the tool reports.
# FD* / LD* are the 7-series flip-flops and latches; IDDR* / IDES* / ISERDESE*
# are the input-side serialisers an input pad may legitimately reach.  Anything
# else (SRL*, RAM*, hard IP) is reported in unknown_families rather than dropped,
# so "0 sequential first stages" can never hide a family this list simply does
# not know about.
proc sc7f0_is_sequential_ref {ref} {
    foreach family {FD LD IDDR IDES ISERDESE} {
        if {[string match ${family}* $ref]} {return 1}
    }
    return 0
}

# A pad signal must not terminate on a clock or an asynchronous set / reset pin.
# 7-series flip-flops use C for the clock and R / S for the async set / reset; the
# earlier list omitted R and S, so such a load counted as 0.
proc sc7f0_is_clock_or_sr_pin {pin} {
    foreach role {C CLK CP CLR PRE SET SR R S} {
        if {$pin eq $role} {return 1}
    }
    return 0
}

# Split a cell collection into sequential cells and the rest, keyed on REF_NAME.
# `lindex` on a Vivado collection yields objects, while a name string produced by
# `foreach` does not have to resolve again - so the classification indexes the
# collection instead of iterating over it (T1).
proc sc7f0_sequential_cells {cells} {
    array set r {cells {} count 0 families {} unknown_families {} error {}}
    if {$cells eq "" || [llength $cells] == 0} {
        set r(error) "no cells to classify"
        return [array get r]
    }
    # same funnel as every other property query, so an unset value is one empty
    # value and a genuinely short result is still an error
    array set probe [sc7f0_prop REF_NAME $cells]
    if {$probe(error) ne ""} {
        set r(error) $probe(error)
        return [array get r]
    }
    set refs $probe(values)
    for {set i 0} {$i < [llength $cells]} {incr i} {
        set ref [lindex $refs $i]
        if {[sc7f0_is_sequential_ref $ref]} {
            lappend r(cells) [lindex $cells $i]
            if {[lsearch -exact $r(families) $ref] < 0} {lappend r(families) $ref}
        } elseif {[lsearch -exact $r(unknown_families) $ref] < 0} {
            lappend r(unknown_families) $ref
        }
    }
    set r(count) [llength $r(cells)]
    return [array get r]
}

# all_fanout's <from> is documented as "the source ports, pins, or nets"; a cell
# is converted to its output pins first (help get_pins: -of_objects takes "pins
# of these cells") so the query is always issued with a documented type.
proc sc7f0_fanout_source {obj} {
    array set r {objects {} note {} error {}}
    if {$obj eq "" || [llength $obj] == 0} {
        set r(error) "empty object list"
        return [array get r]
    }
    set pins {}
    set failed 0
    if {[catch {get_pins -quiet -of_objects $obj -filter {DIRECTION == OUT}} pins]} {
        set failed 1
    }
    if {!$failed && [llength $pins] > 0} {
        set r(objects) $pins
        set r(note) {output pins of from-objects}
        return [array get r]
    }
    set r(objects) $obj
    set r(note) {from objects as given}
    return [array get r]
}

# First-stage loads of `from`, resolved to cells (T1 / T5 of the pad question).
# Both queries used are documented in 2023.2 and both are whole-collection calls;
# whichever produced cells is recorded in `method`, so the manifest says how the
# number was measured instead of just asserting a count.
proc sc7f0_fanout_loads {obj} {
    array set r {cells {} cell_count 0 endpoints {} endpoint_count 0 pin_roles {}
                 clock_pin_loads 0 seq_cells {} seq_count 0 async_reg_count 0
                 ref_families {} unknown_ref_families {} clocks - method {}
                 source {} probe_error {}}
    if {$obj eq "" || [llength $obj] == 0} {
        set r(probe_error) "empty object list"
        return [array get r]
    }
    array set src [sc7f0_fanout_source $obj]
    set r(source) $src(note)
    if {$src(error) ne ""} {
        append r(probe_error) $src(error) "; "
        return [array get r]
    }
    # (1) endpoint pins, and the pin role each load arrives at (clock / set / reset
    #     loads are the dangerous ones and have to be reported, not assumed)
    if {![catch {all_fanout -flat -endpoints_only $src(objects)} endpoints]} {
        set r(endpoints) $endpoints
        set r(endpoint_count) [llength $endpoints]
    } else {
        append r(probe_error) "all_fanout -endpoints_only failed; "
    }
    if {$r(endpoint_count) > 0} {
        array set p [sc7f0_prop REF_PIN_NAME $r(endpoints)]
        if {$p(error) eq ""} {
            foreach role $p(values) {
                if {[lsearch -exact $r(pin_roles) $role] < 0} {lappend r(pin_roles) $role}
                if {[sc7f0_is_clock_or_sr_pin $role]} {incr r(clock_pin_loads)}
            }
        } else {
            append r(probe_error) "$p(error); "
        }
    }
    # (2) endpoint cells, asked of the fanout engine itself
    if {![catch {all_fanout -flat -endpoints_only -only_cells $src(objects)} cells]} {
        set r(cells) $cells
        set r(cell_count) [llength $cells]
    } else {
        append r(probe_error) "all_fanout -endpoints_only -only_cells failed; "
    }
    if {$r(cell_count) > 0} {
        set r(method) {all_fanout -endpoints_only -only_cells}
    } elseif {$r(endpoint_count) > 0} {
        # (3) the documented pin -> owning cell query, over the whole collection
        if {![catch {get_cells -quiet -of_objects $r(endpoints)} cells]} {
            set r(cells) $cells
            set r(cell_count) [llength $cells]
            if {$r(cell_count) > 0} {set r(method) {get_cells -of_objects <endpoints>}}
        } else {
            append r(probe_error) "get_cells -of_objects <endpoints> failed; "
        }
    }
    if {$r(cell_count) == 0} {
        if {$r(endpoint_count) == 0} {
            if {$r(probe_error) eq ""} {set r(probe_error) "fanout resolved to 0 endpoints"}
        } else {
            append r(probe_error) "$r(endpoint_count) endpoint(s) did not resolve to any cell; "
        }
        return [array get r]
    }
    array set s [sc7f0_sequential_cells $r(cells)]
    set r(seq_cells) $s(cells)
    set r(seq_count) $s(count)
    set r(ref_families) [join $s(families) |]
    set r(unknown_ref_families) [join $s(unknown_families) |]
    if {$s(error) ne ""} {append r(probe_error) "$s(error); "}
    if {$r(seq_count) > 0} {
        array set a [sc7f0_prop ASYNC_REG $r(seq_cells)]
        if {$a(error) eq ""} {
            foreach flag $a(values) {if {[sc7f0_true $flag]} {incr r(async_reg_count)}}
        } else {
            append r(probe_error) "$a(error); "
        }
        set r(clocks) [sc7f0_clks $r(seq_cells)]
        if {$r(clocks) eq {QUERY_ERROR}} {append r(probe_error) "get_clocks failed; "}
    }
    return [array get r]
}

proc sc7f0_true {value} {
    return [expr {$value in {1 TRUE true}}]
}

# Driver side of an output pad: every cell that attaches a pin to the pad net.
proc sc7f0_pad_drivers {port_list} {
    array set r {cells {} refs {} clocks {} errors {}}
    foreach port $port_list {
        set net {}
        if {[catch {get_nets -quiet -of_objects $port} net]} {
            append r(errors) "get_nets failed "
            continue
        }
        if {$net eq ""} {continue}
        # Whole-collection queries: -of_objects is the documented spelling, and a
        # stringified pin name need not resolve again (see the pad-closure note).
        set pins {}
        if {[catch {get_pins -quiet -of_objects $net} pins]} {continue}
        if {$pins eq ""} {continue}
        set cells {}
        if {[catch {get_cells -quiet -of_objects $pins} cells]} {continue}
        foreach cell $cells {lappend r(cells) $cell}
    }
    set r(cells) [lsort -unique $r(cells)]
    set refs {}
    foreach cell $r(cells) {
        set ref {}
        if {[catch {get_property REF_NAME $cell} ref]} {continue}
        if {$ref eq ""} {continue}
        lappend refs $ref
    }
    set r(refs) [lsort -unique $refs]
    set r(clocks) [sc7f0_clks $r(cells)]
    return [array get r]
}

# report_exceptions for one scope, returned as text.  -return_string is a
# documented 2023.2 option and keeps this hook from writing scratch at all (T3);
# if it ever stops working, the fallback file goes under the absolute report
# directory - never the working directory, never the repository root.
proc sc7f0_report_exceptions {tag mode from to} {
    array set r {text {} source {} error {}}

    # An output-direction exception (`set_false_path -to <port>`) has no -from side
    # at all, so the query is built from the sides that exist.  Asking with an empty
    # -from made this helper answer nothing, nothing was read as "no exception", and
    # nobody checked that - so a pad exception could be deleted from the XDC and the
    # manifest still looked clean.
    set sel {}
    if {$from ne "" && [llength $from] > 0} {lappend sel -from $from}
    if {$to ne "" && [llength $to] > 0} {lappend sel -to $to}
    if {$sel eq ""} {
        set r(error) "no -from and no -to objects to query an exception with"
        return [array get r]
    }
    if {$mode eq {plain}} {
        if {![catch {report_exceptions {*}$sel -quiet -return_string} text]} {
            set r(text) $text
            set r(source) {report_exceptions -return_string}
            return [array get r]
        }
        set path [sc7f0_scratch_file "exceptions-$tag.rpt"]
        if {[catch {report_exceptions {*}$sel -quiet -file $path} err]} {
            set r(error) "report_exceptions: $err"
            return [array get r]
        }
    } elseif {$mode eq {coverage}} {
        if {![catch {report_exceptions -coverage {*}$sel -quiet \
                         -return_string} text]} {
            set r(text) $text
            set r(source) {report_exceptions -coverage -return_string}
            return [array get r]
        }
        set path [sc7f0_scratch_file "exceptions-coverage-$tag.rpt"]
        if {[catch {report_exceptions -coverage {*}$sel -quiet \
                         -file $path} err]} {
            set r(error) "report_exceptions -coverage: $err"
            return [array get r]
        }
    } elseif {$mode eq {ignored}} {
        if {![catch {report_exceptions -ignored {*}$sel -quiet \
                         -return_string} text]} {
            set r(text) $text
            set r(source) {report_exceptions -ignored -return_string}
            return [array get r]
        }
        set path [sc7f0_scratch_file "exceptions-ignored-$tag.rpt"]
        if {[catch {report_exceptions -ignored {*}$sel -quiet \
                         -file $path} err]} {
            set r(error) "report_exceptions -ignored: $err"
            return [array get r]
        }
    } else {
        if {![catch {report_exceptions -scope_override {*}$sel -quiet \
                         -return_string} text]} {
            set r(text) $text
            set r(source) {report_exceptions -scope_override -return_string}
            return [array get r]
        }
        set path [sc7f0_scratch_file "exceptions-scope-override-$tag.rpt"]
        if {[catch {report_exceptions -scope_override {*}$sel -quiet \
                         -file $path} err]} {
            set r(error) "report_exceptions -scope_override: $err"
            return [array get r]
        }
    }
    set r(text) [sc7f0_text $path]
    set r(source) "scratch [file tail $path]"
    return [array get r]
}

# report_exceptions -coverage writes a column-aligned table:
#   Position  Type  Setup  Hold  From  Through  To  Endpoints  From (%)  Through (%)  To (%)
# The columns are NOT a fixed number of whitespace tokens apart.  An exception
# that covers only output pins leaves From and Through blank
# (`3   False Path   false   false                  2 pins   1            0.00`), so
# counting tokens shifts every later column; round 26111202's reader picked
# [lindex $fields 8], which is the word "cells" from the From column, and handed
# it to scripts/sc7f0_review_policy.py:383 as a percentage - the Layer B gate then
# died on `float("cells")`.  Columns are therefore sliced at the offsets the
# report's own header declares, and a value that is not a number is reported
# rather than guessed.
proc sc7f0_coverage_columns {text} {
    foreach line [split $text \n] {
        # NOTE: in a Tcl regexp \b is a backspace, not a word boundary, so the
        # header is anchored on literal whitespace; the (% ) columns are matched
        # with a leading \y only, because a trailing \y cannot match after ')'.
        if {![regexp {^\s{0,3}Position\s+Type\s.*Endpoints\s+From \(%\)} $line]} continue
        set pairs {}
        foreach name {Position Type Setup Hold From Through To Endpoints
                      {{From \(%\)} {Through \(%\)} {To \(%\)}}} {
            foreach one $name {
                if {[regexp -indices -- "\\y${one}" $line range]} {
                    # the plain column is always printed before its (%) twin, so
                    # the first match is the one this row is sliced on
                    # $one is a regexp, so the (%) columns still carry their
                    # backslashes; the row is keyed by the column name as the
                    # tool prints it
                    lappend pairs [list [lindex $range 0] [string map [list \\ {}] $one]]
                }
            }
        }
        return [lsort -integer -index 0 $pairs]
    }
    return {}
}

# Slice one aligned row at the header's offsets, returning a {column value} list.
proc sc7f0_column_row {line columns} {
    set out {}
    set len [string length $line]
    set n [llength $columns]
    for {set i 0} {$i < $n} {incr i} {
        set start [lindex $columns $i 0]
        if {$i + 1 < $n} {
            set end [expr {[lindex $columns [expr {$i + 1}] 0] - 1}]
        } else {
            set end [expr {$len - 1}]
        }
        set value {}
        if {$start < $len} {
            set value [string trim [string range $line $start $end]]
        }
        lappend out [lindex $columns $i 1] $value
    }
    return $out
}

# A coverage row is read as a dict of column name -> value; the column names
# contain spaces and parentheses, which $array(name) cannot spell.
proc sc7f0_column_value {row name} {
    if {![dict exists $row $name]} {return {}}
    return [dict get $row $name]
}

# Position / type / endpoints of the exception that covers a from->to pair, plus
# the two audit lists that prove it was neither ignored nor scope overridden.
# Those two audits used to be read from files this hook never wrote, which is why
# every entry of round 26111202 carried "missing .tmp-exceptions-ignored.rpt"
# (T3).  Each is now a scoped query, with this round's own exceptions-ignored.rpt
# / exceptions-scope-override.rpt (written by the implementation flow and hashed
# into this manifest) as the read-only fallback.
proc sc7f0_exception {from to tag {expect_from 1}} {
    # expect_from = 0 is for an exception declared with no -from side at all
    # (`set_false_path -to <port>`): its From (%) column is legitimately absent, so
    # it is recorded as not applicable instead of being raised as a coverage failure.
    # Everything else about the row - position, type, endpoints - is still required.
    array set r {position {} type {} setup {} endpoints {} endpoints_total 0 \
                 coverage_rows 0 from_pct {} rows 0 ignored 0 scope_overridden 0 \
                 coverage_row {} coverage_from {} coverage_to {} to_pct {} \
                 from_coverage {} audit_source {} probe_error {}}
    # One side may legitimately be absent: `set_false_path -to <port>` has no -from.
    # Both sides absent is still a caller error.
    if {($from eq "" || [llength $from] == 0) && ($to eq "" || [llength $to] == 0)} {
        set r(probe_error) "empty object list"
        return [array get r]
    }
    array set q [sc7f0_report_exceptions $tag plain $from $to]
    if {$q(error) ne ""} {
        set r(probe_error) $q(error)
        return [array get r]
    }
    set r(audit_source) $q(source)
    foreach line [split $q(text) \n] {
        if {[regexp {^\s*([0-9]+)\s.*max_dpo=([0-9.]+)} $line unused pos setup]} {
            if {$r(position) eq ""} {set r(position) $pos}
            set r(setup) "max_dpo=$setup"
            incr r(rows)
        }
    }
    array set c [sc7f0_report_exceptions $tag coverage $from $to]
    if {$c(error) ne ""} {
        append r(probe_error) "$c(error) "
    } else {
        append r(audit_source) "; $c(source)"
        set columns [sc7f0_coverage_columns $c(text)]
        foreach line [split $c(text) \n] {
            if {![regexp {^\s*([0-9]+)\s+(False Path|Max Delay|Clock Group|Multicycle|Min Delay)\s} \
                    $line unused pos type]} continue
            if {$r(position) eq ""} {set r(position) $pos}
            set r(type) $type
            incr r(rows)
            incr r(coverage_rows)
            if {$columns eq {}} {
                append r(probe_error) "coverage report has no column header; "
                append r(probe_error) "endpoints of position $pos cannot be read "
                continue
            }
            set f [sc7f0_column_row $line $columns]
            set r(coverage_row) [string trim $line]
            set r(coverage_from) [sc7f0_column_value $f From]
            set r(coverage_to) [sc7f0_column_value $f To]
            set endpoints [sc7f0_column_value $f Endpoints]
            if {![string is integer -strict $endpoints]} {
                append r(probe_error) "coverage row at position $pos has Endpoints "
                append r(probe_error) "column \"$endpoints\"; refusing to guess "
                continue
            }
            set r(endpoints) $endpoints
            incr r(endpoints_total) $endpoints
            # A blank From (%) is a real answer: the exception names no from-side
            # pins, so from coverage is unknown, not 100 and not 0.  Leave the
            # field empty (the policy reports it as missing) and say why.
            set pct [sc7f0_column_value $f {From (%)}]
            if {![string is double -strict $pct]} {
                if {$expect_from} {
                    append r(probe_error) "coverage row at position $pos reports no "
                    append r(probe_error) "From (\%) (From column \"$r(coverage_from)\"); "
                    append r(probe_error) "from coverage is unknown "
                } else {
                    set r(from_coverage) {not applicable, no -from side declared}
                }
            } else {
                set r(from_pct) $pct
            }
            set r(to_pct) [sc7f0_column_value $f {To (%)}]
        }
    }
    if {$r(rows) == 0} {set r(type) "none"}
    foreach {flag mode round_report} [list ignored ignored exceptions-ignored.rpt \
                                          scope_overridden scope_override \
                                          exceptions-scope-override.rpt] {
        array set a [sc7f0_report_exceptions $tag $mode $from $to]
        set text $a(text)
        if {$a(error) ne ""} {
            set path [file join $::sc7f0_out_dir $round_report]
            if {![file exists $path]} {
                append r(probe_error) "$a(error), and no $round_report in \
$::sc7f0_out_dir "
                continue
            }
            set text [sc7f0_text $path]
            append r(audit_source) "; this round's $round_report"
        } else {
            append r(audit_source) "; $a(source)"
        }
        if {$r(position) eq ""} {
            # No position means the audit cannot be tied to this pair's
            # declaration.  Say so instead of quietly reporting "not ignored".
            if {[regexp {^\s*[0-9]+\s+\S} $text]} {
                append r(probe_error) "$mode audit has rows but this pair has no "
                append r(probe_error) "exception position "
            }
            continue
        }
        foreach line [split $text \n] {
            if {[regexp "^\s*$r(position)\s" $line]} {set r($flag) 1; break}
        }
    }
    return [array get r]
}

# Worst path arriving AT a collection, with no -from.  Used for the source side of
# a named internal asynchronous entry: the feed-in to the source register must be
# timed at its OWN clock's requirement, which is exactly what a `-to`-only query
# answers.  0 paths is recorded as an error, never as "nothing to check".
proc sc7f0_timing_to {to {max_paths 8}} {
    array set r {paths 0 requirement {} slack {} start_clocks {} probe_error {}}
    if {$to eq "" || [llength $to] == 0} {
        set r(probe_error) "empty object list"
        return [array get r]
    }
    if {[catch {get_timing_paths -to $to -delay_type max \
                    -max_paths $max_paths -nworst 1} paths]} {
        set r(probe_error) "get_timing_paths -to failed"
        return [array get r]
    }
    set r(paths) [llength $paths]
    if {$r(paths) > 0} {
        set first [lindex $paths 0]
        set r(requirement) [get_property REQUIREMENT $first]
        set r(slack) [get_property SLACK $first]
        if {![catch {get_property STARTPOINT_CLOCK $paths} start]} {
            set r(start_clocks) [join [lsort -unique $start] |]
        }
    }
    return [array get r]
}

# Worst REQUIREMENT between two collections: with a max_delay in force the
# requirement is that exception value; without it the clock period appears; and
# if a clock group had swallowed the pair, no paths come back at all.
proc sc7f0_timing {from to {max_paths 8}} {
    array set r {paths 0 requirement {} slack {} probe_error {}}
    if {[llength $from] == 0 || [llength $to] == 0} {
        set r(probe_error) "empty object list"
        return [array get r]
    }
    if {[catch {get_timing_paths -from $from -to $to -delay_type max \
                    -max_paths $max_paths -nworst 1} paths]} {
        set r(probe_error) "get_timing_paths failed"
        return [array get r]
    }
    set r(paths) [llength $paths]
    if {$r(paths) > 0} {
        set first [lindex $paths 0]
        set r(requirement) [get_property REQUIREMENT $first]
        set r(slack) [get_property SLACK $first]
    }
    return [array get r]
}

# Bus skew, measured with a signature 2023.2 actually has (T4).
#
# `help report_bus_skew` in 2023.2 lists -delay_type, -setup/-hold,
# -no_detailed_paths, -max_paths, -nworst, -unique_pins, -path_type,
# -sort_by_slack, -input_pins, -no_header, -significant_digits, -file, -append,
# -return_string, -warn_on_violation, -rpx and -cells - and NO -from / -to /
# -of_objects.  The previous revision asked for `-from ... -to ...`, the tool
# answered "Unknown option '-from'", the catch turned that into
# bus_skew_violated = 0, and a measurement that never happened was graded as a
# passing one.  The whole-design report is therefore taken once per run with a
# supported signature, and the row belonging to this item is located by the
# constraint's own -from / -to declaration (the named root the policy reviews).
# A report without that root is a hard error, never an absent measurement.
proc sc7f0_bus_skew_report {} {
    upvar #0 sc7f0_bus_skew_cache cache
    upvar #0 sc7f0_bus_skew_source source
    array set r {text {} source {} error {}}
    if {[info exists cache] && $cache ne ""} {
        set r(text) $cache
        set r(source) $source
        return [array get r]
    }
    if {![catch {report_bus_skew -delay_type max -max_paths 1 -nworst 1 \
                     -sort_by_slack -quiet -return_string} text]} {
        set cache $text
        set source {report_bus_skew -return_string}
        set r(text) $text
        set r(source) $source
        return [array get r]
    }
    # Read-only fallback: this round's own bus-skew.rpt, which
    # scripts/impl_sc7f0_dual_video.tcl writes before this hook runs and which
    # this manifest hashes.
    set path [file join $::sc7f0_out_dir bus-skew.rpt]
    if {![file exists $path]} {
        set r(error) "report_bus_skew is unavailable and this round's report "
        append r(error) "$::sc7f0_out_dir/bus-skew.rpt does not exist"
        return [array get r]
    }
    set cache [sc7f0_text $path]
    set source "this round's bus-skew.rpt"
    set r(text) $cache
    set r(source) $source
    return [array get r]
}

# "Id  Position  From ..." summary table -> {constraint id} position.
proc sc7f0_bus_skew_positions {text} {
    array set map {}
    foreach line [split $text \n] {
        if {[regexp {^\s*([0-9]+)\s+([0-9]+)\s+\[get_} $line unused id position]} {
            set map($id) $position
        }
    }
    return [array get map]
}

# Section 2 of the bus skew report is one block per constraint:
#   Id: 1
#   set_bus_skew -from <expr> -to <expr> 6.000
#   Requirement: 6.000ns
#   Endpoints: 64
#   Slack (MET) :             4.224ns  (requirement - actual skew)
#   Actual Bus Skew:            1.776ns  (...)
# One flat dict per block is returned; the declaration line is what identifies
# the named root.
proc sc7f0_bus_skew_rows {text} {
    set rows {}
    set have 0
    array set cur {}
    foreach line [split $text \n] {
        if {[regexp {^Id:\s*([0-9]+)\s*$} $line unused id]} {
            if {$have} {lappend rows [array get cur]}
            catch {array unset cur}
            array set cur {constraint_id {} from_expr {} to_expr {} requirement {}
                           endpoints {} actual {} slack {} violated 0}
            # assigned, not written inside { }: braces do not substitute, and a
            # literal "$id" here would be reported as the constraint's name
            set cur(constraint_id) $id
            set have 1
            continue
        }
        if {!$have} continue
        if {[regexp {^set_bus_skew\s.*-from\s+(.+)\s+-to\s+(.+?)\s+([0-9.]+)\s*$} \
                $line unused from_expr to_expr requirement]} {
            set cur(from_expr) $from_expr
            set cur(to_expr) $to_expr
            if {$cur(requirement) eq ""} {set cur(requirement) $requirement}
        } elseif {[regexp {^Requirement:\s*([0-9.]+)ns} $line unused value]} {
            set cur(requirement) $value
        } elseif {[regexp {^\s*Endpoints:\s*([0-9]+)} $line unused count]} {
            set cur(endpoints) $count
        } elseif {[regexp {^\s*Actual Bus Skew:\s*([0-9.]+)ns} $line unused value]} {
            set cur(actual) $value
        } elseif {[regexp {^\s*Slack \((MET|VIOLATED)\)\s*:\s*(-?[0-9.]+)ns} \
                      $line unused verdict value]} {
            set cur(slack) $value
            if {$verdict eq {VIOLATED}} {set cur(violated) 1}
        }
    }
    if {$have} {lappend rows [array get cur]}
    return $rows
}

# The named root is recognised by the very expression the constraint was created
# with, because the report prints that expression verbatim.
proc sc7f0_expr_names_root {expression root} {
    if {$expression eq "" || $root eq ""} {return 0}
    return [expr {[string first $root $expression] >= 0 ? 1 : 0}]
}

proc sc7f0_bus_skew {from to from_re to_re} {
    array set r {constraints 0 requirement {} actual {} slack {} violated 0
                 measured 0 constraint_id {} position {} endpoints {} match {}
                 report_source {} probe_error {}}
    if {$from_re eq "" || $to_re eq ""} {
        set r(probe_error) "no named root to look the bus skew constraint up by"
        return [array get r]
    }
    array set rep [sc7f0_bus_skew_report]
    if {$rep(error) ne ""} {
        set r(probe_error) $rep(error)
        return [array get r]
    }
    set r(report_source) $rep(source)
    array unset positions
    array set positions [sc7f0_bus_skew_positions $rep(text)]
    set rows [sc7f0_bus_skew_rows $rep(text)]
    set r(constraints) [llength $rows]
    set matches {}
    foreach row $rows {
        array unset rowrec
        array set rowrec $row
        if {![sc7f0_expr_names_root $rowrec(from_expr) $from_re]} continue
        if {![sc7f0_expr_names_root $rowrec(to_expr) $to_re]} continue
        lappend matches $row
    }
    if {[llength $matches] == 0} {
        set r(probe_error) "no set_bus_skew constraint of $r(constraints) reported "
        append r(probe_error) "matches the named root $from_re -> $to_re; "
        append r(probe_error) "bus skew was NOT measured"
        return [array get r]
    }
    if {[llength $matches] > 1} {
        set r(probe_error) "bus skew root $from_re -> $to_re matched "
        append r(probe_error) "[llength $matches] constraints; refusing to guess "
        append r(probe_error) "which one to grade"
        return [array get r]
    }
    array unset hit
    array set hit [lindex $matches 0]
    set r(measured) 1
    set r(constraint_id) $hit(constraint_id)
    set r(requirement) $hit(requirement)
    set r(actual) $hit(actual)
    set r(slack) $hit(slack)
    set r(violated) $hit(violated)
    set r(endpoints) $hit(endpoints)
    if {[info exists positions($hit(constraint_id))]} {
        set r(position) $positions($hit(constraint_id))
    }
    set r(match) "constraint $hit(constraint_id), -from expression contains $from_re"
    return [array get r]
}

array set sc7f0_items {}
proc sc7f0_put {id fields} {
    upvar #0 sc7f0_items items
    set items($id) $fields
}

# ---------------------------------------------------------------------------
# design level facts
# ---------------------------------------------------------------------------
# T5: the design state has to be an evidence-backed value.  Vivado writes its own
# wording into the header of every report it puts in the report directory
# (| Design State      : Physopt postRoute ), and scripts/check_sc7f0_timing.py
# grades exactly that string, so the hook reads it back from those reports and
# cross-checks the live design object.  Round 26111202 wrote "design_state": "",
# which the policy correctly refused; an unknown or pre-route state still fails.
set post_route_states [list {Routed} {Physopt postRoute} {Fully Routed}]
set state_evidence {}
set design_state {}
set design_state_source {}
foreach name [list timing_summary.rpt check-timing.rpt cdc.rpt methodology.rpt \
                  bus-skew.rpt drc.rpt exceptions-coverage.rpt clock-interaction.rpt \
                  io.rpt] {
    set path [file join $out_dir $name]
    if {![file exists $path]} {continue}
    if {[regexp -line {^\|?\s*Design State\s*:\s*(.+)$} [sc7f0_text $path] unused state]} {
        set state [string trim $state]
        if {$design_state eq ""} {
            set design_state $state
            set design_state_source $name
        }
        if {[lsearch -exact $state_evidence "$name=$state"] < 0} {
            lappend state_evidence "$name=$state"
        }
    }
}
# Cross-checks.  These are recorded, never trusted on their own: a design-object
# property is not this round's report, and a project run does not even exist when
# the hook is replayed on a checkpoint.  Built with lappend because a newline
# inside [ ... ] terminates the command - a multi-line list there is a syntax
# error, not a continuation.
set state_probes {}
lappend state_probes current_design.STATE {get_property STATE [current_design]}
lappend state_probes current_design.DESIGN_STATE {get_property DESIGN_STATE [current_design]}
lappend state_probes run_impl_1.STATE {get_property STATE [get_runs impl_1]}
foreach {probe_label probe_code} $state_probes {
    if {[catch {uplevel #0 $probe_code} probe_value]} {
        lappend state_evidence "$probe_label=query_failed"
    } elseif {[string trim $probe_value] eq ""} {
        lappend state_evidence "$probe_label=empty"
    } else {
        lappend state_evidence "$probe_label=[string trim $probe_value]"
    }
}
set design_state_error {}
if {$design_state eq ""} {
    set design_state_error "no report in $out_dir carries a Vivado \"Design State\" "
    append design_state_error "header, so this round cannot prove it was routed"
} elseif {[lsearch -exact $post_route_states $design_state] < 0} {
    set state_list [join $post_route_states {|}]
    set design_state_error "design state $design_state (read from "
    append design_state_error "$design_state_source) is not a known post-route "
    append design_state_error "state ($state_list); refusing to assume routing"
}
set clock_group_rows [sc7f0_count "$out_dir/exceptions-coverage.rpt" {Clock Group}]
set cdc_sha [sc7f0_sha256 "$out_dir/cdc.rpt"]

# Binding every gate input, not just cdc.rpt.  cdc.rpt + manifest used to be the
# only round binding, so a methodology.rpt / drc.rpt / check-timing.rpt from
# another round could be graded against this round's CDC evidence (the hand-made
# tmp-named-evidence-check/ pair is exactly that shape).  Reports only: logs and
# the manifest itself are never hashed, because a hash of the file inside the file
# proves nothing and log bytes are not deterministic.
set gate_reports [list timing_summary.rpt check-timing.rpt cdc.rpt methodology.rpt \
    bus-skew.rpt drc.rpt clock-interaction.rpt exceptions-ignored.rpt \
    exceptions-scope-override.rpt exceptions-coverage.rpt exceptions-all.rpt io.rpt \
    clock-networks.rpt disable-timing-user.rpt utilization_routed_hierarchical.rpt]
set report_hashes {}
foreach name $gate_reports {
    if {![file exists "$out_dir/$name"]} {continue}
    set digest [sc7f0_sha256 "$out_dir/$name"]
    if {$digest eq ""} {continue}
    lappend report_hashes "\"$name\": \"$digest\""
}

sc7f0_put clock_groups [list class metric review_required 0 count \
    [expr {$clock_group_rows < 0 ? 0 : $clock_group_rows}]]

# ---------------------------------------------------------------------------
# named max-delay / bus-skew exceptions
#   id | from cell regexp | from pin | to cell regexp | to pin |
#   expected max_delay ns (0 = any) | expected bus skew ns (0 = none expected)
#
# overlay_epoch_sync_max_delay / overlay_poison_sync_max_delay /
# overlay_arm_sync_max_delay are the three hand-rolled 125 MHz -> 300 MHz
# single-bit synchronisers of the RGB overlay path (writer epoch_sync_l[0],
# writer poison_sync[0], ingress sync0), bounded by constraints/
# sc7f0_overlay_sync.xdc with set_max_delay -datapath_only 3.333 -to the named
# first stage.  Measured on rgb-fullimpl-26111331-20261113T194329Z (routed,
# BEFORE that file existed): -1.109 / -0.923 / -0.913 ns against a 0.337 ns
# requirement, 0-1 logic levels, 1.42-1.72 ns data path - those three async
# endpoints were the whole design's WNS.  These rows measure them (object counts,
# timed paths, the REQUIREMENT the engine applied this round); they approve
# nothing: scripts/gates/*.json holds no REVIEWED_SAFE entry for them, so the
# gate still fails them closed until a reviewer writes one.  No comment may be
# written INSIDE the [list] below - within a command substitution '#' is a
# literal word, so prose there silently becomes table rows (caught by
# test_stub_harness_runs_the_evidence_hook_end_to_end).
# ---------------------------------------------------------------------------
set max_delay_table [list \
    [list probe_meter_max_delay \
        {.*/u_meter[A-Za-z0-9_]*/snapshot_test_reg\[[0-9]+\]} {} \
        {.*/u_meter[A-Za-z0-9_]*/(measured_freq_hz|raw_cycle_count)_reg\[[0-9]+\]} {} \
        10.000 0] \
    [list capture_gray_to_source_time \
        {.*u_ps_capture/u_tap/gray_q_reg\[[0-9]+\]} {} \
        {.*u_ps_capture/u_tap/u_source_time/stage0_reg\[[0-9]+\]} {} 6.000 6.000] \
    [list overlay_epoch_sync_max_delay \
        {.*u_pcie_ip/inst/user_reset_reg.*} {} \
        {.*u_overlay_writer/epoch_sync_l_reg\[0\]} {} 3.333 0] \
    [list overlay_poison_sync_max_delay \
        {.*u_overlay_writer/debt_poison_epoch_reg} {} \
        {.*u_overlay_writer/poison_sync_reg\[0\]} {} 3.333 0] \
    [list overlay_arm_sync_max_delay \
        {.*u_overlay_ingress/arm_toggle_reg} {} \
        {.*u_overlay_ingress/sync0_reg} {} 3.333 0] \
    [list capture_gray_to_csr_time \
        {.*u_ps_capture/u_tap/gray_q_reg\[[0-9]+\]} {} \
        {.*u_ps_capture/u_regs/u_time/stage0_reg\[[0-9]+\]} {} 6.000 6.000] \
    [list rx_ss_dpram_max_delay \
        {.*aclk_dpram_reg.*} {CLK} {.*bclk_dout_reg.*} {D} 15.000 0] \
    [list xpm_async_fifo_ce_arcs \
        {.*gnuram_async_fifo\..*xpm_memory_base_inst.*} {CLK} \
        {.*gnuram_async_fifo\..*xpm_fifo_base_inst.*doutb?_reg.*} {D} 0 0]]

foreach row $max_delay_table {
    foreach {id from_re from_pin to_re to_pin want_delay want_skew} $row break
    set from [sc7f0_select $from_re $from_pin]
    set to [sc7f0_select $to_re $to_pin]
    # array set only overwrites the keys it lists: clear first, or a field from
    # the previous row (bus_skew_ns, max_delay_effective, ...) would leak into
    # this item's record and hide a missing measurement.
    catch {array unset rec}
    array set rec {class cdc_constraint review_required 1 probe_error {}}
    set rec(from_objects) [llength $from]
    set rec(to_objects) [llength $to]
    # One failing item must not cost the rest of the manifest: the body is
    # caught, the failure is recorded on THIS item, and the hook still fails at
    # the end because a probe_error is a problem (never a silent pass).
    if {[catch {
    array set t [sc7f0_timing $from $to 8]
    set rec(paths_analysed) $t(paths)
    set rec(requirement) $t(requirement)
    set rec(worst_slack) $t(slack)
    if {$t(probe_error) ne ""} {append rec(probe_error) $t(probe_error) " "}
    if {$want_delay > 0} {
        # The table value is only what this file expects.  What the policy is
        # allowed to check is max_delay_measured_ns, i.e. the REQUIREMENT the
        # timing engine applied to the routed netlist this round; comparing the
        # policy against the producer's own hope was a tautology (review P1-3).
        set rec(max_delay_expected_ns) $want_delay
        set requirement $t(requirement)
        if {[string is double -strict $requirement]} {
            set rec(max_delay_measured_ns) $requirement
            if {[expr {abs($requirement - $want_delay) < 0.001}]} {
                set rec(max_delay_effective) 1
            } else {
                set rec(max_delay_effective) 0
            }
        } else {
            # No numeric requirement means the pair is not timed by a max delay at
            # all (a clock group swallowed it, or no paths came back): that is
            # max_delay_effective = 0, not "the value we wanted".
            set rec(max_delay_effective) 0
        }
    }
    array set e [sc7f0_exception $from $to $id]
    set rec(exception_position) $e(position)
    set rec(exception_type) $e(type)
    set rec(exception_setup) $e(setup)
    set rec(endpoints) [expr {$e(endpoints) eq {} ? 0 : $e(endpoints)}]
    set rec(endpoints_total) $e(endpoints_total)
    set rec(exception_rows) $e(coverage_rows)
    set rec(from_coverage_pct) $e(from_pct)
    set rec(to_coverage_pct) $e(to_pct)
    set rec(coverage_from_column) $e(coverage_from)
    set rec(coverage_to_column) $e(coverage_to)
    set rec(coverage_row) $e(coverage_row)
    set rec(ignored) $e(ignored)
    set rec(scope_overridden) $e(scope_overridden)
    set rec(exception_audit_source) $e(audit_source)
    if {$e(probe_error) ne ""} {append rec(probe_error) $e(probe_error) " "}
    if {$want_skew > 0} {
        # 2023.2 has no scoped report_bus_skew, so the named root is looked up in
        # the one report this run takes; a missing root is recorded as "bus skew
        # was NOT measured" and fails the round (T4).
        array set s [sc7f0_bus_skew $from $to $from_re $to_re]
        set rec(bus_skew_measured) $s(measured)
        set rec(bus_skew_ns) $s(requirement)
        set rec(bus_skew_actual_ns) $s(actual)
        set rec(bus_skew_slack_ns) $s(slack)
        set rec(bus_skew_violated) $s(violated)
        set rec(bus_skew_constraint_id) $s(constraint_id)
        set rec(bus_skew_position) $s(position)
        set rec(bus_skew_endpoints) $s(endpoints)
        set rec(bus_skew_report_source) $s(report_source)
        if {$s(probe_error) ne ""} {append rec(probe_error) $s(probe_error) " "}
    }
    } err]} {
        append rec(probe_error) "item query aborted: $err "
        incr ::sc7f0_section_errors
    }
    sc7f0_put $id [array get rec]
}

# The DPRAM sample-timing item only proves the cross-domain arcs are still
# analysed (the vendor does NOT disable them: measured 416 CLK->O, 0 disabled).
catch {array unset drec}
array set drec {class cdc_constraint review_required 1 probe_error {}}
if {[catch {
set dpram_from [sc7f0_select {.*aclk_dpram_reg.*} {CLK}]
set dpram_to [sc7f0_select {.*bclk_dout_reg.*} {D}]
set drec(from_objects) [llength $dpram_from]
set drec(to_objects) [llength $dpram_to]
array set d [sc7f0_timing $dpram_from $dpram_to 16]
set drec(paths_analysed) $d(paths)
set drec(requirement) $d(requirement)
set drec(worst_slack) $d(slack)
set drec(instances) [sc7f0_count "$out_dir/clock-networks.rpt" {aclk_dpram}]
} err]} {
    append drec(probe_error) "item query aborted: $err "
    incr ::sc7f0_section_errors
}
# `instances` lives on THIS item (it counts the DPRAM clock-network rows), not on
# rx_ss_dpram_max_delay: a policy requirement for instance families must be
# attached to the record whose producer actually measures them (review P1-2).
set drec(max_delay_measured_ns) $d(requirement)
sc7f0_put rx_ss_dpram_sample_timing [array get drec]

# ---------------------------------------------------------------------------
# asynchronous IO exceptions (class io_exception -> must be named in io_items)
#   id | port list | first-stage cell regexp (empty = output-only exception)
# ---------------------------------------------------------------------------
set io_table [list \
    [list async_in_hdmi_tx_hpd_in {hdmi_tx_hpd_in} {.*u_hdmi_probe/tx_hpd_sync_reg\[0\]}] \
    [list async_in_hdmi_tx_ddc_scl {hdmi_tx_ddc_scl} {.*u_hdmi_probe/tx_scl_sync_reg\[0\]}] \
    [list async_in_hdmi_tx_ddc_sda {hdmi_tx_ddc_sda} {.*u_hdmi_probe/tx_sda_sync_reg\[0\]}] \
    [list async_in_hdmi_tx_refclk_rdy {hdmi_tx_refclk_rdy} {.*u_hdmi_probe/tx_rdy_sync_reg\[0\]}] \
    [list async_in_hdmi_tx_refclk_rdy_vphy {hdmi_tx_refclk_rdy} \
        {.*clock_detector_inst/TX_LOCK_CAP_INST/syncstages_ff_reg\[0\]}] \
    [list async_in_hdmi_rx_5v_det_probe {hdmi_rx_5v_det} {.*u_hdmi_probe/det5v_sync_reg\[0\]}] \
    [list async_in_hdmi_rx_5v_det_pcie {hdmi_rx_5v_det} {.*sync_5v_det_q_reg\[0\]}] \
    [list async_in_hdmi_rx_5v_det_rxss {hdmi_rx_5v_det} \
        {.*CD_INST/DET_SYNC_INST/XPM_INST/syncstages_ff_reg\[0\]}] \
    [list async_in_hdmi_rx_ddc_scl_probe {hdmi_rx_ddc_scl} {.*u_hdmi_probe/scl_sync_reg\[0\]}] \
    [list async_in_hdmi_rx_ddc_scl_filter {hdmi_rx_ddc_scl} {.*DDC_INST/clk_scl_flt_reg\[0\]}] \
    [list async_in_hdmi_rx_ddc_sda_probe {hdmi_rx_ddc_sda} {.*u_hdmi_probe/sda_sync_reg\[0\]}] \
    [list async_in_hdmi_rx_ddc_sda_filter {hdmi_rx_ddc_sda} {.*DDC_INST/clk_sda_flt_reg\[0\]}] \
    [list async_out_hdmi_rx_hpd_out {hdmi_rx_hpd_out} {}] \
    [list async_out_leds {user_led_dma_active user_led_pcie_link_up} {}] \
    [list async_out_hdmi_rx_ddc_scl {hdmi_rx_ddc_scl} {}] \
    [list async_out_hdmi_rx_ddc_sda {hdmi_rx_ddc_sda} {}]]

# ---------------------------------------------------------------------------
# HDMI TX subsystem first stages (SC7F0-RGB profile, row set verified against
# the design, never against a wish).
#
# Candidate rgb-fullimpl-26111335-20261113T214238Z (E) failed Layer B with three
# unclaimed first-stage loads: hdmi_tx_ddc_scl / hdmi_tx_ddc_sda on
# u_hdmi_tx_ss/.../SYS_INST/GEN_DDC.DDC_INST/clk_{scl,sda}_flt_reg[0] and
# hdmi_tx_hpd_in on .../SYS_INST/HPD_INST/HPD_CAP_INST/XPM_INST/syncstages_ff_reg[0]
# (E/evidence-r3-finaldcp/reports/named-constraint-evidence.json, three items with
# endpoint_count = 2 and claimed_first_stage_endpoints = 1;
# E/logs/runner_post_r3.log:218-260).  The legacy rows at
# constraints/sc7f0_async_io.xdc:60-71 claim only our u_hdmi_probe chain and say
# why: they were written while the TX subsystem was not built.  With the RGB
# compositor the TX SS is a second, real consumer of the same asynchronous pads,
# so it gets its own named row per chain - the same shape the RX DDC pair and
# hdmi_rx_5v_det already use.  Nothing is deleted, nothing is marked NA, no item
# is NA'd and no coverage rule is relaxed: the pad closure below still enumerates
# every sequential load of each pad with all_fanout and fails on any load these
# rows do not name, so a fourth consumer still stops the round.
#
# The rows are added only when (a) this is the RGB profile and (b) the design
# really contains the TX subsystem.  Both halves are required: (a) keeps the
# legacy capture-only and display personalities answering the same 40 items they
# answered before, and (b) makes the RGB round fail closed if the subsystem is
# renamed or dropped rather than reporting an empty to_objects as clean.  The
# exceptions themselves are applied by scripts/apply_sc7f0_tx_io_first_stage.tcl
# (STEPS.OPT_DESIGN.TCL.PRE, RGB branch), which guards 1 port / 1 cell / 1 D pin
# and reads the exception back; a row here without its exception in the design
# reports exception_type/position as missing and fails the manifest.
# ---------------------------------------------------------------------------
set sc7f0_tx_rgb_profile [expr {[info exists ::env(SC7F0_RGB_COMPOSITOR)] &&
    [string tolower [string trim $::env(SC7F0_RGB_COMPOSITOR)]] in {1 true yes}}]
set sc7f0_tx_ss_cells [get_cells -quiet -hier -regexp {.*u_hdmi_tx_ss/inst/v_hdmi_tx/inst/SYS_INST/.*}]
puts "SC7F0_NAMED_TX_SS_CELLS objects=[llength $sc7f0_tx_ss_cells] rgb_profile=$sc7f0_tx_rgb_profile"
if {$sc7f0_tx_rgb_profile} {
    if {[llength $sc7f0_tx_ss_cells] == 0} {
        error "SC7F0_NAMED_TX_SS_ABSENT: the SC7F0-RGB profile builds v_hdmi_tx inside u_hdmi_tx_ss, but this design has 0 cells under u_hdmi_tx_ss/inst/v_hdmi_tx/inst/SYS_INST. Either the TX subsystem disappeared (a functional change, not a measurement change) or the hierarchy moved; the three TX input rows below cannot be graded from an absent subsystem."
    }
    lappend io_table \
        [list async_in_hdmi_tx_hpd_in_txss {hdmi_tx_hpd_in} \
            {.*u_hdmi_tx_ss/inst/v_hdmi_tx/inst/SYS_INST/HPD_INST/HPD_CAP_INST/XPM_INST/syncstages_ff_reg\[0\]}] \
        [list async_in_hdmi_tx_ddc_scl_filter {hdmi_tx_ddc_scl} \
            {.*u_hdmi_tx_ss/inst/v_hdmi_tx/inst/SYS_INST/GEN_DDC.DDC_INST/clk_scl_flt_reg\[0\]}] \
        [list async_in_hdmi_tx_ddc_sda_filter {hdmi_tx_ddc_sda} \
            {.*u_hdmi_tx_ss/inst/v_hdmi_tx/inst/SYS_INST/GEN_DDC.DDC_INST/clk_sda_flt_reg\[0\]}]
    # Output direction of the same DDC pair.  These two ids are the manifest half
    # of the two rows scripts/apply_sc7f0_tx_io_first_stage.tcl now applies
    # (`set_false_path -to [get_ports hdmi_tx_ddc_scl|sda]`), and they exist for a
    # measured reason: round rgb-fullimpl-26111403-20261114T041353Z still reported
    #   TIMING-18#1  An output delay is missing on hdmi_tx_ddc_scl relative to the
    #                rising and/or falling clock edge(s) of clk_pl_0
    #   TIMING-18#2  ... on hdmi_tx_ddc_sda ...
    # (audit_final_dcp/methodology_final.rpt:1655-1663), i.e. a fabric register
    # launches each pad and nothing describes when.  The pad is a passive I2C line
    # whose timing is the bus protocol, not clk_pl_0, so the honest constraint is
    # an output-direction false path ending at the pad - the identical shape the RX
    # DDC pair already carries above (async_out_hdmi_rx_ddc_scl / _sda,
    # constraints/sc7f0_async_io.xdc:183/185).
    #
    # What this does NOT do: it adds no input-direction exception, so the pad's two
    # measured first-stage loads (vendor clk_*_flt_reg[0] and u_hdmi_probe) stay
    # individually claimed by the four async_in_* rows and the pad closure still
    # fails on a third load; the output-only branch of the loop below measures
    # direction / IOSTANDARD / pad leaf / endpoint count and demands that a named
    # exception really resolves at the port.  Both ids stay review_required = 1:
    # adding a row to the manifest is not the same as approving the crossing, and
    # no gate JSON is edited here.
    lappend io_table \
        [list async_out_hdmi_tx_ddc_scl {hdmi_tx_ddc_scl} {}] \
        [list async_out_hdmi_tx_ddc_sda {hdmi_tx_ddc_sda} {}]
} else {
    # Capture-only personality: the TMDS clock pads are not driven as a forwarded
    # clock here (HDMI TX is not the acceptance path), so the historical
    # output-direction exception record stays, and only here.  The two commands live
    # in constraints/sc7f0_tx_tmds_clk_capture_only.xdc, which scripts/build_zu4ev.tcl
    # mounts in this branch only.  In the RGB profile this id is deliberately absent:
    # the pads get the tx_tmds_clock_forwarded record below instead, and a record
    # that names an exception which no longer exists would be a fake, not evidence.
    lappend io_table \
        [list async_out_hdmi_tx_tmds_clk {hdmi_tx_tmds_clk_p hdmi_tx_tmds_clk_n} {}]
}

# OSERDESE3 population of the routed netlist: the TMDS pad entry is reviewed as
# "the VPHY still serialises into this pad" (build/evidence-dcpio-26111106/query/
# s4-tx-tmds-driver.txt), so the driver family has to be re-measured every round.
set oserdes_cells [get_cells -quiet -hier -filter {REF_NAME =~ OSERDESE3*}]
set oserdes_count [llength $oserdes_cells]
catch {array unset claims}

foreach row $io_table {
    foreach {id ports first_stage} $row break
    catch {array unset rec}
    array set rec {class io_exception review_required 1 endpoints 0 endpoint_count 0 \
                   probe_error {} ignored 0 scope_overridden 0 clock_or_setreset_pin_loads 0 \
                   paths_analysed 0}
    set rec(port) $ports
    set port_list [get_ports -quiet $ports]
    set rec(from_objects) [llength $port_list]
    # One failing entry must not cost the rest of the manifest (see the note in
    # the max-delay loop above).
    if {[catch {
    if {$first_stage ne ""} {
        set to [get_cells -quiet -hier -regexp $first_stage]
        set rec(to_objects) [llength $to]
        set rec(first_stage_cells) $first_stage
        set async 0
        if {[llength $to] > 0} {
            array set sc7f0_async_prop [sc7f0_prop ASYNC_REG $to]
            if {$sc7f0_async_prop(error) eq ""} {
                foreach flag $sc7f0_async_prop(values) {
                    if {[sc7f0_true $flag]} {incr async}
                }
            } else {
                append rec(probe_error) "$sc7f0_async_prop(error) "
            }
        }
        set rec(first_stage_async_reg) $async
        set rec(first_stage_clock_domains) [sc7f0_clks $to]
        # What the first stage drives.  A pad exception may only cut pad -> first
        # FF, so everything downstream must sit in the same clock domain AND stay
        # analysed; internal_filter_same_domain + paths_analysed are that proof in
        # machine-readable form (review P1-8: the RX DDC vendor filter must keep
        # its full-speed 10 ns timing, only the pad entry may be excepted).
        # The loads are resolved to cells by sc7f0_fanout_loads: the previous
        # revision stringified each endpoint and asked for its cell one by one,
        # which resolves to nothing and left internal_load_count at 0 (T1).
        array set loads [sc7f0_fanout_loads $to]
        set rec(internal_load_count) $loads(cell_count)
        set rec(internal_load_endpoint_count) $loads(endpoint_count)
        set rec(internal_load_sequential_count) $loads(seq_count)
        set rec(internal_load_clock_domains) $loads(clocks)
        set rec(internal_load_clock_pin_loads) $loads(clock_pin_loads)
        set rec(internal_load_ref_families) $loads(ref_families)
        set rec(internal_load_method) $loads(method)
        if {$loads(probe_error) ne ""} {
            append rec(probe_error) "first-stage loads: $loads(probe_error) "
        }
        set same 0
        set domains {}
        foreach candidate [concat [split $rec(first_stage_clock_domains) |] \
                                [split $rec(internal_load_clock_domains) |]] {
            # "-" is "measured, no clock", not a clock domain, and QUERY_ERROR is
            # a failed query: neither may be counted as a domain, because that is
            # how a round used to reach clock_domain_count = 2 from one clock.
            if {$candidate eq "-" || $candidate eq {QUERY_ERROR}} continue
            if {[lsearch -exact $domains $candidate] < 0} {lappend domains $candidate}
        }
        set rec(clock_domain_names) [join $domains |]
        set rec(clock_domain_count) [llength $domains]
        if {[llength $domains] == 1} {set same 1}
        set rec(internal_filter_same_domain) $same
        if {$loads(cell_count) > 0} {
            array set it [sc7f0_timing $to $loads(cells) 4]
            set rec(paths_analysed) $it(paths)
            set rec(internal_worst_slack) $it(slack)
            if {$it(probe_error) ne ""} {append rec(probe_error) $it(probe_error) " "}
        }
        array set e [sc7f0_exception $port_list $to $id]
        set rec(exception_position) $e(position)
        set rec(exception_type) $e(type)
        set rec(exception_rows) $e(coverage_rows)
        set rec(ignored) $e(ignored)
        set rec(scope_overridden) $e(scope_overridden)
        set rec(exception_audit_source) $e(audit_source)
        if {$e(probe_error) ne ""} {append rec(probe_error) $e(probe_error) " "}
        # The pad's own loads, measured by the same resolver the closure item
        # uses, so the two records cannot disagree about the same pad.  The old
        # pin-role list lacked R and S, so a load on an async set / reset pin
        # counted as 0; the pin names seen are recorded next to the count.
        array set pad [sc7f0_fanout_loads $port_list]
        set rec(endpoint_count) $pad(endpoint_count)
        set rec(endpoint_pin_names) [join $pad(pin_roles) |]
        set rec(pad_load_cell_count) $pad(cell_count)
        set rec(pad_load_method) $pad(method)
        set rec(clock_or_setreset_pin_loads) $pad(clock_pin_loads)
        if {$pad(probe_error) ne ""} {append rec(probe_error) "pad fanout: $pad(probe_error) "}
        foreach p $port_list {lappend claims($p) [join [sc7f0_names $to] {|}]}
    } else {
        set rec(to_objects) [llength $port_list]
        set rec(direction) [sc7f0_join [get_property DIRECTION $port_list]]
        set rec(io_standard) [sc7f0_join [get_property IOSTANDARD $port_list]]
        set rec(port_count) [llength $port_list]
        array set drv [sc7f0_pad_drivers $port_list]
        set rec(pad_driver_cells) [llength $drv(cells)]
        set rec(pad_driver_refs) [join $drv(refs) |]
        set rec(pad_driver_clock_domains) $drv(clocks)
        set rec(driver_is_vphy) [expr {[string match *vid_phy* $rec(pad_driver_refs)] ? 1 : 0}]
        set rec(driver_is_obuf) [expr {[string match *OBUF* $rec(pad_driver_refs)] ? 1 : 0}]
        set rec(oserdes_cells) $oserdes_count
        if {$drv(errors) ne ""} {append rec(probe_error) $drv(errors)}
        set endpoints {}
        if {[catch {all_fanout -flat -endpoints_only $port_list} endpoints]} {
            append rec(probe_error) "all_fanout(port) failed "
        }
        set rec(endpoint_count) [llength [lsort -unique $endpoints]]
        array set pp [sc7f0_prop REF_PIN_NAME $endpoints]
        if {$pp(error) eq ""} {
            set rec(endpoint_pin_names) [join [lsort -unique $pp(values)] |]
        } else {
            append rec(probe_error) "$pp(error) "
        }
        # An output direction is excepted at the pad, so the exception is queried
        # on the pad alone (no -from).  Measuring the driver without also proving
        # that the named constraint exists would let a deleted set_false_path pass
        # as "everything measured": no position is a named failure here.
        array set e [sc7f0_exception {} $port_list $id 0]
        set rec(exception_position) $e(position)
        set rec(exception_type) $e(type)
        set rec(exception_rows) $e(coverage_rows)
        set rec(ignored) $e(ignored)
        set rec(scope_overridden) $e(scope_overridden)
        set rec(exception_audit_source) $e(audit_source)
        set rec(exception_from_coverage) $e(from_coverage)
        if {$e(probe_error) ne ""} {append rec(probe_error) "$e(probe_error) "}
        if {$e(position) eq ""} {
            append rec(probe_error) "no exception resolves at port(s) $ports: the "
            append rec(probe_error) "named output-direction constraint $id is not in "
            append rec(probe_error) "this design "
        }
    }
    } err]} {
        append rec(probe_error) "item query aborted: $err "
        incr ::sc7f0_section_errors
    }
    sc7f0_put $id [array get rec]
}

# ---------------------------------------------------------------------------
# TX TMDS clock pads, SC7F0-RGB (TX-live) profile: forwarded-clock record.
#
# This REPLACES async_out_hdmi_tx_tmds_clk in this profile. That record graded an
# output-direction false path on hdmi_tx_tmds_clk_p/_n, which was the capture-only
# personality's answer and whose own rationale said a TX personality must delete it.
# In the RGB profile those pads are the VPHY forwarded TMDS clock (MMCM CLKOUT1 ->
# OSERDESE3 in ODDR mode -> OBUFTDS -> the differential pair), constrained by
# scripts/apply_sc7f0_tx_tmds_clock_forward.tcl as a generated clock, and the two
# legacy set_false_path commands now live only in constraints/
# sc7f0_tx_tmds_clk_capture_only.xdc (mounted by scripts/build_zu4ev.tcl for the
# capture profile only). So this record measures a CLOCK, not an exception:
#   * the forwarder and buffer cells with REF_NAME / ODDR_MODE / DATA_WIDTH,
#   * the canonical forwarded-clock pin pattern (UG903 D[0]=1, D[4]=0, no CE,
#     CLK == CLKDIV) read back as constant nets, not copied from a comment,
#   * the pad clock objects: period, both waveforms, master, root clock and port,
#   * the required negatives: 0 exception rows -to either pad and 0 clock groups
#     naming the pad clocks (a pad that is both a clock and excepted would be
#     green-without-model).
# review_required stays 1: measuring a topology is not approving it, and no policy
# JSON is edited here. Until scripts/gates/sc7f0_cdc_review.json carries a matching
# entry the Layer B coverage check fails on this id, which is the fail-closed
# direction: an unreviewed record must stop the round, not pass it.
# ---------------------------------------------------------------------------
if {$sc7f0_tx_rgb_profile} {
if {[info procs sc7f0_fwd_pin] eq ""} {
proc sc7f0_fwd_pin {cell suffix} {
    set n [string length $suffix]
    set out {}
    foreach p [get_pins -quiet -of_objects $cell] {
        set nm [get_property NAME $p]
        if {[string length $nm] >= $n &&
            [string equal [string range $nm end-[expr {$n - 1}] end] $suffix]} {lappend out $p}
    }
    return $out
}
}
if {[info procs sc7f0_fwd_pin_state] eq ""} {
proc sc7f0_fwd_pin_state {cell suffix} {
    set hit [sc7f0_fwd_pin $cell $suffix]
    if {[llength $hit] != 1} {return "pin_absent([llength $hit])"}
    set nets [get_nets -quiet -of_objects [lindex $hit 0]]
    if {[llength $nets] == 0} {return "no_net"}
    set nm [lindex [get_property NAME [lindex $nets 0]] 0]
    set ty [lindex [get_property TYPE [lindex $nets 0]] 0]
    if {[string match {*<const1>} $nm] && $ty eq "POWER"}  {return VCC}
    if {[string match {*<const0>} $nm] && $ty eq "GROUND"} {return GND}
    if {$ty eq "SIGNAL"} {return "SIGNAL:$nm"}
    return "OTHER:$ty:$nm"
}
}
if {[info procs sc7f0_fwd_net_name] eq ""} {
proc sc7f0_fwd_net_name {cell suffix} {
    set hit [sc7f0_fwd_pin $cell $suffix]
    if {[llength $hit] != 1} {return ""}
    set nets [get_nets -quiet -of_objects [lindex $hit 0]]
    if {[llength $nets] != 1} {return ""}
    return [lindex [get_property NAME [lindex $nets 0]] 0]
}
}
catch {array set fwd_rec {}}
array set fwd_rec {class forwarded_clock review_required 1 probe_error {} measured 0 \
    ports {hdmi_tx_tmds_clk_p hdmi_tx_tmds_clk_n} \
    forwarder {} forwarder_ref {} oddr_mode {} data_width {} \
    clk_net {} clkdiv_net {} clkdiv_same_net 0 d_pattern {} rst_state {} tri_state_state {} ce_pins 0 \
    buffer {} buffer_ref {} p_leg_net {} n_leg_net {} \
    clock_p_count 0 clock_n_count 0 clock_p_names {} clock_n_names {} \
    period_p {} period_n {} waveform_p {} waveform_n {} master_p {} master_n {} \
    source_clock {} source_period {} source_waveform {} root_clock {} root_port {} root_period {} \
    ratio_p {} ratio_n {} \
    exception_rows_p -1 exception_rows_n -1 exception_rows_to_p -1 exception_rows_to_n -1 clock_group_rows -1 \
    legacy_async_exception_on_pads -1}
if {[catch {
    set fwd_oddr u_vid_phy_controller/inst/gt_usrclk_source_inst/tx_mmcm.GT0_TX_MMCM_CLKOUT1_ODDR_INST
    set fwd_buf  u_vid_phy_controller/inst/gt_usrclk_source_inst/tx_mmcm.GT0_TX_MMCM_CLKOUT1_OBUFTDS_INST
    set fwd_rec(forwarder) $fwd_oddr
    set cells [get_cells -quiet $fwd_oddr]
    if {[llength $cells] != 1} {
        append fwd_rec(probe_error) "forwarder matched [llength $cells] objects "
    } else {
        set fcell [lindex $cells 0]
        set fwd_rec(forwarder_ref) [get_property REF_NAME $fcell]
        catch {set fwd_rec(oddr_mode) [get_property ODDR_MODE $fcell]}
        catch {set fwd_rec(data_width) [get_property DATA_WIDTH $fcell]}
        set states {}
        for {set i 0} {$i < 8} {incr i} {
            lappend states [format {D[%d]=%s} $i [sc7f0_fwd_pin_state $fcell [format {/D[%d]} $i]]]
        }
        set fwd_rec(d_pattern) [join $states ,]
        set fwd_rec(rst_state) [sc7f0_fwd_pin_state $fcell /RST]
        set fwd_rec(tri_state_state) [sc7f0_fwd_pin_state $fcell /T]
        set nce 0
        foreach p [get_pins -quiet -of_objects $fcell] {
            if {[string match {@*/CE} [get_property NAME $p]]} {incr nce}
        }
        set fwd_rec(ce_pins) $nce
        set fwd_rec(clk_net)    [sc7f0_fwd_net_name $fcell /CLK]
        set fwd_rec(clkdiv_net) [sc7f0_fwd_net_name $fcell /CLKDIV]
        if {$fwd_rec(clk_net) ne "" && $fwd_rec(clk_net) eq $fwd_rec(clkdiv_net)} {
            set fwd_rec(clkdiv_same_net) 1
        }
    }
    set fwd_rec(buffer) $fwd_buf
    set bcells [get_cells -quiet $fwd_buf]
    if {[llength $bcells] != 1} {
        append fwd_rec(probe_error) "buffer matched [llength $bcells] objects "
    } else {
        set bcell [lindex $bcells 0]
        set fwd_rec(buffer_ref) [get_property REF_NAME $bcell]
        set fwd_rec(p_leg_net) [sc7f0_fwd_net_name $bcell /O]
        set fwd_rec(n_leg_net) [sc7f0_fwd_net_name $bcell /OB]
    }
    foreach {pad nkey names_key per_key wave_key master_key ratio_key} [list \
        hdmi_tx_tmds_clk_p clock_p_count clock_p_names period_p waveform_p master_p ratio_p \
        hdmi_tx_tmds_clk_n clock_n_count clock_n_names period_n waveform_n master_n ratio_n] {
        set po [get_ports -quiet $pad]
        if {[llength $po] != 1} {append fwd_rec(probe_error) "$pad missing "; continue}
        set ck [get_clocks -quiet -of_objects $po]
        set fwd_rec($nkey) [llength $ck]
        if {[llength $ck] != 1} {continue}
        set fwd_rec($names_key)  [lindex [get_property NAME $ck] 0]
        set fwd_rec($per_key)    [lindex [get_property PERIOD $ck] 0]
        set fwd_rec($wave_key)   [join [lindex [get_property WAVEFORM $ck] 0] -]
        set fwd_rec($master_key) [lindex [get_property MASTER_CLOCK $ck] 0]
        set m [get_clocks -quiet $fwd_rec($master_key)]
        if {[llength $m] == 1} {
            set fwd_rec(source_clock)   [lindex [get_property NAME $m] 0]
            set fwd_rec(source_period)  [lindex [get_property PERIOD $m] 0]
            set fwd_rec(source_waveform) [join [lindex [get_property WAVEFORM $m] 0] -]
            set root $m
            for {set g 0} {$g < 12} {incr g} {
                if {![string is true -quiet [lindex [get_property IS_GENERATED $root] 0]]} {break}
                set mname [lindex [get_property MASTER_CLOCK $root] 0]
                if {$mname eq "" || [llength [get_clocks -quiet $mname]] != 1} {break}
                set root [get_clocks -quiet $mname]
            }
            set fwd_rec(root_clock)  [lindex [get_property NAME $root] 0]
            set fwd_rec(root_period) [lindex [get_property PERIOD $root] 0]
            set rp [get_ports -quiet -of_objects $root]
            if {[llength $rp] == 1} {set fwd_rec(root_port) [lindex [get_property NAME $rp] 0]}
            if {$fwd_rec(source_period) ne "" && $fwd_rec($per_key) ne "" &&
                [string is double -strict $fwd_rec(source_period)] &&
                [double $fwd_rec(source_period)] > 0} {
                set fwd_rec($ratio_key) [format {%.4f} [expr {double($fwd_rec($per_key)) / double($fwd_rec(source_period))}]]
            }
        }
    }
    foreach {pad slot to_slot} [list hdmi_tx_tmds_clk_p exception_rows_p exception_rows_to_p \
                                 hdmi_tx_tmds_clk_n exception_rows_n exception_rows_to_n] {
        set po [get_ports -quiet $pad]
        if {[llength $po] != 1} {continue}
        # -to filtered table and a name scan of the full -coverage table are counted
        # separately; the reported row count is the larger of the two, so a query form
        # that resolves nothing cannot read as "no exception on the clock pad".
        set txt [report_exceptions -coverage -quiet -return_string -to $po]
        set n 0
        foreach l [split $txt \n] {
            if {[regexp {^\d+\s+(False Path|Clock Groups|Multicycle Path|Max Delay|Min Delay)} [string trim $l]]} {incr n}
        }
        set fwd_rec($to_slot) $n
        set all [report_exceptions -quiet -return_string]
        set m 0
        foreach l [split $all \n] {
            set t [string trim $l]
            if {![regexp {^\d+\s} $t]} {continue}
            set pat "get_ports $pad"
            if {[string match *$pat* $t]} {incr m}
        }
        set fwd_rec($slot) [expr {$m > $n ? $m : $n}]
    }
    set all_exc [report_exceptions -coverage -quiet -return_string]
    set cg 0
    foreach l [split $all_exc \n] {
        if {[string match {*Clock Groups*} $l] && [string match {*hdmi_tx_tmds_clk_fwd*} $l]} {incr cg}
    }
    set fwd_rec(clock_group_rows) $cg
    if {$fwd_rec(exception_rows_p) >= 0 && $fwd_rec(exception_rows_n) >= 0} {
        set fwd_rec(legacy_async_exception_on_pads) [expr {$fwd_rec(exception_rows_p) + $fwd_rec(exception_rows_n)}]
    }
    if {$fwd_rec(clock_p_count) == 1 && $fwd_rec(clock_n_count) == 1 &&
        $fwd_rec(clkdiv_same_net) == 1 && $fwd_rec(exception_rows_p) == 0 &&
        $fwd_rec(exception_rows_n) == 0} {
        set fwd_rec(measured) 1
    } else {
        append fwd_rec(probe_error) "forwarded-clock model incomplete: p=$fwd_rec(clock_p_count) n=$fwd_rec(clock_n_count) clkdiv_same=$fwd_rec(clkdiv_same_net) fp_rows=$fwd_rec(exception_rows_p)/$fwd_rec(exception_rows_n) "
    }
} err]} {
    append fwd_rec(probe_error) "item query aborted: $err "
    incr ::sc7f0_section_errors
}
sc7f0_put tx_tmds_clock_forwarded [array get fwd_rec]
}

# ---------------------------------------------------------------------------
# named INTERNAL asynchronous entries: one registered source flop -> one named
# first-stage flop (rtl/sc7f0_hdmi_probe.v, round 26111202 CDC-10 / WNS holders).
#   id | source-register stem | destination chain stem | reviewed source clock
# Each item proves four separate things, all of them measured: (1) both object
# lists resolve, (2) the destination first stage really carries ASYNC_REG, (3) the
# crossing spans exactly the two reviewed clock domains, and (4) the exception did
# not swallow anything else - the internal chain stages [0] -> [1]/[2] must still
# be analysed, and the feed-in to the source register must still be timed at that
# register's own clock requirement (not at a 0.002 ns async requirement).
# ---------------------------------------------------------------------------
set internal_table [list \
    [list probe_rxss_tlast_src_to_probe  rxss_tlast_src  rxss_tlast_sync  clkout2] \
    [list probe_rxss_tuser_src_to_probe  rxss_tuser_src  rxss_tuser_sync  clkout2] \
    [list probe_rxss_tvalid_src_to_probe rxss_tvalid_src rxss_tvalid_sync clkout2] \
    [list probe_phy_ch0_tvalid_src_to_probe phy_ch0_tvalid_src phy_ch0_tvalid_sync phy_rxoutclk] \
    [list probe_phy_ch1_tvalid_src_to_probe phy_ch1_tvalid_src phy_ch1_tvalid_sync phy_rxoutclk] \
    [list probe_phy_ch2_tvalid_src_to_probe phy_ch2_tvalid_src phy_ch2_tvalid_sync phy_rxoutclk]]

foreach row $internal_table {
    foreach {id src_stem dst_stem src_clock} $row break
    catch {array unset rec}
    array set rec {class internal_async review_required 1 probe_error {} \
                   first_stage_async_reg 0 paths_analysed 0 upstream_paths 0 \
                   crossing_paths_timed 0 clock_domain_count 0 ignored 0 \
                   scope_overridden 0}
    set rec(reviewed_source_clock) $src_clock
    if {[catch {
    # Whole-name anchors.  These three queries are the measurement behind
    # probe_*_src_to_probe; in rgb-fullimpl-26111333 the same queries reported
    # from_objects=1, to_objects=1 but chain_stage_objects=0, i.e. the [1]/[2]
    # stages of the chain did not resolve while the first stage did.  That is a
    # fact about this round's netlist or about the query, not permission to drop
    # the item: the truth was measured read-only in
    # <D>/smoke-probe-names2-215308Z (the source FDREs and the u_meter/* chains
    # are present) and <D>/smoke-probe-stages2-* (per-stage names + ASYNC_REG +
    # source->stage timing).  No item here was deleted or marked NA on the
    # strength of an empty query.
    set from [get_cells -quiet -hier -regexp [format {.*u_hdmi_probe/%s_reg} $src_stem]]
    set to [get_cells -quiet -hier -regexp [format {.*u_hdmi_probe/%s_reg\[0\]} $dst_stem]]
    # `\[[12]\]`, not `\[12\]`: the latter is a literal "[12]" and matches no
    # real cell name, which is the measured reason chain_stage_objects reported 0
    # while the chain cells exist (verified against
    # <D>/smoke-probe-stages2-*/smoke.log: u_hdmi_probe/<stem>_reg[0..2] all present
    # with ASYNC_REG=1; and in tclsh, {.*reg\[[12]\]} matches reg[1] and reg[2] and
    # not reg[0] or reg[12], whereas {.*reg\[12\]} matches only the literal reg[12]).
    set chain [get_cells -quiet -hier -regexp [format {.*u_hdmi_probe/%s_reg\[[12]\]} $dst_stem]]
    set rec(from_cells) [format {u_hdmi_probe/%s_reg} $src_stem]
    set rec(to_cells) [format {u_hdmi_probe/%s_reg[0]} $dst_stem]
    set rec(from_objects) [llength $from]
    set rec(to_objects) [llength $to]
    set rec(chain_stage_objects) [llength $chain]
    if {[llength $from] == 0} {
        append rec(probe_error) "source register $src_stem not found; the crossing "
        append rec(probe_error) "is not the reviewed structure "
    }
    if {[llength $to] == 0} {
        append rec(probe_error) "first stage ${dst_stem}[0] not found; the crossing "
        append rec(probe_error) "is not the reviewed structure "
    }
    if {[llength $from] > 0 && [llength $to] > 0} {
        set async 0
        array set sc7f0_async_prop [sc7f0_prop ASYNC_REG $to]
        if {$sc7f0_async_prop(error) eq ""} {
            foreach flag $sc7f0_async_prop(values) {
                if {[sc7f0_true $flag]} {incr async}
            }
        } else {
            append rec(probe_error) "$sc7f0_async_prop(error) "
        }
        set rec(first_stage_async_reg) $async
        set rec(source_clocks) [sc7f0_clks $from]
        set rec(destination_clocks) [sc7f0_clks $to]
        set domains {}
        foreach candidate [concat [split $rec(source_clocks) |] \
                                [split $rec(destination_clocks) |]] {
            if {$candidate eq "-" || $candidate eq {QUERY_ERROR}} continue
            if {[lsearch -exact $domains $candidate] < 0} {lappend domains $candidate}
        }
        set rec(clock_domain_names) [join $domains |]
        set rec(clock_domain_count) [llength $domains]
        if {$rec(source_clocks) ne $src_clock} {
            append rec(probe_error) "source register is clocked by "
            append rec(probe_error) "$rec(source_clocks), this entry reviews the "
            append rec(probe_error) "$src_clock domain "
        }
        # (4a) the three chain stages must still be timed: an exception that grew
        # beyond `-from src -to chain[0]` shows up here as zero analysed paths.
        array set c [sc7f0_timing $to $chain 8]
        set rec(paths_analysed) $c(paths)
        set rec(internal_worst_slack) $c(slack)
        if {$c(probe_error) ne ""} {append rec(probe_error) "$c(probe_error) "}
        if {$c(paths) == 0 && [llength $chain] > 0} {
            append rec(probe_error) "chain\[0\] -> chain\[1\]/\[2\] has 0 analysed "
            append rec(probe_error) "paths: the exception is broader than the "
            append rec(probe_error) "named entry "
        }
        # (4b) the feed-in of the source register is an ordinary same-domain path
        # and must be timed at that clock, which is the whole point of adding the
        # register (26111202 timed these nets with a 0.002 ns requirement).
        array set u [sc7f0_timing_to $from 8]
        set rec(upstream_paths) $u(paths)
        set rec(upstream_requirement) $u(requirement)
        set rec(upstream_worst_slack) $u(slack)
        set rec(upstream_start_clocks) $u(start_clocks)
        if {$u(probe_error) ne ""} {append rec(probe_error) "$u(probe_error) "}
        if {$u(paths) == 0} {
            append rec(probe_error) "no timing path reaches $src_stem; its input is "
            append rec(probe_error) "not analysed, so the crossing cannot be graded "
        }
        # recorded for information: with the false path in force the crossing
        # itself is expected to return 0 timed paths.
        array set x [sc7f0_timing $from $to 4]
        set rec(crossing_paths_timed) $x(paths)
        array set e [sc7f0_exception $from $to $id]
        set rec(exception_position) $e(position)
        set rec(exception_type) $e(type)
        set rec(exception_rows) $e(coverage_rows)
        set rec(ignored) $e(ignored)
        set rec(scope_overridden) $e(scope_overridden)
        set rec(exception_audit_source) $e(audit_source)
        if {$e(probe_error) ne ""} {append rec(probe_error) "$e(probe_error) "}
        if {$e(type) ne "False Path"} {
            append rec(probe_error) "exception type is $e(type), not the False Path "
            append rec(probe_error) "this entry reviews "
        }
    }
    } err]} {
        append rec(probe_error) "item query aborted: $err "
        incr ::sc7f0_section_errors
    }
    sc7f0_put $id [array get rec]
}

# ---------------------------------------------------------------------------
# pad consumer closure: is EVERY sequential first stage of an async input pad
# named by one of the exceptions above?  A -to-chain exception on one consumer
# must never silently cover a second consumer added later, and "we enumerated
# three loads" must be re-measured instead of being asserted by a policy file.
# ---------------------------------------------------------------------------
foreach port [array names claims] {
    set id "async_pad_$port"
    catch {array unset crec}
    array set crec {class pad_closure review_required 1 probe_error {} \
                    clock_or_setreset_pin_loads 0}
    set crec(port) $port
    set port_obj [get_ports -quiet $port]
    set crec(from_objects) [expr {$port_obj eq "" ? 0 : 1}]
    if {[catch {
    if {$port_obj eq ""} {
        set crec(probe_error) "port $port is not in this design"
    } else {
        # One resolver, one set of numbers, shared with the io_exception record of
        # the same pad.  The previous revision enumerated each endpoint as a name
        # string and asked for its cell one element at a time, and classified the
        # cells with a three-argument get_property that catch turned into "no
        # cells": every pad reported to_objects = 0 while its own endpoint_count
        # said 1-3 (T1).
        array set pad [sc7f0_fanout_loads $port_obj]
        set seqcells $pad(seq_cells)
        set crec(endpoint_count) $pad(endpoint_count)
        set crec(endpoint_pin_names) [join $pad(pin_roles) |]
        set crec(pad_load_cell_count) $pad(cell_count)
        set crec(first_stage_resolution_method) $pad(method)
        set crec(first_stage_resolution_source) $pad(source)
        set crec(first_stage_ref_families) $pad(ref_families)
        set crec(nonsequential_ref_families) $pad(unknown_ref_families)
        set crec(clock_or_setreset_pin_loads) $pad(clock_pin_loads)
        set crec(to_objects) [llength $seqcells]
        set crec(sequential_endpoint_count) [llength $seqcells]
        set crec(async_reg_endpoint_count) $pad(async_reg_count)
        if {$pad(probe_error) ne ""} {append crec(probe_error) "$pad(probe_error) "}
        # An empty result is named, never written as a clean 0.
        if {$pad(endpoint_count) == 0} {
            append crec(probe_error) "pad $port has no measurable first stage "
        } elseif {[llength $seqcells] == 0} {
            append crec(probe_error) "pad $port reached $pad(endpoint_count) "
            append crec(probe_error) "endpoint(s) in $pad(cell_count) cell(s) but "
            append crec(probe_error) "0 sequential first-stage cells (method="
            append crec(probe_error) "$pad(method), non-sequential refs="
            append crec(probe_error) "$pad(unknown_ref_families)) "
        }
        set claimed_names {}
        foreach group $claims($port) {
            foreach name [split $group {|}] {lappend claimed_names $name}
        }
        set seq_names [sc7f0_names $seqcells]
        if {[llength $seqcells] > 0 && [llength $seq_names] != [llength $seqcells]} {
            append crec(probe_error) "cell names of $port could not be read "
        }
        set unclaimed {}
        foreach name $seq_names {
            if {[lsearch -exact $claimed_names $name] < 0} {lappend unclaimed $name}
        }
        # Only ever 0 when every first stage of this pad carries the placement /
        # metastability-chain annotation.  It is a measurement, not a claim: the DDC
        # vendor filter measures 1 (probe chain annotated, filter stage not).
        set crec(first_stage_endpoints_missing_async_reg) \
            [expr {[llength $seqcells] - $pad(async_reg_count)}]
        set crec(claimed_first_stage_endpoints) [expr {[llength $seqcells] - [llength $unclaimed]}]
        set crec(unclaimed_first_stage_endpoints) [llength $unclaimed]
        set crec(unclaimed_first_stage_cells) [join [lrange $unclaimed 0 9] |]
        set crec(clock_or_setreset_pin_loads) $pad(clock_pin_loads)
        set clock_text [sc7f0_clks $seqcells]
        set crec(clock_domains) $clock_text
        if {$clock_text eq {-} || $clock_text eq {QUERY_ERROR}} {
            set crec(clock_domain_count) 0
        } else {
            set crec(clock_domain_count) [llength [split $clock_text |]]
        }
        if {$clock_text eq {QUERY_ERROR}} {append crec(probe_error) "get_clocks failed "}
    }
    } err]} {
        append crec(probe_error) "item query aborted: $err "
        incr ::sc7f0_section_errors
    }
    sc7f0_put $id [array get crec]
}

# ---------------------------------------------------------------------------
# write the manifest
# ---------------------------------------------------------------------------
proc sc7f0_value_json {raw} {
    if {[string is integer -strict $raw] || [string is double -strict $raw]} {return $raw}
    return "\"[sc7f0_escape $raw]\""
}

proc sc7f0_list_json {values} {
    set out {}
    foreach value $values {lappend out [sc7f0_value_json $value]}
    return "\[[join $out {, }]\]"
}

set chunks {}
foreach id [lsort [array names sc7f0_items]] {
    catch {array unset rec}
    array set rec $sc7f0_items($id)
    set fields {}
    foreach key [lsort [array names rec]] {
        set value $rec($key)
        if {$value eq ""} continue
        lappend fields [format {    "%s": %s} [sc7f0_escape $key] [sc7f0_value_json $value]]
    }
    lappend chunks [format {  "%s": {%s}} [sc7f0_escape $id] [join $fields {, }]]
}

set design_name {}
if {[catch {get_property NAME [current_design]} design_name]} {set design_name QUERY_ERROR}
set start_cwd $::sc7f0_start_cwd
# T3: the hook must leave nothing in the directory Vivado happens to run in.  The
# files below are the ones earlier revisions wrote there; finding any of them is
# reported (and fails the round) instead of being ignored.
set stray_scratch {}
foreach pattern [list .tmp-exceptions-*.rpt .tmp-bus-skew.rpt] {
    foreach path [glob -nocomplain -directory $start_cwd $pattern] {
        lappend stray_scratch $path
    }
}
set scratch_names {}
if {[file isdirectory $::sc7f0_scratch]} {
    foreach path [glob -nocomplain -directory $::sc7f0_scratch *] {
        lappend scratch_names [file tail $path]
    }
}

# The verdict is decided BEFORE the manifest is written, so a failing round still
# leaves a complete, parseable manifest that says what failed (T2).  The gate
# reads this file; losing it to one probe error is what turned 30+ entries into
# "absent from this round's coverage manifest".
set problems {}
if {$design_state_error ne ""} {lappend problems "design_state: $design_state_error"}
if {[llength $stray_scratch]} {
    lappend problems "scratch left in the working directory $start_cwd"
    lappend problems [join $stray_scratch {; }]
}
foreach id [lsort [array names sc7f0_items]] {
    # Clear first: `array set` only overwrites the keys it lists, so without
    # this a field from the previous item (max_delay_effective, bus_skew_violated)
    # was reported against items that never measured it.
    catch {array unset rec}
    array set rec $sc7f0_items($id)
    if {[expr {double($rec(review_required))}] == 0} continue
    if {([info exists rec(from_objects)] && $rec(from_objects) == 0) ||
        ([info exists rec(to_objects)] && $rec(to_objects) == 0)} {
        lappend problems "$id resolved to [expr {$rec(from_objects)}]/[expr {$rec(to_objects)}] objects"
    }
    if {[info exists rec(ignored)] && $rec(ignored)} {lappend problems "$id is ignored"}
    if {[info exists rec(scope_overridden)] && $rec(scope_overridden)} {
        lappend problems "$id is scope overridden"
    }
    if {[info exists rec(max_delay_effective)] && !$rec(max_delay_effective)} {
        lappend problems "$id requirement is not in force"
    }
    if {[info exists rec(unclaimed_first_stage_endpoints)] &&
        $rec(unclaimed_first_stage_endpoints) > 0} {
        lappend problems "$id has $rec(unclaimed_first_stage_endpoints) sequential "
        lappend problems "first-stage load(s) that no exception names: "
        lappend problems "$rec(unclaimed_first_stage_cells)"
    }
    if {[info exists rec(bus_skew_violated)] && $rec(bus_skew_violated)} {
        lappend problems "$id bus skew is violated"
    }
    # A recorded query error is always a problem: a measurement that was never
    # taken may not be graded as a clean one, whatever else looks fine.
    if {[info exists rec(probe_error)] && [string trim $rec(probe_error)] ne ""} {
        lappend problems "$id query error: [string trim $rec(probe_error)]"
    }
}
set verdict [expr {[llength $problems] == 0 ? {PASS} : {FAIL}}]

set text [format {// generated by scripts/check_sc7f0_named_constraints.tcl
{
  "generated_by": "scripts/check_sc7f0_named_constraints.tcl",
  "design": "%s",
  "design_state": "%s",
  "design_state_source": "%s",
  "design_state_evidence": %s,
  "report_dir": "%s",
  "hook_scratch_files": %s,
  "hook_section_errors": %s,
  "hook_verdict": "%s",
  "hook_problems": %s,
  "cdc_rpt_sha256": "%s",
  "reports_sha256": {%s},
  "items": {
%s
  }
}
} $design_name $design_state $design_state_source [sc7f0_list_json $state_evidence] \
  $out_dir [sc7f0_list_json $scratch_names] $::sc7f0_section_errors $verdict \
  [sc7f0_list_json $problems] $cdc_sha [join $report_hashes {, }] [join $chunks ",\n"]]

# Strip the comment line: the file must be strictly parseable JSON.
set lines [split $text \n]
set text [join [lrange $lines 1 end] \n]
set fh [open $evidence w]
puts $fh $text
close $fh
puts "SC7F0_NAMED_EVIDENCE $evidence items=[llength [array names sc7f0_items]] "
puts "SC7F0_NAMED_EVIDENCE state=$design_state source=$design_state_source verdict=$verdict"
# Every failing query is named on the console too, so a section that degraded is
# visible in the build log even though the rest of the manifest survived.
foreach id [lsort [array names sc7f0_items]] {
    catch {array unset rec}
    array set rec $sc7f0_items($id)
    if {[info exists rec(probe_error)] && [string trim $rec(probe_error)] ne ""} {
        puts "SC7F0_NAMED_EVIDENCE_PROBE_ERROR $id: "
        puts "  [string range [string trim $rec(probe_error)] 0 220]"
    }
}

# Fail loudly only after the evidence file exists, so the reviewer can see what
# is missing instead of losing the run.  `problems` was already computed above,
# before the file was written, so the manifest and this abort always agree.
if {[llength $problems]} {
    puts "SC7F0_NAMED_EVIDENCE_PROBLEMS [llength $problems]"
    foreach problem $problems {puts "  $problem"}
    error "named constraint coverage failed: [join $problems {; }]"
}
puts "SC7F0_NAMED_CONSTRAINT_COVERAGE_PASS"
