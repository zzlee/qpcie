"""Run against a real routed candidate; mutate private report copies, never DCPs."""
from pathlib import Path
import os
import re
import shutil
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'scripts'))
from check_sc7f0_full_profile import check


@unittest.skipUnless(os.environ.get('SC7F0_ROUTED_CANDIDATE'),'real routed candidate not selected')
class RoutedProfileMutations(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='sc7f0-profile-mutation-',dir=ROOT/'build')
        base=Path(self.temp.name);self.directory=base/'candidate';self.directory.mkdir()
        original=Path(os.environ['SC7F0_ROUTED_CANDIDATE']).resolve()
        for name in ('cdc.rpt','timing_summary.rpt','check-timing.rpt','methodology.rpt','bus-skew.rpt','drc.rpt','ip_status.rpt','c2h-personality.rpt'):
            shutil.copy2(original/name,self.directory/name)
        for name in ('qpcie_zu4ev_card.srcs','qpcie_zu4ev_card.runs'):
            (self.directory/name).symlink_to(original/name,target_is_directory=True)
        logs=base/'candidate-logs';logs.mkdir()
        original_logs=original.parent/(original.name+'-logs')
        for name in ('SOURCE_RTL.sha256','SOURCE_BUILD.sha256','impl-console.log'):
            shutil.copy2(original_logs/name,logs/name)
        (logs/'source').symlink_to(original_logs/'source',target_is_directory=True)
        self.logs=logs
        self.evidence=Path(os.environ['SC7F0_ROUTED_EVIDENCE']).resolve()
        self.safety=Path(os.environ['SC7F0_ROUTED_SAFETY']).resolve()

    def tearDown(self):self.temp.cleanup()

    def result(self):
        return check(self.directory,self.evidence,
            '/home/zzlee/qpcie/build/sc7f0-audio-doorbell-26102702-r1/fpga/cdc.rpt',
            '/home/zzlee/qpcie/build/qpcie_zu4ev_hdmi_proj/qpcie_zu4ev_card.srcs/sources_1/ip',self.safety)

    def mutate(self,file,old,new):
        p=self.directory/file;t=p.read_text();self.assertIn(old,t);p.write_text(t.replace(old,new))

    def test_real_positive_candidate(self):
        r=self.result();self.assertTrue(r['pass_gate'],r['errors'])
        self.assertFalse(r['zero_warning_claim'])

    def test_negative_setup(self):
        self.mutate('timing_summary.rpt','0.671','-0.001')
        self.assertFalse(self.result()['pass_gate'])

    def test_negative_hold(self):
        self.mutate('timing_summary.rpt','0.010','-0.001')
        self.assertFalse(self.result()['pass_gate'])

    def test_unknown_high_io_endpoint(self):
        self.mutate('check-timing.rpt','hdmi_rx_5v_det','unreviewed_video_data')
        self.assertFalse(self.result()['pass_gate'])

    def test_unreviewed_multibit_crossing(self):
        self.mutate('cdc.rpt','u_ps_capture/u_regs/u_state/','u_ps_capture/u_regs/new_bus/')
        self.assertFalse(self.result()['pass_gate'])

    def test_unsupported_cdc_severity(self):
        p=self.directory/'cdc.rpt';p.write_text(p.read_text()+'\nCDC-99 Error 1 unknown crossing\n')
        with self.assertRaises(ValueError):self.result()

    def test_missing_gray_hook(self):
        p=self.logs/'impl-console.log';p.write_text(p.read_text().replace('SC7F0_CAPTURE_GRAY_CONSTRAINTS_PASS','REMOVED'))
        self.assertFalse(self.result()['pass_gate'])

    def test_snapshot_manifest_cannot_be_empty(self):
        (self.logs/'SOURCE_RTL.sha256').write_text('')
        with self.assertRaises(ValueError):self.result()

    def test_new_methodology_critical(self):
        self.mutate('methodology.rpt','ULMTCS-1','UNREVIEWED-1')
        self.assertFalse(self.result()['pass_gate'])

    def test_same_count_drc_with_different_memory_is_not_approved(self):
        self.mutate('drc.rpt','u_audio_stream_engine_ch0','unreviewed_fifo')
        self.assertFalse(self.result()['pass_gate'])

    def test_non_purchased_hdmi_license_cannot_pass(self):
        self.mutate('ip_status.rpt','Purchased','Evaluation')
        self.assertFalse(self.result()['pass_gate'])

    def test_forbidden_tx_hardware_cannot_be_present(self):
        self.mutate('c2h-personality.rpt','ABSENT u_hdmi_tx_ss 0','ABSENT u_hdmi_tx_ss 1')
        self.assertFalse(self.result()['pass_gate'])

    def test_evidence_bound_to_another_dcp_cannot_pass(self):
        evidence=Path(self.temp.name)/'different-evidence';evidence.mkdir()
        text=(self.evidence/'netlist.tsv').read_text()
        text=re.sub(r'(?m)^CHECKPOINT\t[^\n]+','CHECKPOINT\t/another/checkpoint.dcp\t'+'0'*64,text)
        (evidence/'netlist.tsv').write_text(text);self.evidence=evidence
        with self.assertRaises(ValueError):self.result()


if __name__=='__main__':unittest.main()
