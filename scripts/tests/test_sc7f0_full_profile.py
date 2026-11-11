"""Explicit full-profile CDC recognition and fail-closed mutations."""
from copy import deepcopy
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from check_sc7f0_full_profile import classify, io_ports
from sc7f0_reset_proof import parse_evidence, prove


class FullProfileTest(unittest.TestCase):
    def row(self, **kw):
        row = dict(rule='CDC-15', severity='Warning', source_clock='a', destination_clock='b', source='', destination='')
        row.update(kw)
        return row

    def test_only_explicit_fifo_and_exact_ram_to_output_shape(self):
        root='u_ps_capture/u_regs/u_config/u_fifo/gnuram_async_fifo.xpm_fifo_base_inst'
        row=self.row(source=root+'/gen_sdpram.xpm_memory_base_inst/gen_wr_a.gen_word_narrow.mem_reg_0_15_0_13/RAMA/CLK',
                     destination=root+'/gen_sdpram.xpm_memory_base_inst/gen_rd_b.gen_rd_b_synth_template.gen_rf_narrow_pipe.doutb_reg_reg[0]/D')
        self.assertIsNotNone(classify(row,set(),{}))
        for old,new in (('u_config','unreviewed_fifo'),('RAMA/CLK','data_reg/C'),('doutb_reg_reg[0]','owner_state_reg')):
            r={k:v.replace(old,new) for k,v in row.items()}
            self.assertIsNone(classify(r,set(),{}))

    def test_reset_requires_truth_proof_and_named_request(self):
        e=(Path(__file__).parent/'fixtures/sc7f0_reset_r5.tsv').read_text()
        proof=prove(*parse_evidence(e));dest=next(iter(proof))
        source=proof[dest]['terms'][0][:-1]+'C'
        row=self.row(rule='CDC-10',severity='Critical',source=source,destination=dest)
        self.assertIsNotNone(classify(row,set(),proof))
        self.assertIsNone(classify(row,set(),{}))
        row['source']='unreviewed_data_reg/C'
        self.assertIsNone(classify(row,set(),proof))

    def test_no_arbitrary_critical_or_multibit_waiver(self):
        for rule,severity in (('CDC-10','Critical'),('CDC-12','Critical'),('CDC-6','Warning')):
            self.assertIsNone(classify(self.row(rule=rule,severity=severity,source='a/C',destination='b/D'),set(),{}))

    def test_gray_only_two_explicit_64bit_samplers(self):
        r=self.row(rule='CDC-6',source='u_ps_capture/u_tap/gray_q_reg[63:0]/C',
                   destination='u_ps_capture/u_regs/u_time/stage0_reg[63:0]/D')
        self.assertIsNotNone(classify(r,set(),{}))
        r['destination']=r['destination'].replace('stage0','stage4')
        self.assertIsNone(classify(r,set(),{}))

    def test_frozen_vendor_match_does_not_accept_other_logic(self):
        from check_sc7f0_full_profile import identity
        r=self.row(rule='CDC-26',source='new_fifo/mem/C',destination='new_fifo/out/D')
        self.assertIsNone(classify(r,{identity(r)},{}))

    def test_unsupported_severity_and_info_rule_fail(self):
        self.assertIsNone(classify(self.row(rule='CDC-99',severity='Error'),set(),{}))
        self.assertIsNone(classify(self.row(rule='CDC-1',severity='Info'),set(),{}))

    def test_gpio_inventory_is_complete_not_summary_only(self):
        c='\n5. checking no_input_delay (1)\n-----\n There are 1 input ports with no input delay specified. (HIGH)\n\nhdmi_rx_5v_det\n\n6. checking no_output_delay (0)\n'
        self.assertEqual(io_ports(c,5,'no_input_delay',6),{'hdmi_rx_5v_det'})
        with self.assertRaises(ValueError):io_ports(c.replace('There are 1','There are 2'),5,'no_input_delay',6)


if __name__=='__main__':unittest.main()
