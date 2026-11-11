#!/usr/bin/env python3
"""Real application ELF/bin positives and paired-load mutations; no hardware."""
import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('app_gate', ROOT/'scripts/check_sc7f0_mcu_app_image.py')
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class AppImageTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.elf = Path(self.tmp.name)/'app.elf'
        self.bin = Path(self.tmp.name)/'app.bin'
        source = ROOT/'test_mcu_nuc1262/nuc1262_bringup'
        if not source.with_suffix('.elf').exists():
            self.skipTest('Build real MCU candidate first')
        self.elf.write_bytes(source.with_suffix('.elf').read_bytes())
        self.bin.write_bytes(source.with_suffix('.bin').read_bytes())

    def audit(self):
        return gate.audit(self.elf, self.bin, 'app')

    def paired_patch(self, address, data):
        blob = bytearray(self.elf.read_bytes())
        elf = gate.Elf32(blob)
        image = bytearray(self.bin.read_bytes())
        found = False
        for kind, off, _, physical, size, *_ in elf.loads:
            if kind == 1 and physical <= address and address+len(data) <= physical+size:
                blob[off+address-physical:off+address-physical+len(data)] = data
                found = True
        self.assertTrue(found)
        image[address:address+len(data)] = data
        self.elf.write_bytes(blob)
        self.bin.write_bytes(image)
        self.assertEqual(gate.Elf32(blob).binary(), image)

    def mutate_stage(self, word_index, value):
        blob = bytearray(self.elf.read_bytes())
        header = struct.unpack_from('<16sHHIIIIIHHHHHH', blob)
        section = gate.Elf32(blob).sections['.upgrade_stage']
        for i in range(header[12]):
            off = header[6]+i*40
            if struct.unpack_from('<10I', blob, off) == section:
                struct.pack_into('<I', blob, off+word_index*4, value)
                self.elf.write_bytes(blob)
                return
        self.fail('stage section missing')

    def test_actual_image_never_claims_deployment(self):
        result = self.audit()
        self.assertTrue(result['static_pass'])
        self.assertEqual(result['version'], '0x12620112')
        self.assertLessEqual(result['bytes'], 8192)
        self.assertFalse(result['deployment_allowed'])
        self.assertFalse(result['power_fail_safe'])

    def test_wrong_stack(self):
        self.paired_patch(0, struct.pack('<I', 0x20003000))
        with self.assertRaisesRegex(ValueError, 'vectors'):
            self.audit()

    def test_non_thumb_entry(self):
        value = struct.unpack_from('<I', self.bin.read_bytes(), 4)[0]
        self.paired_patch(4, struct.pack('<I', value & ~1))
        with self.assertRaisesRegex(ValueError, 'vectors'):
            self.audit()

    def test_compiled_identity_mismatch(self):
        address = gate.Elf32(self.elf.read_bytes()).symbol('sc7f0_mcu_version')
        self.paired_patch(address, struct.pack('<I', 0x1262010f))
        with self.assertRaisesRegex(ValueError, 'identity'):
            self.audit()

    def test_legacy_reset_destination_mutation(self):
        self.paired_patch(0x204, b'\x00\xbf')
        with self.assertRaisesRegex(ValueError, 'migration unsafe'):
            self.audit()

    def test_stage_must_be_noload(self):
        self.mutate_stage(1, 1)
        with self.assertRaisesRegex(ValueError, 'NOLOAD'):
            self.audit()

    def test_cannot_silently_expand_stage_to_12k(self):
        self.mutate_stage(5, 12288)
        with self.assertRaisesRegex(ValueError, '8KiB'):
            self.audit()

    def test_bin_mismatch(self):
        data = bytearray(self.bin.read_bytes()); data[-1] ^= 1
        self.bin.write_bytes(data)
        with self.assertRaisesRegex(ValueError, 'BIN differs'):
            self.audit()

    def test_flash_branch_rejected(self):
        with patch.object(gate.subprocess, 'check_output', return_value='20000072: f000 f800 bl 204 <flash>\n'):
            with self.assertRaisesRegex(ValueError, 'escapes SRAM'):
                self.audit()

    def test_vacuous_disassembly_rejected(self):
        with patch.object(gate.subprocess, 'check_output', return_value=''):
            with self.assertRaisesRegex(ValueError, 'vacuous'):
                self.audit()

    def test_role_not_rebranded(self):
        with self.assertRaisesRegex(ValueError, 'application'):
            gate.audit(self.elf, self.bin, 'bridge')


if __name__ == '__main__':
    unittest.main()
