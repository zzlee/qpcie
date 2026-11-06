#!/usr/bin/env python3
"""Phase 1 Todo 1.3 scoped whole-card delta review for the encoder-only VCU build.

Purpose
-------
The shipped whole-design gate (scripts/check_sc7f0_timing.py) is deliberately
absolute: it fails closed on the frozen R7 (26102901) inventory as well, because
thousands of vendor/XPM FIFO CE and LUTRAM crossings still need source-level
review (see docs/sc7f0_full_profile_r6_review.md). A VCU build therefore cannot
be judged by re-running that absolute gate; it must be judged by *what the VCU
changed*. This script is that fail-closed delta gate:

  * absolute timing safety is checked in full, not as a delta
    (WNS > 0, WHS > 0, WPWS > 0, TNS = THS = TPWS = 0, zero failing endpoints,
    zero check_timing violations, clean DRC/methodology severities, no routing
    errors, no negative bus skew);
  * every CDC/methodology/DRC difference against the frozen R7 evidence is
    accounted for, and any new Critical/Error-severity item, or any new CDC
    warning outside the VCU subtree, fails the gate;
  * the C2H personality audit, the 128 routed Gray endpoints, the VCU hard macro
    (1 of 1) and the routed resource inventory are re-read from the reports, so
    a passing verdict always means "the reports say so", never "the log says so".

This is engineering evidence, NOT publication signoff: it does not authorize
deployment, PS image reuse, packaging or a flash.

    cd /home/zzlee/vibecoding/sc7f0-dual-video
    python3 scripts/check_sc7f0_vcu_delta.py \
        --candidate build/dual-video-26102902-vcu-r1 \
        --baseline  build/dual-video-26102901-r7 \
        --console   build/dual-video-26102902-vcu-r1-logs/impl-console.log \
        --out       build/vcu-delta-review-26102902-r1
"""
import argparse
from collections import Counter
import hashlib
import json
import math
import re
import sys
from pathlib import Path

import audit_sc7f0_cdc_delta as cdc_inventory

RUN_SUB = "qpcie_zu4ev_card.runs/impl_1"
TOP = "zu4ev_pcie_card_top"
PART_CLB_LUTS = 87840
LUT_BUDGET_PERCENT = 85.0
VCU_MARKERS = ("/vcu_0/", "/axil_vcu/", "/xbar_vcu_enc/", "/dwc_vcu_mcu/",
               "/vcu_rst_mem/", "/vcu_rst_lite/", "/vcu_irq_cat/")
TIMING_TABLE = re.compile(r"^\s*WNS\(ns\).*WPWS\(ns\).*\n[^\n]*\n([^\n]+)", re.M)
CLOCK_ROW = re.compile(r"^(?P<name>\S+)(?:\s+(?P<tok>-?[\d.]+|None)){11}\s*$")
HIER_KEYS = ("LUTs", "LogicLUTs", "LUTRAMs", "SRLs", "FFs", "RAMB36", "RAMB18",
             "URAM", "DSP")
# Clocks whose existence and cleanliness the card depends on; every revision
# must keep all of them timed and met.
REQUIRED_CLOCKS = ("clk_pl_0", "pl_clk_300m", "capture_clk_150m",
                   "sys_clk", "pcie_user_clk", "pipe_clk", "hdmi_rx_clk_p",
                   "hdmi_dru_clk_p", "phy_rxoutclk", "phy_txoutclk")
# A VCU revision additionally has to route and time the PS pl_clk1 that feeds
# the VCU PLL.  Vivado lists such a clock in the intra-clock table only when it
# owns at least one endpoint, so it is asserted here (present, and clean when
# present) instead of in REQUIRED_CLOCKS, which must stay valid for VCU-off
# builds as well.
VCU_CLOCKS = {"clk_pl_1": 30.002}      # name -> expected period in ns
PERIOD_TOLERANCE_NS = 0.05
TABLE_ROW = re.compile(r"^\|\s*(?P<rule>[A-Z]+-[A-Z0-9]+)\s*\|\s*"
                       r"(?P<severity>[A-Za-z ]+?)\s*\|[^|]*\|\s*(?P<count>\d+)\s*\|",
                       re.M)
SKEW_ROW = re.compile(r"^\s*(?:Slow|Fast)\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s*$",
                      re.M)


def read(path):
    return Path(path).read_text(errors="replace")


def design_margins(text):
    """Design-level WNS/TNS/... from a report_timing_summary table."""
    match = TIMING_TABLE.search(text)
    if not match:
        raise ValueError("missing design timing summary")
    values = [float(x) for x in match[1].split()]
    if len(values) != 12 or not all(math.isfinite(x) for x in values):
        raise ValueError("invalid design timing summary")
    names = ("WNS", "TNS", "TNS_failing", "TNS_total", "WHS", "THS", "THS_failing",
             "THS_total", "WPWS", "TPWS", "TPWS_failing", "TPWS_total")
    return dict(zip(names, values))


def clock_periods(text):
    """{clock: (period_ns, frequency_mhz)} from the routed clock summary.

    Rows look like ``clk_pl_1  {0.000 15.001}  30.002  33.331``; a clock listed
    here has no endpoint and therefore no intra-clock row, which is exactly how
    a VCU reference clock can still be proved alive.
    """
    if "| Clock Summary" not in text or "| Intra Clock Table" not in text:
        raise ValueError("missing clock summary")
    block = text.split("| Clock Summary", 1)[1].split("| Intra Clock Table", 1)[0]
    periods = {}
    for line in block.splitlines():
        fields = " ".join(line.split()).split()
        if len(fields) >= 4 and fields[1].startswith("{"):
            try:
                periods[fields[0]] = (float(fields[-2]), float(fields[-1]))
            except ValueError:
                continue
    if not periods:
        raise ValueError("empty clock summary")
    return periods


def clock_summary(text):
    """Per-clock rows of the intra-clock (WNS/TNS/...) summary table.

    Vivado pads the clock column to ~450 characters and prints None where a
    clock has no paths of that kind, so only fully populated 12-column rows are
    returned; the design-level summary is checked separately and absolutely.
    """
    lines = text.splitlines()
    headers = [i for i, line in enumerate(lines)
               if " ".join(line.split()).startswith("Clock WNS(ns)")]
    if not headers:
        raise ValueError("missing intra-clock timing summary")
    rows, index = {}, headers[0] + 2
    while index < len(lines):
        fields = " ".join(lines[index].split()).split()
        index += 1
        if not fields:
            if rows:
                break
            continue
        if fields[0].startswith("|") or set(fields[0]) == {"-"}:
            if rows:
                break
            continue
        if len(fields) != 13:
            continue
        try:
            values = [None if token == "None" else float(token) for token in fields[1:]]
        except ValueError:
            # Next table of the report; the clock rows are behind us.
            if rows:
                break
            continue
        name = fields[0]
        if name in rows and (values[3] is None or
                             (rows[name][3] is not None and rows[name][3] >= values[3])):
            continue
        rows[name] = values
    return {name: {"WNS": v[0], "TNS": v[1], "TNS_failing": v[2], "TNS_total": v[3],
                   "WHS": v[4], "THS": v[5], "THS_failing": v[6]}
            for name, v in rows.items()}


def check_timing_counts(text):
    counts = {}
    for name in ("no_clock", "constant_clock", "pulse_width_clock",
                 "unconstrained_internal_endpoints", "no_input_delay",
                 "no_output_delay", "multiple_clock", "generated_clocks", "loops",
                 "latch_loops", "partial_input_delay", "partial_output_delay"):
        matches = re.findall(r"checking " + name + r" \((\d+)\)", text)
        if not matches:
            raise ValueError("missing check_timing check: " + name)
        counts[name] = max(map(int, matches))
    return counts


def table_rows(text):
    rows = {}
    for match in TABLE_ROW.finditer(text):
        rows[match["rule"]] = (match["severity"].strip(), int(match["count"]))
    total = re.search(r"Violations found:\s*(\d+)", text)
    if total and rows and int(total[1]) != sum(count for _, count in rows.values()):
        raise ValueError("incomplete " + text.splitlines()[0][:40] + " summary")
    return rows


def hier_rows(text):
    """Rows of report_utilization -hierarchical as (name, module, values, depth)."""
    rows = []
    for line in text.splitlines():
        if not line.startswith("|") or "Instance" in line or "+--" in line:
            continue
        fields = [field.strip() for field in line.strip().strip("|").split("|")]
        if len(fields) != 11:
            continue
        try:
            values = [int(field) for field in fields[2:]]
        except ValueError:
            continue
        after = line[1:]
        indent = len(after) - len(after.lstrip(" "))
        rows.append((fields[0], fields[1],
                     dict(zip(HIER_KEYS, values)), indent // 2))
    if not rows:
        raise ValueError("no rows in report_utilization -hierarchical")
    return rows


def routed_totals(text):
    """Totals row (the top instance itself, not its glue-logic row)."""
    for name, module, values, _depth in hier_rows(text):
        if module == "(top)" and not name.startswith("("):
            return values
    raise ValueError("missing routed hierarchical totals")


def hierarchy_rows(text):
    """Instance totals by name; Vivado's indented "(name)" glue rows are skipped."""
    rows = {}
    for name, _module, values, _depth in hier_rows(text):
        if name.startswith("(") or name in rows:
            continue
        rows[name] = values
    return rows


def placed_counts(text):
    out = {}
    for name in ("CLB LUTs", "LUT as Logic", "LUT as Memory", "CLB Registers",
                 "Block RAM Tile", "URAM", "VCU", "Bonded IOB"):
        match = re.search(r"^\|\s*" + re.escape(name) + r"\s*\|\s*(\d+(?:\.\d+)?)"
                          r"\s*\|\s*\d+\s*\|\s*\d+\s*\|\s*(\d+(?:\.\d+)?)\s*\|"
                          r"\s*(\d+(?:\.\d+)?)\s*\|", text, re.M)
        if match:
            out[name] = {"used": float(match[1]), "available": float(match[2]),
                         "percent": float(match[3])}
    return out


def review(candidate, baseline, console, expect_version, vcu_expected, out,
           baseline_gate=None, xsa_rel="hardware.xsa"):
    errors, notes = [], []
    candidate, baseline = Path(candidate), Path(baseline)
    required = ["c2h-personality.rpt", "timing_summary.rpt", "check-timing.rpt",
                "cdc.rpt", "methodology.rpt", "bus-skew.rpt",
                "exceptions-coverage.rpt", "utilization_routed_hierarchical.rpt",
                "utilization_synth_hierarchical.rpt",
                "timing-gate-record.json", xsa_rel]
    run_files = [TOP + ".bit", TOP + "_utilization_placed.rpt",
                 TOP + "_drc_routed.rpt", TOP + "_methodology_drc_routed.rpt",
                 TOP + "_route_status.rpt", TOP + "_clock_utilization_routed.rpt"]
    for rel in required:
        if not (candidate / rel).is_file() or (candidate / rel).stat().st_size == 0:
            errors.append("missing/empty artifact: " + rel)
    for rel in run_files:
        if not (candidate / RUN_SUB / rel).is_file():
            errors.append("missing run artifact: " + rel)
    if errors:
        return dict(pass_gate=False, errors=errors, notes=notes), {}

    # ---- 1. routed timing, checked absolutely -------------------------------
    timing = read(candidate / "timing_summary.rpt")
    if not re.search(r"Design State\s*:\s*Routed\b", timing):
        errors.append("candidate timing report is not routed")
    margins = design_margins(timing)
    base_timing = read(baseline / "timing_summary.rpt")
    base_margins = design_margins(base_timing)
    if margins["WNS"] <= 0:
        errors.append("WNS %s ns is not strictly positive" % margins["WNS"])
    if margins["WHS"] <= 0:
        errors.append("WHS %s ns is not strictly positive" % margins["WHS"])
    if margins["WPWS"] < 0:
        errors.append("WPWS %s ns is negative" % margins["WPWS"])
    for key in ("TNS", "THS", "TPWS"):
        if margins[key] != 0:
            errors.append(key + " is %s, expected 0" % margins[key])
    for key in ("TNS_failing", "THS_failing", "TPWS_failing"):
        if margins[key] != 0:
            errors.append(key + " is %s, expected 0" % margins[key])
    if "All user specified timing constraints are met" not in timing:
        errors.append("timing summary does not state all constraints met")
    clocks = clock_summary(timing)
    base_clocks = clock_summary(base_timing)
    for name, row in sorted(clocks.items()):
        if row["WNS"] is None:
            continue
        if row["WNS"] <= 0 or (row["TNS"] or 0) != 0 or (row["WHS"] or 0) <= 0 \
                or (row["THS"] or 0) != 0 or (row["TNS_failing"] or 0) != 0 \
                or (row["THS_failing"] or 0) != 0:
            errors.append("clock %s timing not clean: %s" % (name, row))
    for name in REQUIRED_CLOCKS:
        if name not in clocks:
            errors.append("required clock is absent from the routed summary: " + name)
    for name in sorted(base_clocks):
        if name not in clocks and name in REQUIRED_CLOCKS:
            errors.append("baseline clock lost: " + name)
    for name in sorted(set(clocks) - set(base_clocks)):
        notes.append("clock introduced by this revision: %s %s"
                     % (name, clocks[name]))
    if vcu_expected:
        periods = clock_periods(timing)
        for name, period in sorted(VCU_CLOCKS.items()):
            measured = periods.get(name)
            if measured is None:
                errors.append("VCU reference clock absent from the routed "
                              "clock summary: " + name)
            elif abs(measured[0] - period) > PERIOD_TOLERANCE_NS:
                errors.append("VCU reference clock %s is %.3f ns, expected "
                              "%.3f ns" % (name, measured[0], period))
            else:
                notes.append("VCU reference clock %s = %.3f ns / %.3f MHz"
                             % (name, measured[0], measured[1]))

    # ---- 2. routing, check_timing, bus skew ---------------------------------
    route = read(candidate / RUN_SUB / (TOP + "_route_status.rpt"))
    match = re.search(r"nets with routing errors\D*:\s*(\d+)", route)
    if not match or int(match[1]) != 0:
        errors.append("routing errors reported by the router")
    if "CONGESTED" in route.upper():
        errors.append("router reported a congested design")
    coverage = count_check_timing(candidate, baseline, errors, notes)
    cand_high = high_severity_endpoints(read(candidate / "check-timing.rpt"))
    base_high = high_severity_endpoints(read(baseline / "check-timing.rpt"))
    for wording, count in sorted(cand_high.items()):
        if count > base_high.get(wording, 0):
            errors.append("new uncovered HIGH-severity endpoints: %s %d -> %d" %
                          (wording, base_high.get(wording, 0), count))
    skew = read(candidate / "bus-skew.rpt")
    rows = SKEW_ROW.findall(skew)
    if not rows or "(VIOLATED)" in skew:
        errors.append("missing or violated bus-skew summary")
    else:
        skew_min = min(float(r[2]) for r in rows)
        if skew_min < 0:
            errors.append("negative bus-skew minimum %s" % skew_min)

    # ---- 3. C2H personality audit -------------------------------------------
    personality = read(candidate / "c2h-personality.rpt")
    if "C2H_PERSONALITY_SYNTH_PASS" not in personality:
        errors.append("C2H personality audit did not pass")
    macro_counts = {}
    for line in personality.splitlines():
        fields = line.split()
        if len(fields) != 3:
            continue
        if fields[0] == "PRESENT" and fields[1].startswith("VCU_hard_macro"):
            macro_counts[fields[1]] = int(fields[2])
            continue
        if fields[0] == "ABSENT" and int(fields[2]) != 0:
            errors.append("personality: unwanted hardware present " + line)
        if fields[0] == "PRESENT" and int(fields[2]) == 0:
            errors.append("personality: required hardware missing " + line)
    if vcu_expected and not any(macro_counts.values()):
        errors.append("personality: no VCU hard macro in the synth audit %s" %
                      macro_counts)
    if not vcu_expected and macro_counts and any(macro_counts.values()):
        errors.append("personality: VCU hard macro in a VCU-off build %s" %
                      macro_counts)
    if "PRESENT" not in personality or "ABSENT" not in personality:
        errors.append("personality audit has no inventory lines")

    # ---- 4. routed resource inventory + VCU hard macro ----------------------
    totals = routed_totals(read(candidate / "utilization_routed_hierarchical.rpt"))
    base_totals = routed_totals(read(baseline / "utilization_routed_hierarchical.rpt"))
    placed = placed_counts(read(candidate / RUN_SUB /
                                (TOP + "_utilization_placed.rpt")))
    base_placed = placed_counts(read(baseline / RUN_SUB /
                                    (TOP + "_utilization_placed.rpt")))
    if "VCU" not in placed:
        errors.append("placed utilization has no VCU row")
    else:
        used = placed["VCU"]["used"]
        if vcu_expected and used != 1:
            errors.append("VCU hard macro used = %s, expected 1 of %s" %
                          (used, placed["VCU"]["available"]))
        if not vcu_expected and used != 0:
            errors.append("VCU hard macro used = %s, expected 0" % used)
    lut_percent = totals["LUTs"] * 100.0 / PART_CLB_LUTS
    if lut_percent > LUT_BUDGET_PERCENT:
        errors.append("routed CLB LUTs %.2f%% exceeds the %.1f%% budget" %
                      (lut_percent, LUT_BUDGET_PERCENT))
    for key in ("RAMB36", "RAMB18"):
        if totals[key] > base_totals[key] + 2:
            errors.append("%s grew by more than 2 tiles (%d -> %d)" %
                          (key, base_totals[key], totals[key]))
    if totals["URAM"] > base_totals["URAM"]:
        errors.append("URAM grew (%d -> %d) although ENC_BUFFER_EN=false" %
                      (base_totals["URAM"], totals["URAM"]))
    if totals["DSP"] > base_totals["DSP"]:
        errors.append("DSP48 grew (%d -> %d) with no new arithmetic IP" %
                      (base_totals["DSP"], totals["DSP"]))

    # ---- 5. CDC delta -------------------------------------------------------
    cand_summary, cand_rows = cdc_inventory.parse_report(read(candidate / "cdc.rpt"))
    base_summary, base_rows = cdc_inventory.parse_report(read(baseline / "cdc.rpt"))
    remaining = Counter(tuple(row[k] for k in cdc_inventory.KEY) for row in base_rows)
    new_rows, vcu_rows = [], []
    for row in cand_rows:
        key = tuple(row[f] for f in cdc_inventory.KEY)
        if remaining[key]:
            remaining[key] -= 1
            continue
        if any(marker in row["source"] or marker in row["destination"]
               for marker in VCU_MARKERS):
            vcu_rows.append(row)
        else:
            new_rows.append(row)
    for rule, (severity, count) in sorted(cand_summary.items()):
        base_count = base_summary.get(rule, ("Info", 0))[1]
        if count > base_count and severity not in ("Info", "Warning"):
            errors.append("CDC %s (%s) %d -> %d" % (rule, severity, base_count, count))
    for row in new_rows:
        if row["severity"] not in ("Info", "Warning"):
            errors.append("new %s CDC path outside the VCU subtree: %s %s -> %s" %
                          (row["severity"], row["rule"], row["source"],
                           row["destination"]))
    if new_rows:
        rules = Counter((r["rule"], r["severity"]) for r in new_rows)
        errors.append("new CDC paths outside the VCU subtree: %s" %
                      json.dumps({r[0] + "/" + r[1]: n for r, n in rules.items()}))
    if vcu_rows:
        notes.append("VCU-subtree CDC paths: %s" % json.dumps(
            dict(Counter(r["rule"] + "/" + r["severity"] for r in vcu_rows))))
    cdc_detail = dict(
        candidate={r: {"severity": s, "count": c} for r, (s, c) in cand_summary.items()},
        baseline={r: {"severity": s, "count": c} for r, (s, c) in base_summary.items()},
        candidate_paths=len(cand_rows), baseline_paths=len(base_rows),
        vcu_subtree_new=dict(Counter(r["rule"] + "/" + r["severity"] for r in vcu_rows)),
        outside_vcu_new=dict(Counter(r["rule"] + "/" + r["severity"] for r in new_rows)),
        baseline_paths_removed=sum(remaining.values()),
        samples=[{k: r[k] for k in ("rule", "severity", "source_clock",
                                    "destination_clock", "source", "destination")}
                 for r in (vcu_rows + new_rows)[:40]])

    # ---- 6. methodology + DRC delta ------------------------------------------
    methodology = {}
    for label, path in (("project", candidate / "methodology.rpt"),
                        ("routed", candidate / RUN_SUB /
                         (TOP + "_methodology_drc_routed.rpt"))):
        rows = table_rows(read(path))
        methodology[label] = rows
    base_methodology = table_rows(read(baseline / "methodology.rpt"))
    for rule, (severity, count) in sorted(methodology["project"].items()):
        base = base_methodology.get(rule, ("Info", 0))[1]
        if count > base and severity in ("Critical Warning", "Error"):
            errors.append("methodology %s (%s) %d -> %d" % (rule, severity, base, count))
    drc = table_rows(read(candidate / RUN_SUB / (TOP + "_drc_routed.rpt")))
    base_drc = table_rows(read(baseline / RUN_SUB / (TOP + "_drc_routed.rpt")))
    for rule, (severity, count) in sorted(drc.items()):
        if severity in ("Critical Warning", "Error"):
            errors.append("routed DRC %s (%s) = %d" % (rule, severity, count))
        elif rule not in base_drc:
            notes.append("new routed DRC warning %s (%s) = %d" % (rule, severity, count))

    # ---- 7. routed Gray endpoints (128) --------------------------------------
    gray = read(console)
    marked = "SC7F0_GRAY_ROUTED_BEGIN" in gray
    if marked:
        anchor = "SC7F0_GRAY_ROUTED_BEGIN"
        tail = gray[gray.rfind(anchor) + len(anchor):]
        own_marker = 1
    else:
        # R7 evidence predates the markers: use the window before the last pass.
        anchor = "SC7F0_CAPTURE_GRAY_CONSTRAINTS_PASS"
        stop = gray.rfind(anchor)
        tail = gray[max(0, stop - 4000):stop]
        own_marker = 0
    endpoints = len(re.findall(r"SC7F0_GRAY_ENDPOINTS_PASS .*?64 direct bits", tail))
    if endpoints != 2 or tail.count("SC7F0_CAPTURE_GRAY_CONSTRAINTS_PASS") != own_marker:
        errors.append("routed Gray check did not report 2 x 64 = 128 endpoints "
                      "(anchor %s, %d groups found after it)" % (anchor, endpoints))
    if vcu_expected:
        for marker in ("SC7F0_VCU_BD_OK", "SC7F0_IMPL_VCU 1", "SC7F0_VCU_ROUTED_CELL"):
            if marker not in gray:
                errors.append("missing VCU build marker: " + marker)
        match = re.search(r"SC7F0_VCU_ROUTED_CELL (\S+)", gray)
        if match:
            notes.append("VCU routed cell " + match[1])
    if expect_version:
        generic = re.search(r"C_VERSION=32'h([0-9A-Fa-f]{8})", gray)
        if generic and generic[1].upper() != expect_version.upper():
            errors.append("build generic C_VERSION=0x%s, expected 0x%s" %
                          (generic[1], expect_version))

    # ---- 8. shipped whole-design gate record ---------------------------------
    try:
        recorded = json.loads(read(candidate / "timing-gate-record.json"))
    except ValueError:
        recorded = {}
        notes.append("timing-gate-record.json is not valid JSON")
    if recorded:
        cand_err = set(e.split("=")[0].split(" ")[0] for e in recorded.get("errors", []))
        base_record = baseline_gate or baseline / "timing-gate-record.json"
        if Path(base_record).is_file():
            base_err = set(e.split("=")[0].split(" ")[0] for e in
                           json.loads(read(base_record)).get("errors", []))
            extra = sorted(cand_err - base_err)
            if extra:
                errors.append("shipped gate gained new failure classes: " +
                              json.dumps(extra))
        notes.append("shipped gate errors: " + json.dumps(recorded.get("errors", [])))

    summary = dict(
        margins_ns={k: margins[k] for k in ("WNS", "TNS", "WHS", "THS", "WPWS", "TPWS")},
        baseline_margins_ns={k: base_margins[k] for k in
                             ("WNS", "TNS", "WHS", "THS", "WPWS", "TPWS")},
        clocks=clocks, baseline_clocks=base_clocks,
        check_timing=coverage,
        routed_totals=totals, baseline_routed_totals=base_totals,
        high_severity_endpoints=cand_high, baseline_high_severity_endpoints=base_high,
        placed_counts=placed, baseline_placed_counts=base_placed,
        lut_percent=round(lut_percent, 2),
        lut_delta_vs_baseline=totals["LUTs"] - base_totals["LUTs"],
        ff_delta_vs_baseline=totals["FFs"] - base_totals["FFs"],
        methodology=methodology, routed_drc=drc,
        cdc=cdc_detail, gray_endpoint_groups=endpoints)
    result = dict(pass_gate=not errors, errors=errors, notes=notes,
                  review_only=True, deployment_authorized_by_this_report=False,
                  candidate=str(candidate), baseline=str(baseline),
                  summary=summary)
    return result, dict(totals=totals, base_totals=base_totals,
                        hierarchy=hierarchy_rows(read(candidate /
                                                      "utilization_synth_hierarchical.rpt")))


def high_severity_endpoints(text):
    """Uncovered HIGH-severity endpoint counts by check_timing wording."""
    found = {}
    for match in re.finditer(r"There are (\d+) [^\n]*\(HIGH\)", text):
        key = re.sub(r"\s+", " ", match.group(0)).replace(match.group(1), "N")
        found[key] = max(found.get(key, 0), int(match.group(1)))
    return found


def count_check_timing(candidate, baseline, errors, notes):
    text = read(candidate / "check-timing.rpt")
    counts = check_timing_counts(text)
    base = check_timing_counts(read(baseline / "check-timing.rpt"))
    for name, value in counts.items():
        if name in ("no_clock", "constant_clock", "pulse_width_clock",
                    "unconstrained_internal_endpoints", "multiple_clock",
                    "generated_clocks", "loops", "latch_loops",
                    "partial_input_delay", "partial_output_delay") and value:
            errors.append(name + "=" + str(value))
        elif value > base.get(name, 0):
            errors.append("check_timing %s grew %d -> %d" %
                          (name, base.get(name, 0), value))
    if re.search(r"There are [1-9]\d* [^\n]*\(HIGH\)", text):
        notes.append("check_timing reports uncovered HIGH-severity endpoints "
                     "(compared against the baseline as a delta)")
    return counts


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--candidate", required=True)
    parser.add_argument("--baseline", required=True)
    parser.add_argument("--console", required=True,
                        help="impl-console.log of the candidate build")
    parser.add_argument("--out", required=True)
    parser.add_argument("--expect-version", default="")
    parser.add_argument("--baseline-gate", default=None,
                        help="check_sc7f0_timing.py record of the baseline build")
    parser.add_argument("--xsa", default="hardware.xsa",
                        help="candidate hardware platform, relative to --candidate")
    parser.add_argument("--vcu", type=int, choices=(0, 1), default=1)
    args = parser.parse_args()
    out = Path(args.out)
    if out.exists():
        parser.error("refusing to overwrite " + str(out))
    try:
        result, extra = review(args.candidate, args.baseline, args.console,
                               args.expect_version, bool(args.vcu), out,
                               args.baseline_gate, args.xsa)
    except (OSError, ValueError, IndexError) as exc:
        print("VCU_DELTA_FAIL: " + str(exc), file=sys.stderr)
        return 2
    out.mkdir(parents=True)
    (out / "review.json").write_text(json.dumps(result, indent=2) + "\n")
    if extra.get("hierarchy"):
        keep = ("zu4ev_ps_bd_i", "vcu_0", "xbar_vcu_enc", "dwc_vcu_mcu",
                "axil_vcu", "vcu_rst_mem", "vcu_rst_lite", "vcu_irq_cat",
                "zynq_ultra_ps_e_0")
        lines = ["instance\tLUTs\tLogicLUTs\tLUTRAMs\tSRLs\tFFs\tRAMB36\tRAMB18\tURAM\tDSP"]
        for name, row in extra["hierarchy"].items():
            if any(token in name for token in keep):                lines.append("\t".join([name] + [str(row[k]) for k in
                                                 ("LUTs", "LogicLUTs", "LUTRAMs", "SRLs",
                                                  "FFs", "RAMB36", "RAMB18", "URAM",
                                                  "DSP")]))
        (out / "vcu_hierarchy_utilization.tsv").write_text("\n".join(lines) + "\n")
    for path in (Path(args.candidate) / "cdc.rpt", Path(args.baseline) / "cdc.rpt",
                 Path(args.candidate) / "timing_summary.rpt",
                 Path(args.baseline) / "timing_summary.rpt"):
        if path.is_file():
            result.setdefault("input_sha256", {})[str(path)] = \
                hashlib.sha256(path.read_bytes()).hexdigest()
    (out / "review.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({k: v for k, v in result.items() if k != "summary"}, indent=2))
    print("VCU_DELTA_PASS" if result["pass_gate"] else "VCU_DELTA_FAIL")
    print("review only: NOT signoff, NOT permission to deploy")
    return 0 if result["pass_gate"] else 1


if __name__ == "__main__":
    sys.exit(main())
