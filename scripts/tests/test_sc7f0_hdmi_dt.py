#!/usr/bin/env python3
"""Regression for the DTS/XCI consistency check (requires existing DTG output)."""
import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
XCI = ROOT / "build/qpcie_zu4ev_hdmi_proj/qpcie_zu4ev_card.srcs/sources_1/ip"


class HDMIConsistencyTest(unittest.TestCase):
    def check_parameters(self, mutation=None, disabled=False):
        with tempfile.TemporaryDirectory(prefix="sc7f0-dt-test-", dir="/tmp/opencode") as temp:
            xci = Path(temp) / "ip"
            for module in ("vid_phy_controller_0", "v_hdmi_rx_ss_0"):
                (xci / module).mkdir(parents=True)
                shutil.copy2(XCI / module / f"{module}.xci", xci / module)
            if mutation:
                module, parameter, value = mutation
                path = xci / module / f"{module}.xci"
                data = json.loads(path.read_text())
                data["ip_inst"]["parameters"]["component_parameters"][parameter][0]["value"] = value
                path.write_text(json.dumps(data))
            command = [
                "python3", str(ROOT / "scripts/check_sc7f0_hdmi_dt.py"),
                "--xci-dir", str(xci), "--output-dir", str(Path(temp) / "dt"),
            ]
            if disabled:
                command.append("--disabled")
            return subprocess.run(command, text=True, capture_output=True)

    def test_matching_parameters(self):
        result = self.check_parameters()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("HDMI_DT_PASS", result.stdout)

    def test_wrong_rx_ppc_rejected(self):
        result = self.check_parameters(("v_hdmi_rx_ss_0", "C_INPUT_PIXELS_PER_CLOCK", "2"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("C_INPUT_PIXELS_PER_CLOCK", result.stderr)

    def test_wrong_phy_pll_rejected(self):
        result = self.check_parameters(("vid_phy_controller_0", "C_RX_PLL_SELECTION", "6"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("C_RX_PLL_SELECTION", result.stderr)

    def test_default_does_not_probe_hdmi(self):
        result = self.check_parameters(disabled=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("HDMI_DT_DISABLED_PASS", result.stdout)


if __name__ == "__main__":
    unittest.main()
