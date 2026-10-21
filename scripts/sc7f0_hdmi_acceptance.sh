#!/usr/bin/env bash
# SC7F0 HDMI06 acceptance runbook. Runs on the PCIe HOST, never flashes.
#
#   sudo ./sc7f0_hdmi_acceptance.sh [output-dir]
#
# It records evidence for: firmware/driver identity, RX telemetry, TPG
# regression, real HDMI capture, and repeated STREAMON/STREAMOFF. Any step that
# cannot run is reported as FAIL/BLOCKED; nothing is reported as PASS unless the
# tool actually returned success.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-/tmp/sc7f0-hdmi-acceptance-$(date +%Y%m%d-%H%M%S)}"
BDF="$(lspci -Dn -d 12ab:e380 2>/dev/null | awk '{print $1; exit}')"
TOOLS="${SC7F0_TOOLS:-$HERE}"
V4L2_APP="${V4L2_APP:-$TOOLS/v4l2_test_app}"
HDMI_CTL="${HDMI_CTL:-$TOOLS/qpcie_hdmi_ctl}"
UPGRADE="${UPGRADE:-$TOOLS/qpcie_upgrade}"

mkdir -p "$OUT"
SUMMARY="$OUT/summary.txt"
: > "$SUMMARY"

say()  { printf '%s\n' "$*" | tee -a "$SUMMARY"; }
pass() { say "PASS    $*"; }
fail() { say "FAIL    $*"; FAILED=1; }
skip() { say "BLOCKED $*"; FAILED=1; }
FAILED=0

run() { # run <name> <cmd...>
    local name="$1"; shift
    local log="$OUT/$name.log"
    say "---- $name :: $*"
    if "$@" >"$log" 2>&1; then
        pass "$name"
        return 0
    fi
    fail "$name (see $log)"
    tail -5 "$log" | sed 's/^/        /' | tee -a "$SUMMARY"
    return 1
}

say "SC7F0 HDMI acceptance $(date -Is)"
say "host=$(hostname) kernel=$(uname -r) out=$OUT"
say "BDF=${BDF:-NOT FOUND}"
say ""

[ -n "$BDF" ] || fail "PCIe device 12ab:e380 not present"
[ -x "$V4L2_APP" ] || skip "missing $V4L2_APP (build test_app/v4l2_test_app)"
[ -x "$HDMI_CTL" ] || skip "missing $HDMI_CTL"
[ -x "$UPGRADE" ] || skip "missing $UPGRADE"

# 1. Firmware/upgrade state (must be IDLE after a completed deploy).
run upgrade-status "$UPGRADE" --status || true
[ -n "$BDF" ] && lspci -s "$BDF" -vv > "$OUT/lspci.log" 2>&1

# 2. Driver identity, bind state and PL version.
run driver-info bash -c '
    lsmod | grep -E "^(qpcie|qpcie_v4l2_bridge|xilinx_hdmi_rx|xilinx_vphy) " || true
    modinfo qpcie 2>/dev/null | grep -E "^(filename|version|vermagic)" || true
    readlink -f /sys/bus/pci/devices/'"$BDF"'/driver || true
'
run dmesg-before dmesg

# 3. RX telemetry + AER baseline.
run hdmi-status "$HDMI_CTL" || true
run aer-before bash -c 'lspci -s '"${BDF:-0000:03:00.0}"' -vv | grep -A6 "Advanced Error Reporting" || true'

# 4. RX timings (fails honestly when no cable / no locked timing).
run query-dv-timings "$V4L2_APP" --source 2 --timings || true

# 5. TPG regression: force TPG even if an HDMI source is attached.
run tpg-capture "$V4L2_APP" --source 1 --frames 120 --out "$OUT/tpg.nv12" || true

# 6. Real HDMI capture.
run hdmi-capture "$V4L2_APP" --source 2 --frames 120 --out "$OUT/hdmi.nv12" || true

# 7. Repeated STREAMON/STREAMOFF on the real source.
for i in 1 2 3; do
    run "hdmi-restart-$i" "$V4L2_APP" --source 2 --frames 30 || true
done

# 8. Post-run state.
run dmesg-after dmesg
run aer-after bash -c 'lspci -s '"${BDF:-0000:03:00.0}"' -vv | grep -A6 "Advanced Error Reporting" || true'

say ""
if grep -qiE 'StreamOn refused|drain timeout|DMA error|ARM-SMMU|AER.*Uncorr|Unsupported Request' "$OUT"/*.log 2>/dev/null; then
    fail "error keywords found in captured logs (review before accepting)"
else
    pass "no error keywords in captured logs"
fi

say ""
if [ "$FAILED" -eq 0 ]; then
    say "RESULT: PASS"
else
    say "RESULT: FAIL/BLOCKED (see per-step lines above)"
fi
say "Evidence directory: $OUT"
[ "$FAILED" -eq 0 ]
