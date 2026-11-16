#!/usr/bin/env python3
"""Negative controls for scripts/tb_sc7f0_pcie_ext_tag_enable.sv.

Each mutant is a copy of rtl/sc7f0_pcie_ext_tag_enable.v with one real bug put
back in.  The fixture must reject every one of them; if a mutant passes, the
fixture is not covering the thing it claims to cover.  Nothing here modifies the
repository source - the mutants live in a scratch directory.
"""
import os
import subprocess
import sys

OUT = "/mnt/data-root/home/zzlee/sc7f0-vivado-builds/rgb-compositor-int-26111317-20261113T082428Z"
REPO = "/home/zzlee/qpcie"
WORK = os.path.join(OUT, "tmp", "mutcheck3")
os.makedirs(WORK, exist_ok=True)
SRC = os.path.join(REPO, "rtl", "sc7f0_pcie_ext_tag_enable.v")

MUTANTS = {
    # Device Control bit 4 is Relaxed Ordering, bit 8 is Extended Tag Field
    # Enable (/usr/include/linux/pci_regs.h).
    "m1_devctl_bit4": [
        ("ext_tag_enable <= rd_shift[8];", "ext_tag_enable <= rd_shift[4]; // MUTANT"),
    ],
    # capability pointer is the LOW byte of doubleword 0x0D; bits [15:8] is byte
    # 0x35.  All three uses in the PH_PTR branch must change together.
    "m2_pointer_high_byte": [
        ("if (cfg_mgmt_read_data[7:0] == 8'd0) begin",
         "if (cfg_mgmt_read_data[15:8] == 8'd0) begin"),
        ("cap_dw   <= {2'd0, cfg_mgmt_read_data[7:0]}",
         "cap_dw   <= {2'd0, cfg_mgmt_read_data[15:8]}"),
        ("req_dw   <= {2'd0, cfg_mgmt_read_data[7:0]}",
         "req_dw   <= {2'd0, cfg_mgmt_read_data[15:8]}"),
    ],
    # cfg_mgmt_addr is a doubleword index: using the byte address 0x34 reads the
    # wrong doubleword entirely.
    "m3_byte_address": [
        ("localparam [9:0] DW_CAP_PTR = 10'h00D;",
         "localparam [9:0] DW_CAP_PTR = 10'h034; // MUTANT"),
    ],
    # Device Capability support bit ignored: the block would authorise a
    # function that cannot use tags above 31.
    "m4_ignore_devcap": [
        ("if (!rd_shift[5]) begin", "if (1'b0) begin // MUTANT"),
    ],
    # no bounded walk: a looping capability list would be trusted eventually.
    "m5_unbounded_walk": [
        ("end else if (steps >= WALK_BOUND) begin", "end else if (1'b0) begin // MUTANT"),
    ],
}


def run(cmd, log):
    with open(log, "w") as f:
        return subprocess.call(cmd, shell=True, stdout=f, stderr=subprocess.STDOUT, cwd=WORK)


def main():
    env = dict(os.environ, TMPDIR=os.path.join(OUT, "tmp"))
    bad = []
    for name, edits in MUTANTS.items():
        text = open(SRC).read()
        for old, new in edits:
            if old not in text:
                print("MUTANT_PREP_FAIL %s: pattern not found: %s" % (name, old))
                bad.append(name)
                break
            text = text.replace(old, new)
        else:
            path = os.path.join(WORK, name + ".v")
            open(path, "w").write(text)
            run("/opt/Xilinx/Vivado/2023.2/bin/xvlog -sv %s %s"
                % (os.path.join(REPO, "scripts/tb_sc7f0_pcie_ext_tag_enable.sv"), path),
                os.path.join(WORK, name + ".xvlog"))
            run("/opt/Xilinx/Vivado/2023.2/bin/xelab -debug typical "
                "tb_sc7f0_pcie_ext_tag_enable -s snap_%s" % name,
                os.path.join(WORK, name + ".xelab"))
            run("/opt/Xilinx/Vivado/2023.2/bin/xsim snap_%s -R" % name,
                os.path.join(WORK, name + ".log"))
            log = open(os.path.join(WORK, name + ".log")).read()
            fails = [l for l in log.splitlines() if l.startswith("FIXTURE_FAIL")]
            passed = "FIXTURE_PASS" in log
            verdict = "CAUGHT" if (not passed and fails) else "NOT_CAUGHT"
            print("%s %-22s %s (%d failing checks)" % (verdict, name, verdict, len(fails)))
            for f in fails[:3]:
                print("      " + f)
            if verdict != "CAUGHT":
                bad.append(name)
    print("NEGATIVE_CONTROL_" + ("OK" if not bad else "INCOMPLETE:" + ",".join(bad)))
    return 1 if bad else 0


sys.exit(main())
