"""Offline policy for the accepted lab19 package. No device I/O.

The reviewed RELEASE.sha256 digest binds the entire target, including the
transport source, both version files, FPGA artifacts and four-file upgrade tar.
The 73 source hashes are from the offline-package manifest, NOT the SD root.
"""
import hashlib
import sys
from pathlib import Path


TARGET_MANIFEST = "1d3449c2ccf51f13b432ff2ff03577634b6ed476eba8d498ef87191a0e11683d"
BOOT19 = "3851cdc9c4b9ca43de20c7fe59a970f6c2fab44af10968a726eb264bb245c06b"
SCRIPT = "14c14ececc4b35eb6ac10253f06a0f3dad10b7750d7283a7892676288df3bad6"
SOURCES = {
    ("26112573", "26112573"): ("full-boot-chain",
        "24d83c6cd95cab2d1731c53fd55fbc8c251cedfd0cadcc216af504163c1722b9",
        "d5b79309d7c334466dc4581158f1b2e903db2fcc4ba83139933d9bd5b3d6cd75"),
    # Original release has no PS marker. Identify its rootfs by its measured
    # packaged encoder binary, in addition to PL and all three eMMC digests.
    ("vcud:9d76fc87bf92ebecc056521fbbeefbac092e7302aea6ffe5bf294221db77d6d0",
     "26112419"): ("ps-only", BOOT19,
        "f5ab6f3f07f05666f53a49c8cb65ca22d6dcce60900654732e39b5c73962a999"),
    ("26112501", "26112419"): ("same-release", BOOT19,
        "0eb4e17d3cb1c8e893038964336f13d7a18577e139b15aab422ae357e32a9287"),
}


def classify(manifest, ps, pl, measurements):
    if manifest != TARGET_MANIFEST or (ps, pl) not in SOURCES:
        raise ValueError("unreviewed target manifest or live source PS/PL")
    mode, boot, image = SOURCES[ps, pl]
    expected = {f"{digest}  /run/media/BOOT-mmcblk0p1/{name}"
                for name, digest in (("BOOT.BIN", boot), ("image.ub", image), ("boot.scr", SCRIPT))}
    if len(measurements) != 3 or set(measurements) != expected:
        raise ValueError("source eMMC differs from the attested boot chain")
    return mode


if __name__ == "__main__":
    manifest = hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest()
    if manifest != TARGET_MANIFEST:
        sys.exit("unreviewed lab release manifest")
    if len(sys.argv) == 2:
        sys.exit(0)
    ps, pl, hashes = sys.argv[2:]
    try:
        print(classify(manifest, ps, pl, Path(hashes).read_text().splitlines()))
    except ValueError as exc:
        sys.exit(str(exc))
