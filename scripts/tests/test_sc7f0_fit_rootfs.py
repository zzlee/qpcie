#!/usr/bin/env python3
"""Tests for the read-only FIT/rootfs reader in scripts/package_sc7f0_rootfs.py.

This reader is the evidence behind "the runtime is really inside image.ub", so it
is tested against files it has to survive, not against a file it happens to like:

  * a bare FIT (device tree at byte 0, PetaLinux image.ub shape),
  * a u-Boot legacy wrapper (64-byte header, data-offset counted from the tree),
  * inline `data` properties and external data-offset/data-size,
  * gzip and nested-legacy ramdisk layers,
  * truncated, mis-headed and wrong-magic files,
  * zero or two ramdisk sub-images, and a kernel that must not be mistaken for one,
  * cpio symlink entries (enabled units are symlinks) including a dangling one.

Every negative case must produce a clean failure, never a traceback: a gate that
raises is a gate somebody will wrap in `|| true`.
"""
from __future__ import annotations

from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from package_sc7f0_rootfs import (ARM64_ELF_MACHINE, FIT_MAGIC, _ramdisk_bytes,  # noqa: E402
                                  fit_subimages, verify)

# --------------------------------------------------------------------------
# builders
# --------------------------------------------------------------------------

ARM64 = (b"\x7fELF" + bytes([2, 1, 1]) + b"\0" * 9 + (2).to_bytes(2, "little")
         + ARM64_ELF_MACHINE.to_bytes(2, "little") + b"\0" * 40)


def newc(entries: list[tuple[str, int, bytes]]) -> bytes:
    """cpio newc archive; entry = (name, mode, data). Symlink data is the target.

    Field padding mirrors the project's own reader in
    scripts/check_sc7f0_ps_watchdog_image.cpio(), which is what has to parse this.
    """
    out = bytearray()

    def emit(name: str, mode: int, data: bytes):
        head = bytearray(b"070701")
        # newc field order: ino mode uid gid nlist mtime filesize devmajor devminor
        #                          rmajor rminor namesize chksum
        fields = [0, mode, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(name) + 1, 0]
        for value in fields:
            head += ("%08X" % value).encode()
        assert len(head) == 110, len(head)
        raw = name.encode() + b"\0"
        out.extend(head)
        out.extend(raw)
        while len(out) % 4:
            out.extend(b"\0")
        out.extend(data)
        while len(out) % 4:
            out.extend(b"\0")

    for name, mode, data in entries:
        emit(name, mode, data)
    emit("TRAILER!!!", 0, b"")
    while len(out) % 4:
        out += b"\0"
    return bytes(out)


def rootfs(capture_tool: bytes = ARM64, extra_units: bool = True) -> bytes:
    entries = [("usr/bin/sc7f0_vcud", stat.S_IFREG | 0o755, capture_tool),
               ("bin/sh", stat.S_IFREG | 0o755, ARM64)]
    if extra_units:
        entries.append(("lib/systemd/system/sc7f0-vcud.service", stat.S_IFREG | 0o644,
                        b"[Unit]\nDescription=SC7F0 VCU\n[Service]\n"
                        b"ExecStart=/usr/bin/sc7f0_vcud\n[Install]\n"
                        b"WantedBy=multi-user.target\n"))
        entries.append(("etc/systemd/system/multi-user.target.wants/sc7f0-vcud.service",
                        stat.S_IFLNK | 0o777, b"/lib/systemd/system/sc7f0-vcud.service"))
    return newc(entries)


class Fdt:
    """Minimal flat device tree writer, enough for a FIT image description."""

    def __init__(self):
        self.struct = bytearray()
        self.strings: dict[str, int] = {}

    def _string(self, s: str) -> int:
        if s not in self.strings:
            self.strings[s] = len(b"".join(
                k.encode() + b"\0" for k in self.strings))
        return self.strings[s]

    def begin(self, name: str):
        raw = name.encode() + b"\0"
        self.struct += (1).to_bytes(4, "big") + raw
        while len(self.struct) % 4:
            self.struct += b"\0"

    def end(self):
        self.struct += (2).to_bytes(4, "big")

    def prop(self, name: str, value: bytes):
        self.struct += (3).to_bytes(4, "big") + len(value).to_bytes(4, "big")
        self.struct += self._string(name).to_bytes(4, "big") + value
        while len(self.struct) % 4:
            self.struct += b"\0"

    def bytes(self) -> bytes:
        strings = b"".join(k.encode() + b"\0" for k in self.strings)
        body = bytes(self.struct) + (9).to_bytes(4, "big")     # FDT_END
        total = 40 + len(body) + len(strings)
        head = b"".join(x.to_bytes(4, "big") for x in
                        (0xD00DFEED, total, 40, 40 + len(body), 0, 17, 16, 0,
                         len(strings), len(body)))
        return head + body + strings


def _image_node(fdt: Fdt, name: str, kind: str, blob: bytes | None,
                offset: int | None = None, size: int | None = None,
                compression: str = "none"):
    fdt.begin(name)
    fdt.prop("description", ("sc7f0 test " + kind).encode() + b"\0")
    fdt.prop("type", kind.encode() + b"\0")
    fdt.prop("compression", compression.encode() + b"\0")
    if blob is not None:
        fdt.prop("data", blob)
    else:
        fdt.prop("data-offset", offset.to_bytes(4, "big"))
        fdt.prop("data-size", size.to_bytes(4, "big"))
    fdt.prop("hash-1", b"\0" * 8)
    fdt.end()


def fit(kernel: bytes = b"\x1f\x8b\x08\x00fake-kernel", ramdisk: bytes | None = None,
        extra_ramdisks: int = 0, wrapped: bool = False, inline: bool = True) -> bytes:
    """Assemble a FIT. wrapped=True produces the legacy 64-byte-header shape.

    With inline=False the payload lives after the device tree and each sub-image
    carries data-offset/data-size, exactly like a real image.ub. The tree is built
    twice because the offsets depend on the tree length; a 4-byte placeholder has
    the same length as the real value, so the second pass lands on the same size.
    """
    ramdisk = rootfs() if ramdisk is None else ramdisk
    payloads: list[tuple[str, bytes]] = [("kernel-1", kernel), ("ramdisk-1", ramdisk)]
    payloads += [("ramdisk-%d" % (i + 2), ramdisk) for i in range(extra_ramdisks)]

    def tree(offsets: dict[str, int] | None) -> bytes:
        fdt = Fdt()
        fdt.begin("")
        fdt.prop("description", b"sc7f0 test fit\0")
        fdt.begin("images")
        for name, blob in payloads:
            kind = "kernel" if name == "kernel-1" else "ramdisk"
            comp = "gzip" if kind == "kernel" else "none"
            if offsets is None:
                _image_node(fdt, name, kind, blob, compression=comp)
            else:
                _image_node(fdt, name, kind, None, offset=offsets[name], size=len(blob),
                            compression=comp)
        fdt.end()
        fdt.begin("configurations")
        fdt.begin("conf-1")
        fdt.prop("description", b"sc7f0 test conf\0")
        fdt.prop("kernel", b"kernel-1\0")
        fdt.end()
        fdt.end()
        fdt.end()
        return fdt.bytes()

    if inline:
        dtb, body = tree(None), b""
        pad = b""
    else:
        dtb = tree({name: 0 for name, _ in payloads})
        pad = b"\0" * ((-len(dtb)) % 4)
        cursor, offsets = len(dtb) + len(pad), {}
        for name, blob in payloads:
            offsets[name] = cursor
            cursor += len(blob) + ((-len(blob)) % 4)
        dtb = tree(offsets)                       # same length, real offsets
        body = b"".join(blob + b"\0" * ((-len(blob)) % 4) for _, blob in payloads)
    if not wrapped:
        return dtb + pad + body
    # u-Boot wrapper: 64-byte header, then the tree, then the payload. The reader has
    # to locate the tree by its own magic and totalsize (a real vendor header does
    # not keep a header length where a reader might guess one), so this builder only
    # has to honour that contract.
    inner = dtb + pad + body
    header = bytearray(b"".join(x.to_bytes(4, "big") for x in
                                (FIT_MAGIC, len(inner), len(inner), 0, 0, 0)))
    header += bytes([5, 25, 5, 1]) + b"sc7f0-test-fit".ljust(36, b"\0")
    assert len(header) == 64, len(header)
    return bytes(header) + inner


# --------------------------------------------------------------------------

class FitReaderTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="sc7f0-fit-test-"))

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write(self, blob: bytes, name: str = "image.ub") -> Path:
        p = self.tmp / name
        p.write_bytes(blob)
        return p

    # ---- positive shapes ---------------------------------------------------
    def test_bare_fit_with_inline_data(self):
        p = self.write(fit(wrapped=False, inline=True))
        imgs = fit_subimages(p)
        self.assertEqual({n: i["type"] for n, i in imgs.items()},
                         {"kernel-1": "kernel", "ramdisk-1": "ramdisk"})
        self.assertEqual(imgs["ramdisk-1"]["data"], rootfs())

    def test_bare_fit_with_external_offsets(self):
        p = self.write(fit(wrapped=False, inline=False))
        imgs = fit_subimages(p)
        self.assertEqual(imgs["ramdisk-1"]["data"], rootfs())
        self.assertEqual(imgs["kernel-1"]["data"], b"\x1f\x8b\x08\x00fake-kernel")

    def test_legacy_wrapped_fit(self):
        p = self.write(fit(wrapped=True, inline=False))
        imgs = fit_subimages(p)
        self.assertEqual(imgs["ramdisk-1"]["data"], rootfs())

    def test_gzip_and_nested_legacy_ramdisk_layers(self):
        import gzip
        inner = rootfs()
        header = bytearray(b"".join(x.to_bytes(4, "big") for x in
                                    (FIT_MAGIC, len(inner), len(inner), 0, 0, 0)))
        header += bytes([5, 25, 8, 2]) + b"sc7f0-nested".ljust(36, b"\0")
        nested = gzip.compress(bytes(header) + inner)     # gzip(uImage(cpio))
        p = self.write(fit(ramdisk=gzip.compress(nested)))
        self.assertEqual(_ramdisk_bytes(fit_subimages(p)["ramdisk-1"]["data"]), inner)

    def test_ramdisk_that_is_neither_gzip_nor_cpio(self):
        with self.assertRaises(ValueError):
            fit_subimages(self.write(fit(ramdisk=b"not an archive at all, really" * 4)))

    # ---- negatives: the reader must refuse, not improvise ------------------
    def test_bad_magic(self):
        with self.assertRaises(ValueError):
            fit_subimages(self.write(b"hello" * 20))

    def test_truncated_at_every_interesting_offset(self):
        blob = fit(wrapped=True, inline=False)
        for cut in (0, 1, 32, 63, 64, 100, len(blob) // 2, len(blob) - 1):
            with self.subTest(cut=cut):
                try:
                    fit_subimages(self.write(blob[:cut], name="cut-%d.ub" % cut))
                except ValueError:
                    pass
                except Exception as exc:            # a traceback is a test failure
                    self.fail("cut %d raised %s (%s); must raise ValueError"
                              % (cut, type(exc).__name__, exc))

    def test_inconsistent_device_tree_length(self):
        blob = bytearray(fit(wrapped=True, inline=False))
        blob[68:72] = (len(blob) + 4096).to_bytes(4, "big")   # tree claims too much
        with self.assertRaises(ValueError):
            fit_subimages(self.write(bytes(blob)))

    def test_wrapper_without_a_device_tree(self):
        blob = bytearray(fit(wrapped=True, inline=False))
        blob[64:68] = b"junk"
        with self.assertRaises(ValueError):
            fit_subimages(self.write(bytes(blob)))

    def test_bad_root_magic_is_refused(self):
        blob = bytearray(fit(wrapped=False, inline=True))
        blob[0:4] = b"junk"
        with self.assertRaises(ValueError):
            fit_subimages(self.write(bytes(blob)))

    def test_offset_outside_file(self):
        blob = bytearray(fit(wrapped=False, inline=False))
        from package_sc7f0_rootfs import fdt_tree
        target = None
        for path, name, value in fdt_tree(bytes(blob)):
            if name == "data-offset":
                target = (path, value)
                break
        self.assertIsNotNone(target, "synthetic FIT has no external data-offset")
        pos = bytes(blob).index(bytes(target[1]))
        blob[pos:pos + 4] = (1 << 31).to_bytes(4, "big")
        with self.assertRaises(ValueError):
            fit_subimages(self.write(bytes(blob)))

    def test_no_ramdisk_is_not_silently_the_kernel(self):
        with self.assertRaises(ValueError) as ctx:
            fit_subimages(self.write(fit_without_ramdisk()))
        self.assertIn("ramdisk", str(ctx.exception))

    def test_two_ramdisks_are_refused(self):
        with self.assertRaises(ValueError) as ctx:
            fit_subimages(self.write(fit(extra_ramdisks=1)))
        self.assertIn("exactly one ramdisk", str(ctx.exception))

    def test_empty_cpio_is_refused(self):
        with self.assertRaises(ValueError):
            fit_subimages(self.write(fit(ramdisk=newc([]))))

    # ---- verify(): verdicts, never tracebacks ------------------------------
    def test_verify_passes_on_a_complete_runtime(self):
        report = verify(self.write(fit()), {"sc7f0_vcud": None},
                        ["sc7f0-vcud.service"], [], ["sc7f0-vcud.service"])
        self.assertEqual(report["verdict"], "ROOTFS_RUNTIME_CONTENT_PASS", report["errors"])
        self.assertTrue(report["binaries"]["sc7f0_vcud"]["arm64"])

    def test_verify_can_require_a_literal_inside_a_binary(self):
        body = ARM64 + b"\0COMMIT: refused, no room for a backup generation\0"
        packed = newc([("usr/bin/sc7f0_vcud", stat.S_IFREG | 0o755, body)])
        report = verify(self.write(fit(ramdisk=packed)), {"sc7f0_vcud": None}, [], [], [],
                        [("usr/bin/sc7f0_vcud", b"no room for a backup generation")])
        self.assertEqual(report["verdict"], "ROOTFS_RUNTIME_CONTENT_PASS", report["errors"])
        self.assertTrue(report["strings"]["usr/bin/sc7f0_vcud"]
                        ["no room for a backup generation"])

    def test_verify_fails_when_a_required_literal_is_missing(self):
        """A recipe-compiled binary cannot be byte-compared to a local rebuild, so a
        missing literal is the only honest way to catch a fix that never shipped."""
        report = verify(self.write(fit()), {"sc7f0_vcud": None}, [], [], [],
                        [("usr/bin/sc7f0_vcud", b"retention policy v2")])
        self.assertEqual(report["verdict"], "ROOTFS_RUNTIME_CONTENT_FAIL")
        self.assertTrue(any("retention policy v2" in e for e in report["errors"]),
                        report["errors"])

    def test_verify_reports_a_missing_file_for_a_literal_check(self):
        packed = newc([("bin/sh", stat.S_IFREG | 0o755, ARM64)])
        report = verify(self.write(fit(ramdisk=packed)), {}, [], [], [],
                        [("usr/bin/never_built", b"anything")])
        self.assertEqual(report["verdict"], "ROOTFS_RUNTIME_CONTENT_FAIL")
        self.assertTrue(any("never_built" in e for e in report["errors"]), report["errors"])

    # ---- --expect-size: OE packagedata is the durable install record ----------
    # bitbake deletes the recipe's $D after packaging, so "the bytes equal a build
    # tree file" is unavailable for a recipe-installed binary. The size OE recorded
    # in pkgdata/<machine>/runtime/<pn> FILES_INFO is what survives, and comparing it
    # is what stops "present" from meaning "a file with that name exists".

    def test_verify_accepts_the_packagedata_size(self):
        body = ARM64 + b"x" * 64
        packed = newc([("usr/bin/sc7f0_vcud", stat.S_IFREG | 0o755, body)])
        report = verify(self.write(fit(ramdisk=packed)), {"sc7f0_vcud": None}, [], [], [],
                        [("usr/bin/sc7f0_vcud", b"x" * 8)],
                        [("usr/bin/sc7f0_vcud", len(body))])
        self.assertEqual(report["verdict"], "ROOTFS_RUNTIME_CONTENT_PASS", report["errors"])
        self.assertTrue(report["sizes"]["usr/bin/sc7f0_vcud"]["match"])

    def test_verify_rejects_a_size_that_is_not_the_packaged_file(self):
        """A stale or replaced binary of a different length must fail: this is the
        only byte-level claim available for a recipe-built runtime."""
        body = ARM64 + b"x" * 64
        packed = newc([("usr/bin/sc7f0_vcud", stat.S_IFREG | 0o755, body)])
        report = verify(self.write(fit(ramdisk=packed)), {"sc7f0_vcud": None}, [], [], [],
                        None, [("usr/bin/sc7f0_vcud", len(body) - 1)])
        self.assertEqual(report["verdict"], "ROOTFS_RUNTIME_CONTENT_FAIL")
        self.assertTrue(any("OE packagedata" in e for e in report["errors"]), report["errors"])

    def test_verify_reports_a_sized_file_that_is_absent(self):
        report = verify(self.write(fit()), {"sc7f0_vcud": None}, [], [], [],
                        None, [("usr/bin/not_installed", 100)])
        self.assertEqual(report["verdict"], "ROOTFS_RUNTIME_CONTENT_FAIL")
        self.assertTrue(any("not_installed" in e for e in report["errors"]), report["errors"])

    def test_verify_fails_when_the_runtime_binary_is_absent(self):
        packed = newc([("bin/sh", stat.S_IFREG | 0o755, ARM64)])
        report = verify(self.write(fit(ramdisk=packed)), {"sc7f0_vcud": None},
                        ["sc7f0-vcud.service"], [], ["sc7f0-vcud.service"])
        self.assertEqual(report["verdict"], "ROOTFS_RUNTIME_CONTENT_FAIL")
        self.assertIn("usr/bin/sc7f0_vcud is not in the image rootfs", report["errors"])
        self.assertIn("unit sc7f0-vcud.service is not installed", report["errors"][1])

    def test_verify_rejects_a_loose_file_execstart(self):
        unit = (b"[Unit]\nDescription=x\n[Service]\n"
                b"ExecStart=/run/media/mmcblk0p1/sc7f0_vcud\n[Install]\n"
                b"WantedBy=multi-user.target\n")
        packed = newc([("usr/bin/sc7f0_vcud", stat.S_IFREG | 0o755, ARM64),
                       ("lib/systemd/system/sc7f0-vcud.service", stat.S_IFREG | 0o644, unit),
                       ("etc/systemd/system/multi-user.target.wants/sc7f0-vcud.service",
                        stat.S_IFLNK | 0o777, b"/lib/systemd/system/sc7f0-vcud.service")])
        report = verify(self.write(fit(ramdisk=packed)), {"sc7f0_vcud": None},
                        ["sc7f0-vcud.service"], [], ["sc7f0-vcud.service"])
        self.assertEqual(report["verdict"], "ROOTFS_RUNTIME_CONTENT_FAIL")
        self.assertTrue(any("boot-partition" in e or "in-image path" in e
                            for e in report["errors"]), report["errors"])

    def test_verify_requires_the_unit_to_be_enabled(self):
        packed = newc([("usr/bin/sc7f0_vcud", stat.S_IFREG | 0o755, ARM64),
                       ("lib/systemd/system/sc7f0-vcud.service", stat.S_IFREG | 0o644,
                        b"[Service]\nExecStart=/usr/bin/sc7f0_vcud\n")])
        report = verify(self.write(fit(ramdisk=packed)), {}, ["sc7f0-vcud.service"],
                        [], ["sc7f0-vcud.service"])
        self.assertEqual(report["verdict"], "ROOTFS_RUNTIME_CONTENT_FAIL")
        self.assertIn("sc7f0-vcud.service is installed but not enabled for boot",
                      report["errors"])

    def test_dangling_enable_symlink_fails_cleanly(self):
        packed = newc([("usr/bin/sc7f0_vcud", stat.S_IFREG | 0o755, ARM64),
                       ("lib/systemd/system/sc7f0-vcud.service", stat.S_IFREG | 0o644,
                        b"[Service]\nExecStart=/usr/bin/sc7f0_vcud\n"),
                       ("etc/systemd/system/multi-user.target.wants/sc7f0-vcud.service",
                        stat.S_IFLNK | 0o777, b"/lib/systemd/system/gone.service")])
        report = verify(self.write(fit(ramdisk=packed)), {}, ["sc7f0-vcud.service"],
                        [], ["sc7f0-vcud.service"])
        self.assertEqual(report["verdict"], "ROOTFS_RUNTIME_CONTENT_FAIL", report)

    def test_non_arm64_binary_is_reported(self):
        packed = newc([("usr/bin/sc7f0_vcud", stat.S_IFREG | 0o755, b"\x7fELF\x01" + b"\0" * 40)])
        report = verify(self.write(fit(ramdisk=packed)), {"sc7f0_vcud": None}, [], [], [])
        self.assertEqual(report["verdict"], "ROOTFS_RUNTIME_CONTENT_FAIL")
        self.assertIn("usr/bin/sc7f0_vcud is not an ARM64 ELF", report["errors"])

    def test_unreadable_image_reports_instead_of_raising(self):
        report = verify(self.write(b"\0" * 512), {"sc7f0_vcud": None}, [], [], [])
        self.assertEqual(report["verdict"], "ROOTFS_RUNTIME_CONTENT_FAIL")
        self.assertIn("cannot read the rootfs", report["errors"][0])

    def test_reader_never_writes_to_its_input(self):
        blob = fit(wrapped=False, inline=False)
        p = self.write(blob)
        before = p.read_bytes()
        fit_subimages(p)
        verify(p, {"sc7f0_vcud": None}, [], [], [])
        self.assertEqual(p.read_bytes(), before)
        self.assertEqual(p.stat().st_size, len(blob))


def fit_without_ramdisk() -> bytes:
    """A FIT carrying only a kernel: the reader must not call that a rootfs."""
    fdt = Fdt()
    fdt.begin("")
    fdt.prop("description", b"kernel only\0")
    fdt.begin("images")
    _image_node(fdt, "kernel-1", "kernel", b"\x1f\x8b\x08\x00k", compression="gzip")
    fdt.end()
    fdt.begin("configurations")
    fdt.begin("conf-1")
    fdt.prop("kernel", b"kernel-1\0")
    fdt.end()
    fdt.end()
    fdt.end()
    return fdt.bytes()


class DumpimageCrossCheck(unittest.TestCase):
    """Cross-check the reader against the vendor tool, which must stay read-only.

    mkimage (the *builder*) patches a FIT in place when handed -p; that destroyed a
    historical image.ub once, so this test exists to keep any future edit from
    pointing a writing tool at a release image again.
    """

    DUMP = "/opt/Xilinx/petalinux/2023.2/components/yocto/buildtools/sysroots/" \
           "x86_64-petalinux-linux/usr/bin/dumpimage"
    SAMPLE = Path("build/sc7f0-ps-watchdog-20261027-r2-release/images/image.ub")

    def test_vendor_tool_agrees_and_does_not_write(self):
        if not Path(self.DUMP).is_file():
            self.skipTest("dumpimage not installed here: " + self.DUMP)
        if not self.SAMPLE.is_file():
            self.skipTest("no shipped image.ub available for a cross-check: "
                          + str(self.SAMPLE))
        before = self.SAMPLE.read_bytes()
        with tempfile.TemporaryDirectory(prefix="sc7f0-dumpimage-") as t:
            # Never point an external tool at a release artifact, even a nominally
            # read-only one: run it on a copy and prove the copy is unchanged.
            sample = Path(t) / "image.ub"
            sample.write_bytes(before)
            mine = fit_subimages(self.SAMPLE)
            ramdisk = [n for n in mine if mine[n]["type"] == "ramdisk"][0]
            extracted = {}
            for index in range(4):
                out = Path(t) / ("subimage-%d" % index)
                proc = subprocess.run([self.DUMP, "-T", "flat_dt", "-p", str(index),
                                       "-o", str(out), str(sample)],
                                      capture_output=True)
                if proc.returncode == 0 and out.is_file():
                    extracted[index] = out.read_bytes()
            # the point of this test: the vendor tool must never modify its input
            self.assertEqual(before, sample.read_bytes(),
                             "dumpimage modified its input - never use it on a release")
            self.assertTrue(extracted, "dumpimage extracted nothing usable")
            matches = [i for i, blob in extracted.items() if blob == mine[ramdisk]["data"]]
            self.assertTrue(matches,
                            "no dumpimage sub-image matches the reader's ramdisk (%s)"
                            % {i: len(b) for i, b in extracted.items()})
            # and the reader's own unwrapping of that exact blob yields the cpio
            from check_sc7f0_capture_image import cpio
            entries = cpio(_ramdisk_bytes(mine[ramdisk]["data"]))
            self.assertGreater(len(entries), 1000, "rootfs cpio looks truncated")
            self.assertIn("bin/sh", entries)


if __name__ == "__main__":
    unittest.main(verbosity=2)
