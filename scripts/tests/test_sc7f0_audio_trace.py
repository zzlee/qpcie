import importlib.util
from pathlib import Path
import struct
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("trace", ROOT/"scripts/sc7f0_decode_audio_trace.py")
TRACE = importlib.util.module_from_spec(spec)
spec.loader.exec_module(TRACE)


def record(raw, tid, tick):
    return struct.pack("<II", raw, 0xA5000000 | tid << 16 | tick)


class TraceTest(unittest.TestCase):
    def test_original_bits_tid_wrap_and_parity(self):
        d = record(0x90000003,1,65535)+record(2,0,4)
        r = TRACE.decode(d)
        self.assertEqual(r["records"],2)
        self.assertEqual(r["cycle_sum_modulo16"],5)
        self.assertEqual(r["channels"][1]["invalid"],1)
        self.assertEqual(r["channels"][1]["first_words"],["90000003"])
        self.assertEqual(r["channels"][1]["parity_errors"],0)

    def test_marker_and_record_bounds(self):
        for d in (b"",bytes(7),bytes(8)):
            with self.subTest(d=d), self.assertRaises(ValueError):
                TRACE.decode(d)

    def test_channel_status_alignment(self):
        data=b""
        for n in range(384):
            pre=1 if n%192==0 else 2
            cbit=(0x02000000>>(n%192)&1) if n%192<32 else 0
            raw=pre | cbit<<30 | cbit<<31
            data+=record(raw,0,n*100&65535)
        r=TRACE.decode(data)
        c=r["channels"][0]
        self.assertEqual(c["cs_blocks"],2)
        self.assertEqual(c["cs"][0]["first32"],"02000000")
        self.assertEqual(c["block_frame_spacings"],{192:1})

    def test_invalid_is_not_silently_zeroed(self):
        r=TRACE.decode(record(0x11234562,0,0))
        self.assertEqual(r["channels"][0]["invalid"],1)
        self.assertEqual(r["channels"][0]["nonzero_payload"],1)


if __name__=="__main__":
    unittest.main()
