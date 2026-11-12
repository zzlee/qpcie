#!/usr/bin/env python3
"""Layer B of the SC7F0 strict gate: itemised, machine-checkable review policy.

Why this exists
---------------
The old gate graded "correctness defects" and "vendor/advisory findings that
nobody classified" with the same pass/fail, so either every shipped generation
failed (2660 unreviewed CDC warnings, TIMING-6/7, ULMTCS-1, CLKC-*) or a coder
widened a whitelist and the finding silently disappeared.  Neither is an audit.

Layer B therefore keeps *every* Warning/Advisory visible and demands, per rule
and per exact root instance, a structural description plus evidence that is
re-checked against the reports of the round being judged:

* a policy item that matches no row / no violation in this round is an error
  (stale or fabricated entry), not a silent no-op;
* a row matched by two items is an error (duplicate classification masking);
* a Warning/Advisory matched by no item is an error (uncovered finding);
* a REVIEWED_SAFE item must carry at least one requirement that this module can
  verify from this round's reports - prose alone, "vendor says so" alone, or an
  evidence pointer to a file that does not exist all fail;
* NEEDS_STRUCTURAL_REVIEW / BLOCKED items always fail Layer B and say what is
  missing, which is how the RX-DDC first stage and the TX TMDS pad stay open
  instead of being laundered through a clock group.

Offline, deterministic, no Vivado, no network.
"""
from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path

SCHEMA = "sc7f0-review-policy/1"
STATUSES = ("REVIEWED_SAFE", "NEEDS_STRUCTURAL_REVIEW", "BLOCKED")
# Requirement kinds this module knows how to verify.  A kind nobody implements
# is a load-time error, so a policy cannot invent its own "proof".
REQUIREMENT_KINDS = ("row_exception", "named_constraint", "clock_interaction",
                     "io_exception", "report_nonempty", "manifest_metric")
# Every option name a requirement of each kind may carry.  A typo used to be
# silently ignored, which is a fail-open: the entry looked stricter than it was.
# Adding an option here means implementing it in the checker of the same name.
REQUIREMENT_OPTIONS = {
    "row_exception": {"kind", "type", "any_of"},
    "named_constraint": {"kind", "id", "min_objects", "min_endpoints", "max_delay_ns",
                         "bus_skew_ns", "min_bus_skew_slack_ns", "min_from_coverage_pct",
                         "min_instances", "require_row_endpoint_match",
                         "allow_extra_endpoints", "min_distinct_src_cells",
                         "min_distinct_dest_cells", "min_distinct_dest_parents",
                         "min_distinct_src_roots", "min_first_stage_async_reg",
                         "require_same_domain_filter", "min_paths_analysed",
                         "max_clock_domains", "max_clock_or_setreset_pin_loads",
                         "max_exception_rows", "not_ignored"},
    "manifest_metric": {"kind", "id", "field", "equals", "min", "max"},
    "clock_interaction": {"kind", "from", "to", "classification_any",
                          "constraints_any", "require_endpoints"},
    "report_nonempty": {"kind", "report"},
    "io_exception": {"kind", "id"},
}
# Severity words Vivado uses in report_drc / report_methodology / report_cdc.
CRITICAL_SEVERITIES = ("error", "critical warning", "critical")
NON_CRITICAL_SEVERITIES = ("warning", "advisory", "info")

# Reports the two-layer gate reads as input.  The coverage manifest must bind
# every one of these that exists in the round's report directory
# (verify_report_binding below): binding only cdc.rpt let one round's cdc.rpt +
# manifest be graded against another round's methodology / DRC / check_timing /
# bus-skew reports, which is exactly what the hand-made
# tmp-named-evidence-check/named-constraint-evidence.json demonstrates is
# reachable.  Reports only - never logs, never the manifest itself - because a
# file whose bytes depend on when it was written, or a hash of the manifest inside
# the manifest, proves nothing.
GATE_REPORT_NAMES = ('timing_summary.rpt', 'check-timing.rpt', 'cdc.rpt',
                     'methodology.rpt', 'bus-skew.rpt', 'drc.rpt',
                     'clock-interaction.rpt', 'exceptions-ignored.rpt',
                     'exceptions-scope-override.rpt', 'exceptions-coverage.rpt',
                     'exceptions-all.rpt', 'io.rpt', 'clock-networks.rpt',
                     'disable-timing-user.rpt', 'utilization_routed_hierarchical.rpt')


def _text(value):
    return value.strip() if isinstance(value, str) else ""


def is_critical_severity(severity: str) -> bool:
    return severity.strip().lower() in CRITICAL_SEVERITIES


def is_non_critical_severity(severity: str) -> bool:
    return severity.strip().lower() in NON_CRITICAL_SEVERITIES


def load_policy(path: Path, expect: str = "cdc") -> dict:
    """Load and validate one policy file.  Anything malformed raises."""
    path = Path(path)
    if not path.is_file():
        raise ValueError(f"review policy {path} does not exist")
    policy = json.loads(path.read_text())
    if not isinstance(policy, dict):
        raise ValueError(f"review policy {path} is not a JSON object")
    if policy.get("schema") != SCHEMA:
        raise ValueError(f"review policy {path} has schema {policy.get('schema')!r}, "
                         f"expected {SCHEMA!r}")
    if _text(policy.get("kind")) != expect:
        raise ValueError(f"review policy {path} kind {policy.get('kind')!r} != {expect!r}")
    if not _text(policy.get("id")):
        raise ValueError(f"review policy {path} has no id")
    items = policy.get("items")
    if not isinstance(items, list) or not items:
        raise ValueError(f"review policy {path} has an empty or missing items list")
    seen = set()
    for item in items:
        _validate_item(item, path, seen, expect)
        seen.add(item["id"])
    for item in policy.get("io_items", []) or []:
        _validate_item(item, path, seen, "io")
        seen.add(item["id"])
    for item in policy.get("methodology_items", []) or []:
        _validate_item(item, path, seen, "methodology")
        seen.add(item["id"])
    return policy


def _validate_item(item, path, seen, kind="cdc"):
    if not isinstance(item, dict):
        raise ValueError(f"review policy {path}: item {item!r} is not an object")
    item_id = _text(item.get("id"))
    if not item_id:
        raise ValueError(f"review policy {path}: item without id")
    if item_id in seen:
        raise ValueError(f"review policy {path}: duplicate item id {item_id}")
    if not _text(item.get("rule")) and kind != "io":
        raise ValueError(f"{item_id}: no rule")
    if kind == "io" and not _text(item.get("port")):
        raise ValueError(f"{item_id}: io entry has no port")
    status = _text(item.get("status"))
    if status not in STATUSES:
        raise ValueError(f"{item_id}: status {status!r} not in {STATUSES}")
    if not _text(item.get("structure")):
        raise ValueError(f"{item_id}: no structural description")
    if not _text(item.get("rationale")):
        raise ValueError(f"{item_id}: no review rationale")
    evidence = item.get("evidence")
    if not isinstance(evidence, list) or not [e for e in evidence if _text(str(e))]:
        raise ValueError(f"{item_id}: no evidence entries")
    requires = item.get("requires", [])
    if not isinstance(requires, list):
        raise ValueError(f"{item_id}: requires must be a list")
    for requirement in requires:
        kind = _text(requirement.get("kind")) if isinstance(requirement, dict) else ""
        if kind not in REQUIREMENT_KINDS:
            raise ValueError(f"{item_id}: requirement kind {kind!r} is not verifiable "
                             f"(known: {', '.join(REQUIREMENT_KINDS)})")
        unknown = sorted(set(requirement) - REQUIREMENT_OPTIONS[kind])
        if unknown:
            raise ValueError(f"{item_id}: {kind} requirement carries options this gate "
                             f"does not implement: {unknown} (an option that is ignored "
                             "would make the entry look stricter than it is)")
    # Prose-only "review" is exactly what this module exists to reject.
    if status == "REVIEWED_SAFE" and not requires:
        # DRC/IO entries carry their own structural check (instance allow-list or
        # the named exception in the coverage manifest), so they need a
        # non-empty instance_prefixes / manifest_id instead of a `requires` list.
        structural = _text(item.get("manifest_id")) or (item.get("instance_prefixes") or [])
        if kind not in ("drc", "io") or not structural:
            raise ValueError(f"{item_id}: REVIEWED_SAFE without a machine-checkable "
                             "requirement (vendor wording alone is not a review)")
        if kind == "drc" and item.get("instance_prefixes") is not None \
                and not item.get("instance_prefixes"):
            raise ValueError(f"{item_id}: REVIEWED_SAFE DRC entry with an empty "
                             "instance_prefixes allow-list")
    for key in ("src_regex", "dest_regex", "root_regex", "instance_prefixes"):
        value = item.get(key)
        if value is None:
            continue
        values = value if isinstance(value, list) else [value]
        for entry in values:
            try:
                re.compile(entry)
            except (re.error, TypeError) as exc:
                raise ValueError(f"{item_id}: bad {key} {entry!r}: {exc}") from None


# ---------------------------------------------------------------------------
# coverage manifest (regenerated every round by the implementation hook)
# ---------------------------------------------------------------------------
def load_coverage_manifest(path: Path, cdc_rpt: Path) -> dict:
    """Return this round's named-constraint evidence, bound to this cdc.rpt.

    The implementation hook hashes cdc.rpt when it writes the manifest, so a
    manifest from an older round - or one hand-written to describe a report that
    was never produced - is rejected here instead of being trusted.
    """
    path = Path(path)
    if not path.is_file():
        raise ValueError(f"named-constraint coverage manifest {path} does not exist; "
                         "Layer B cannot be judged without a manifest regenerated this "
                         "round (scripts/check_sc7f0_named_constraints.tcl)")
    manifest = json.loads(path.read_text())
    if not isinstance(manifest, dict):
        raise ValueError(f"coverage manifest {path} is not a JSON object")
    if not _text(manifest.get("generated_by")):
        raise ValueError(f"coverage manifest {path} does not say what produced it")
    state = _text(manifest.get("design_state"))
    if state not in ("Routed", "Physopt postRoute", "Fully Routed"):
        raise ValueError(f"coverage manifest {path} design state {state!r} is not a "
                         "known post-route state; refusing to accept constraint "
                         "coverage from an unrouted design")
    want = hashlib.sha256(Path(cdc_rpt).read_bytes()).hexdigest()
    got = _text(manifest.get("cdc_rpt_sha256"))
    if got != want:
        raise ValueError(f"coverage manifest {path} was generated against cdc.rpt "
                         f"{got[:12] or '<missing>'}, not the {want[:12]} being judged")
    items = manifest.get("items")
    if not isinstance(items, dict):
        raise ValueError(f"coverage manifest {path} has no items map")
    return manifest


def verify_report_binding(manifest, directory, names=GATE_REPORT_NAMES):
    """Errors for every gate input report the manifest does not bind to this round.

    The manifest is written by the implementation hook after every report exists,
    so `reports_sha256` must name each report the gate is about to read with the
    digest of the bytes on disk right now.  Three ways a round used to be able to
    lie, and how this catches it:

    * report present, no entry                -> 'never bound'      (round mix)
    * report present, different digest         -> 'was regenerated'
    * entry present, report absent             -> 'binds a file that this round
      never produced' (a manifest copied in from another round)

    The manifest's own file is deliberately not hashed anywhere, so this is not a
    self-referential hash chain.
    """
    directory = Path(directory)
    binding = manifest.get("reports_sha256")
    if not isinstance(binding, dict) or not binding:
        return ["coverage manifest has no reports_sha256 map; only cdc.rpt would be "
                "bound to this round, so every other gate input (methodology, DRC, "
                "check_timing, bus skew, clock interaction, exception audit) could be "
                "swapped between rounds undetected "
                "(scripts/check_sc7f0_named_constraints.tcl writes this map)"]
    errors = []
    for name in sorted(set(names) | {k for k, v in binding.items() if _text(str(v))}):
        path = directory / name
        got = _text(binding.get(name))
        if not path.is_file():
            if got:
                errors.append(f"coverage manifest binds {name} "
                              f"({got[:12]}), but this round's report directory has no "
                              f"{name}: the manifest came from a different round")
            continue
        want = hashlib.sha256(path.read_bytes()).hexdigest()
        if not got:
            errors.append(f"coverage manifest does not bind {name}, which this round "
                          "produced and the gate is about to read")
        elif got != want:
            errors.append(f"coverage manifest binds {name} to {got[:12]}, the report "
                          f"being judged is {want[:12]}: {name} was regenerated after "
                          "the manifest, or comes from another round")
    return errors


# ---------------------------------------------------------------------------
# requirement verification
# ---------------------------------------------------------------------------
def endpoint_token_width(token: str) -> int:
    """How many endpoint cells one report_cdc endpoint token stands for.

    `u_tap/gray_q_reg[63:0]/C` is 64 endpoints while `doutb_reg[0]/D` and a plain
    `mem/CLK` are 1, so the endpoint count a policy may compare against a routed
    measurement has to be expanded from the rows themselves instead of being
    copied from whichever round the policy was written in (review P1-9: the
    hardcoded 416/64 broke the moment an IP changed).
    """
    total = 1
    for high, low in re.findall(r"\[(\d+)(?::(\d+))?\]", token):
        total *= abs(int(high) - int(low or high)) + 1
    return total


def _cell_of(token: str) -> str:
    """`.../reg[3]/D` -> `.../reg[3]` (the endpoint's cell path)."""
    return token.rsplit("/", 1)[0] if "/" in token else token


def row_endpoint_expectation(rows) -> dict:
    """Endpoint facts derived from the CDC rows an entry matched, this round."""
    endpoints = 0
    src_cells, dest_cells, dest_parents, src_roots = set(), set(), set(), set()
    for row in rows:
        src, dest = row.get("src", ""), row.get("dest", "")
        endpoints += endpoint_token_width(dest) or endpoint_token_width(src)
        src_cells.add(_cell_of(src))
        dest_cells.add(_cell_of(dest))
        cell = _cell_of(dest)
        dest_parents.add(cell.rsplit("/", 1)[0] if "/" in cell else cell)
        src_cell = _cell_of(src)
        src_roots.add(src_cell.rsplit("/", 1)[0] if "/" in src_cell else src_cell)
    return {"endpoints": endpoints, "src_cells": src_cells, "dest_cells": dest_cells,
            "dest_parents": dest_parents, "src_roots": src_roots}


def _check_named_constraint(item_id, requirement, manifest, errors, rows=()):
    name = _text(requirement.get("id"))
    if not name:
        errors.append(f"{item_id}: named_constraint requirement without id")
        return
    record = manifest.get("items", {}).get(name)
    if record is None:
        errors.append(f"{item_id}: named constraint {name} is absent from this round's "
                      "coverage manifest (the constraint or its check never ran)")
        return
    if not isinstance(record, dict):
        errors.append(f"{item_id}: named constraint {name} record is malformed")
        return
    objects = int(record.get("from_objects", 0) or 0)
    to_objects = int(record.get("to_objects", 0) or 0)
    if objects <= 0 or to_objects <= 0:
        errors.append(f"{item_id}: named constraint {name} resolved to "
                      f"{objects}/{to_objects} objects; an exception on an empty "
                      "object list is not coverage")
        return
    minimum = int(requirement.get("min_objects", 1))
    if objects < minimum or to_objects < minimum:
        errors.append(f"{item_id}: named constraint {name} resolved to fewer objects "
                      f"than the policy minimum {minimum}")
    # `endpoints` is only demanded when the requirement says so: the hook writes
    # endpoints = 0 for a false path (report_exceptions -coverage counts endpoints for
    # timed exceptions), and an io entry that asked for "min_endpoints 1 by default"
    # could therefore never pass on real hook output while a fixture that omitted the
    # field passed. Requirements state what they need.
    if "min_endpoints" in requirement:
        got = int(record.get("endpoints", 0) or 0)
        if got < int(requirement["min_endpoints"]):
            errors.append(f"{item_id}: named constraint {name} covers {got} "
                          f"endpoints, below the required {requirement['min_endpoints']}")
    # A max delay is compared against what the timing engine MEASURED on the
    # routed netlist (max_delay_measured_ns, written by the hook from
    # get_property REQUIREMENT), never against the value the hook's own table
    # hoped for.  The old code let the producer write its expectation into the
    # evidence and the policy then re-check that expectation, which is true by
    # construction and proves nothing.
    if "max_delay_ns" in requirement:
        measured = record.get("max_delay_measured_ns")
        if measured is None:
            errors.append(f"{item_id}: named constraint {name} reports no "
                          "max_delay_measured_ns; the hook never measured the "
                          "requirement in force, and the policy's own expectation is "
                          "not evidence")
        elif abs(float(measured) - float(requirement["max_delay_ns"])) > 1e-6:
            errors.append(f"{item_id}: named constraint {name} is actually timed at "
                          f"{measured} ns, policy reviews {requirement['max_delay_ns']} ns")
        if str(record.get("max_delay_effective", "")) not in ("1", "1.0", "true", "True"):
            errors.append(f"{item_id}: named constraint {name} has no max delay in force "
                          f"this round (max_delay_effective="
                          f"{record.get('max_delay_effective', 'missing')})")
    if "bus_skew_ns" in requirement:
        if record.get("bus_skew_ns") is None:
            errors.append(f"{item_id}: named constraint {name} reports no bus_skew_ns; "
                          "the constraint is missing or was overridden")
        elif abs(float(record["bus_skew_ns"]) - float(requirement["bus_skew_ns"])) > 1e-6:
            errors.append(f"{item_id}: named constraint {name} has bus_skew_ns "
                          f"{record['bus_skew_ns']}, policy expects {requirement['bus_skew_ns']}")
    if requirement.get("not_ignored", True) and record.get("ignored"):
        errors.append(f"{item_id}: named constraint {name} is reported as ignored by "
                      "report_exceptions -ignored")
    if requirement.get("not_ignored", True) and record.get("scope_overridden"):
        errors.append(f"{item_id}: named constraint {name} is scope-overridden by a "
                      "later constraint")
    if "min_bus_skew_slack_ns" in requirement:
        slack = record.get("bus_skew_slack_ns")
        if slack is None:
            errors.append(f"{item_id}: named constraint {name} has no bus-skew slack; "
                          "no bus_skew constraint is in effect")
        elif float(slack) < float(requirement["min_bus_skew_slack_ns"]):
            errors.append(f"{item_id}: named constraint {name} bus-skew slack {slack} "
                          f"is below {requirement['min_bus_skew_slack_ns']}")
    if "min_from_coverage_pct" in requirement:
        coverage = record.get("from_coverage_pct")
        if coverage is None or float(coverage) < float(requirement["min_from_coverage_pct"]):
            errors.append(f"{item_id}: named constraint {name} from-coverage "
                          f"{coverage} is below {requirement['min_from_coverage_pct']}%")
    if "min_instances" in requirement:
        if record.get("instances") is None:
            errors.append(f"{item_id}: named constraint {name} has no `instances` field, "
                          "so this requirement is attached to a record whose producer "
                          "never counts instances (attach it to the item that does)")
        else:
            got = int(record["instances"] or 0)
            if got < int(requirement["min_instances"]):
                errors.append(f"{item_id}: named constraint {name} found {got} instances, "
                              f"policy expects at least {requirement['min_instances']}")
    # Dynamic coverage: the exception must account for the endpoints THIS round's
    # CDC rows describe, not for a number copied out of a past round.
    expect = row_endpoint_expectation(rows)
    if requirement.get("require_row_endpoint_match"):
        got = int(record.get("endpoints", 0) or 0)
        if not expect["endpoints"]:
            errors.append(f"{item_id}: {name} demands row-derived endpoint coverage but "
                          "this entry matched no CDC row this round")
        elif got != expect["endpoints"]:
            errors.append(f"{item_id}: {name} covers {got} endpoints while the "
                          f"{len(rows)} CDC rows classified here describe exactly "
                          f"{expect['endpoints']}; a constraint that stopped covering "
                          "them, or rows that vanished, must be re-reviewed (a bare "
                          ">= would let half the rows disappear unnoticed)")
    if requirement.get("allow_extra_endpoints"):
        got = int(record.get("endpoints", 0) or 0)
        if got < expect["endpoints"]:
            errors.append(f"{item_id}: {name} covers {got} endpoints, below the "
                          f"{expect['endpoints']} endpoints the matched CDC rows describe")
    for key, field in (("min_distinct_src_cells", "src_cells"),
                       ("min_distinct_dest_cells", "dest_cells"),
                       ("min_distinct_dest_parents", "dest_parents"),
                       ("min_distinct_src_roots", "src_roots")):
        if key in requirement and len(expect[field]) < int(requirement[key]):
            errors.append(f"{item_id}: {name} matched rows spanning "
                          f"{len(expect[field])} distinct {field.replace('_', ' ')}, "
                          f"the reviewed structure spans at least {requirement[key]}")
    # Asynchronous pad entry points: read the real routed attributes instead of
    # trusting the prose in the policy file.
    if "max_exception_rows" in requirement:
        got = record.get("exception_rows")
        if got is None:
            errors.append(f"{item_id}: {name} reports no exception_rows; how many "
                          "exceptions the report actually found was never measured, so "
                          "an exact endpoint match would be coincidence")
        elif int(got) > int(requirement["max_exception_rows"]):
            errors.append(f"{item_id}: {name} is spread over {got} exception rows, more "
                          f"than the {requirement['max_exception_rows']} this entry "
                          "reviews; one named exception is claimed, not a population")
    if "min_first_stage_async_reg" in requirement:
        got = record.get("first_stage_async_reg")
        if got is None:
            errors.append(f"{item_id}: {name} reports no first_stage_async_reg; the "
                          "first-stage attribute was never read, so the synchroniser "
                          "claim is unverified (ASYNC_REG is a placement / "
                          "metastability-group annotation - its absence is never "
                          "'safer', it is simply unannotated)")
        elif int(got) < int(requirement["min_first_stage_async_reg"]):
            errors.append(f"{item_id}: {name} found {got} first-stage cells carrying "
                          f"ASYNC_REG, policy requires "
                          f"{requirement['min_first_stage_async_reg']}")
    if requirement.get("require_same_domain_filter"):
        if str(record.get("internal_filter_same_domain", "")) not in ("1", "1.0", "true", "True"):
            errors.append(f"{item_id}: {name} does not measure a same-domain internal "
                          "filter downstream of the first stage "
                          "(internal_filter_same_domain="
                          f"{record.get('internal_filter_same_domain', 'missing')}): the "
                          "internal filter/synchroniser paths are not proven to stay "
                          "fully timed at the internal clock")
    if "min_paths_analysed" in requirement:
        got = int(record.get("paths_analysed", 0) or 0)
        if got < int(requirement["min_paths_analysed"]):
            errors.append(f"{item_id}: {name} has {got} analysed paths on the measured "
                          f"object pair, below {requirement['min_paths_analysed']}; "
                          "an exception that stopped the engine from analysing the "
                          "path (or a pair that no longer exists) shows up here")
    if "max_clock_domains" in requirement:
        got = record.get("clock_domain_count")
        if got is None:
            errors.append(f"{item_id}: {name} reports no clock_domain_count; the clock "
                          "domains of the first stage and its loads were never measured")
        elif int(got) > int(requirement["max_clock_domains"]):
            errors.append(f"{item_id}: {name} spans {got} clock domains, policy reviews "
                          f"at most {requirement['max_clock_domains']}")
    if "max_clock_or_setreset_pin_loads" in requirement:
        got = record.get("clock_or_setreset_pin_loads")
        if got is None:
            errors.append(f"{item_id}: {name} reports no clock_or_setreset_pin_loads; a "
                          "pad that reaches a clock/set/reset pin is not a level input")
        elif int(got) > int(requirement["max_clock_or_setreset_pin_loads"]):
            errors.append(f"{item_id}: {name} has {got} endpoints on clock/set/reset "
                          "pins, policy reviews at most "
                          f"{requirement['max_clock_or_setreset_pin_loads']}")


def _check_manifest_metric(item_id, requirement, manifest, errors):
    """Compare one numeric metric the implementation hook measured this round.

    Used for 'no clock group may exist unless it is declared here' and similar
    whole-design facts that no individual row can prove.
    """
    name = _text(requirement.get("id"))
    field = _text(requirement.get("field"))
    record = manifest.get("items", {}).get(name)
    if not isinstance(record, dict) or record.get(field) is None:
        errors.append(f"{item_id}: coverage manifest has no {name}.{field}; the metric "
                      "was never measured this round so the claim is unverified")
        return
    value = float(record[field])
    if "equals" in requirement and abs(value - float(requirement["equals"])) > 1e-9:
        errors.append(f"{item_id}: {name}.{field} = {record[field]}, policy requires "
                      f"exactly {requirement['equals']}")
    if "max" in requirement and value > float(requirement["max"]):
        errors.append(f"{item_id}: {name}.{field} = {record[field]} exceeds the "
                      f"policy maximum {requirement['max']}")
    if "min" in requirement and value < float(requirement["min"]):
        errors.append(f"{item_id}: {name}.{field} = {record[field]} is below the "
                      f"policy minimum {requirement['min']}")


def _check_clock_interaction(item_id, requirement, pair_rows, errors):
    frm = _text(requirement.get("from"))
    to = _text(requirement.get("to"))
    row = pair_rows.get((frm, to))
    if row is None:
        errors.append(f"{item_id}: clock interaction row {frm} -> {to} is missing from "
                      "this round's report_clock_interaction; the direction was never "
                      "checked")
        return
    allowed = requirement.get("classification_any")
    if allowed and not any(re.search(p, row["classification"]) for p in allowed):
        errors.append(f"{item_id}: {frm} -> {to} classified {row['classification']!r}, "
                      f"policy accepts {allowed}")
    allowed_constraints = requirement.get("constraints_any")
    if allowed_constraints and not any(
            re.search(p, row["constraints"]) for p in allowed_constraints):
        errors.append(f"{item_id}: {frm} -> {to} inter-clock constraint "
                      f"{row['constraints']!r} is not one the policy reviewed "
                      f"({allowed_constraints})")
    if requirement.get("require_endpoints") and int(row.get("endpoints", 0) or 0) <= 0:
        errors.append(f"{item_id}: {frm} -> {to} reports no endpoints")


def _check_report_nonempty(item_id, requirement, reports, errors):
    name = _text(requirement.get("report"))
    text = reports.get(name)
    if text is None:
        errors.append(f"{item_id}: required report {name} was not produced this round")
        return
    if not text.strip():
        errors.append(f"{item_id}: required report {name} is empty")


def _verify_requirements(item, rows, manifest, pair_rows, reports, errors):
    item_id = item["id"]
    for requirement in item.get("requires", []):
        kind = requirement.get("kind")
        if kind == "row_exception":
            expected = _text(requirement.get("type"))
            want_any = requirement.get("any_of")
            bad = []
            for row in rows:
                got = row.get("exception", "")
                ok = (any(re.search(p, got) for p in want_any) if want_any
                      else got == expected)
                if not ok:
                    bad.append(row)
            if bad:
                errors.append(
                    f"{item_id}: {len(bad)} row(s) are not covered by the expected "
                    f"timing exception (expected {want_any or expected!r}, "
                    f"got {bad[0].get('exception', '')!r} on {bad[0]['dest'][:60]})")
        elif kind == "named_constraint":
            # `rows` is already the set of rows this item matched (see
            # review_rows), so the endpoint expectation below is the row set this
            # entry is actually claiming, not the whole report.
            _check_named_constraint(item_id, requirement, manifest, errors, rows)
        elif kind == "clock_interaction":
            _check_clock_interaction(item_id, requirement, pair_rows, errors)
        elif kind == "manifest_metric":
            _check_manifest_metric(item_id, requirement, manifest, errors)
        elif kind == "report_nonempty":
            _check_report_nonempty(item_id, requirement, reports, errors)


def _matches(item, row):
    rule = _text(item.get("rule"))
    if rule not in ("*", row["rule"]):
        if not (item.get("rule_regex") and re.fullmatch(item["rule_regex"], row["rule"])):
            return False
    for key, field in (("src_regex", "src"), ("dest_regex", "dest")):
        patterns = item.get(key)
        if patterns is None:
            continue
        patterns = patterns if isinstance(patterns, list) else [patterns]
        if not any(re.search(p, row[field]) for p in patterns):
            return False
    roots = item.get("root_regex")
    if roots is not None:
        roots = roots if isinstance(roots, list) else [roots]
        if not any(re.search(p, row["src"]) or re.search(p, row["dest"]) for p in roots):
            return False
    return True


def review_rows(rows, items, manifest, pair_rows, reports):
    """Classify cdc/methodology rows against policy items.  Returns (ledger, errors)."""
    errors = []
    ledger = {}
    unmatched = []
    for row in rows:
        hits = [item for item in items if _matches(item, row)]
        if not hits:
            unmatched.append(row)
            continue
        if len(hits) > 1:
            errors.append(f"{row['rule']}: row {row['dest'][:60]} is classified by "
                          + ", ".join(item["id"] for item in hits)
                          + " (duplicate classification hides which structure it is)")
            continue
        item = hits[0]
        entry = ledger.setdefault(item["id"], {"status": item["status"], "count": 0,
                                               "rule": item["rule"], "rows": []})
        entry["count"] += 1
        if len(entry["rows"]) < 3:
            entry["rows"].append({"rule": row["rule"], "src": row["src"][:120],
                                  "dest": row["dest"][:120],
                                  "exception": row.get("exception", "")})
    for item in items:
        entry = ledger.get(item["id"])
        count = entry["count"] if entry else 0
        if count == 0:
            if item.get("optional"):
                ledger[item["id"]] = {"status": item["status"], "count": 0,
                                      "rule": item["rule"], "note": "not present this round"}
            else:
                errors.append(f"{item['id']}: policy entry matched no row this round; "
                              "a stale or fabricated review entry is not evidence")
            continue
        if item["status"] != "REVIEWED_SAFE":
            errors.append(f"{item['id']}: {count} finding(s) are {item['status']} - "
                          + _text(item.get("missing_evidence", item.get("rationale"))))
            continue
        _verify_requirements(item, [row for row in rows if _matches(item, row)],
                             manifest, pair_rows, reports, errors)
    if unmatched:
        sample = "; ".join(f"{row['rule']} {row['dest'][:60]}" for row in unmatched[:5])
        errors.append(f"{len(unmatched)} finding(s) are not covered by any review entry "
                      f"(fail closed): {sample}")
    for item_id, entry in sorted(ledger.items()):
        entry["status"] = entry["status"]
    return ledger, errors


def parse_drc(details_text, summary_total):
    """Parse report_drc details into ({rule: {severity, count, instances}}, errors).

    Violation text is not always an instance: RTSTAT-10 prints net names,
    PDCN-1569 prints a quoted LUT pin plus its cell, DPIP-2/DPOP-3/DPOP-4 print
    `DSP <path>` and REQP-1935 prints `BRAM (<path>)`.  A single `u_*` regex
    therefore found nothing on whole rules, and an empty instance list used to mean
    "nothing outside the reviewed instances", i.e. an unparseable detail block
    looked safe.  Owners now come from quoted objects, from `<keyword> <path>` and
    from any 3+-level hierarchical path, and a block that yields no owner at all is
    reported (see review_drc) instead of passing.
    """
    errors = []
    blocks = re.findall(r'^([A-Z]+-\d+)#(\d+)[ \t]+([A-Za-z][A-Za-z ]*?)[ \t]*$',
                        details_text, re.M)
    if not blocks:
        if summary_total == 0:
            return {}, []
        raise ValueError("report_drc declares violations but has no 'Rule#N Severity' "
                         "detail blocks")
    parsed = {}
    positions = [(m.start(), m.group(1), m.group(3).strip()) for m in
                 re.finditer(r'^([A-Z]+-\d+)#(\d+)[ \t]+([A-Za-z][A-Za-z ]*?)[ \t]*$',
                             details_text, re.M)]
    for index, (start, rule, severity) in enumerate(positions):
        end = positions[index + 1][0] if index + 1 < len(positions) else len(details_text)
        body = details_text[start:end]
        entry = parsed.setdefault(rule, {"severity": severity, "count": 0,
                                         "instances": [], "owners_unparsed": 0})
        if entry["severity"].lower() != severity.lower():
            errors.append(f"{rule}: mixed severities {entry['severity']!r} and "
                          f"{severity!r} in one report")
        entry["count"] += 1
        found = drc_violation_owners(body)
        if not found:
            entry["owners_unparsed"] += 1
        for name in found:
            if len(entry["instances"]) < 200:
                entry["instances"].append(name)
    if sum(entry["count"] for entry in parsed.values()) != summary_total:
        raise ValueError(f"report_drc detail blocks sum to "
                         f"{sum(e['count'] for e in parsed.values())}, header declares "
                         f"{summary_total}")
    return parsed, errors


# `Net 'a/b/c[3]'`, `pin u_x/y/Z`, `BRAM (u_x/y/mem_reg_0)`, `DSP u_x/y/acc`.
_DRC_QUOTED = re.compile(r"'([^']+)")
_DRC_KEYWORD = re.compile(
    r"\b(?:net|nets|Net|pin|Pin|cell|Cell|instance|Instance|DSP|BRAM|RAMB\d*E?\d*)"
    r"[ \t]*\(?([A-Za-z_][\w./\[\]:-]*)")
# A hierarchical path only counts as an owner with at least two separators; that is
# what separates `u_dma_top/u_fifo/x` from a sentence containing one slash.
_DRC_HIER = re.compile(r"\b([A-Za-z_][\w]*(?:/[\w\[\]:-]+){2,})")
_DRC_STOPWORDS = {"none", "the", "and", "or", "is", "of", "in", "to"}


def drc_violation_owners(body: str) -> list:
    """Every object path a report_drc violation block names, de-duplicated."""
    found = []
    for pattern in (_DRC_KEYWORD, _DRC_QUOTED, _DRC_HIER):
        for match in pattern.finditer(body):
            name = match.group(1).strip().rstrip('.,()')
            if not name or name.lower() in _DRC_STOPWORDS:
                continue
            if name not in found:
                found.append(name)
    return found


def review_drc(parsed, items):
    """Layer B for DRC: every rule needs one named entry, severities must agree."""
    errors = []
    ledger = {}
    for rule, data in sorted(parsed.items()):
        hits = [item for item in items if _text(item.get("rule")) == rule]
        if not hits:
            errors.append(f"DRC {rule} ({data['severity']}, {data['count']} violation(s)) "
                          "has no review entry")
            continue
        if len(hits) > 1:
            errors.append(f"DRC {rule} has {len(hits)} review entries; only one is allowed")
            continue
        item = hits[0]
        expected = _text(item.get("severity"))
        if expected and expected.lower() != data["severity"].lower():
            errors.append(f"DRC {rule} severity is {data['severity']!r}, the review "
                          f"entry documents {expected!r}")
        if item["status"] != "REVIEWED_SAFE":
            errors.append(f"DRC {rule}: {data['count']} violation(s) are "
                          f"{item['status']} - "
                          + _text(item.get("missing_evidence", item.get("rationale"))))
            ledger[rule] = {"status": item["status"], "count": data["count"],
                            "severity": data["severity"]}
            continue
        prefixes = item.get("instance_prefixes") or []
        if data.get("owners_unparsed"):
            errors.append(f"DRC {rule}: {data['owners_unparsed']} violation block(s) "
                          "name no net, pin or cell this parser can locate; an entry "
                          "that cannot see the object cannot review it either")
        if prefixes and not data["instances"]:
            errors.append(f"DRC {rule}: the review entry allows {sorted(prefixes)} but "
                          "the report names no object at all; an empty match against an "
                          "allow-list is not coverage, it means the detail block was "
                          "never understood")
        outside = sorted({name for name in data["instances"]
                          if not any(name.startswith(p) for p in prefixes)})
        if prefixes and outside:
            errors.append(f"DRC {rule}: {len(outside)} violation(s) fall outside the "
                          f"reviewed instances, e.g. {outside[0]}")
        distinct = len(set(data["instances"]))
        minimum = int(item.get("min_instances", 0))
        maximum = item.get("max_instances")
        if minimum and distinct < minimum:
            errors.append(f"DRC {rule}: the review entry was written against at least "
                          f"{minimum} named objects, the report names {distinct}")
        if maximum is not None and data["count"] > int(maximum):
            errors.append(f"DRC {rule}: {data['count']} violation(s) exceed the "
                          f"{maximum} this entry was reviewed against; the finding grew, "
                          "so it must be re-reviewed instead of quietly re-counted")
        ledger[rule] = {"status": item["status"], "count": data["count"],
                        "severity": data["severity"],
                        "instances_reviewed": distinct}
    for item in items:
        if _text(item.get("rule")) not in parsed:
            if item.get("optional"):
                ledger[item["id"]] = {"status": item["status"], "count": 0,
                                      "note": "not present this round"}
                continue
            errors.append(f"{item['id']}: DRC review entry for {_text(item.get('rule'))} "
                          "matched no violation this round")
    return ledger, errors


def review_io(io_items, manifest, reports=None):
    """Per-port asynchronous IO review, driven by this round's coverage manifest.

    The manifest (not check_timing) is the driver, because a named exception
    removes its port from the HIGH list.  Two directions are checked:

    * every manifest item tagged class == io_exception must be claimed by exactly
      one policy entry, otherwise a new false path someone added is unreviewed;
    * every policy entry must still find its object lists non-empty and not
      ignored, or it is a stale claim.

    Entries that declare the same `pair_group` succeed or fail together: a DDC
    clock reviewed while its data line is not, or one pad of a TMDS differential
    pair excepted while the other is not, is not a reviewed interface.  The failure
    of one member is therefore copied to every member of its group.
    """
    errors = []
    ledger = {}
    claimed = set()
    per_item = {}
    groups = {}
    for item in io_items:
        item_id = item["id"]
        group = _text(item.get("pair_group"))
        if group:
            groups.setdefault(group, []).append(item_id)
        manifest_id = _text(item.get("manifest_id")) or _text(item.get("id"))
        record = manifest.get("items", {}).get(manifest_id)
        if record is not None:
            if manifest_id in claimed:
                per_item.setdefault(item_id, []).append(
                    f"manifest item {manifest_id} is claimed by more than one review entry")
            claimed.add(manifest_id)
        if item["status"] != "REVIEWED_SAFE":
            per_item.setdefault(item_id, []).append(
                f"io {item_id} ({_text(item.get('port'))}) is {item['status']} - "
                + _text(item.get("missing_evidence", item.get("rationale"))))
            ledger[item_id] = {"status": item["status"], "port": item.get("port"),
                               "count": 1 if record else 0, "pair_group": group}
            continue
        if record is None:
            per_item.setdefault(item_id, []).append(
                f"io {item_id}: named exception {manifest_id} is absent from this "
                "round's coverage manifest; the exception was never written, or the "
                "port no longer exists")
            continue
        local = []
        _verify_requirements(item, [], manifest, {}, reports or {}, local)
        if local:
            per_item.setdefault(item_id, []).extend(local)
            continue
        ledger[item_id] = {"status": item["status"], "port": item.get("port"),
                           "count": 1, "objects": record.get("from_objects"),
                           "exception": record.get("exception"), "pair_group": group}
    for group, members in sorted(groups.items()):
        failed = [m for m in members if m in per_item]
        if not failed:
            continue
        for member in members:
            if member not in per_item:
                ledger.pop(member, None)
                per_item.setdefault(member, []).append(
                    f"io {member}: pair_group {group} fails as a pair because "
                    f"{', '.join(sorted(failed))} is not reviewed; half of a paired "
                    "interface (DDC clock without data, one half of a differential pad) "
                    "is not an reviewed interface")
    for item_id in sorted(per_item):
        errors.extend(f"io {message}" if not message.startswith("io ") else message
                      for message in per_item[item_id])
    for name, record in sorted(manifest.get("items", {}).items()):
        if isinstance(record, dict) and record.get("class") == "io_exception" \
                and name not in claimed:
            errors.append(f"named IO exception {name} exists in this design but no "
                          "review entry claims it; every async pad exception must be "
                          "itemised in sc7f0_cdc_review.json io_items")
    return ledger, errors


def review_manifest_coverage(items_by_policy, manifest):
    """Every constraint the hook measured must be claimed by some policy entry."""
    errors = []
    claimed = set()
    for items in items_by_policy:
        for item in items:
            for requirement in item.get("requires", []):
                if requirement.get("kind") in ("named_constraint", "manifest_metric"):
                    claimed.add(_text(requirement.get("id")))
    for name, record in sorted(manifest.get("items", {}).items()):
        if isinstance(record, dict) and record.get("review_required") and name not in claimed:
            errors.append(f"coverage manifest item {name} is not claimed by any review "
                          "entry (an unreviewed timing exception)")
    return errors


def parse_clock_interaction(text):
    """Return {(from_clock, to_clock): row} from report_clock_interaction output."""
    rows = {}
    for line in text.splitlines():
        tokens = re.split(r"\s{2,}", line.strip())
        if len(tokens) < 4 or not line.strip() or set(line.strip()) <= {"-", " "}:
            continue
        frm, to = tokens[0], tokens[1]
        if not frm or not to or frm.startswith(("From Clock", "-----")):
            continue
        classification = tokens[-2]
        constraints = tokens[-1]
        if classification in ("Clean", "Ignored", "Timed") or "Clock" in classification \
                or classification in ("No Common Clock",):
            pass
        elif len(tokens) < 8:
            continue
        floats = [t for t in tokens[2:-2] if re.fullmatch(r"-?\d+\.\d+", t)]
        ints = [int(t) for t in tokens[2:-2] if re.fullmatch(r"\d+", t)]
        rows[(frm, to)] = {"classification": classification, "constraints": constraints,
                           "wns": floats[0] if floats else None,
                           "whs": floats[4] if len(floats) > 4 else None,
                           "endpoints": ints[1] if len(ints) > 1 else 0}
    return rows


def methodology_clock_pairs(text):
    """Extract the clock pairs TIMING-6/TIMING-7 name in report_methodology details."""
    pairs = []
    for rule, _index, severity, body in re.findall(
            r'^(TIMING-\d+)#(\d+)[ \t]+([A-Za-z][A-Za-z ]*?)\n(.*?)(?=^[A-Z]+-\d+#|\Z)',
            text, re.M | re.S):
        for match in re.finditer(r'The clocks (\S+) and (\S+) are', body):
            pairs.append({"rule": rule, "severity": severity.strip(),
                          "clocks": (match.group(1), match.group(2))})
    return pairs


def review_methodology_clock_pairs(pairs, items, pair_rows, manifest, reports,
                                   layer_a_clean):
    """Classify TIMING-6/7 findings as a named, evidence-backed clock-pair pair.

    A finding is only reclassified when the pair is declared in the policy, the
    policy entry is REVIEWED_SAFE, its own requirements verify against this
    round's reports, and Layer A has no critical CDC / uncovered endpoint left.
    Anything else keeps the Layer A failure, so this is not a silent removal.
    """
    errors = []
    classified = []
    ledger = {}
    for pair in pairs:
        frm, to = pair["clocks"]
        hits = [item for item in items
                if set(_text(c) for c in item.get("clocks", [])) == {frm, to}]
        label = f"{pair['rule']} {frm}<->{to}"
        if not hits:
            errors.append(f"{label}: clock pair is not declared in "
                          "sc7f0_clock_pair_review.json; an unknown asynchronous pair "
                          "is never accepted by default")
            continue
        if len(hits) > 1:
            errors.append(f"{label}: {len(hits)} policy entries describe the same pair")
            continue
        item = hits[0]
        if item["status"] != "REVIEWED_SAFE":
            errors.append(f"{label}: {item['status']} - "
                          + _text(item.get("missing_evidence", item.get("rationale"))))
            ledger[item["id"]] = {"status": item["status"], "count": 1}
            continue
        if not layer_a_clean:
            errors.append(f"{label}: cannot be classified as reviewed methodology while "
                          "Layer A still has a critical CDC or uncovered-endpoint "
                          "finding; the pair is not independently clean")
            continue
        local = []
        _verify_requirements(item, [], manifest, pair_rows, reports, local)
        # Both directions must be present in the interaction table, otherwise one
        # half of the crossing was never examined.
        for a, b in ((frm, to), (to, frm)):
            if (a, b) not in pair_rows:
                local.append(f"{item['id']}: report_clock_interaction has no {a} -> {b} "
                             "row; both directions of an independent pair must be shown")
        if local:
            errors.append(f"{label}: claimed reviewed but " + "; ".join(local))
            continue
        ledger[item["id"]] = {"status": item["status"],
                              "count": ledger.get(item["id"], {}).get("count", 0) + 1}
        classified.append({"rule": pair["rule"], "clocks": [frm, to],
                           "policy_id": item["id"]})
    return classified, errors, ledger
