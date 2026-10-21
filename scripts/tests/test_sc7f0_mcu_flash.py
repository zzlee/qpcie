#!/usr/bin/env python3
"""Flash-protocol unit harness; NEVER accesses SSH, I2C, or a real MCU."""
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "mcu_flash", Path(__file__).resolve().parents[1] / "sc7f0_mcu_flash.py")
TOOL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TOOL)


class ShellHarness(TOOL.Flasher):
    """Run the actual generated shell against a unit-test I2C command stub."""
    def __init__(self, directory, response="0x00", fail_opcode="", new_version=0x1262010D):
        super().__init__()
        self.directory = Path(directory)
        self.new_version = new_version
        self.queries = 0
        self.env = {**os.environ, "PATH": str(directory) + ":" + os.environ["PATH"],
                    "UNIT_RESPONSE": response, "UNIT_FAIL_OPCODE": fail_opcode,
                    "UNIT_LOG": str(self.directory / "calls")}
        command = self.directory / "i2ctransfer"
        command.write_text('#!/bin/sh\n'
                           'echo "$4" >> "$UNIT_LOG"\n'
                           'if [ "$4" = "$UNIT_FAIL_OPCODE" ]; then printf "%s\\n" "$UNIT_RESPONSE"; '
                           'else echo 0x00; fi\n')
        command.chmod(0o700)

    def query_status(self):
        self.queries += 1
        version = 0x1262010C if self.queries == 1 else self.new_version
        return {"version_raw": version, "version": hex(version), "it6663_present": True,
                "vendor_id": "TI", "device_id": "6366", "temperature_c": 40, "slaves": []}

    def exec_card(self, command, timeout=30):
        if command.startswith("i2ctransfer"):
            assert "0x01 r4" in command  # HELLO only; burn commands run in shell.
            return "0x01 0x00 0x02 0x20"
        command = command.replace("/tmp/burn_mcu.sh", str(self.directory / "burn.sh"))
        result = subprocess.run(["sh", "-c", command], capture_output=True, text=True,
                                timeout=timeout, env=self.env)
        if result.returncode:
            raise RuntimeError(result.stderr)
        return result.stdout.strip()


class FlashSafetyTest(unittest.TestCase):
    def run_harness(self, size=65, **kwargs):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "fw.bin"
            binary.write_bytes(bytes(size))
            harness = ShellHarness(directory, **kwargs)
            error = None
            with patch.object(TOOL.time, "sleep"), contextlib.redirect_stdout(io.StringIO()) as output:
                try:
                    harness.flash_binary(binary, expected_version=0x1262010D)
                except (RuntimeError, ValueError) as exc:
                    error = exc
            calls = Path(directory) / "calls"
            return error, output.getvalue(), calls.read_text().splitlines() if calls.exists() else []

    def test_success_requires_checked_ack_and_exact_version(self):
        error, output, calls = self.run_harness()
        self.assertIsNone(error)
        self.assertEqual(calls, ["0x02", "0x03", "0x03", "0x03", "0x04"])
        self.assertIn("expected firmware version read back", output)

    def test_begin_rejection_prevents_chunks_and_commit(self):
        error, output, calls = self.run_harness(response="0x01", fail_opcode="0x02")
        self.assertIsNotNone(error)
        self.assertEqual(calls, ["0x02"])
        self.assertNotIn("SUCCESSFUL", output)

    def test_chunk_rejection_or_bad_response_prevents_commit(self):
        for response in ("0x03", "", "0x00 0x00", "garbage"):
            with self.subTest(response=response):
                error, output, calls = self.run_harness(response=response, fail_opcode="0x03")
                self.assertIsNotNone(error)
                self.assertEqual(calls, ["0x02", "0x03"])
                self.assertNotIn("SUCCESSFUL", output)

    def test_commit_rejection_not_success(self):
        error, output, calls = self.run_harness(response="0x03", fail_opcode="0x04")
        self.assertIsNotNone(error)
        self.assertEqual(calls.count("0x04"), 1)
        self.assertNotIn("SUCCESSFUL", output)

    def test_old_version_never_counts_as_upgrade_success_or_retries_commit(self):
        error, output, calls = self.run_harness(new_version=0x1262010C)
        self.assertIsNotNone(error)
        self.assertIn("do not retry", str(error))
        self.assertEqual(calls.count("0x04"), 1)
        self.assertNotIn("SUCCESSFUL", output)

    def test_empty_and_oversize_images_never_reach_card(self):
        for size in (0, 8193):
            error, _, calls = self.run_harness(size=size)
            self.assertIsInstance(error, ValueError)
            self.assertEqual(calls, [])

    def test_maximum_size_batching_stays_in_mailbox_budget(self):
        error, _, calls = self.run_harness(size=8192)
        self.assertIsNone(error)
        self.assertEqual(len(calls), 258)

    def test_status_length_and_identity(self):
        flasher = TOOL.Flasher()
        raw = [0x0D, 0x01, 0x62, 0x12] + [0] * 32
        for data in (raw[:16], raw[:35], raw + [0], [255] * 36):
            with patch.object(flasher, "exec_card", return_value=" ".join(hex(x) for x in data)), self.assertRaises(RuntimeError):
                flasher.query_status()
        with patch.object(flasher, "exec_card", return_value=" ".join(hex(x) for x in raw)):
            self.assertEqual(flasher.query_status()["version_raw"], 0x1262010D)

    def test_unlocked_protocol_and_cached_dimensions_are_not_valid_output(self):
        raw = [0x0D, 0x01, 0x62, 0x12] + [0] * 32
        raw[4] = 0x80  # Stale HDMI bit, but lock bit clear.
        raw[14:16] = [0x00, 0x0F]
        raw[32:34] = [0x70, 0x08]
        flasher = TOOL.Flasher()
        with patch.object(flasher, "exec_card", return_value=" ".join(hex(x) for x in raw)):
            result = flasher.query_status()
        self.assertEqual(result["hdmi_mode"], "UNKNOWN (unlocked)")
        self.assertEqual(result["resolution"], "No Signal / Invalid timing")
        self.assertEqual(result["raw_h_active"], 3840)

    def test_remote_command_roundtrip_quoting(self):
        cmd = "printf '%s\\n' 'literal $HOME' >> /tmp/burn_mcu.sh"
        with patch.object(TOOL.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "", "")) as run:
            TOOL.Flasher(host="unit-test").exec_card(cmd)
        self.assertEqual(shlex.split(run.call_args.args[0][-1])[-1], cmd)


if __name__ == "__main__":
    unittest.main()
