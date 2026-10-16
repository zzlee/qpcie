# Pure Tcl gate shared by artifact packaging and its regression test.
proc a50t_validate_timing_summary {summary} {
    foreach line [split $summary "\n"] {
        if {[regexp {^\s*(-?[0-9]+\.[0-9]+)\s+(-?[0-9]+\.[0-9]+)\s+[0-9]+\s+[0-9]+\s+(-?[0-9]+\.[0-9]+)\s+(-?[0-9]+\.[0-9]+)\s+[0-9]+\s+[0-9]+\s+(-?[0-9]+\.[0-9]+)\s+(-?[0-9]+\.[0-9]+)\s+[0-9]+\s+[0-9]+\s*$} \
            $line -> wns tns whs ths wpws tpws]} {
            if {$wns < 0 || $whs < 0 || $wpws < 0 || $tns < 0 || $ths < 0 || $tpws < 0} {
                error "Timing failed: WNS=$wns WHS=$whs WPWS=$wpws; no release export."
            }
            return [dict create WNS $wns WHS $whs WPWS $wpws]
        }
    }
    error "Cannot validate timing summary; no release export."
}
