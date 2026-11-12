#!/usr/bin/env bash
# ============================================================================
# One-command reset / probe RTL validation gate.  SIMULATION ONLY.
#
#   ./scripts/run_sc7f0_reset_probe_validation.sh [output-dir]
#
# What it runs
#   1. scripts/tests/test_sc7f0_reset_probe_structure.py - the always-runnable
#      static contract checks (no simulator, no vendor library needed).
#   2. scripts/sim_sc7f0_reset_cdc.tcl                   - the real XSim gate
#      (tb/sc7f0_reset_cdc_tb.sv S0..S7 and
#       tb/sc7f0_hdmi_probe_async_levels_tb.sv P0..P8) elaborated against the
#      shipped xpm_cdc / xpm_fifo / xpm_memory models.  There is no local XPM
#      stub in this repository, and test_no_local_xpm_stub_can_fake_the_contract
#      keeps it that way.
#
# What it never does
#   no synthesis, no implementation, no PetaLinux, no package, no deploy, no
#   flash, no board access, no driver load, no git add/commit/push.  Everything
#   it writes lives under the output directory (default
#   build/reset-probe-validation-<stamp>/), which is git-ignored.
#
# Environment
#   VIVADO_SETTINGS   default /opt/Xilinx/Vivado/2023.2/settings64.sh
#                     (xvlog/xelab/xsim are NOT on the default PATH; they come
#                     from this file, they are not missing installs)
#   SC7F0_RESET_SIM_WAVE=1  also dump every signal and copy the .wdb out
# ============================================================================
set -u -o pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root" || exit 1

stamp="$(date +%y%m%d%H%M)"
out="${1:-$root/build/reset-probe-validation-$stamp}"
mkdir -p "$out/failed-attempts" "$out/sim" || exit 1

settings="${VIVADO_SETTINGS:-/opt/Xilinx/Vivado/2023.2/settings64.sh}"
status_struct=0
status_sim=1

echo "== reset/probe validation, output: $out"
{
    echo "== tool environment"
    date -Is
    if [ -r "$settings" ]; then
        # shellcheck disable=SC1090
        source "$settings"
        echo "settings=$settings"
    else
        echo "MISSING VIVADO SETTINGS: $settings"
    fi
    for t in xvlog xelab xsim vivado; do
        printf '%s=%s\n' "$t" "$(command -v "$t" || echo NOT_FOUND)"
    done
    command -v vivado >/dev/null && vivado -version 2>&1 | head -2
    echo "XILINX_VIVADO=${XILINX_VIVADO:-unset}"
} 2>&1 | tee "$out/environment.txt"

echo "-- 1/2 static reset/probe contract tests"
python3 scripts/tests/test_sc7f0_reset_probe_structure.py -v > "$out/structure-tests.log" 2>&1
status_struct=$?
tail -n 5 "$out/structure-tests.log"

echo "-- 2/2 XSim reset/probe gate (real XPM models)"
if source "$settings" 2>/dev/null; then
    SC7F0_RESET_SIM_OUT="$out/sim" \
        vivado -mode batch -notrace -nojournal -log reset-sim.log -jou reset-sim.jou \
        -source scripts/sim_sc7f0_reset_cdc.tcl 2>&1 | tee "$out/reset-sim-stdout.log"
    status_sim=${PIPESTATUS[0]}
else
    echo "cannot source $settings; the XSim gate did not run" | tee -a "$out/reset-sim-stdout.log"
    echo "VIVADO_EXIT=127" >> "$out/reset-sim-stdout.log"
fi

# Keep the simulator's own transcripts next to the verdict.
simrun="$out/sim/sc7f0_reset_cdc_sim.sim/sim_1/behav/xsim"
for f in xvlog.log elaborate.log simulate.log; do
    [ -f "$simrun/$f" ] && cp -f "$simrun/$f" "$out/"
done
if [ "${SC7F0_RESET_SIM_WAVE:-0}" = "1" ]; then
    for w in "$simrun"/*.wdb; do
        [ -f "$w" ] && cp -f "$w" "$out/"
    done
fi

echo "== verdict"
echo "structure_tests_exit=$status_struct"
echo "simulation_exit=$status_sim"
grep -E "RESET_CDC_TB_SUMMARY|RESET_CDC_TB_EVIDENCE|PROBE_LEVEL_SUMMARY|RESET_CDC_SIM_TOP|RESET_CDC_SIM_EVIDENCE|RESET_CDC_SIM_VERDICT|RESET_CDC_SIM_GATE|PROBE_LEVEL_SIM_GATE" \
    "$out/reset-sim-stdout.log" | tee "$out/verdict.txt"
if [ "$status_struct" -eq 0 ] && [ "$status_sim" -eq 0 ]; then
    echo "RESET_PROBE_VALIDATION_PASS out=$out"
    exit 0
fi
echo "RESET_PROBE_VALIDATION_FAIL out=$out (structure=$status_struct sim=$status_sim)"
exit 1
