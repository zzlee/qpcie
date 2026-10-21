#!/usr/bin/env python3
"""Pure decoder/transport unit tests; fixtures are not hardware validation."""
import contextlib
import importlib.util
import io
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "it6663_dump", Path(__file__).resolve().parents[1] / "sc7f0_it6663_dump.py")
TOOL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TOOL)


def fixture(h_active=3840):
    raw = [0] * 19
    def reg(address, value):
        raw[address - 0x98] = value
    for addr, value in ((0x9B, 4400), (0x9D, h_active), (0xA2, 2250), (0xA4, 2160)):
        reg(addr, value & 255)
        reg(addr + 1, value >> 8)
    reg(0x9F, 88)
    reg(0xA0, 176)
    reg(0xA6, 10)
    reg(0xA7, 8)
    reg(0xAA, 0x60)
    result = {"timing_first": raw.copy(), "timing_second": raw.copy()}
    for prefix in ("before", "after"):
        for key, value in (("bank", 0), ("r13", 0x11), ("r14", 0xF8), ("r19", 0x80)):
            result[f"{prefix}_{key}"] = [value]
    return result


def response(data, status=0):
    return "\n".join(key + " " + " ".join(f"0x{x:02x}" for x in data[key] + [status]) for key in TOOL.FIELDS)


class DecoderTest(unittest.TestCase):
    def test_locked_geometry_but_no_rate_inference(self):
        report = TOOL.analyze_snapshot(fixture())
        self.assertTrue(report["timing_valid"])
        self.assertEqual(report["raw_timing"]["h_back_porch"], 296)
        self.assertIsNone(report["frame_rate_hz"])
        self.assertIsNone(report["pixel_clock_hz"])

    def test_does_not_substitute_active_width(self):
        report = TOOL.analyze_snapshot(fixture(3800))
        self.assertEqual(report["raw_timing"]["h_active"], 3800)
        self.assertEqual(report["raw_timing"]["h_back_porch"], 336)

    def test_no_signal_with_stale_4k_registers_is_invalid(self):
        data = fixture()
        for prefix in ("before", "after"):
            data[f"{prefix}_r13"] = [1]
            data[f"{prefix}_r14"] = [1]
            data[f"{prefix}_r19"] = [0x20]
        report = TOOL.analyze_snapshot(data)
        self.assertFalse(report["timing_valid"])
        report.update(host="unit-test", timestamp="unit-test")
        text = TOOL.format_report(report)
        self.assertIn("Timing valid (sampled lock + raw geometry): NO", text)
        self.assertNotIn("60Hz", text)
        self.assertNotIn("VIC 97", text)

    def test_each_lock_flag_required_on_both_sides(self):
        for prefix in ("before", "after"):
            for key, mask in (("r13", 1), ("r13", 0x10), ("r14", 0x08), ("r19", 0x80)):
                with self.subTest(prefix=prefix, key=key, mask=mask):
                    data = fixture()
                    data[f"{prefix}_{key}"][0] &= ~mask
                    self.assertFalse(TOOL.analyze_snapshot(data)["timing_valid"])

    def test_bit3_alone_does_not_satisfy_vendor_bit4_check(self):
        data = fixture()
        for prefix in ("before", "after"):
            data[f"{prefix}_r13"] = [0x09]
        self.assertFalse(TOOL.analyze_snapshot(data)["status_after"]["clock_stable"])

    def test_changed_counters_or_bank_invalid(self):
        data = fixture()
        data["timing_second"][0] ^= 2
        self.assertFalse(TOOL.analyze_snapshot(data)["timing_valid"])
        data = fixture()
        data["after_bank"] = [3]
        self.assertFalse(TOOL.analyze_snapshot(data)["timing_valid"])

    def test_high_bits_and_polarity(self):
        raw = fixture()["timing_first"]
        raw[0] = 2
        raw[0xA8 - 0x98] = 0x31
        raw[0xA1 - 0x98] = 0x21
        t = TOOL.decode_timing(raw)
        self.assertEqual(t["v_front_porch"], 0x308)
        self.assertEqual(t["v_sync_width"], 0x10A)
        self.assertEqual(t["h_front_porch"], 0x2B0)
        self.assertEqual(t["h_sync_width"], 0x158)
        self.assertTrue(t["interlaced"])
        self.assertTrue(t["h_sync_positive"])
        self.assertTrue(t["v_sync_positive"])

    def test_impossible_geometry_not_clamped(self):
        data = fixture()
        for key in ("timing_first", "timing_second"):
            data[key][0x9B - 0x98] = 3
            data[key][0x9C - 0x98] = 0
        report = TOOL.analyze_snapshot(data)
        self.assertFalse(report["timing_valid"])
        self.assertLess(report["raw_timing"]["h_back_porch"], 0)

    def test_all_ones_response_invalid(self):
        data = {key: [255] * size for key, size in TOOL.FIELDS.items()}
        self.assertFalse(TOOL.analyze_snapshot(data)["timing_valid"])

    def test_timing_length_is_exact(self):
        for length in (0, 16, 18, 20):
            with self.assertRaises(ValueError):
                TOOL.decode_timing([0] * length)


class TransportTest(unittest.TestCase):
    def test_exact_response(self):
        data = fixture()
        self.assertEqual(TOOL.parse_response(response(data)), data)

    def test_downstream_errors_and_old_firmware_rejected(self):
        for status in (1, 2, 3, 4, 255, 127):
            with self.subTest(status=status), self.assertRaises(TOOL.ReadError):
                TOOL.parse_response(response(fixture(), status=status))
        # Every transaction is checked, not just the first status read.
        valid = response(fixture()).splitlines()
        for i in range(len(valid)):
            bad = valid.copy()
            bad[i] = bad[i][:-4] + "0x02"
            with self.subTest(field=i), self.assertRaises(TOOL.ReadError):
                TOOL.parse_response("\n".join(bad))

    def test_ff_data_not_confused_with_status(self):
        data = {key: [255] * size for key, size in TOOL.FIELDS.items()}
        self.assertEqual(TOOL.parse_response(response(data)), data)
        self.assertFalse(TOOL.analyze_snapshot(data)["timing_valid"])

    def test_partial_extra_duplicate_or_malformed_response_rejected(self):
        valid = response(fixture())
        for bad in ("", valid.replace("0x00", "error", 1), valid + "\nextra 0x00",
                    valid + "\nbefore_bank 0x00", valid.replace("before_bank 0x00", "before_bank"),
                    valid.replace("0xf8", "0x100"), valid.replace("timing_first ", "timing_first 0x00 ")):
            with self.subTest(bad=bad[:40]), self.assertRaises(TOOL.ReadError):
                TOOL.parse_response(bad)

    def test_nonzero_exit_and_stderr_are_not_signal_loss(self):
        for proc in (subprocess.CompletedProcess([], 1, "", "I2C failure"),
                     subprocess.CompletedProcess([], 0, response(fixture()), "I2C warning")):
            with patch.object(TOOL.subprocess, "run", return_value=proc), self.assertRaises(TOOL.ReadError):
                TOOL.read_snapshot("unit-test", 3)

    def test_timeout_and_missing_ssh(self):
        for error in (subprocess.TimeoutExpired("ssh", 1), FileNotFoundError("ssh")):
            with patch.object(TOOL.subprocess, "run", side_effect=error), self.assertRaises(TOOL.ReadError):
                TOOL.read_snapshot("unit-test", 1)

    def test_read_command_fail_closed_and_no_config_writes(self):
        with patch.object(TOOL.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, response(fixture()), "")) as run:
            TOOL.read_snapshot("unit-test", 3)
        args, kwargs = run.call_args
        self.assertIn("BatchMode=yes", args[0])
        self.assertIn("set -eu", args[0][-1])
        self.assertIn("0x71 19 0x98 r20@0x33", args[0][-1])
        self.assertIn("0x71 1 0x13 r2@0x33", args[0][-1])
        self.assertNotIn("i2cset", args[0][-1])
        self.assertEqual(kwargs["timeout"], 3)

    def test_cli_exit_codes(self):
        data = fixture()
        for prefix in ("before", "after"):
            data[f"{prefix}_r19"] = [0]
        with patch.object(TOOL, "read_snapshot", return_value=data), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(TOOL.main(["--json"]), 2)
        with patch.object(TOOL, "read_snapshot", return_value=fixture()), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(TOOL.main([]), 0)
        with patch.object(TOOL, "read_snapshot", side_effect=TOOL.ReadError("failure")), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(TOOL.main([]), 1)

    def test_bad_timeout_and_option_host_rejected(self):
        for args in (["--timeout", "0"], ["--timeout", "nan"], ["--timeout", "inf"], ["--host=-oProxyCommand=bad"]):
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                TOOL.main(args)


if __name__ == "__main__":
    unittest.main()
