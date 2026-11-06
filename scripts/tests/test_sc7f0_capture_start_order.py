"""Startup admission must follow the complete downstream graph start."""
from pathlib import Path
import re
import unittest
ROOT=Path(__file__).resolve().parents[2]
PATCH=ROOT/'petalinux/qpcie-zu4ev/project-spec/meta-user/recipes-kernel/linux/linux-xlnx/0001-sc7f0-vipp-frame-tap.patch'
class CaptureStartOrder(unittest.TestCase):
    def test_credit_follows_graph_ready_and_preserves_unwind(self):
        text=PATCH.read_text()
        graph=text.index('ret = xvip_pipeline_set_stream(pipe, true);')
        credit=text.index('ret = sc7f0_tap_credit(dma->frame_tap, queued);')
        self.assertLess(graph,credit)
        added='\n'.join(x[1:] for x in text.splitlines() if x.startswith('+') and not x.startswith('+++'))
        self.assertIn('sc7f0_tap_quiesce(dma->frame_tap);',added)
        self.assertIn('xvip_pipeline_set_stream(pipe, false);',added)
    def test_metadata_error_is_reported_not_suppressed(self):
        driver=(PATCH.parent/'sc7f0-frame-tap.c').read_text()
        self.assertIn('flags=0x%08x',driver)
        self.assertIn('return flags ? -EIO : 0;',driver)
        self.assertIn('VB2_BUF_STATE_ERROR',PATCH.read_text())
if __name__=='__main__':unittest.main()
