import importlib.util
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
with patch.object(sys, "path", [str(SCRIPTS)] + sys.path):
    spec = importlib.util.spec_from_file_location("av_preview", SCRIPTS / "sc7f0_av_preview.py")
    av = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(av)


def healthy():
    return dict(errors=[], warnings=[], eos=True, pcm_alignment_errors=0,
                audio_discont_buffers=1, audio_pts_jumps=0, audio_missing_pts=0,
                audio_pts_duration_error_ns=0,
                video_rendered=600, audio_frames=480000,
                video_source_fps=60, video_render_fps=60, audio_capture_fps=48000,
                dma_drops_before=0, dma_drops_after=0)


class AVTests(unittest.TestCase):
    def test_real_sources_common_clock_and_no_software_video_transform(self):
        s = av.pipeline_description("/dev/video0", "hw:CARD=QPCIeAudio0,DEV=1", 3840, 2160)
        for part in ("provide-clock=false use-driver-timestamps=false", "slave-method=skew",
                     "use-driver-timestamps=false slave-method=none",
                     "format=S32LE,rate=48000,channels=2", "format=NV12,width=3840,height=2160"):
            self.assertIn(part, s)
        for part in ("audiotestsrc", "fakesink", "videoconvert", "videoscale", "slave-method=resample"):
            self.assertNotIn(part, s)

    def test_actual_continuous_transport(self):
        self.assertTrue(av.transport_ok(healthy()))

    def test_stalled_branch_is_not_long_run_acceptance(self):
        for key, value in (("video_source_fps", 0.1), ("video_render_fps", 0.1),
                           ("audio_capture_fps", 1000)):
            s = healthy(); s[key] = value
            self.assertFalse(av.transport_ok(s), key)

    def test_pts_gap_not_hidden_by_discont_or_eos(self):
        self.assertLess(abs(av.audio_pts_delta(0, 512, 10666667)), 2)
        self.assertGreater(av.audio_pts_delta(0, 512, 21333333), 10000000)
        self.assertLess(av.audio_pts_delta(10666667, 512, 10666667), -10000000)

    def test_unknown_drops_never_pass(self):
        s = healthy(); s["dma_drops_before"] = s["dma_drops_after"] = None
        self.assertFalse(av.transport_ok(s))

    def test_integrity_warnings_xruns_eos_and_drops_fail(self):
        for key, value in (("warnings", ["Dropped samples"]), ("errors", ["failed"]),
                           ("eos", False), ("pcm_alignment_errors", 1),
                           ("audio_discont_buffers", 2), ("dma_drops_after", 1),
                           ("audio_pts_jumps", 1), ("audio_missing_pts", 1),
                           ("audio_pts_duration_error_ns", 1000000000),
                           ("audio_pts_duration_error_ns", None)):
            s = healthy(); s[key] = value
            self.assertFalse(av.transport_ok(s), key)


if __name__ == "__main__":
    unittest.main()
