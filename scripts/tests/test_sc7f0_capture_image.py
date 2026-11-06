"""Real-image audits and private-copy mutations; never execute ARM programs."""
from pathlib import Path
import os
import shutil
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'scripts'))
from check_sc7f0_capture_image import audit,node


class DtsNodeTest(unittest.TestCase):
    def test_nested_node_and_duplicate_refusal(self):
        d='\nvideo-capture { status = "okay"; ports { port@0 {}; }; };\n'
        self.assertIn('ports',node(d,'video-capture'))
        with self.assertRaises(AssertionError):node(d+d,'video-capture')


@unittest.skipUnless(os.environ.get('SC7F0_CAPTURE_RELEASE'),'real capture image not selected')
class CaptureImageMutations(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='capture-image-mutation-',dir=ROOT/'build')
        self.build=Path(self.temp.name)
        original=Path(os.environ['SC7F0_CAPTURE_RELEASE']).resolve()
        for folder in ('fpga','images','logs'):
            (self.build/folder).mkdir()
            for source in (original/folder).iterdir():
                if source.is_file():
                    target=self.build/folder/source.name
                    if source.name in ('kernel.config','kernel.System.map'):shutil.copy2(source,target)
                    else:target.symlink_to(source)

    def tearDown(self):self.temp.cleanup()

    def check(self):
        audit(self.build,ROOT/'petalinux/qpcie-zu4ev',Path(os.environ['SC7F0_CAPTURE_PS_BUILD']).resolve())

    def test_real_matching_image(self):self.check()

    def test_missing_capture_option_fails_despite_successful_peta_build(self):
        p=self.build/'images/kernel.config'
        p.write_text(p.read_text().replace('CONFIG_VIDEO_SC7F0_FRAME_TAP=y','# CONFIG_VIDEO_SC7F0_FRAME_TAP is not set'))
        with self.assertRaises(AssertionError):self.check()

    def test_missing_compiled_quiesce_symbol_fails(self):
        p=self.build/'images/kernel.System.map';p.write_text(p.read_text().replace(' T sc7f0_tap_quiesce',' T missing_quiesce'))
        with self.assertRaises(AssertionError):self.check()


if __name__=='__main__':unittest.main()
