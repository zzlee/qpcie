#!/usr/bin/env python3
"""Inventory exact CDC path deltas. Classification is NOT approval or a gate waiver."""
import argparse
from collections import Counter
import csv
import hashlib
import json
from pathlib import Path
import re

SUMMARY = re.compile(r"^(CDC-\d+)\s+(Info|Warning|Critical)\s+(\d+)\s")
DETAIL = re.compile(r"^\s*\d+\s+(CDC-\d+)\s+(Info|Warning|Critical)\s")
KEY = ("rule", "severity", "source_clock", "destination_clock", "source", "destination")


def parse_report(text):
    summary, rows = {}, []
    source_clock = destination_clock = None
    for line in text.splitlines():
        match = SUMMARY.match(line)
        if re.match(r'^CDC-\d+\b', line) and not match:
            raise ValueError('unsupported/malformed CDC summary severity')
        if match:
            if match[1] in summary:
                raise ValueError("duplicate CDC summary rule: " + match[1])
            summary[match[1]] = (match[2], int(match[3]))
        if line.startswith("Source Clock: "):
            source_clock = line.partition(": ")[2]
            destination_clock = None
        if line.startswith("Destination Clock: "):
            destination_clock = line.partition(": ")[2]
        match = DETAIL.match(line)
        if re.match(r'^\s*\d+\s+CDC-\d+\b', line) and not match:
            raise ValueError('unsupported/malformed CDC detail severity')
        if not match:
            continue
        if not source_clock or not destination_clock:
            raise ValueError("CDC detail without clock pair")
        fields = line.split()
        rows.append(dict(rule=match[1], severity=match[2], source_clock=source_clock,
                         destination_clock=destination_clock, source=fields[-2],
                         destination=fields[-1]))
    if not summary:
        raise ValueError("missing CDC summary")
    counts = Counter((row["rule"], row["severity"]) for row in rows)
    expected = Counter({(rule, severity): count for rule, (severity, count) in summary.items()})
    if counts != expected:
        raise ValueError("CDC detailed counts differ from summary")
    return summary, rows


def review_category(row):
    dest = row["destination"]
    if row["severity"] == "Critical":
        if re.search(r"/arststages_ff_reg\[0\]/PRE$", dest):
            return "async_reset_entry_REQUIRES_CONE_AND_RELEASE_REVIEW"
        if dest.startswith("u_hdmi_probe/u_pin_levels_cdc/"):
            return "diagnostic_probe_REQUIRES_SOURCE_AND_USE_REVIEW"
        return "UNCLASSIFIED_CRITICAL"
    if row["rule"] == "CDC-26":
        return "LUTRAM_REQUIRES_COLLISION_OWNERSHIP_REVIEW"
    if row["rule"] == "CDC-6":
        return "BUS_REQUIRES_COHERENCE_REVIEW"
    if row["rule"] == "CDC-15":
        return "CE_REQUIRES_HELD_DATA_OR_FIFO_OWNERSHIP_REVIEW"
    return "information_only"


def inventory(current, baseline):
    summary, rows = parse_report(current)
    base_summary, base_rows = parse_report(baseline)
    remaining = Counter(tuple(row[key] for key in KEY) for row in base_rows)
    for row in rows:
        key = tuple(row[field] for field in KEY)
        row["exact_baseline_match"] = bool(remaining[key])
        if remaining[key]:
            remaining[key] -= 1
        row["review_category"] = review_category(row)
        row["approved"] = False  # Even a baseline match is not automatic approval.
    result = dict(review_only=True, deployment_authorized_by_this_report=False,
                  current_summary={k: {"severity": v[0], "count": v[1]} for k, v in summary.items()},
                  baseline_summary={k: {"severity": v[0], "count": v[1]} for k, v in base_summary.items()},
                  current_paths=len(rows), exact_baseline_matches=sum(r["exact_baseline_match"] for r in rows),
                  removed_baseline_paths=sum(remaining.values()),
                  critical_categories=dict(Counter(r["review_category"] for r in rows if r["severity"] == "Critical")),
                  approval_policy="none: exact clock/path inventory only; no normalization, blanket waiver or gate changes")
    return result, rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--current", required=True, type=Path)
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    if args.out.exists():
        parser.error("refusing to overwrite audit directory")
    result, rows = inventory(args.current.read_text(), args.baseline.read_text())
    result["input_sha256"] = {str(p): hashlib.sha256(p.read_bytes()).hexdigest()
                              for p in (args.current, args.baseline)}
    args.out.mkdir(parents=True)
    with (args.out / "paths.csv").open("w", newline="") as output:
        writer = csv.DictWriter(output, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    (args.out / "review.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    print("CDC_INVENTORY_COMPLETE: NOT signoff, NOT permission to export XSA/deploy")


if __name__ == "__main__":
    main()
