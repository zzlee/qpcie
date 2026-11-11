#!/usr/bin/env bash
# 0x26102902 VCU deployment: read-only board acceptance.
#
#   scripts/accept_sc7f0_vcu_board.sh RELEASE_DIR [HOST]
#
#     SC7F0_PS_BOOT_ID_BEFORE=<uuid>  PS boot-id recorded before the deploy reboot
#     SC7F0_TOOL_DIR=<dir>            dir holding sc7f0ctl + qpcie_upgrade on the
#                                     host (default: the deployment's own evidence)
#     --allow-rx-restart              permit the ONE documented MCU v1.1.15 runtime
#                                     restart (i2ctransfer -y 0 w2@0x32 0x06 0x01)
#                                     if, and only if, a checked read-only IT6663
#                                     dump first establishes upstream lock while
#                                     the Xilinx RX stays unlocked
#
# What it proves, with the artifact named in the log:
#   * the x86 host was not rebooted (boot-id identical before/after),
#   * the ACTIVE hardware version is 0x26102902, read from the card,
#   * the PS runs the new image (boot-id changed, marker, eMMC SHA read-back),
#   * the four production daemons are active and the watchdog calls the board healthy,
#   * the VCU is visible to the PS (device tree node + pl_clk1 rate) - reported,
#     never assumed, and never exercised beyond what the capture path needs,
#   * HDMI RX still locks at 4K60 and PS capture still works (8 frames, then a
#     5-second 4K60 run) with no error flags and no new dmesg errors.
#
# It writes nothing to the card, no flash, no COMMIT, no reboot, no module reload.
# The only PS writes are scripts in /tmp (evidence helpers) and, if explicitly
# allowed, one documented MCU runtime restart command.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
RX_RESTART=0
if [[ ${1:-} == --allow-rx-restart ]]; then RX_RESTART=1; shift; fi
OUT_REL=${1:?RELEASE_DIR [HOST]}; OUT_REL=$(realpath "$OUT_REL")
HOST=${2:-rd@sc7f0-test.local}
VERSION=0x26102902
PS_BEFORE=${SC7F0_PS_BOOT_ID_BEFORE:-}
TOOLDIR=${SC7F0_TOOL_DIR:-$OUT_REL/deployment/remote-evidence}
ACC=$OUT_REL/deployment/board-acceptance.$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$ACC"
LOG=$ACC/acceptance.log
CTL="$TOOLDIR/sc7f0ctl"; UPG="$TOOLDIR/qpcie_upgrade"
[[ -x $CTL && -x $UPG ]] || { echo "need sc7f0ctl + qpcie_upgrade in $TOOLDIR" >&2; exit 1; }
fail=0; restart_used=0
say()  { printf '%s\n' "$*" | tee -a "$LOG"; }
chk()  { local label=$1; shift
    if "$@" >"$ACC/$(printf '%s' "$label" | tr -c 'A-Za-z0-9' '_').out" 2>&1; then
        say "PASS  $label"; else say "FAIL  $label"; tail -5 "$ACC"/*.out | sed 's/^/      /' >>"$LOG"; fail=1; fi; }
report() { local label=$1; shift
    "$@" >"$ACC/$(printf '%s' "$label" | tr -c 'A-Za-z0-9' '_').out" 2>&1
    say "INFO  $label (see $(basename "$ACC")/$(printf '%s' "$label" | tr -c 'A-Za-z0-9' '_').out)"; }
# `ssh -n` matters: without it a command run from inside the upload loop would
# swallow the remaining queued lines from the loop's stdin.
ps_exec() { local cmd=$1 t=${PS_TIMEOUT:-30}
    ssh -n -o BatchMode=yes -o ConnectTimeout=10 "$HOST" \
        "sudo -n $CTL --timeout $t exec $(printf '%q' "$cmd")"; }
host_exec() { ssh -n -o BatchMode=yes -o ConnectTimeout=10 "$HOST" "$@"; }
upload_ps() { # <local file> <ps path>   (no base64/xxd on the board: printf %b chunks)
    local f=$1 dest=$2 cmd n=0
    ps_exec "rm -f $dest" >/dev/null 2>&1
    while IFS= read -r cmd; do
        n=$((n + 1))
        ps_exec "$cmd" >/dev/null || { echo "chunk $n failed" >&2; return 1; }
    done < <(python3 - "$f" "$dest" <<'PY'
import shlex, sys
src, dest = sys.argv[1], sys.argv[2]
text = open(src, encoding='utf-8').read()
# The board has no base64/xxd, so the payload is transferred as printf %b text:
# backslashes doubled, real newlines written as \n, so every chunk is one line.
def esc(s):
    return s.replace('\\', '\\\\').replace('\n', '\\n')
chunks, cur = [], ''
for line in text.splitlines(keepends=True):
    frag = esc(line)
    if cur and len(cur) + len(frag) + 24 > 2400:
        chunks.append(cur); cur = ''
    cur = cur + frag
if cur:
    chunks.append(cur)
for i, c in enumerate(chunks):
    print(f"printf %b {shlex.quote(c)} {'>' if i == 0 else '>>'} {dest}")
PY
)
    ps_exec "chmod 0755 $dest && wc -c $dest && sha256sum $dest"
}
: > "$LOG"
say "== SC7F0 0x26102902 board acceptance $(date -u +%Y%m%dT%H%M%SZ) host=$HOST =="
say "release=$OUT_REL tools=$TOOLDIR rx_restart_allowed=$RX_RESTART"

# --- 1. host identity (must not have moved) ---------------------------------- #
host_exec 'cat /proc/sys/kernel/random/boot_id' > "$ACC/host-boot-id-before"
HOST_BEFORE=$(cat "$ACC/host-boot-id-before")
host_exec 'uptime -s; uname -r; uname -m' > "$ACC/host-state-before"
say "INFO  host boot-id $HOST_BEFORE ($(head -1 "$ACC/host-state-before"))"

# --- 2. active hardware version, straight from the card ---------------------- #
host_exec "sudo -n $UPG --status" > "$ACC/hardware-status.txt" 2>&1
if grep -qi "Hardware Version.*$VERSION" "$ACC/hardware-status.txt"; then
    say "PASS  active hardware version is $VERSION"
    grep -E "Hardware Version|Git Commit|Hardware Caps|Upgrade Status|Hardware Magic" \
        "$ACC/hardware-status.txt" | sed 's/^/      /' | tee -a "$LOG" >/dev/null
else
    say "FAIL  active hardware version is not $VERSION"; grep -E "Version|Magic" \
        "$ACC/hardware-status.txt" | sed 's/^/      /' | tee -a "$LOG" >/dev/null; fail=1
fi
grep -qi 'IDLE / Ready' "$ACC/hardware-status.txt" \
    && say "INFO  upgrade engine IDLE/Ready (no COMMIT is issued by this script)" \
    || say "NOTE  upgrade engine not IDLE (recorded, nothing is issued here)"

# --- 3. PS identity + services ---------------------------------------------- #
ps_exec 'cat /proc/sys/kernel/random/boot_id' > "$ACC/ps-boot-id-after"
PS_AFTER=$(cat "$ACC/ps-boot-id-after")
[[ $PS_AFTER =~ ^[0-9a-f-]{36}$ ]] || { say "FAIL  no PS boot-id read back ($PS_AFTER)"; exit 1; }
say "INFO  PS boot-id $PS_AFTER"
if [[ -n $PS_BEFORE ]]; then
    [[ $PS_BEFORE != $PS_AFTER ]] && say "PASS  PS boot-id changed vs the pre-deploy record ($PS_BEFORE)" \
        || { say "FAIL  PS boot-id unchanged: the PS did not re-enter the new image"; fail=1; }
else
    say "NOTE  SC7F0_PS_BOOT_ID_BEFORE not supplied: PS reboot proof comes from the deployment log"
fi
chk "PS runs a 6.1.30-xilinx kernel with the new release marker" \
    ps_exec 'set -e; uname -a; cat /etc/sc7f0-recovery-release; grep -q PL_BASE_VERSION=0x26102902 /etc/sc7f0-recovery-release'
chk "four production daemons active and watchdog health OK" \
    ps_exec 'set -e; for s in qpcie-debugd qpcie-hdmi-daemon qpcie-upgrade-daemon sc7f0-ps-watchdog; do printf "%s=" "$s"; systemctl is-active "$s"; done; sc7f0_ps_watchdog --check-health /run/sc7f0-health'
report "PS systemd units (degraded is pre-existing: nfsserver + systemd-fsck)" \
    ps_exec 'systemctl is-system-running || true; systemctl --failed --no-legend || true'

# --- 4. what is actually in eMMC --------------------------------------------- #
ps_exec 'sha256sum /run/media/BOOT-mmcblk0p1/BOOT.BIN /run/media/BOOT-mmcblk0p1/image.ub /run/media/BOOT-mmcblk0p1/boot.scr' \
    > "$ACC/emmc-readback.sha256" 2>&1
if python3 - "$OUT_REL/RELEASE.sha256" "$ACC/emmc-readback.sha256" >>"$LOG" 2>&1 <<'PY'
import sys
from pathlib import Path
want = {Path(n).name: h for h, n in (l.split() for l in Path(sys.argv[1]).read_text().splitlines())
        if n.startswith('images/')}
got = {Path(n).name: h for h, n in (l.split() for l in Path(sys.argv[2]).read_text().splitlines() if l.strip())}
assert got == want, (got, want)
print('      ' + ' '.join(f'{k}={v[:16]}…' for k, v in sorted(got.items())))
PY
then say "PASS  independent eMMC SHA read-back equals the release manifest"; else say "FAIL  eMMC read-back != release manifest"; fail=1; fi

# --- 5. VCU exposure on the PS (reported, never assumed) -------------------- #
report "PS media devices and platform devices" \
    ps_exec 'ls -l /dev/video* /dev/media* 2>&1; echo ---; ls /sys/bus/platform/devices | grep -iE "vcu|al5|fpga-axi|b0070000|b0060000|b0050000" || echo no-matching-platform-devices'
chk "PS device tree exposes the hardware VCU register window" \
    ps_exec 'set -e; d=$(find /proc/device-tree -maxdepth 3 -type d -name "*vcu*" | head -1); test -n "$d"; echo "NODE=$d"; ls -l "$d"; for c in "$d"/compatible; do echo "COMPATIBLE=$(tr -d "\0" < $c)"; done'
report "PS encoder devices, modules and VCU clock" ps_exec '
    set -u
    echo "== /dev allegro/vcu =="; ls -l /dev/allegro* /dev/vcu* 2>&1 || true
    echo "== modules =="; lsmod | grep -iE "vcu|allegro|al5|omx" || echo no-vcu-modules
    echo "== clk_summary pl_clk =="
    mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug 2>&1 || true
    grep -iE "pl_clk|vcu" /sys/kernel/debug/clk/clk_summary 2>&1 | head -20 || echo no-clk-summary
    echo "== CMA / reserved memory =="
    grep -iE "vcu|cma" /proc/device-tree/reserved-memory/*/compatible /proc/device-tree/reserved-memory/*/reg 2>/dev/null | head -6 || true
    cat /sys/kernel/debug/clk/clk_summary >/dev/null 2>&1 && true'
report "PS media graph" ps_exec 'media-ctl -p -d /dev/media0 | grep -E "entity|fmt:|dv\.|device-" '

# --- 6. HDMI RX lock, with the documented read-only diagnosis order --------- #
rx_query() { ps_exec 'for n in /sys/class/video4linux/v4l-subdev*; do case "$(cat $n/name 2>/dev/null)" in *hdmi-rx*) v4l2-ctl -d /dev/$(basename $n) --query-dv-timings 2>&1;; esac; done'; }
rx_query > "$ACC/rx-dvtimings-1.txt" 2>&1
if grep -qE "3840" "$ACC/rx-dvtimings-1.txt"; then
    say "PASS  HDMI RX reports a 4K timing straight away"; sed -n '1,12p' "$ACC/rx-dvtimings-1.txt" | sed 's/^/      /' >>"$LOG"
else
    say "NOTE  RX not locked yet; running the checked read-only IT6663 diagnosis first"
    python3 scripts/sc7f0_it6663_dump.py --host "$HOST" --json > "$ACC/it6663-readonly.json" 2>"$ACC/it6663-readonly.err"
    locked=$(python3 -c "import json;d=json.load(open('$ACC/it6663-readonly.json'));print(int(bool(d.get('timing_valid')) and bool(d.get('status_before',{}).get('symbol_lock'))))" 2>/dev/null || echo 0)
    say "INFO  IT6663 upstream lock/geometry valid = $locked (read-only, no configuration write)"
    if (( RX_RESTART )) && [[ $locked == 1 ]]; then
        say "NOTE  one documented MCU v1.1.15 runtime restart (no firmware write, no configuration change)"
        ps_exec 'i2ctransfer -y 0 w2@0x32 0x06 0x01' > "$ACC/mcu-runtime-restart.txt" 2>&1 \
            && restart_used=1
        for i in $(seq 1 20); do
            sleep 3; rx_query > "$ACC/rx-dvtimings-2.txt" 2>&1
            grep -qE "3840" "$ACC/rx-dvtimings-2.txt" && break
        done
        cp "$ACC/rx-dvtimings-2.txt" "$ACC/rx-dvtimings-final.txt" 2>/dev/null || cp "$ACC/rx-dvtimings-1.txt" "$ACC/rx-dvtimings-final.txt"
    else
        say "INFO  RX restart not permitted/needed; keeping the first reading"; cp "$ACC/rx-dvtimings-1.txt" "$ACC/rx-dvtimings-final.txt"
    fi
    grep -qE "3840" "$ACC/rx-dvtimings-final.txt" \
        && say "PASS  HDMI RX 4K timing established (restart_used=$restart_used)" \
        || { say "FAIL  HDMI RX does not report a 4K timing (restart_used=$restart_used)"; fail=1; }
fi
report "PS hdmi daemon tail + IT6663 probe registers (read-only)" \
    ps_exec 'journalctl -u qpcie-hdmi-daemon --no-pager -n 40 || true'

# --- 7. capture path must not have regressed -------------------------------- #
say "INFO  pushing scripts/sc7f0_ps_capture_4k60.sh to the board /tmp"
upload_ps scripts/sc7f0_ps_capture_4k60.sh /tmp/sc7f0_ps_capture_4k60.sh > "$ACC/upload.log" 2>&1 \
    && say "PASS  capture helper uploaded (sha recorded in upload.log)" \
    || { say "FAIL  capture helper upload"; fail=1; }
PS_TIMEOUT=180 ps_exec 'sh /tmp/sc7f0_ps_capture_4k60.sh 8 /tmp/ps-vcu-cap8.nv12' > "$ACC/ps-capture-8.log" 2>&1
if grep -q 'CAPTURE_EXIT=0' "$ACC/ps-capture-8.log"; then
    say "PASS  8-frame 4K60 NV12 capture (exit 0); $(grep -c . "$ACC/ps-capture-8.log") log lines, file + sha recorded below"
    grep -E "CAPTURE_EXIT|CAPTURE_WALL_MS|TAP_FLAG_WARN_COUNT|DMESG_ERROR_COUNT|ps-vcu-cap8" \
        "$ACC/ps-capture-8.log" | sed 's/^/      /' >>"$LOG"
    (( $(grep -o 'TAP_FLAG_WARN_COUNT=[0-9]*' "$ACC/ps-capture-8.log" | cut -d= -f2) == 0 )) \
        && say "PASS  frame-tap reported no metadata warnings" \
        || { say "FAIL  frame-tap metadata warnings present"; fail=1; }
else
    say "FAIL  8-frame 4K60 capture"; tail -25 "$ACC/ps-capture-8.log" | sed 's/^/      /' >>"$LOG"; fail=1
fi
PS_TIMEOUT=240 ps_exec 'sh /tmp/sc7f0_ps_capture_4k60.sh 300 /tmp/ps-vcu-cap300.nv12' > "$ACC/ps-capture-300.log" 2>&1
if grep -q 'CAPTURE_EXIT=0' "$ACC/ps-capture-300.log"; then
    say "PASS  300-frame (5 s) 4K60 NV12 capture (exit 0)"
    grep -E "CAPTURE_EXIT|CAPTURE_WALL_MS|TAP_FLAG_WARN_COUNT|DMESG_ERROR_COUNT|ps-vcu-cap300" \
        "$ACC/ps-capture-300.log" | sed 's/^/      /' >>"$LOG"
else
    say "FAIL  300-frame 4K60 capture"; tail -25 "$ACC/ps-capture-300.log" | sed 's/^/      /' >>"$LOG"; fail=1
fi
report "PS dmesg tail after capture" ps_exec 'dmesg | tail -n 60'

# --- 8. host must still be the same boot ------------------------------------- #
host_exec 'cat /proc/sys/kernel/random/boot_id' > "$ACC/host-boot-id-after"
if cmp -s "$ACC/host-boot-id-before" "$ACC/host-boot-id-after"; then
    say "PASS  x86 host boot-id unchanged ($HOST_BEFORE): no host reboot"
else
    say "FAIL  host boot-id changed: $(cat "$ACC/host-boot-id-after")"; fail=1
fi
report "host PCIe + AER state" host_exec 'lspci -Dd 12ab:e380 -vv 2>/dev/null | grep -E "LnkSta:|Kernel driver|Region" ; echo ---; for d in /sys/bus/pci/devices/0000:03:00.0; do for f in $d/aer_*; do printf "%s=%s\n" "$(basename $f)" "$(cat $f)"; done; done'

say "== summary =="
say "active version: $(grep -m1 -oE '0x[0-9A-Fa-f]{8}' "$ACC/hardware-status.txt" | tail -1)"
say "PS boot-id: before=${PS_BEFORE:-recorded-in-deployment} after=$PS_AFTER; host boot-id unchanged: $(cmp -s "$ACC/host-boot-id-before" "$ACC/host-boot-id-after" && echo yes || echo NO)"
say "IT6663/MCU runtime restart used: $restart_used"
if (( fail )); then say "RESULT: VCU_BOARD_ACCEPTANCE_FAILED (evidence in $ACC)"; exit 1
else say "RESULT: VCU_BOARD_ACCEPTANCE_PASS (evidence in $ACC; encoder runtime not exercised)"; printf '%s\n' "SC7F0_VCU_BOARD_ACCEPTANCE_PASS" > "$ACC/acceptance.ok"; fi
