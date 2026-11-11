"""Source-personality checks; linked-cell/resource gates remain separate."""
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class C2HProfileTest(unittest.TestCase):
    def run_tb(self, top, sources):
        with tempfile.TemporaryDirectory(prefix="sc7f0-c2h-") as tmp:
            output = Path(tmp) / "test.vvp"
            subprocess.run(["iverilog", "-g2012", "-DSC7F0_C2H_ONLY",
                            "-s", top, "-o", str(output), *sources],
                           cwd=ROOT, check=True, capture_output=True, text=True)
            result = subprocess.run(["vvp", str(output)], cwd=ROOT,
                                    check=True, capture_output=True, text=True)
            self.assertNotRegex(result.stdout + result.stderr, r"FATAL|ERROR")
            return result.stdout

    def test_caps_advertise_only_supported_channels(self):
        self.assertIn("SC7F0_C2H_CAPS_PASS", self.run_tb(
            "sc7f0_c2h_caps_tb", ["rtl/axil_reg_space.v", "tb/sc7f0_c2h_caps_tb.sv"]))

    def test_disabled_windows_accept_both_aw_w_orders(self):
        self.assertIn("SC7F0_DISABLED_AXI_PASS", self.run_tb(
            "sc7f0_axil_disabled_tb", ["rtl/sc7f0_axil_disabled.v", "tb/sc7f0_axil_disabled_tb.sv"]))

    def test_production_removes_unused_instances(self):
        with tempfile.TemporaryDirectory(prefix="sc7f0-personality-") as tmp:
            for production in (False, True):
                output = Path(tmp) / "preprocessed.v"
                command = ["iverilog", "-g2012", "-E", "-o", str(output)]
                if production:
                    command += ["-DSC7F0_C2H_ONLY"]
                subprocess.run(command + ["rtl/zu4ev_pcie_card_top.v",
                                          "rtl/custom_pcie_dma_top.v"],
                               cwd=ROOT, check=True, capture_output=True, text=True)
                text = output.read_text()
                # Check instance identifiers, not comments or module declarations.
                for name in ("u_hdmi_tx_ss", "u_hdmi_tx_video_bridge", "u_hdmi_tx_audio_bridge",
                             "u_v_tpg", "u_audio_pattern_gen", "u_tpg_video_cdc",
                             "u_nv12_capture_engine_ch1", "u_nv12_capture_engine_ch2",
                             "u_nv12_capture_engine_ch3", "u_audio_h2c_fifo_ch1",
                             "u_audio_h2c_fifo_ch2", "u_audio_h2c_fifo_ch3",
                             "u_audio_stream_engine_ch1", "u_audio_stream_engine_ch2",
                             "u_audio_stream_engine_ch3"):
                    found = bool(re.search(r"\b" + name + r"\s*\(", text))
                    self.assertEqual(found, not production, name)
                for name in ("u_hdmi_rx_ss", "u_vid_phy_controller", "u_ps_capture",
                             "u_nv12_capture_engine", "u_audio_stream_engine_ch0",
                             "u_dualpath", "u_h2c_ps_ddr_writer"):
                    self.assertRegex(text, r"\b" + name + r"\s*\(")


if __name__ == "__main__":
    unittest.main()
