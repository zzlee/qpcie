#!/usr/bin/env python3
"""scripts/check_sc7f0_rx_upsize_seam_static.py

READ-ONLY static guard for tb/fixtures/sc7f0_rx_upsize_root_seam_fixture.v.

The fixture is only worth anything while it is the product.  This script compares
every non-comment line inside each fixture's VERBATIM markers against the CURRENT
rtl/zu4ev_pcie_card_top.v, in order, and fails if:

  * any verbatim line is missing from the root, or is present only in a different
    order (the seam was re-wired and the test is now testing something else);
  * the repaired variant no longer contains the ready assignment, or the root no
    longer contains it (the repair was reverted);
  * the round H negative variant is not exactly the repaired variant minus that
    one assignment (the baseline was weakened into a straw man).

Second job (added with the pixel-group-order fix): the ORACLE must still be the
official one.  The first version of this regression derived its expected quad
from the DUT's own concatenation, so it could not fail while the adapter rotated
every pixel group; the guard below pins the UG934 reading (LSB group = earliest /
left-most pixel) in tb/sc7f0_rx_upsize_official_oracle.v and rejects the
compensating high-group-first spelling anywhere in the oracle or the testbench.

It writes nothing.  Exit 0 = fixture still equals the product AND the oracle still
reads the UG934 low group first; non-zero = the seam test must not be trusted.
"""
import re
import sys

ASSIGN = "assign rx_ss_video_up_tready = 1'b1;"
BEGIN = "// ---- BEGIN VERBATIM"
END = "// ---- END VERBATIM"

# UG934 "Encoding Multiple Pixels": LSB group = left-most pixel / earliest in
# time, so the 96-bit published beat must be read pixel0=[23:0] pixel1=[47:24]
# pixel2=[71:48] pixel3=[95:72].
UG934_RANGES = [
    "got4[0] = o_tdata[23:0];",
    "got4[1] = o_tdata[47:24];",
    "got4[2] = o_tdata[71:48];",
    "got4[3] = o_tdata[95:72];",
]
# The pre-fix reading (pixel 2 in the low slot, i.e. the DUT's own concatenation
# order).  If it comes back in EXECUTABLE code the test is once again scoring the
# DUT against itself; comments that merely describe the historical defect are fine.
COMPENSATING = re.compile(r"(got4\[0\]|quad\[0\])\s*=\s*\w+\[71:48\]")


def compensating_hits(path):
    hits = []
    for n, ln in enumerate(open(path).read().splitlines(), 1):
        s = ln.strip()
        if s.startswith("//") or s.startswith("*") or s.startswith("/*"):
            continue
        if COMPENSATING.search(s):
            hits.append("%s:%d %s" % (path, n, s))
    return hits


def verbatim(lines, keep_comments=False):
    out, inside = [], False
    for ln in lines:
        if BEGIN in ln:
            inside = True
            continue
        if END in ln:
            inside = False
            continue
        if not inside:
            continue
        if ln.strip() == "":
            continue
        if not keep_comments and ln.strip().startswith("//"):
            continue
        out.append(ln.rstrip("\n"))
    return out


def blocks(lines):
    """Split the fixture into per-module verbatim blocks."""
    return verbatim(lines), None


def sub_file(lines, marker):
    """Return ONLY the body of the module whose declaration contains `marker`
    (module line up to and including its endmodule), so one fixture file can hold
    both the repaired and the baseline variant without their blocks merging."""
    start = None
    for i, ln in enumerate(lines):
        if ln.startswith("module ") and marker in ln:
            start = i
            break
    if start is None:
        return None
    for j in range(start + 1, len(lines)):
        if lines[j].strip().startswith("endmodule"):
            return lines[start:j + 1]
    return lines[start:]


def check_oracle(oracle_path, tb_path):
    """The pixel-group oracle must be the published UG934 rule, not the DUT's."""
    fails = []
    o = open(oracle_path).read()
    for want in UG934_RANGES:
        if want not in o:
            fails.append("oracle no longer asserts the UG934 range '%s' "
                         "(LSB group = earliest/left-most pixel)" % want)
    if COMPENSATING.search(o):
        hits = compensating_hits(oracle_path)
        if hits:
            fails.append("oracle reads the HIGH 48-bit group as pixel 0: that is the "
                         "DUT's own concatenation order, which cannot detect the swap "
                         "(%s)" % "; ".join(hits))
    if "UG934" not in o:
        fails.append("oracle lost its citation of the normative source (UG934)")
    tb = open(tb_path).read()
    if COMPENSATING.search(tb):
        hits = compensating_hits(tb_path)
        if hits:
            fails.append("testbench contains a high-group-first expectation (%s)"
                         % "; ".join(hits))
    if "sc7f0_rx_upsize_official_oracle" not in tb:
        fails.append("testbench no longer instantiates the official UG934 oracle")
    return fails


def main():
    root_path, fix_path = sys.argv[1], sys.argv[2]
    root = open(root_path).read().splitlines()
    fix = open(fix_path).read().splitlines()

    pos_src = sub_file(fix, "sc7f0_rx_upsize_root_seam_pos ")
    neg_src = sub_file(fix, "sc7f0_rx_upsize_root_seam_h ")
    fails = []
    if pos_src is None:
        fails.append("fixture is missing module sc7f0_rx_upsize_root_seam_pos")
    if neg_src is None:
        fails.append("fixture is missing module sc7f0_rx_upsize_root_seam_h")
    if fails:
        print("SEAM_STATIC_FAIL " + " ; ".join(fails))
        return 1

    pos = verbatim(pos_src)
    neg = verbatim(neg_src)

    # 1. every pos line must exist in the live root, in the same order
    i = 0
    matched = 0
    for want in pos:
        found = -1
        j = i
        while j < len(root):
            if root[j] == want:
                found = j
                break
            j += 1
        if found < 0:
            # tolerate a re-ordered root: report, do not silently pass
            if want in root:
                fails.append("verbatim line present but out of order: %s" % want.strip())
            else:
                fails.append("verbatim line absent from root: %s" % want.strip())
        else:
            matched += 1
            i = found + 1

    # 2. the repair must be present in both the fixture and the product
    if ASSIGN not in [l.strip() for l in pos]:
        fails.append("repaired fixture does not contain the ready assignment")
    if ASSIGN not in [l.strip() for l in root]:
        fails.append("rtl/zu4ev_pcie_card_top.v does not contain '%s' - the repair is "
                     "gone, so the positive fixture is a fiction" % ASSIGN)

    # 3. baseline == repaired minus exactly that assignment
    expect_neg = [l for l in pos if l.strip() != ASSIGN]
    if neg != expect_neg:
        fails.append("round H baseline is not 'repaired minus the assignment' "
                     "(%d lines vs expected %d)" % (len(neg), len(expect_neg)))
    if ASSIGN in [l.strip() for l in neg]:
        fails.append("round H baseline still drives the ready net; it is not a baseline")

    if len(sys.argv) > 4:
        fails.extend(check_oracle(sys.argv[3], sys.argv[4]))
    else:
        fails.append("oracle guard not exercised: pass the oracle and testbench paths")

    print("SEAM_STATIC root_lines=%d fixture_pos_lines=%d fixture_neg_lines=%d matched_in_order=%d"
          % (len(root), len(pos), len(neg), matched))
    for f in fails:
        print("SEAM_STATIC_DETAIL " + f)
    if fails:
        print("SEAM_STATIC_FAIL n=%d" % len(fails))
        return 1
    print("SEAM_STATIC_PASS pos_lines=%d neg_lines=%d assignment_present_in_root=1 "
          "oracle_ug934_low_group_first=1" % (len(pos), len(neg)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
