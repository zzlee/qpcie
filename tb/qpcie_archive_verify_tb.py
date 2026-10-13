"""Strict extraction regression; all fixtures stay in /tmp/opencode."""
import io
import pathlib
import subprocess
import tarfile
import tempfile

root = pathlib.Path(tempfile.mkdtemp(prefix="qav_", dir="/tmp/opencode"))
exe = root / "qav"
subprocess.run(["gcc", "-O2", "-Wall", "-Wextra", "-Werror", "-Itest_app",
                "tb/qpcie_archive_verify_tb.c", "-o", str(exe)], check=True)

def member(name, data=b"fixture", kind=tarfile.REGTYPE, link=""):
    m = tarfile.TarInfo(name)
    m.type = kind
    m.linkname = link
    m.size = len(data) if kind == tarfile.REGTYPE else 0
    return m, data

good = [member(n) for n in ("BOOT.BIN", "image.ub", "boot.scr")]
cases = [
    ("valid", good, True),
    ("missing", good[:2], False),
    ("duplicate", good + [good[0]], False),
    ("traversal", [member("../escape")] + good, False),
    ("absolute", [member("/tmp/escape")] + good, False),
    ("symlink", [member("BOOT.BIN", kind=tarfile.SYMTYPE, link="/etc/passwd")] + good[1:], False),
    ("hardlink", [member("BOOT.BIN", kind=tarfile.LNKTYPE, link="image.ub")] + good[1:], False),
    ("directory", [member("dir", kind=tarfile.DIRTYPE)] + good, False),
    ("extra", good + [member("autorun.sh")], False),
    ("empty", [member("BOOT.BIN", b"")] + good[1:], False),
]
for name, members, valid in cases:
    archive = root / (name + ".tar.gz")
    dest = root / name
    dest.mkdir()
    with tarfile.open(archive, "w:gz", format=tarfile.USTAR_FORMAT) as t:
        for m, data in members:
            t.addfile(m, io.BytesIO(data) if m.size else None)
    rc = subprocess.run([str(exe), str(archive), str(dest)], capture_output=True).returncode
    assert (rc == 0) == valid, (name, rc)
    assert not (root / "escape").exists()
    if valid:
        assert (dest / "BOOT.BIN").read_bytes() == b"fixture"
# Truncated gzip must never produce VERIFIED.
archive = root / "truncated.gz"
archive.write_bytes((root / "valid.tar.gz").read_bytes()[:20])
dest = root / "truncated"
dest.mkdir()
assert subprocess.run([str(exe), str(archive), str(dest)], capture_output=True).returncode != 0
print("TB_PASS: strict archive allowlist, links/paths/duplicates/empty/truncated refusal")
