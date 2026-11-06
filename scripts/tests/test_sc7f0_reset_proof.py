"""Actual routed-R5 fixture plus fail-closed truth-table/connectivity mutations."""
from copy import deepcopy
from pathlib import Path
import unittest
from scripts.sc7f0_reset_proof import parse_evidence, prove

FIXTURE = Path(__file__).parent / 'fixtures/sc7f0_reset_r5.tsv'

class ResetProofTest(unittest.TestCase):
    def evidence(self):
        return parse_evidence(FIXTURE.read_text())

    def test_25_actual_cones_exhaustive_or_truth_tables(self):
        proof = prove(*self.evidence())
        self.assertEqual(len(proof), 25)
        self.assertEqual(sum(x['truth_combinations'] for x in proof.values()), 276)

    def test_reset_assertion_xor_or_wrong_polarity_fails(self):
        for init in ("16'h6996", "16'hFFFF", "16'h0000"):
            with self.subTest(init=init):
                e = self.evidence()
                root = next(iter(e[1].values()))[0]
                e[0][root][3] = init
                with self.assertRaises(ValueError):
                    prove(*e)

    def test_data_signal_cannot_be_a_reset_request(self):
        e = self.evidence()
        root = next(iter(e[1].values()))[0]
        def corrupt(net):
            r = e[0][net]
            if r[0] == 'TERM':
                r[2] = 'payload_valid_reg/Q'
                return True
            return r[0] == 'LUT' and any(corrupt(n) for n in r[4:])
        self.assertTrue(corrupt(root))
        with self.assertRaises(ValueError):
            prove(*e)

    def test_ce_constant_first_d_and_release_chain(self):
        for bit, field in ((0, 0), (0, 1), (2, 0)):
            with self.subTest(bit=bit, field=field):
                e = self.evidence(); target = next(iter(e[1]))
                e[2][(target, bit)][field] = next(n for n,r in e[0].items() if r[0]=='CONST' and r[2]=='VCC') if field==0 else next(n for n,r in e[0].items() if r[0]=='CONST' and r[2]=='GND')
                with self.assertRaises(ValueError):
                    prove(*e)

    def test_probe_must_not_drive_control(self):
        e = self.evidence(); e[3][25] = ['dma_enable_reg/D']
        with self.assertRaises(ValueError):
            prove(*e)

    def test_missing_stage_port_or_complete_marker(self):
        e = self.evidence(); del e[2][next(iter(e[2]))]
        with self.assertRaises(ValueError): prove(*e)
        e = self.evidence(); e[4]['hdmi_rx_5v_det'][1] = 'A13'
        with self.assertRaises(ValueError): prove(*e)
        with self.assertRaises(ValueError):
            parse_evidence(FIXTURE.read_text().replace('END\t25', 'END\t24'))

if __name__ == '__main__': unittest.main()
