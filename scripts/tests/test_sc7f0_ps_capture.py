"""Userspace V4L2 API model tests; explicitly not real capture/DMA validation."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class PSCaptureAppTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cc = shutil.which("cc")
        if not cc:
            raise unittest.SkipTest("native C compiler unavailable")
        cls.temp = tempfile.TemporaryDirectory()
        cls.binary = Path(cls.temp.name) / "capture-model"
        cmd = [cc, "-O2", "-std=c11", "-Wall", "-Wextra", "-Werror",
               str(ROOT / "test_app/sc7f0_ps_capture.c"),
               str(ROOT / "tb/sc7f0_ps_capture_model.c"), "-o", str(cls.binary)]
        cmd += ["-Wl,--wrap=" + n for n in
                ("open", "close", "ioctl", "mmap", "munmap", "poll")]
        subprocess.run(cmd, check=True, capture_output=True, text=True)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def capture(self, fmt="NV12", multi=False, fault=None, soe=False):
        env = os.environ.copy()
        env.pop("CAPTURE_MODEL_FAULT", None)
        env.pop("CAPTURE_MODEL_MPLANE", None)
        env.pop("CAPTURE_MODEL_SOE", None)
        if soe:
            env["CAPTURE_MODEL_SOE"] = "1"
        if multi:
            env["CAPTURE_MODEL_MPLANE"] = "1"
        if fault:
            env["CAPTURE_MODEL_FAULT"] = fault
        output = Path(self.temp.name) / "frame.nv12"
        output.unlink(missing_ok=True)
        result = subprocess.run([str(self.binary), "/dev/v4l2-model", fmt,
                                 "64", "64", "3", str(output)], env=env,
                                capture_output=True, text=True, timeout=5)
        return result, output

    def test_single_planar_nv12(self):
        r, p = self.capture()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(p.stat().st_size, 64 * 64 * 3 // 2)
        self.assertIn("dmabuf_exports=4", r.stdout)
        self.assertIn("timestamp_source=EOF", r.stdout)
        self.assertIn("vcu_import_verified=false", r.stdout)

    def test_mplane_contiguous_nv12(self):
        r, _ = self.capture(multi=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("dmabuf_exports=4", r.stdout)

    def test_mplane_nv12m(self):
        r, p = self.capture("NV12M", multi=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(p.stat().st_size, 64 * 64 * 3 // 2)
        self.assertIn("dmabuf_exports=8", r.stdout)

    def test_hardware_start_timestamp_flags(self):
        r, _ = self.capture(multi=True, soe=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("timestamp_source=SOE", r.stdout)

    def test_errors_cannot_report_pass(self):
        for multi in (False, True):
            for fault in ("format", "export", "timeout", "sequence", "timestamp",
                          "source", "error", "short", "streamoff"):
                with self.subTest(multi=multi, fault=fault):
                    r, p = self.capture(multi=multi, fault=fault)
                    self.assertNotEqual(r.returncode, 0)
                    self.assertNotIn("CAPTURE_PASS", r.stdout)
                    self.assertFalse(p.exists())

    def test_invalid_args_do_not_open_device(self):
        for args in (("--help",), (), ("/dev/v4l2-model", "NV12", "63", "64", "3")):
            with self.subTest(args=args):
                r = subprocess.run([str(self.binary), *args], capture_output=True,
                                   text=True, timeout=5)
                self.assertEqual(r.returncode, 0 if args == ("--help",) else 2)


if __name__ == "__main__":
    unittest.main()
