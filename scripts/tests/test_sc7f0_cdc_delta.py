"""CDC inventory completeness/identity checks; never tests safety by category."""
import unittest
from scripts.audit_sc7f0_cdc_delta import inventory, parse_report

REPORT = """CDC-10  Critical  1  combinational synchronizer input
Source Clock: source_a
Destination Clock: dest_b
1 CDC-10 Critical description 4 False Path reset_a/C fifo/u_reset/arststages_ff_reg[0]/PRE
"""


class CdcDeltaTest(unittest.TestCase):
    def test_exact_baseline_does_not_approve(self):
        result, rows = inventory(REPORT, REPORT)
        self.assertEqual(result["exact_baseline_matches"], 1)
        self.assertFalse(rows[0]["approved"])
        self.assertFalse(result["deployment_authorized_by_this_report"])
        self.assertTrue(result["review_only"])

    def test_clock_and_path_identity_are_both_required(self):
        for old, new in (("source_a", "source_new"), ("reset_a/C", "reset_b/C")):
            with self.subTest(old=old):
                result, _ = inventory(REPORT.replace(old, new), REPORT)
                self.assertEqual(result["exact_baseline_matches"], 0)
                self.assertEqual(result["removed_baseline_paths"], 1)

    def test_duplicate_paths_keep_multiplicity(self):
        twice = REPORT.replace("Critical  1", "Critical  2") + REPORT.splitlines()[-1] + "\n"
        result, rows = inventory(twice, REPORT)
        self.assertEqual(len(rows), 2)
        self.assertEqual(result["exact_baseline_matches"], 1)

    def test_incomplete_and_malformed_reports_fail(self):
        for text in (REPORT.replace("Critical  1", "Critical  2"),
                     REPORT.replace("Destination Clock: dest_b\n", ""),
                     REPORT + "CDC-10 Critical 1 duplicated summary\n",
                     REPORT + "CDC-99 Error 1 unsafe crossing\n",
                     REPORT + "2 CDC-99 Error unsafe src/Q dest/D\n", ""):
            with self.subTest(text=text):
                with self.assertRaises(ValueError):
                    parse_report(text)

    def test_unknown_critical_is_not_folded_into_reset(self):
        result, rows = inventory(REPORT.replace("fifo/u_reset/arststages_ff_reg[0]/PRE", "payload/data_reg/D"), REPORT)
        self.assertEqual(rows[0]["review_category"], "UNCLASSIFIED_CRITICAL")
        self.assertFalse(rows[0]["approved"])


if __name__ == "__main__":
    unittest.main()
