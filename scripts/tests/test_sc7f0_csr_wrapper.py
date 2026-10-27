"""The register bank and generated dual-clock wrapper must never drift."""
import subprocess
import sys
import unittest
from pathlib import Path


class CsrWrapperTest(unittest.TestCase):
    def test_generated_wrapper_matches_authoritative_bank(self):
        root = Path(__file__).resolve().parents[2]
        result = subprocess.run(
            [sys.executable, str(root / 'scripts/generate_sc7f0_csr_cdc.py'), '--check'],
            cwd=root, capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
