"""Strict extraction regression; all fixtures stay in /tmp/opencode."""
import hashlib
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

def calc_manifest(files):
    lines = []
    for name, data in files:
        h = hashlib.sha256(data).hexdigest()
        lines.append(f"{h}  {name}\n")
    return "".join(lines).encode("utf-8")

good_files = [
    ("BOOT.BIN", b"boot_bin_content_12345"),
    ("image.ub", b"image_ub_content_67890"),
    ("boot.scr", b"boot_scr_content_abcde"),
]
good = [member(name, data) for name, data in good_files]

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

# 1. Test gzip-compressed archives (.tar.gz)
for name, members, valid in cases:
    archive = root / (name + ".tar.gz")
    dest = root / ("gz_" + name)
    dest.mkdir()
    with tarfile.open(archive, "w:gz", format=tarfile.USTAR_FORMAT) as t:
        for m, data in members:
            t.addfile(m, io.BytesIO(data) if m.size else None)
    rc = subprocess.run([str(exe), str(archive), str(dest)], capture_output=True).returncode
    assert (rc == 0) == valid, (f"gz_{name}", rc)
    assert not (root / "escape").exists()
    if valid:
        assert (dest / "BOOT.BIN").read_bytes() == b"boot_bin_content_12345"

# Truncated gzip must never produce VERIFIED.
archive = root / "truncated.gz"
archive.write_bytes((root / "valid.tar.gz").read_bytes()[:20])
dest = root / "truncated"
dest.mkdir()
assert subprocess.run([str(exe), str(archive), str(dest)], capture_output=True).returncode != 0

# 2. Test uncompressed archives (.tar)
for name, members, valid in cases:
    archive = root / (name + ".tar")
    dest = root / ("tar_" + name)
    dest.mkdir()
    with tarfile.open(archive, "w", format=tarfile.USTAR_FORMAT) as t:
        for m, data in members:
            t.addfile(m, io.BytesIO(data) if m.size else None)
    rc = subprocess.run([str(exe), str(archive), str(dest)], capture_output=True).returncode
    assert (rc == 0) == valid, (f"tar_{name}", rc)
    if valid:
        assert (dest / "BOOT.BIN").read_bytes() == b"boot_bin_content_12345"

# 3. Test uncompressed archives WITH manifest.sha256
manifest_data = calc_manifest(good_files)
good_with_manifest = good + [member("manifest.sha256", manifest_data)]

archive = root / "valid_manifest.tar"
dest = root / "tar_manifest_valid"
dest.mkdir()
with tarfile.open(archive, "w", format=tarfile.USTAR_FORMAT) as t:
    for m, data in good_with_manifest:
        t.addfile(m, io.BytesIO(data))
rc = subprocess.run([str(exe), str(archive), str(dest), "--check-manifest"], capture_output=True).returncode
assert rc == 0, f"Valid manifest test failed, rc={rc}"

# 4. Test tampering: corrupted payload must fail manifest verification
corrupted_files = [
    ("BOOT.BIN", b"TAMPERED_BOOT_BIN"),
    ("image.ub", b"image_ub_content_67890"),
    ("boot.scr", b"boot_scr_content_abcde"),
]
tampered = [member(n, d) for n, d in corrupted_files] + [member("manifest.sha256", manifest_data)]
archive = root / "tampered_manifest.tar"
dest = root / "tar_manifest_tampered"
dest.mkdir()
with tarfile.open(archive, "w", format=tarfile.USTAR_FORMAT) as t:
    for m, data in tampered:
        t.addfile(m, io.BytesIO(data))
rc = subprocess.run([str(exe), str(archive), str(dest), "--check-manifest"], capture_output=True).returncode
assert rc == 3, f"Tampered manifest test expected rc=3, got {rc}"

print("TB_PASS: strict archive allowlist (.tar.gz and .tar), manifest.sha256 verification and tamper refusal")

