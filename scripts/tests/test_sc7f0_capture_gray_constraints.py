"""Fail-closed Gray constraint hook checks; real routed diagnostic is separate."""
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HOOK = ROOT / "scripts/check_sc7f0_capture_gray.tcl"
MODEL = r'''
set mode [lindex $argv 0]
proc get_cells {args} {
    global mode
    set count 64
    if {$mode eq "missing_cell"} {set count 63}
    set result {}
    for {set i 0} {$i < $count} {incr i} {lappend result cell$i}
    return $result
}
proc get_timing_paths {args} {
    global mode
    set count 64
    if {$mode eq "missing_path"} {set count 63}
    set result {}
    for {set i 0} {$i < $count} {incr i} {lappend result $i}
    return $result
}
proc get_property {property path} {
    global mode
    if {$mode eq "duplicate"} {set path 0}
    switch $property {
        STARTPOINT_PIN {return "u_ps_capture/u_tap/gray_q_reg\[$path\]/C"}
        ENDPOINT_PIN {
            if {$mode eq "wrong_bit"} {set path [expr {($path+1)%64}]}
            return "u_ps_capture/u_regs/u_time/stage0_reg\[$path\]/D"
        }
        LOGIC_LEVELS {return [expr {$mode eq "logic" ? 1 : 0}]}
        REQUIREMENT {return [expr {$mode eq "ignored" ? 0.002 : 6.000}]}
        default {error "Unexpected property $property"}
    }
}
source [lindex $argv 1]
'''


class GrayConstraintTest(unittest.TestCase):
    def run_hook(self, mode):
        with tempfile.TemporaryDirectory(prefix="sc7f0-gray-") as tmp:
            model = Path(tmp) / "model.tcl"
            model.write_text(MODEL)
            return subprocess.run(["tclsh", str(model), mode, str(HOOK)],
                                  capture_output=True, text=True)

    def test_exact_128_direct_paths(self):
        result = self.run_hook("ok")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("SC7F0_CAPTURE_GRAY_CONSTRAINTS_PASS", result.stdout)
        self.assertEqual(result.stdout.count("SC7F0_GRAY_ENDPOINTS_PASS"), 2)

    def test_missing_overridden_or_unsafe_paths_fail(self):
        for mode in ("missing_cell", "missing_path", "wrong_bit", "logic", "ignored", "duplicate"):
            with self.subTest(mode=mode):
                result = self.run_hook(mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("SC7F0_CAPTURE_GRAY_CONSTRAINTS_PASS", result.stdout)

    def test_xdc_has_only_supported_unrolled_commands(self):
        xdc = (ROOT / "constraints/sc7f0_capture_gray.xdc").read_text()
        commands = [line.split()[0] for line in xdc.splitlines()
                    if line.strip() and not line.lstrip().startswith("#")]
        self.assertTrue(set(commands) <= {"set", "set_max_delay", "set_bus_skew"})
        self.assertEqual(commands.count("set_max_delay"), 2)
        self.assertEqual(commands.count("set_bus_skew"), 2)


if __name__ == "__main__":
    unittest.main()
