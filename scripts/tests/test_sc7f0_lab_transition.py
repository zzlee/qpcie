import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from sc7f0_lab_transition import classify, TARGET_MANIFEST


def evidence(boot, image):
    script = "14c14ececc4b35eb6ac10253f06a0f3dad10b7750d7283a7892676288df3bad6"
    return [f"{h}  /run/media/BOOT-mmcblk0p1/{n}" for n, h in
            (("BOOT.BIN", boot), ("image.ub", image), ("boot.scr", script))]


class TransitionTests(unittest.TestCase):
    source = evidence("24d83c6cd95cab2d1731c53fd55fbc8c251cedfd0cadcc216af504163c1722b9",
                      "d5b79309d7c334466dc4581158f1b2e903db2fcc4ba83139933d9bd5b3d6cd75")
    old = evidence("3851cdc9c4b9ca43de20c7fe59a970f6c2fab44af10968a726eb264bb245c06b",
                   "f5ab6f3f07f05666f53a49c8cb65ca22d6dcce60900654732e39b5c73962a999")

    def test_full_chain(self):
        self.assertEqual("full-boot-chain", classify(TARGET_MANIFEST, "26112573",
                                                     "26112573", self.source))

    def test_unchanged_pl(self):
        self.assertEqual("ps-only", classify(TARGET_MANIFEST,
            "vcud:9d76fc87bf92ebecc056521fbbeefbac092e7302aea6ffe5bf294221db77d6d0",
            "26112419", self.old))

    def test_refusals(self):
        for manifest, ps, pl, hashes in [
            ("0"*64, "26112573", "26112573", self.source),
            (TARGET_MANIFEST, "26112572", "26112573", self.source),
            (TARGET_MANIFEST, "26112573", "26112572", self.source),
            (TARGET_MANIFEST, "26112573", "26112419", self.source),
            (TARGET_MANIFEST, "26112573", "26112573", self.old),
            (TARGET_MANIFEST, "26112573", "26112573", self.source[:-1]),
            (TARGET_MANIFEST, "26112573", "26112573", self.source + self.source[:1]),
            (TARGET_MANIFEST, "26112573", "26112573", self.old[:1] + self.source[1:]),
        ]:
            with self.subTest(ps=ps, pl=pl, hashes=hashes, manifest=manifest):
                with self.assertRaises(ValueError):
                    classify(manifest, ps, pl, hashes)
