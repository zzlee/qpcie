#!/usr/bin/env bash
# ============================================================================
# Negative control for the reg_probe_pins[31:25] tap position.
#
#   ./scripts/check_sc7f0_probe_tap_mutation.sh [output-dir]
#
# Why this exists
#   rtl/sc7f0_hdmi_probe.v samples the seven foreign-domain diagnostic levels
#   with  chain <= {chain[1:0], src}, so the new sample enters [0] and the value
#   the register has to report is [2] (the third stage).  An earlier revision
#   tapped [0] while its comment, its testbench and the release notes all claimed
#   "third stage", and the testbench passed anyway because its P6 compared the
#   chain with the register that chain drives - satisfied by any tap.  A check
#   that cannot fail is not evidence.
#
# What it runs (three full XSim runs against the real XPM models)
#   control            shipped rtl/sc7f0_hdmi_probe.v   -> MUST PASS
#   tap_first_stage    [2] -> [0] in a build/ copy       -> MUST FAIL
#   tap_second_stage   [2] -> [1] in a build/ copy       -> MUST FAIL
# The control is what makes the two rejections mean something: it proves the
# harness elaborates and can report a pass, so a rejection is the mutation and
# not a broken runner.  The shipped RTL file is never modified and never
# restored-over; the mutants are throwaway copies under build/.
#
# Optional fourth run (documents the old vacuity)
#   --old-tb <file>    run tb/sc7f0_hdmi_probe_async_levels_tb.sv as it was
#                      BEFORE the expected-model rewrite against the
#                      tap_first_stage mutant.  It is expected to PASS, which is
#                      the vacuity being retracted; the script reports it and
#                      does not fail the run on it.
#
# It never runs synthesis, implementation, PetaLinux, packaging, deploy, flash,
# board access or any git write.
# ============================================================================
set -u -o pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root" || exit 1

stamp="$(date +%y%m%d%H%M)"
out=""
old_tb=""
while [ $# -gt 0 ]; do
    case "$1" in
        --old-tb) old_tb="${2:-}"; shift 2 ;;
        *) out="$1"; shift ;;
    esac
done
out="${out:-$root/build/probe-tap-mutation-$stamp}"
mkdir -p "$out" || exit 1

settings="${VIVADO_SETTINGS:-/opt/Xilinx/Vivado/2023.2/settings64.sh}"
src="rtl/sc7f0_hdmi_probe.v"
tb="tb/sc7f0_hdmi_probe_async_levels_tb.sv"
chains='rxss_tlast_sync|rxss_tuser_sync|rxss_tready_sync|rxss_tvalid_sync|phy_ch2_tvalid_sync|phy_ch1_tvalid_sync|phy_ch0_tvalid_sync'
status=0

echo "== probe tap mutation gate, output: $out"
[ -r "$settings" ] || { echo "MISSING VIVADO SETTINGS: $settings"; exit 1; }

# ---- build the mutants, and prove the mutation actually applied -------------
make_mutant() {   # $1 = stage to tap, $2 = name; prints the mutant path on stdout
    local stage="$1" name="$2" n
    local dir="$out/$name"
    mkdir -p "$dir" || return 1
    sed -E "s/(${chains})\[2\]/\1[${stage}]/g" "$src" > "$dir/sc7f0_hdmi_probe.v" || return 1
    n=$(grep -cE "(${chains})\[${stage}\]," "$dir/sc7f0_hdmi_probe.v")
    if [ "$n" != "7" ]; then
        echo "$name: expected 7 reg_probe_pins taps on [${stage}], found $n" >&2
        return 1
    fi
    if [ "$stage" != "2" ] && grep -qE "(${chains})\[2\]," "$dir/sc7f0_hdmi_probe.v"; then
        echo "$name: a [2] tap survived, the mutation is incomplete" >&2
        return 1
    fi
    diff -u "$src" "$dir/sc7f0_hdmi_probe.v" > "$dir/mutation.diff"
    echo "$name: 7 reg_probe_pins taps moved to [${stage}]" >&2
    echo "$dir/sc7f0_hdmi_probe.v"
}

run_case() {   # $1 = rtl file, $2 = tb file, $3 = name, $4 = expected (pass|fail)
    local rtl="$1" tbfile="$2" name="$3" expect="$4" log rc
    log="$out/$name.log"
    echo "-- $name (expected $expect): $rtl"
    ( export SC7F0_PROBE_RTL="$rtl" SC7F0_PROBE_TB="$tbfile" SC7F0_PROBE_SIM_OUT="$out/$name-sim"
      source "$settings" >/dev/null 2>&1 || exit 127
      vivado -mode batch -notrace -nojournal -log "$out/$name.vivado.log" \
             -source scripts/sim_sc7f0_probe_tap.tcl ) > "$log" 2>&1
    rc=$?
    grep -E "PROBE_TAP_SIM|PROBE_LEVEL_SUMMARY|CHECK_FAIL|^BAD " "$log" > "$out/$name.verdict.txt"
    # Prove the run really used this RTL/testbench (an env var that does not reach
    # vivado silently falls back to the shipped files, which would make every case
    # look like the control).
    if ! grep -q "PROBE_TAP_SIM rtl=$rtl tb=$tbfile" "$log"; then
        echo "   HARNESS_BROKEN: the run did not report the expected rtl/tb pair"
        status=1
    fi
    echo "   exit=$rc $(grep -o 'PROBE_LEVEL_SUMMARY.*' "$log" | tail -1)"
    if [ "$expect" = "pass" ] && [ "$rc" != "0" ]; then
        echo "   MUTATION_GATE_BROKEN: the control did not pass, so a rejection proves nothing"
        status=1
    elif [ "$expect" = "fail" ] && [ "$rc" = "0" ]; then
        echo "   MUTANT_NOT_REJECTED: the $name mutant passed the testbench"
        status=1
    else
        echo "   as expected"
    fi
}

control="$(make_mutant 2 control)" || exit 1
tap0="$(make_mutant 0 tap_first_stage)" || exit 1
tap1="$(make_mutant 1 tap_second_stage)" || exit 1

run_case "$control" "$tb" control pass
run_case "$tap0" "$tb" tap_first_stage fail
run_case "$tap1" "$tb" tap_second_stage fail

if [ -n "$old_tb" ] && [ -r "$old_tb" ]; then
    log="$out/old_tb_against_tap_first_stage.log"
    echo "-- documented vacuity: pre-rewrite testbench against the [0] tap"
    ( export SC7F0_PROBE_RTL="$tap0" SC7F0_PROBE_TB="$old_tb"
      export SC7F0_PROBE_SIM_OUT="$out/old_tb-sim"
      source "$settings" >/dev/null 2>&1 || exit 127
      vivado -mode batch -notrace -nojournal -log "$out/old_tb.vivado.log" \
             -source scripts/sim_sc7f0_probe_tap.tcl ) > "$log" 2>&1
    rc=$?
    grep -E "PROBE_TAP_SIM|PROBE_LEVEL_SUMMARY|CHECK_FAIL|^BAD " "$log" > "$out/old_tb_against_tap_first_stage.verdict.txt"
    echo "   exit=$rc (0 = the old testbench accepted a first-stage tap, which is the vacuity being retracted)"
    echo "   $(grep -o 'PROBE_LEVEL_SUMMARY.*' "$log" | tail -1)"
elif [ -n "$old_tb" ]; then
    echo "-- --old-tb $old_tb not readable, skipping the vacuity demonstration"
fi

echo "== verdict"
if [ "$status" = "0" ]; then
    echo "PROBE_TAP_MUTATION_GATE_PASS out=$out"
else
    echo "PROBE_TAP_MUTATION_GATE_FAIL out=$out"
fi
exit "$status"
