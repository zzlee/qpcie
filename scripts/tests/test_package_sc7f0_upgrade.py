import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("package_upgrade", ROOT / "scripts/package_sc7f0_upgrade.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class PackageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.work = tempfile.TemporaryDirectory()
        cls.binary = Path(cls.work.name) / "verify"
        src = cls.binary.with_suffix(".c")
        src.write_text('''#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdbool.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include "qpcie_archive_verify.h"
int main(int argc, char **argv) {
    if (argc != 3) return 2;
    if (qav_extract(argv[1], argv[2])) return 3;
    return qav_verify_manifest(argv[2]) ? 4 : 0;
}
''')
        subprocess.run(["cc", "-O2", "-I", str(ROOT / "test_app"), str(src), "-o", str(cls.binary)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.work.cleanup()

    def verify(self, archive, destination):
        destination.mkdir()
        return subprocess.run([str(self.binary), str(archive), str(destination)]).returncode

    def test_real_daemon_parser_raw_and_gzip(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for n in MODULE.NAMES:
                (root / n).write_bytes((n.encode() + b"\0") * 100)
            for suffix in (".tar", ".tar.gz"):
                archive = root / ("upgrade" + suffix)
                MODULE.package(root, archive)
                self.assertEqual(self.verify(archive, root / ("out" + suffix)), 0)

    def test_missing_boot_script_rejected_before_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for n in MODULE.NAMES[:2]:
                (root / n).write_bytes(b"data")
            with self.assertRaises(FileNotFoundError):
                MODULE.package(root, root / "bad.tar")
            self.assertFalse((root / "bad.tar").exists())

    def test_empty_payload_and_overwrite_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for n in MODULE.NAMES:
                (root / n).write_bytes(b"data")
            output = root / "bundle.tar"
            MODULE.package(root, output)
            with self.assertRaises(FileExistsError):
                MODULE.package(root, output)
            (root / "boot.scr").write_bytes(b"")
            with self.assertRaises(ValueError):
                MODULE.package(root, root / "empty.tar")

    def test_manifest_corruption_rejected_by_real_parser(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for n in MODULE.NAMES:
                (root / n).write_bytes(b"unique-boot-content")
            output = root / "bundle.tar"
            MODULE.package(root, output)
            output.write_bytes(output.read_bytes().replace(b"unique-boot-content", b"Unique-boot-content", 1))
            self.assertEqual(self.verify(output, root / "out"), 4)


if __name__ == "__main__":
    unittest.main()
