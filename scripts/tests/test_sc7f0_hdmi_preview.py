import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch, Mock

spec = importlib.util.spec_from_file_location(
    "preview", Path(__file__).resolve().parents[1] / "sc7f0_hdmi_preview.py")
preview = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preview)

RGB = "Status: Signal Locked\nResolution: 3840x2160p\nColor: fmt=0x00800200 mbus=0x100e\n"


class PreviewTests(unittest.TestCase):
    def test_rgb(self):
        self.assertEqual(preview.locked_mode(RGB), (3840, 2160, "RGB"))

    def test_yuv444_to_nv12(self):
        self.assertEqual(preview.locked_mode(RGB.replace("00800200", "01800200")),
                         (3840, 2160, "NV12"))

    def test_fail_closed(self):
        for text in ("Status: No Signal", RGB.replace("2160p", "2160i"),
                     RGB.replace("00800200", "02800200"),
                     RGB.replace("00800200", "03800200"),
                     RGB.replace("00800200", "00a00200"),
                     "Status: Signal Locked\nResolution: 3840x2160p\n"):
            with self.subTest(text=text), self.assertRaises(ValueError):
                preview.locked_mode(text)

    @patch.object(preview.Path, "read_text", return_value=RGB)
    @patch.object(preview.subprocess, "Popen")
    def test_force_hdmi_no_pacer(self, popen, read_text):
        popen.return_value.wait.return_value = 0
        with patch("sys.argv", ["preview", "--sink", "fake", "--frames", "120", "--timeout", "15"]):
            self.assertEqual(preview.main(), 0)
        command = popen.call_args.args[0]
        self.assertIn("num-buffers=120", command)
        self.assertIn("video/x-raw,format=RGB,width=3840,height=2160,framerate=60/1", command)
        self.assertIn("extra-controls=c,qpcie_video_input_source=2,qpcie_frame_pacer_enable=0", command)
        popen.return_value.wait.assert_called_once_with(timeout=15)

    @patch.object(preview.Path, "read_text", return_value=RGB)
    @patch.object(preview.subprocess, "Popen")
    def test_native_nv12_fullscreen_no_software_transform(self, popen, read_text):
        popen.return_value.wait.return_value = 0
        with patch("sys.argv", ["preview", "--sink", "wayland", "--format", "NV12",
                                "--native-size", "--fullscreen", "--frames", "300"]):
            self.assertEqual(preview.main(), 0)
        command = popen.call_args.args[0]
        self.assertIn("video/x-raw,format=NV12,width=3840,height=2160,framerate=60/1", command)
        self.assertIn("video-sink=waylandsink fullscreen=true", command)
        self.assertNotIn("videoconvert", command)
        self.assertNotIn("videoscale", command)

    def test_fullscreen_requires_wayland(self):
        with patch("sys.argv", ["preview", "--sink", "fake", "--fullscreen"]):
            with self.assertRaises(SystemExit) as error:
                preview.main()
        self.assertEqual(error.exception.code, 2)

    @patch.object(preview.Path, "read_text", return_value=RGB)
    @patch.object(preview.subprocess, "Popen")
    @patch.object(preview.os, "killpg")
    def test_timeout_not_success(self, killpg, popen, read_text):
        proc = popen.return_value
        proc.wait.side_effect = [subprocess.TimeoutExpired("gst", 1), 0]
        proc.poll.return_value = None
        with patch("sys.argv", ["preview", "--sink", "fake", "--timeout", "1"]):
            self.assertEqual(preview.main(), 124)
        killpg.assert_called_once_with(proc.pid, preview.signal.SIGINT)


if __name__ == "__main__":
    unittest.main()
