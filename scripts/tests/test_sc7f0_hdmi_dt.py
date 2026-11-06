#!/usr/bin/env python3
"""Regression for the DTS/XCI consistency check (requires existing DTG output)."""
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
XCI = Path(os.environ.get("SC7F0_TEST_XCI_DIR", ROOT / "build/dual-video-26102802-r4/qpcie_zu4ev_card.srcs/sources_1/ip"))


class HDMIConsistencyTest(unittest.TestCase):
    def check_parameters(self, mutation=None, disabled=False, capture=False):
        with tempfile.TemporaryDirectory(prefix="sc7f0-dt-test-") as temp:
            xci = Path(temp) / "ip"
            modules = ["vid_phy_controller_0", "v_hdmi_rx_ss_0"]
            if capture:
                modules += ["sc7f0_frmbuf_wr", "sc7f0_vpss_csc", "axi_crossbar_hdmi", "sc7f0_capture_width"]
            for module in modules:
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
            for env, option in [("SC7F0_TEST_GENERATED_DT", "--generated-dt"), ("SC7F0_TEST_DTC", "--dtc")]:
                if os.environ.get(env):
                    command += [option, os.environ[env]]
            if capture:
                command.append("--capture")
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

    def test_capture_graph_matches_ip(self):
        result = self.check_parameters(capture=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("SC7F0_CAPTURE_DT_PASS", result.stdout)

    def test_capture_forced_fb128_rejected(self):
        result = self.check_parameters(("sc7f0_frmbuf_wr", "AXIMM_DATA_WIDTH", "128"), capture=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("native width", result.stderr)

    def test_capture_wrong_ps_width_rejected(self):
        result = self.check_parameters(("sc7f0_capture_width", "MI_DATA_WIDTH", "256"), capture=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("width converter", result.stderr)

    def test_capture_wrong_memory_format_rejected(self):
        result = self.check_parameters(("sc7f0_frmbuf_wr", "HAS_Y_UV8_420", "0"), capture=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("NV12 enabled", result.stderr)

    def test_capture_wrong_control_aperture_rejected(self):
        result = self.check_parameters(("axi_crossbar_hdmi", "M04_A00_BASE_ADDR", "0x00000000B0080000"), capture=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("control base", result.stderr)

    def test_default_does_not_probe_hdmi(self):
        result = self.check_parameters(disabled=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("HDMI_DT_DISABLED_PASS", result.stdout)


if __name__ == "__main__":
    unittest.main()
