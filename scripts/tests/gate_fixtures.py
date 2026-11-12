"""Fixture helpers shared by the two-layer gate tests.

The manifest fixtures are built from two sources of truth that are both derived
from the repository, never typed by hand:

* the field names come from scripts/check_sc7f0_named_constraints.tcl itself
  (`tcl_produced_fields`), so a policy requirement that names a field the producer
  never writes - the rx_ss_dpram `min_instances` bug - cannot be hidden by a
  fixture that invents it;
* the endpoint counts come from the CDC rows of the round being simulated
  (`row_groups` + sc7f0_review_policy.row_endpoint_expectation), i.e. the same
  dynamic relation the gate now enforces.
"""
import hashlib
import json
import re
from pathlib import Path

import sc7f0_review_policy as review


def tcl_produced_fields(tcl_path):
    """{manifest item id: {field names the hook writes for it}}."""
    text = Path(tcl_path).read_text()

    def block(start, end):
        i = text.index(start)
        return text[i:text.index(end, i)]

    def array_defaults(chunk, var):
        key = "array set %s {" % var
        i = chunk.index(key)
        depth, j = 0, i + len(key)
        while j < len(chunk):
            if chunk[j] == "{":
                depth += 1
            elif chunk[j] == "}":
                depth -= 1
                if not depth:
                    break
            j += 1
        body = chunk[i + len(key):j]
        return {k for k in re.split(r"\s+", body) if re.fullmatch(r"\w+", k or "")}

    def written(chunk, var):
        return set(re.findall(r"set %s\((\w+)\)" % var, chunk))

    md = block("set max_delay_table [list", "foreach row $max_delay_table {")
    md_ids = re.findall(r"\[\s*list\s+([a-z0-9_]+)", md)
    md_body = block("foreach row $max_delay_table {", "# The DPRAM sample-timing item")
    md_fields = array_defaults(md_body, "rec") | written(md_body, "rec")

    sample = block("catch {array unset drec}", "sc7f0_put rx_ss_dpram_sample_timing")

    io_head = block("set io_table [list", "foreach row $io_table {")
    io_rows = re.findall(r"\[\s*list\s+(\w+)\s+\{([^}]*)\}\s*(?:\{([^}]*)\})?", io_head)
    io_body = block("foreach row $io_table {", "set internal_table [list")
    io_fields = array_defaults(io_body, "rec") | written(io_body, "rec")
    internal_head = block("set internal_table [list", "foreach row $internal_table {")
    internal_ids = re.findall(r"\[list\s+(\w+)\s", internal_head)
    internal_body = block("foreach row $internal_table {", "# pad consumer closure")
    internal_fields = (array_defaults(internal_body, "rec")
                       | written(internal_body, "rec"))
    # A silent miss here would make every internal_async requirement look like a
    # field the hook never writes, so say it out loud instead.
    if not internal_ids or not internal_fields:
        raise AssertionError(
            "could not read the internal async section of "
            "scripts/check_sc7f0_named_constraints.tcl "
            f"(ids={internal_ids}, fields={len(internal_fields)})")
    closure_body = block("foreach port [array names claims] {",
                         "sc7f0_put $id [array get crec]")
    closure_fields = array_defaults(closure_body, "crec") | written(closure_body, "crec")

    fields = {"clock_groups": {"class", "review_required", "count"}}
    for item in md_ids:
        fields[item] = md_fields
    fields["rx_ss_dpram_sample_timing"] = array_defaults(sample, "drec") | written(sample, "drec")
    for item, ports, first_stage in io_rows:
        if not item or item.startswith("foreach"):
            continue
        fields[item] = io_fields
        if first_stage:
            for port in ports.split():
                fields["async_pad_" + port] = closure_fields
    for item in internal_ids:
        fields[item] = internal_fields
    return fields


TCL_FIELDS = None


def produced_fields(item_id):
    global TCL_FIELDS
    if TCL_FIELDS is None:
        TCL_FIELDS = tcl_produced_fields(
            Path(__file__).resolve().parents[2] / "scripts"
            / "check_sc7f0_named_constraints.tcl")
    return TCL_FIELDS.get(item_id, set())


def hook_item(item_id, class_=None, **values):
    """One manifest record, rejecting any field the hook never writes."""
    if class_ is not None:
        values["class"] = class_
    never = sorted(set(values) - produced_fields(item_id))
    if never:
        raise AssertionError(
            f"{item_id}: fixture supplies {never}, which "
            "scripts/check_sc7f0_named_constraints.tcl never writes. Either the hook "
            "must measure it or the policy must stop claiming it.")
    return values


def cdc_rows_from_text(text):
    import check_sc7f0_timing as gate
    _counts, rows, _n = gate.parse_cdc(text)
    return rows


def row_groups(rows):
    """Group CDC rows the way the shipped policy items classify them."""
    def keep(predicate):
        return [row for row in rows if predicate(row)]
    return {
        "rx_ss_dpram_max_delay": keep(lambda r: r["rule"] == "CDC-26"),
        "capture_gray_to_source_time": keep(
            lambda r: r["src"].startswith("u_ps_capture/u_tap/gray_q_reg")
            and "/u_source_time/stage0_reg" in r["dest"]),
        "capture_gray_to_csr_time": keep(
            lambda r: r["src"].startswith("u_ps_capture/u_tap/gray_q_reg")
            and "/u_regs/u_time/stage0_reg" in r["dest"]),
        "probe_meter_max_delay": keep(
            lambda r: r["src"].startswith("u_hdmi_probe/u_meter")
            and "snapshot_test_reg" in r["src"]),
        "xpm_async_fifo_ce_arcs": keep(
            lambda r: r["rule"] == "CDC-15" and "gnuram_async_fifo" in r["src"]),
    }


def expected_endpoints(rows, group):
    return review.row_endpoint_expectation(rows[group])["endpoints"]


def io_record(item_id, port, first_stage_cells, async_reg=1, same_domain=1, paths=1,
              domains=1, clock_pin_loads=0, objects=1):
    """An io_exception record shaped like the hook's output.

    `endpoints` is deliberately 0: report_exceptions -coverage counts endpoints for
    timed exceptions, so a false path reports 0. The gate must not read that as "no
    coverage" (that used to be a fixture-only pass).
    """
    return hook_item(
        item_id, class_="io_exception", review_required=1, from_objects=objects,
        to_objects=objects, first_stage_cells=first_stage_cells,
        first_stage_async_reg=async_reg, internal_filter_same_domain=same_domain,
        paths_analysed=paths, clock_domain_count=domains,
        clock_or_setreset_pin_loads=clock_pin_loads, exception_rows=1,
        ignored=0, scope_overridden=0, port=port, endpoint_count=objects,
        internal_load_count=1, first_stage_clock_domains="clk_pl_0",
        internal_load_clock_domains="clk_pl_0", exception_type="False Path",
        exception_position=220, endpoints=0)


def output_record(item_id, ports, drivers=1, vphy=0, oserdes=0, port_count=1):
    return hook_item(
        item_id, class_="io_exception", review_required=1, from_objects=port_count,
        to_objects=port_count, port=ports, endpoint_count=0, endpoints=0,
        ignored=0, scope_overridden=0, exception_rows=1, exception_type="False Path",
        exception_position=210, direction="OUT", io_standard="LVDS",
        port_count=port_count, pad_driver_cells=drivers,
        pad_driver_refs="OBUFTDS" if vphy else "OBUF",
        pad_driver_clock_domains="clk_pl_0", driver_is_vphy=vphy,
        driver_is_obuf=0 if vphy else 1, oserdes_cells=oserdes)


def pad_closure(item_id, port, sequential, async_reg, unclaimed=0,
                clock_pin_loads=0, domains=1):
    return hook_item(
        item_id, class_="pad_closure", review_required=1,
        from_objects=1, to_objects=sequential, port=port, endpoint_count=sequential,
        sequential_endpoint_count=sequential, async_reg_endpoint_count=async_reg,
        first_stage_endpoints_missing_async_reg=sequential - async_reg,
        claimed_first_stage_endpoints=sequential - unclaimed,
        unclaimed_first_stage_endpoints=unclaimed,
        unclaimed_first_stage_cells="", clock_or_setreset_pin_loads=clock_pin_loads,
        clock_domains="clk_pl_0", clock_domain_count=domains)


def reports_digest(directory, names):
    out = {}
    for name in sorted(names):
        path = Path(directory) / name
        if path.is_file():
            out[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    return out


def write_manifest(directory, items, state="Routed", reports=None):
    """Write a manifest bound to every gate report that exists in `directory`."""
    directory = Path(directory)
    digest = hashlib.sha256((directory / "cdc.rpt").read_bytes()).hexdigest()
    if reports is None:
        reports = reports_digest(directory, review.GATE_REPORT_NAMES)
    (directory / "named-constraint-evidence.json").write_text(json.dumps({
        "generated_by": "scripts/check_sc7f0_named_constraints.tcl",
        "design_state": state, "cdc_rpt_sha256": digest,
        "reports_sha256": reports, "items": items}))
