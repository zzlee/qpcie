#!/usr/bin/env python3
"""R7 (26102901) scoped acceptance for the routed C2H production image.

This is deliberately not a blanket waiver. It re-uses the exact-path CDC
classifier from the reviewed R6 profile, proves every reset root and diagnostic
probe against the routed netlist, and pins the routed DRC/methodology/personality
inventories. It does not deploy or claim Linux runtime acceptance.
"""
import argparse
from collections import Counter
import hashlib
import json
import math
from pathlib import Path
import re

import audit_sc7f0_cdc_delta as cdc_inventory
import check_sc7f0_full_profile as reviewed
import sc7f0_reset_proof as reset_proof

VERSION = "26102901"
DRC_DETAILS_SHA = "56c2fa9ed8628f85e6e1267a417138256f0ce4b496466e296346dd75feeac6e3"
BASE_CDC_SHA = "babc386d724c54804b9f4362c7be27f5a11185a09f75545bcea360b3f5ac4827"
BASE_XCI_SHA = {
    "vid_phy_controller_0": "98a9e84f0a20187b6d465ef4ad30193b33806a766598e8ec1ec2398ee6ef05af",
    "v_hdmi_rx_ss_0": "3f132ae51e06641eac295850e88e39e83faaa1f39bcb4fbd85b4608431bda493",
}

CDC_SUMMARY = {
    "CDC-3": ("Info", 331),
    "CDC-6": ("Warning", 8),
    "CDC-9": ("Info", 30),
    "CDC-10": ("Critical", 29),
    "CDC-12": ("Critical", 10),
    "CDC-15": ("Warning", 4292),
    "CDC-26": ("Warning", 416),
}
REVIEWED_CATEGORIES = {
    "explicit_XPM_FIFO_full_empty_FWFT_ownership": 3664,
    "vendor_sync_info": 361,
    "independent_status_NOT_stop_proof_ABI_1_1": 1,
    "registered_Gray64_four_stage_with_checked_6ns_skew_delay": 2,
    "held_snapshot_toggle_ack_10ns_constraint": 448,
    "exact_frozen_HDMI_RX_FIFO_collision_advisory": 416,
    "exact_frozen_VPHY_frequency_or_independent_control": 4,
    "independent_sticky_diagnostics": 1,
    "frozen_vendor_CPLL_held_counter": 180,
    "proved_reset_OR_async_assert_four_stage_release": 32,
    "approximate_level_three_stage_CSR_readback_only": 7,
}
METHOD = {
    "DPIR-2": ("Warning", 192),
    "LUTAR-1": ("Warning", 38),
    "TIMING-9": ("Warning", 1),
    "TIMING-18": ("Warning", 12),
    "ULMTCS-1": ("Warning", 1),
    "CLKC-11": ("Advisory", 2),
    "CLKC-40": ("Advisory", 2),
    "CLKC-56": ("Advisory", 2),
}
DRC = {
    "DPIP-2": ("Warning", 74),
    "DPOP-3": ("Warning", 13),
    "DPOP-4": ("Warning", 30),
    "PDCN-1569": ("Warning", 3),
    "REQP-1935": ("Warning", 2),
    "RTSTAT-10": ("Warning", 1),
}
ABSENT = {
    "u_hdmi_tx_ss", "u_hdmi_tx_video_bridge", "u_hdmi_tx_audio_bridge", "u_v_tpg",
    "u_audio_pattern_gen", "u_tpg_marker_overlay", "u_tpg_video_cdc",
}
ABSENT |= {f"u_ch{ch}_loopback_cdc" for ch in (1, 2, 3)}
ABSENT |= {prefix + str(ch) for ch in (1, 2, 3) for prefix in (
    "u_nv12_capture_engine_ch", "u_video_req_cdc_ch", "u_audio_h2c_fifo_ch",
    "u_audio_stream_engine_ch")}
PRESENT = {
    "u_hdmi_rx_ss", "u_vid_phy_controller", "u_ps_capture", "u_nv12_capture_engine",
    "u_audio_stream_engine_ch0", "u_dualpath", "u_h2c_ps_ddr_writer",
}
SAFETY_FILES = {
    "rtl/sc7f0_dp_fifo.v", "rtl/sc7f0_gray64_sync.v", "rtl/sc7f0_tap_regs.v",
    "rtl/sc7f0_frame_tap.v", "rtl/sc7f0_capture_pipeline.v",
    "tb/sc7f0_tap_stop_ack_tb.sv", "tb/sc7f0_capture_pipeline_tb.sv",
    "tb/sc7f0_capture_pipeline_4k_tb.sv",
    "scripts/sim_sc7f0_stop_ack.tcl", "scripts/sim_sc7f0_capture_pipeline.tcl",
    "scripts/sim_sc7f0_capture_pipeline_4k.tcl", "scripts/test_sc7f0_capture_safety.sh",
}


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def check(directory, evidence, safety, baseline_cdc, baseline_ip):
    directory, evidence, safety = Path(directory), Path(evidence), Path(safety)
    errors = []
    if hashlib.sha256(Path(baseline_cdc).read_bytes()).hexdigest() != BASE_CDC_SHA:
        raise ValueError("frozen baseline CDC hash mismatch")
    _, base_rows = cdc_inventory.parse_report(Path(baseline_cdc).read_text())
    baseline = {reviewed.identity(r) for r in base_rows}
    summary, rows = cdc_inventory.parse_report((directory / "cdc.rpt").read_text())
    if summary != CDC_SUMMARY:
        errors.append("CDC summary differs from reviewed R7 inventory")
    evidence_text = (evidence / "netlist.tsv").read_text()
    bindings = [line.split("\t") for line in evidence_text.splitlines()
                if line.startswith("CHECKPOINT\t")]
    dcp = directory / "qpcie_zu4ev_card.runs/impl_1/zu4ev_pcie_card_top_routed.dcp"
    if (len(bindings) != 1 or len(bindings[0]) != 3 or
            Path(bindings[0][1]).resolve() != dcp.resolve() or
            sha256(dcp) != bindings[0][2]):
        raise ValueError("netlist evidence is not bound to this routed checkpoint")
    reset_proofs = reset_proof.prove(*reset_proof.parse_evidence(evidence_text))

    safety_error = []
    if (safety / "tests.exit").read_text().strip() != "0" or \
            (safety / "tests.ok").read_text().strip() != "SC7F0_CAPTURE_SAFETY_PASS":
        safety_error.append("missing actual-IP capture safety evidence")
    for name, marker in (("stop.log", "SC7F0_STOP_ACK_SIM_GATE_PASS"),
                         ("pipeline.log", "CAPTURE_PIPELINE_SIM_GATE_PASS"),
                         ("pipeline-4k.log", "CAPTURE_PIPELINE_4K_SIM_GATE_PASS")):
        text = (safety / name).read_text()
        if marker not in text or re.search(r"Error:|Fatal:|ERROR:|FATAL:", text):
            safety_error.append("failed actual-IP simulation: " + name)
    errors.extend(safety_error)

    logs = directory.parent / (directory.name + "-logs")
    source_root = logs / "source"
    repo = Path(__file__).resolve().parents[1]
    sim_entries = (safety / "INPUTS.sha256").read_text().splitlines()
    expected_sim = set(SAFETY_FILES)
    current_ip = directory / "qpcie_zu4ev_card.srcs/sources_1/ip"
    for ip in ("sc7f0_frmbuf_wr", "sc7f0_vpss_csc", "axi_clock_converter_0", "sc7f0_capture_width"):
        expected_sim.add(str((current_ip / ip / (ip + ".xci")).resolve().relative_to(repo)))
    if len(sim_entries) != len(expected_sim) or \
            {line.split("  ", 1)[1] for line in sim_entries} != expected_sim:
        errors.append("incomplete/duplicate capture-safety source manifest")
    for line in sim_entries:
        digest, name = line.split("  ", 1)
        path = Path(name)
        if path.is_absolute() or ".." in path.parts or sha256(repo / path) != digest:
            errors.append("capture-safety input drift: " + name)
    for manifest in ("SOURCE_RTL.sha256", "SOURCE_BUILD.sha256"):
        entries = (logs / manifest).read_text().splitlines()
        if not entries:
            raise ValueError("empty source manifest: " + manifest)
        for line in entries:
            digest, name = line.split("  ", 1)
            path = Path(name)
            if path.is_absolute() or ".." in path.parts or not re.fullmatch("[0-9a-f]{64}", digest):
                raise ValueError("invalid source manifest entry: " + name)
            if any(sha256(base / path) != digest for base in (source_root, repo)):
                errors.append("snapshot/live source drift: " + name)

    for ip in ("vid_phy_controller_0", "v_hdmi_rx_ss_0"):
        base_file = Path(baseline_ip) / ip / (ip + ".xci")
        if sha256(base_file) != BASE_XCI_SHA[ip]:
            raise ValueError("baseline XCI provenance mismatch: " + ip)
        def params(base):
            return json.loads((Path(base) / ip / (ip + ".xci")).read_text()
                              )["ip_inst"]["parameters"]["component_parameters"]
        if params(current_ip) != params(baseline_ip):
            errors.append("frozen vendor IP configuration changed: " + ip)

    width = json.loads((current_ip / "sc7f0_frmbuf_wr/sc7f0_frmbuf_wr.xci").read_text()
                       )["ip_inst"]["parameters"]["component_parameters"]
    downsize = json.loads((current_ip / "sc7f0_capture_width/sc7f0_capture_width.xci").read_text()
                          )["ip_inst"]["parameters"]["component_parameters"]
    if width.get("AXIMM_DATA_WIDTH", [{}])[0].get("value") != "256":
        errors.append("R7 framebuffer is not 256-bit AXIMM")
    if (downsize.get("SI_DATA_WIDTH", [{}])[0].get("value") != "256" or
            downsize.get("MI_DATA_WIDTH", [{}])[0].get("value") != "128" or
            downsize.get("PROTOCOL", [{}])[0].get("value") != "AXI4"):
        errors.append("R7 PS 256->128 AXI downsizer is not the reviewed shape")

    rtl = (source_root / "rtl/sc7f0_tap_regs.v").read_text()
    if "32'h00010001" not in rtl or "stop_ack_m<=stop_ack_m+1" not in rtl:
        errors.append("requires ABI1.1 ordered drain barrier")

    classified, unknown = Counter(), []
    for row in rows:
        kind = reviewed.classify(row, baseline, reset_proofs)
        if kind:
            classified[kind] += 1
        else:
            unknown.append(row)
    if unknown:
        errors.append("unreviewed exact CDC paths: " + str(len(unknown)))
    if dict(classified) != REVIEWED_CATEGORIES:
        errors.append("reviewed CDC category counts differ from R7 inventory")

    drc = (evidence / "drc.rpt").read_text()
    drc_rows = re.findall(r"^\|\s*([A-Z]+-\d+)\s*\|\s*([^|]+?)\s*\|[^|]*\|\s*(\d+)\s*\|", drc, re.M)
    drc_total = re.search(r"Violations found:\s*(\d+)", drc)
    if (not drc_total or int(drc_total[1]) != 123 or len(drc_rows) != len(DRC) or
            {r: (s, int(n)) for r, s, n in drc_rows} != DRC or
            hashlib.sha256(drc.partition("2. REPORT DETAILS\n")[2].encode()).hexdigest() != DRC_DETAILS_SHA):
        errors.append("routed DRC inventory differs from exact reviewed R7 scope")
    pdcn = re.findall(r"^PDCN-1569#\d+ Warning\n.*?\n\s*Used physical LUT pin.*?\n",
                      drc, re.M | re.S)
    if len(pdcn) != 3 or any("u_ps_capture/u_memory_width/inst/gen_downsizer." not in x
                             for x in pdcn):
        errors.append("PDCN LUT-term findings are outside the reviewed downsizer")
    if ("u_audio_stream_engine_ch0/u_decouple_fifo" not in drc or
            "u_hdmi_rx_ss/inst/v_hdmi_rx/inst/SYS_INST/lclk_cke[3]" not in drc or
            "u_ps_capture/u_memory_width/inst/gen_downsizer" not in drc):
        errors.append("DRC advisory paths differ from reviewed R7 scope")

    ip_status = (directory / "ip_status.rpt").read_text()
    license_rows = [line for line in ip_status.splitlines()
                    if re.match(r"^\|\s*(?:v_hdmi_rx_ss_0|bd_2422_v_hdmi_rx_0)\s*\|", line)]
    if len(license_rows) != 2 or any("Purchased" not in line for line in license_rows) or \
            "Evaluation" in ip_status or "Design_Linking" in ip_status:
        errors.append("HDMI purchased-license evidence missing")

    timing = (directory / "timing_summary.rpt").read_text()
    if not re.search(r"Tool Version\s*:\s*Vivado v\.?2023\.2\b", timing):
        errors.append("unsupported Vivado report version")
    if not re.search(r"Design State\s*:\s*Routed\b", timing):
        errors.append("not routed")
    table = re.search(r"^\s*WNS\(ns\).*WPWS\(ns\).*\n[^\n]*\n([^\n]+)", timing, re.M)
    if not table:
        raise ValueError("missing timing summary")
    values = list(map(float, table[1].split()))
    if len(values) != 12 or not all(map(math.isfinite, values)):
        raise ValueError("invalid timing summary")
    if any(values[i] < 0 for i in (0, 4, 8)) or any(values[i] != 0 for i in (1, 2, 5, 6, 9, 10)):
        errors.append("setup/hold/pulse failure")

    coverage = (directory / "check-timing.rpt").read_text()
    for name in ("no_clock", "constant_clock", "pulse_width_clock",
                 "unconstrained_internal_endpoints", "multiple_clock", "generated_clocks",
                 "loops", "latch_loops", "partial_input_delay", "partial_output_delay"):
        counts = re.findall(r"checking " + name + r" \((\d+)\)", coverage)
        if not counts or any(int(v) for v in counts):
            errors.append("bad/missing coverage: " + name)
    if (reviewed.io_ports(coverage, 5, "no_input_delay", 6) != reviewed.INPUTS or
            reviewed.io_ports(coverage, 6, "no_output_delay", 7) != reviewed.OUTPUTS):
        errors.append("unreviewed external I/O endpoint")

    methodology = (directory / "methodology.rpt").read_text()
    method = re.findall(r"^\|\s*([A-Z]+-\d+)\s*\|\s*([^|]+?)\s*\|[^|]*\|\s*(\d+)\s*\|",
                        methodology, re.M)
    total = re.search(r"Violations found:\s*(\d+)", methodology)
    if not total or int(total[1]) != sum(int(r[2]) for r in method) or \
            len({r[0] for r in method}) != len(method):
        raise ValueError("incomplete methodology summary")
    if {rule: (severity, int(count)) for rule, severity, count in method} != METHOD:
        errors.append("methodology inventory differs from reviewed R7 profile")

    skew = (directory / "bus-skew.rpt").read_text()
    vals = re.findall(r"^\s*(?:Slow|Fast)\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s*$", skew, re.M)
    if not vals or "(VIOLATED)" in skew or any(not math.isfinite(float(r[2])) or float(r[2]) < 0
                                               for r in vals):
        errors.append("skew coverage/failure")

    log = (logs / "impl-console.log").read_text()
    if log.count("SC7F0_CAPTURE_GRAY_CONSTRAINTS_PASS") != 2:
        errors.append("missing pre-opt/post-route Gray checks")

    personality = (directory / "c2h-personality.rpt").read_text().splitlines()
    records = [line.split() for line in personality[:-1]]
    if (not personality or personality[-1] != "C2H_PERSONALITY_SYNTH_PASS" or
            len(records) != len(ABSENT) + len(PRESENT) or
            {r[1] for r in records if r[0] == "ABSENT" and r[2] == "0"} != ABSENT or
            {r[1] for r in records if r[0] == "PRESENT" and int(r[2]) > 0} != PRESENT):
        errors.append("C2H required/forbidden linked-cell audit differs")

    xpr = (directory / "qpcie_zu4ev_card.xpr").read_text()
    version_tags = re.findall(r'<Generic Name="C_VERSION" Val="([^"]+)"', xpr)
    if not version_tags or set(version_tags) != {f"32&apos;h{VERSION}"}:
        errors.append("project C_VERSION is not the frozen R7 version")
    if '<Verilog_Define Name="SC7F0_C2H_ONLY" Val="1"' not in xpr:
        errors.append("project is not the C2H-only production personality")

    result = dict(
        pass_gate=not errors,
        profile=f"R7_C2H_ABI1.1_{VERSION}",
        zero_warning_claim=False,
        margins_ns=dict(WNS=values[0], WHS=values[4], WPWS=values[8]),
        cdc_summary={k: list(v) for k, v in summary.items()},
        reviewed_categories=dict(classified),
        reset_roots_proved=len(reset_proofs),
        drc=dict(DPIP_2=74, DPOP_3=13, DPOP_4=30, PDCN_1569=3, REQP_1935=2, RTSTAT_10=1),
        unknown_paths=unknown[:20],
        errors=errors,
        deployment_acceptance="separate matching-image/package and real-card gates required",
    )
    return result


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("directory")
    p.add_argument("--evidence", required=True)
    p.add_argument("--safety", required=True)
    p.add_argument("--baseline-cdc", required=True)
    p.add_argument("--baseline-ip", required=True)
    a = p.parse_args()
    try:
        result = check(a.directory, a.evidence, a.safety, a.baseline_cdc, a.baseline_ip)
    except (OSError, ValueError, KeyError, IndexError) as exc:
        print(json.dumps({"pass_gate": False, "error": str(exc)}))
        raise SystemExit(2)
    print(json.dumps(result, indent=2))
    raise SystemExit(0 if result["pass_gate"] else 1)


if __name__ == "__main__":
    main()
