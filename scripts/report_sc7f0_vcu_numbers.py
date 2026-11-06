#!/usr/bin/env python3
"""Print the numbers the Todo 1.3 report needs from one build directory."""
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import check_sc7f0_vcu_delta as m

d = Path(sys.argv[1])
run = d / m.RUN_SUB
placed = m.placed_counts((run / (m.TOP + "_utilization_placed.rpt")).read_text())
clock_lines = []
text = (d / "timing_summary.rpt").read_text()
sec = text.split("| Clock Summary", 1)[1].split("| Intra Clock Table", 1)[0]
for line in sec.splitlines():
    f = " ".join(line.split()).split()
    if len(f) >= 5 and f[0] not in ("Clock",) and set(f[0]) != {"-"} and f[1].startswith("{"):
        try:
            clock_lines.append((f[0], float(f[3]), float(f[4])))
        except ValueError:
            continue
clocks = m.clock_summary(text)
skew = m.SKEW_ROW.findall((d / "bus-skew.rpt").read_text())
glob = (d / "qpcie_zu4ev_card.gen").glob("**/global_clock_ports.xdc")
buffers = {}
for name in ("BUFG_PS", "BUFGCE", "BUFG_GT", "MMCM", "PLL", "CARRY8", "F7 Mux", "F8 Mux",
             "SLICE", "LUT as Logic", "LUT as Memory"):
    match = re.search(r"^\|\s*" + re.escape(name) + r"\*?\s*\|\s*(\d+)\s*\|\s*\d+\s*\|"
                      r"\s*\d+\s*\|\s*(\d+)\s*\|\s*(\d+(?:\.\d+)?)\s*\|",
                      (run / (m.TOP + "_utilization_placed.rpt")).read_text(), re.M)
    if match:
        buffers[name] = (int(match[1]), int(match[2]), float(match[3]))
routed = m.routed_totals((d / "utilization_routed_hierarchical.rpt").read_text())
print(json.dumps(dict(
    directory=str(d),
    placed=placed, buffers=buffers, routed=routed,
    margins=m.design_margins(text),
    clocks={k: clocks[k] for k in sorted(clocks) if clocks[k]["WNS"]},
    clock_periods={n: (p, f) for n, p, f in clock_lines if n in
                   ("clk_pl_0", "clk_pl_1", "capture_clk_150m", "pl_clk_300m",
                    "pcie_user_clk", "pipe_clk", "sys_clk")},
    bus_skew_rows=len(skew), bus_skew_min=min(float(r[2]) for r in skew),
    personality=(d / "c2h-personality.rpt").read_text(),
), indent=2, sort_keys=True, default=str))
