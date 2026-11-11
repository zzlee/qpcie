"""Actual quiesce loop under modeled drain failures, not real DMA validation."""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TAP = ROOT / "petalinux/qpcie-zu4ev/project-spec/meta-user/recipes-kernel/linux/linux-xlnx/sc7f0-frame-tap.c"
PREFIX = r'''
#define _DEFAULT_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
struct sc7f0_frame_tap { int sd, dev, start_unconfirmed; };
#define READ_ONCE(value) (value)
static int mode, attempts, warnings, waits;
static int tap_stream(int *sd, int on) {
    (void)sd;
    if (on) abort();
    ++attempts;
    if (mode == 5 && attempts == 3)
        ((struct sc7f0_frame_tap *)sd)->start_unconfirmed = 0;
    if (mode == 3) return -110;
    if (mode == 2 && attempts <= 5) return attempts % 2 ? -16 : -110;
    return 0;
}
#define dev_err_ratelimited(...) do { ++warnings; } while (0)
static void msleep(unsigned int ms) {
    if (ms != 100) abort();
    ++waits;
    if (mode == 3 || mode == 4) usleep(1000);
}
'''
SUFFIX = r'''
int main(int argc, char **argv) {
    struct sc7f0_frame_tap tap = {0};
    if (argc != 2) return 2;
    mode = atoi(argv[1]);
    tap.start_unconfirmed = (mode == 4 || mode == 5);
    puts("ENTER"); fflush(stdout);
    sc7f0_tap_quiesce(mode ? &tap : NULL);
    printf("TERMINATE_AND_RETURN_BUFFERS attempts=%d warnings=%d waits=%d\n",
           attempts, warnings, waits);
    return 0;
}
'''


class TapDrainTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="sc7f0-drain-")
        temp = Path(cls.temp.name)
        source = TAP.read_text()
        start = source.index("void sc7f0_tap_quiesce(")
        end = source.index("EXPORT_SYMBOL_GPL(sc7f0_tap_quiesce)", start)
        (temp / "model.c").write_text(PREFIX + source[start:end] + SUFFIX)
        cls.binary = temp / "model"
        subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror",
                        str(temp / "model.c"), "-o", str(cls.binary)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def run_mode(self, mode):
        return subprocess.run([str(self.binary), str(mode)], text=True,
                              capture_output=True, timeout=2, check=True).stdout

    def test_no_tap_preserves_legacy_path(self):
        self.assertIn("attempts=0 warnings=0 waits=0", self.run_mode(0))

    def test_clean_drain_needs_no_retry(self):
        self.assertIn("attempts=1 warnings=0 waits=0", self.run_mode(1))

    def test_busy_and_timeout_do_not_release_early(self):
        self.assertIn("attempts=6 warnings=5 waits=5", self.run_mode(2))

    def test_vipp_patch_orders_drain_before_teardown(self):
        kernel = Path(os.environ.get("SC7F0_TEST_KERNEL_SOURCE",
            "/home/zzlee/qpcie/petalinux/qpcie-zu4ev/build/tmp/work-shared/"
            "zynqmp-generic-xczu4ev/kernel-source"))
        patch = TAP.parent / "0001-sc7f0-vipp-frame-tap.patch"
        with tempfile.TemporaryDirectory(prefix="sc7f0-patch-drain-") as tmp:
            stage = Path(tmp)
            for name in ("xilinx-dma.c", "xilinx-dma.h", "Kconfig", "Makefile"):
                relative = Path("drivers/media/platform/xilinx") / name
                (stage / relative).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(kernel / relative, stage / relative)
            with patch.open() as source:
                subprocess.run(["patch", "--batch", "-p1", "-d", tmp], stdin=source,
                               check=True, capture_output=True, text=True)
            text = (stage / "drivers/media/platform/xilinx/xilinx-dma.c").read_text()
            begin = text.index("static void xvip_dma_stop_streaming(")
            end = text.index("\nstatic ", begin + 5)
            stop = text[begin:end]
            self.assertLess(stop.index("sc7f0_tap_quiesce"), stop.index("xvip_pipeline_set_stream"))
            self.assertLess(stop.index("xvip_pipeline_set_stream"), stop.index("dmaengine_terminate_all"))
            self.assertLess(stop.index("dmaengine_terminate_all"), stop.index("vb2_buffer_done"))
            begin = text.index("static int xvip_dma_start_streaming(")
            unwind = text[begin:text.index("static void xvip_dma_stop_streaming(")]
            unwind = unwind[unwind.index("\nerror:"):]
            self.assertLess(unwind.index("sc7f0_tap_quiesce"), unwind.index("dmaengine_terminate_all"))
            self.assertLess(unwind.index("dmaengine_terminate_all"), unwind.index("vb2_buffer_done"))

    def test_posted_start_must_be_observed_before_release(self):
        self.assertIn("attempts=3 warnings=2 waits=2", self.run_mode(5))

    def test_stuck_drain_or_unconfirmed_start_never_releases(self):
        # Mode4 reports idle but a prior ENABLE is still unconfirmed: no
        # sequence ACK exists in R5, so a stale idle snapshot is not proof.
        for mode in (3, 4):
            with self.subTest(mode=mode):
                with self.assertRaises(subprocess.TimeoutExpired) as caught:
                    subprocess.run([str(self.binary), str(mode)], capture_output=True, timeout=0.2)
                self.assertIn(b"ENTER", caught.exception.stdout)
                self.assertNotIn(b"TERMINATE_AND_RETURN_BUFFERS", caught.exception.stdout)


if __name__ == "__main__":
    unittest.main()
