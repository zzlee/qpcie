"""The register bank and generated dual-clock wrapper must never drift.

Beyond byte equality, this pins the *classification* that build
vcu-release-26111103-r1 lost: the Packet DMA counters live in the same clock
domain as the PS register bank, so they must reach the bank directly.  Routing
them through qpcie_status_cdc created 296 CDC-13 critical paths, and also made a
64-bit counter pair non-atomic because the async FIFO snapshots one word per
write and the two halves leave on two different reads.
"""
import importlib.util
import re
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GENERATOR = ROOT / 'scripts/generate_sc7f0_csr_cdc.py'
WRAPPER = ROOT / 'rtl/qpcie_csr_reg_space.v'
BANK = ROOT / 'rtl/axil_reg_space.v'
DUALPATH = ROOT / 'rtl/sc7f0_dualpath.v'
BOARD = ROOT / 'rtl/zu4ev_pcie_card_top.v'
DMA_TOP = ROOT / 'rtl/custom_pcie_dma_top.v'

PKT_PORTS = ['in_pkt_submit_cnt', 'in_pkt_done_cnt', 'in_pkt_err_cnt',
             'in_pkt_msi_cnt', 'in_pkt_bytes_lo', 'in_pkt_bytes_hi',
             'in_pkt_fsm_state', 'in_pkt_last_len',
             'in_pkt_last_pts_lo', 'in_pkt_last_pts_hi']


def load_generator():
    spec = importlib.util.spec_from_file_location('csr_cdc_gen', GENERATOR)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class CsrWrapperTest(unittest.TestCase):
    def test_generated_wrapper_matches_authoritative_bank(self):
        result = subprocess.run(
            [sys.executable, str(GENERATOR), '--check'],
            cwd=ROOT, capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_same_domain_pkt_telemetry_bypasses_the_status_cdc(self):
        text = WRAPPER.read_text()
        status = re.search(r'\.src_status\(\{(.*?)\}\)', text, re.S)
        self.assertIsNotNone(status, 'u_status src_status bundle not found')
        for port in PKT_PORTS:
            with self.subTest(port=port):
                self.assertNotIn(port, status.group(1),
                                 f'{port} is produced in the bank clock domain; '
                                 'crossing it on qpcie_status_cdc is the CDC-13 regression')
                # Must be wired straight to the authoritative bank instance.
                self.assertIn(f'.{port}({port})', text,
                              f'{port} must connect directly to u_bank')

    def test_status_width_matches_the_domain_audit(self):
        # 320 bits of Packet DMA telemetry are LOCAL, so the transported status
        # word is 1743 bits (2063 was the misclassified width).
        text = WRAPPER.read_text()
        match = re.search(r'qpcie_status_cdc #\(\.WIDTH\((\d+)\)\) u_status', text)
        self.assertIsNotNone(match)
        self.assertEqual(int(match.group(1)), 1743,
                         'WIDTH moved; re-audit every src_status member domain first')
        self.assertNotIn('2063', text)

    def test_domain_claim_is_backed_by_the_producing_always_block(self):
        # LOCAL means "same clock as the bank clk".  Re-prove it from RTL rather
        # than trusting the comment: the counters are written on csr_clk and the
        # board drives csr_clk from pl_clk0, which is what u_axil_reg_space gets
        # as .clk.
        self.assertRegex(DUALPATH.read_text(),
                         r'always @\(posedge csr_clk\)[\s\S]{0,2000}reg_pkt_submit_cnt')
        self.assertRegex(BOARD.read_text(),
                         r'u_dualpath[\s\S]{0,4000}\.csr_clk\s*\(\s*pl_clk0\s*\)')
        self.assertRegex(DMA_TOP.read_text(),
                         r'u_axil_reg_space[\s\S]{0,200}\.clk\s*\(\s*pl_clk0\s*\)')

    def test_local_input_names_must_exist_in_the_bank(self):
        gen = load_generator()
        bank = BANK.read_text()
        for name in gen.LOCAL_INPUTS:
            with self.subTest(name=name):
                self.assertRegex(bank, r'input\s+(?:wire\s+|reg\s+)?(?:\[[^]]+\]\s*)?'
                                 + re.escape(name) + r'\b')
        for name in gen.LOCAL_OUTPUTS | set(gen.UPGRADE):
            with self.subTest(name=name):
                self.assertRegex(bank, r'output\s+(?:wire\s+|reg\s+)?(?:\[[^]]+\]\s*)?'
                                 + re.escape(name) + r'\b')

    def test_a_local_claim_on_a_wrong_direction_is_rejected(self):
        gen = load_generator()
        original = set(gen.LOCAL_INPUTS)
        try:
            # An output name parked in LOCAL_INPUTS would silently drop a real
            # cross-domain control; the generator must refuse to generate.
            gen.LOCAL_INPUTS = original | {'out_hdmi_tx_ctrl'}
            with self.assertRaises(AssertionError):
                gen.generate()
        finally:
            gen.LOCAL_INPUTS = original

    def test_a_stale_local_name_is_rejected(self):
        gen = load_generator()
        original = set(gen.LOCAL_INPUTS)
        try:
            gen.LOCAL_INPUTS = original | {'in_pkt_submit_cntx'}
            with self.assertRaises(AssertionError):
                gen.generate()
        finally:
            gen.LOCAL_INPUTS = original

    def test_offline_bar0_semantics_are_declared_not_implied(self):
        # The LOCAL classification changes what BAR0 reads while the link is
        # down.  That must be written down, not discovered later.
        text = GENERATOR.read_text()
        self.assertIn('csr_online', text)
        self.assertIn('0xC0', text,
                      'offline BAR0 read semantics for the LOCAL pkt counters '
                      'must be documented in the generator')


if __name__ == '__main__':
    unittest.main()
