#!/usr/bin/env bash
# SC7F0 HDMI RX post-flash acceptance, written for the 0x26111503 RGB-compositor
# TDLOCK investigation and reusable after any RX-side round.  It answers, in order,
# the questions that matter after a device-tree, driver or board-clocking change to
# the RX chain:
#
#   1. which image.ub is actually running, and what does ITS live device tree say
#      (xlnx,transceiver-width / xlnx,input-pixels-per-clock) - the booted tree, not
#      the tree we think we flashed;
#   2. is the upstream source present, read from the IT6663 over the checked MCU
#      proxy (the only path this card has to the connector), so a failure below is
#      never silently blamed on the source;
#   3. what clock actually reaches the card, measured twice by independent
#      hardware: the PL clock probe (BAR0 0x0684, the clock the IT6663 TX port puts
#      on the lane into the FPGA - char/4 while the TX port holds its HDMI 2.0 ratio,
#      1/10 of the line rate when it does not; measured both ways on 2026-11-16) and
#      the VPHY clock detector (0xB0000210, the reference clock present at
#      the GT refclk input).  The expectation is taken from the pixel clock the PL
#      itself recovered (BAR0 0x060C), the only source-independent number on this path.
#      The GTHE4 CPLL branch of the driver takes
#      that detector value and multiplies it by 40 for a 1/40 stream
#      (hdmi/phy-xilinx-vphy/xvphy_hdmi_intr.c:776 stores it as HdmiRxRefClkHz,
#      xvphy_hdmi.c:1822 then programs RefClk*40), so the board owes the GT
#      char/4 and this stage is where a wrong ratio shows up as arithmetic;
#   4. the VPHY GT state (PLL lock, RX init, RX character lock RX_TDLOCK) and what
#      datapath width the driver programmed;
#   5. what the RX subsystem and its video-timing detector report (PIO_IN, VTD
#      geometry, error counters);
#   6. whether the host driver accepts STREAMON and whether real RGB888 pixels
#      arrive on /dev/video0, ending in a frame written to disk;
#   6b. the fabric side of the same attempt: engine-accepted SOF/EOL/beats
#       (0xA0000088/0x8C/0x90) and the read-only capture-engine diagnosis window
#       (BAR0 GLOBAL 0x0E0..0x0F4 -> 0xA00000E0..0xA00000F4), which split "RX
#       locked but the fabric delivers 0 payload" into engine-not-armed / no SGL
#       entry / no active segment / not accepting beats, and reports
#       bytes_committed / drop_count / frames_completed deltas;
#   7. whether a GStreamer pipeline can pull or display it.
#
# Nothing here writes to the card: the only card-side commands are read-only
# `devmem` and device-tree reads through sc7f0ctl exec, which is the documented
# register path for this board.  It does not rmmod, rescan, reboot or reprogram
# anything; a capture attempt is bounded by its own timeout, so no DMA transaction
# is left unfinished behind it.
#
#   scripts/sc7f0_rx_tdlock_acceptance.sh [--host rd@sc7f0-test.local]
#                                         [--out DIR] [--seconds 10] [--display]
#
# Exit 0 means every stage passed.  Stage lines are greppable as STAGE <name> PASS|FAIL.
set -uo pipefail

HOST=${SC7F0_TEST_HOST:-rd@sc7f0-test.local}
OUT=""
SECONDS_CAP=${SC7F0_ACCEPT_SECONDS:-10}
DISPLAY_SINK=0
WIDTH=${SC7F0_ACCEPT_WIDTH:-3840}
HEIGHT=${SC7F0_ACCEPT_HEIGHT:-2160}
while (($#)); do
    case $1 in
        --host) HOST=${2:?}; shift 2;;
        --out) OUT=${2:?}; shift 2;;
        --seconds) SECONDS_CAP=${2:?}; shift 2;;
        --display) DISPLAY_SINK=1; shift;;
        *) echo "unknown argument $1" >&2; exit 2;;
    esac
done
CTL=${SC7F0CTL:-/home/rd/sc7f0/bin/sc7f0ctl}
DEV=${QPCIE_V4L2_NODE:-/dev/video0}
STAMPS=$(date -u +%Y%m%dT%H%M%SZ)
[[ -n $OUT ]] || OUT=$(pwd)/sc7f0-rx-acceptance-$STAMPS
mkdir -p "$OUT" || exit 1
FAILS=0
say() { printf '%s\n' "$*"; }
stage() { # stage <name> <pass:0|nonzero> <detail>
    if [[ $2 == 0 ]]; then say "STAGE $1 PASS $3"; else say "STAGE $1 FAIL $3"; FAILS=$((FAILS+1)); fi
}
# A single bounded sc7f0ctl exec.  Keep the command free of single quotes: the
# daemon receives one string and the transport adds its own quoting, so nested
# quotes mangle the command and sc7f0ctl answers with its usage text (which is a
# transport artefact, never a hardware reading).
card() {
    timeout 90 ssh -o BatchMode=yes -o ConnectTimeout=8 "$HOST" \
        "timeout 80 sudo -n $CTL exec '$1'" 2>&1
}
host() { timeout 180 ssh -o BatchMode=yes -o ConnectTimeout=8 "$HOST" "$1" 2>&1; }
# read a fixed-order list of card registers into an array indexed by name
regs() { # regs "<name>=<addr>" ...
    local spec=() addrs=()
    local pair
    for pair in "$@"; do spec+=("${pair%%=*}"); addrs+=("${pair#*=}"); done
    local raw
    raw=$(card "for a in ${addrs[*]}; do devmem \$a; done")
    local i=0 line
    while read -r line; do
        [[ -n $line ]] || continue
        printf -v "${spec[$i]}" '%s' "$line"
        i=$((i+1))
    done <<< "$raw"
}
hz() { printf '%d' "${1:-0}" 2>/dev/null || printf '0'; }   # 0x... -> decimal

{
say "# SC7F0 HDMI RX acceptance on $HOST at $(date -u +%FT%TZ)"
say

say "## 1. what is running"
BOOTED=$(card "sha256sum /run/media/BOOT-mmcblk0p1/image.ub" | awk '/image.ub/{print $1}')
BOOTB=$(card "sha256sum /run/media/BOOT-mmcblk0p1/BOOT.BIN" | awk '/BOOT.BIN/{print $1}')
CID=$(card "cat /proc/sys/kernel/random/boot_id" | tr -d '\r')
UPT=$(card "cat /proc/uptime" | awk '{print $1}')
say "booted image.ub sha256 = ${BOOTED:-unknown}"
say "booted BOOT.BIN sha256 = ${BOOTB:-unknown}"
say "card uptime = ${UPT:-?} s, card boot_id = ${CID:-?}"
# DTB properties are big-endian u32 and devmem cannot read a procfs file, so byte 3
# of each (the low byte) is read directly; the four paths are fixed order.
DTW=$(card "for n in phy@b0000000/xlnx,transceiver-width phy@b0000000/xlnx,input-pixels-per-clock hdmi-rx@b0010000/xlnx,input-pixels-per-clock hdmi-tx@b0020000/xlnx,input-pixels-per-clock; do od -An -tx1 -N1 -j3 /proc/device-tree/amba_pl@0/\$n; done")
say "live device tree, low byte of each u32, in the order"
say "  phy transceiver-width / phy input-pixels-per-clock / rx input-pixels-per-clock / tx input-pixels-per-clock:"
printf '%s\n' "$DTW" | sed "s/^/  /"
W=$(printf '%s\n' "$DTW" | awk 'NR==1{print $1}')
P=$(printf '%s\n' "$DTW" | awk 'NR==2{print $1}')
RXPPC=$(printf '%s\n' "$DTW" | awk 'NR==3{print $1}')
TXPPC=$(printf '%s\n' "$DTW" | awk 'NR==4{print $1}')
if [[ $W == 02 && $P == 02 && $RXPPC == 02 && $TXPPC == 02 ]]; then
    stage boot-tree 0 "running tree is 2 PPC everywhere (phy width=0x$W, phy ppc=0x$P, rx ppc=0x$RXPPC, tx ppc=0x$TXPPC)"
else
    stage boot-tree 1 "running tree is phy width=0x${W:-?} phy ppc=0x${P:-?} rx ppc=0x${RXPPC:-?} tx ppc=0x${TXPPC:-?}; this fabric is 2 PPC (0x02), see scripts/audit_sc7f0_rgb_compositor_image.sh"
fi
say

say "## 2. upstream source (IT6663 over the MCU proxy)"
IT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && python3 ./sc7f0_it6663_dump.py --host "$HOST" 2>&1)
say "$IT" | sed -n '/Link:/p;/Protocol bits/p;/Timing valid/p;/H:  active/p;/V:  active/p'
printf '%s\n' "$IT" > "$OUT/it6663.txt"
printf '%s' "$IT" | grep -q "Timing valid (sampled lock + raw geometry): YES" \
    && stage source 0 "clock/symbol/SCDT lock with stable decoded geometry" \
    || stage source 1 "IT6663 reports no valid stable timing - the RX chain cannot be blamed for an absent source; check the source before stage 3"
say

say "## 3. clocks: what the connector carries and what the GT reference input sees"
# REG_HDMI_RX_PIXEL_CLK (BAR0 0x060C, driver/qpcie_driver.h:361) is the pixel clock
# the PL itself recovered, so it is the only reference that does not depend on which
# net a probe happens to sit on.  The 0xA0000684 probe is NOT the connector TMDS clock
# in every IT6663 TX state: measured 2026-11-16, with the IT TX port in its wrong
# ratio that net read 593,948,397 Hz while the GT refclk read 57,081,856 Hz, and after
# one MCU runtime restart the same net read 148,487,098 Hz with the GT refclk at
# 148,482,048 Hz.  It is the IT TX -> FPGA clock lane (1/10 of the line rate in the bad
# state, char/4 in the good one), so it is reported but never used as the expectation.
regs "PROBE_VER=0xA0000680" "PROBE_RX=0xA0000684" "PROBE_DRU=0xA0000688" \
     "PROBE_RXOUTCLK=0xA000068C" "PROBE_RXVIDEOCLK=0xA0000690" "RX_PIXCLK=0xA000060C"
say "PL clock probe  version=${PROBE_VER:-?} tx_clk_lane=${PROBE_RX:-?} dru_clk=${PROBE_DRU:-?} rxoutclk=${PROBE_RXOUTCLK:-?} rx_video_clk=${PROBE_RXVIDEOCLK:-?}"
say "PL recovered pixel clock (BAR0 0x060C) = ${RX_PIXCLK:-?}"
regs "PLL_LOCK=0xB0000018" "RX_INIT=0xB0000028" "TDLOCK=0xB000010C" "REFCLK_SEL=0xB0000010" \
     "CLKDET_CTRL=0xB0000200" "CLKDET_STAT=0xB0000204" "CLKDET_TMR_TO=0xB0000208" \
     "CLKDET_FREQ_TX=0xB000020C" "CLKDET_FREQ_RX=0xB0000210" "CLKDET_FREQ_DRU=0xB000021C"
say "VPHY  pll_lock=${PLL_LOCK:-?} rx_init=${RX_INIT:-?} tdlock=${TDLOCK:-?} refclk_sel=${REFCLK_SEL:-?}"
say "VPHY  clkdet ctrl=${CLKDET_CTRL:-?} stat=${CLKDET_STAT:-?} tmr_to=${CLKDET_TMR_TO:-?} freq_tx=${CLKDET_FREQ_TX:-?} freq_rx=${CLKDET_FREQ_RX:-?} freq_dru=${CLKDET_FREQ_DRU:-?}"
PROBE_RX_HZ=$(hz "${PROBE_RX:-0}"); PROBE_DRU_HZ=$(hz "${PROBE_DRU:-0}")
RX_PIXCLK_HZ=$(hz "${RX_PIXCLK:-0}")
CLKDET_RX_HZ=$(hz "${CLKDET_FREQ_RX:-0}"); CLKDET_DRU_HZ=$(hz "${CLKDET_FREQ_DRU:-0}")
# The detector has to be believed before its RX number can be used, and the DRU
# input is a fixed oscillator on this board, so it is the scale check.
python3 - "$PROBE_DRU_HZ" "$CLKDET_DRU_HZ" <<'PY' > "$OUT/.clk"
import sys
probe_dru, det_dru = (int(x) for x in sys.argv[1:3])
print("DRU_SCALE_OK" if probe_dru and det_dru and abs(det_dru - probe_dru) / probe_dru < 0.02 else "DRU_SCALE_UNKNOWN")
PY
DRU_SCALE=$(cat "$OUT/.clk"); rm -f "$OUT/.clk"
say "clock-detector scale check: DRU input measured ${CLKDET_DRU_HZ} Hz vs probe ${PROBE_DRU_HZ} Hz -> $DRU_SCALE"
python3 - "$RX_PIXCLK_HZ" "$CLKDET_RX_HZ" "$PROBE_RX_HZ" "$DRU_SCALE" > "$OUT/clocks.txt" <<'PY'
import sys
pixclk, refclk, lane, scale = (int(x) if x.isdigit() else x for x in sys.argv[1:5])
want = pixclk / 4
print(f"  pixel clock recovered by the PL  : {pixclk:,} Hz (=> line rate {pixclk*10:,} bit/s, scrambled 1/10)")
print(f"  IT TX clock lane into the FPGA   : {lane:,} Hz (char/4 when the TX port holds its ratio)")
print(f"  reference clock at the GT input  : {refclk:,} Hz")
print(f"  CPLL 1/40 branch needs           : {want:,.0f} Hz (= pixel clock / 4), driver then programs refclk x 40")
if refclk and want:
    print(f"  driver programs line rate        : {refclk*40:,} bit/s while the stream is {pixclk*10:,} bit/s"
          f" ({(refclk*40)/(pixclk*10):.3f}x)")
    if abs(refclk - want) / want < 0.02:
        print("STAGE rxrefclk PASS GT reference clock is char/4 as the 1/40 CPLL branch requires")
    else:
        print("STAGE rxrefclk FAIL GT reference clock is not char/4 (ratio "
              f"{pixclk/refclk:.2f} instead of 4.00): the CPLL cannot lock to the incoming stream, "
              "so GTLNKRDY/VID_RDY never assert regardless of the fabric width")
else:
    print("STAGE rxrefclk FAIL no clock measured at the GT reference input")
if scale != "DRU_SCALE_OK":
    print("  note: the detector's own scale is unverified this run, so treat the absolute numbers as indicative")
PY
cat "$OUT/clocks.txt"
FAILS=$((FAILS + $(grep -c '^STAGE .* FAIL' "$OUT/clocks.txt")))
say

say "## 4. VPHY GT lock and programmed datapath width"
PLL=$(( ${PLL_LOCK:-0} )); INIT=$(( ${RX_INIT:-0} )); TD=$(( ${TDLOCK:-0} ))
say "PLL_LOCK=${PLL_LOCK:-?} (bits 0..2 = CPLL0..2, 0x10/0x20 = QPLL0/1)  RX_INIT_STATUS=${RX_INIT:-?}  RX_TDLOCK=${TDLOCK:-?}"
if (( (PLL & 7) >= 1 )); then stage pll 0 "at least one RX PLL locked (${PLL_LOCK})"
else stage pll 1 "no RX PLL locked (${PLL_LOCK:-?}) - with stage 3's reference-clock reading this is the expected consequence, not an independent fault"; fi
if (( (TD & 7) == 7 )); then stage tdlock 0 "RX_TDLOCK (0xB000010C) = ${TDLOCK} (lane0..2 character lock)"
else stage tdlock 1 "RX_TDLOCK (0xB000010C) = ${TDLOCK:-?}; expected 0x...7 - note: XVPHY_RX_TDLOCK_REG is only a #define in both local vphy copies (build/official-drm-contract/src/xvphy_hw.h:122, 2023.2 vphy/src/xvphy_hw.h:114) and no driver code ever reads it, so a zero here does not contradict GTLNKRDY/VID_RDY/VTD lock; it stays reported because this acceptance asks for it"; fi
say

say "## 5. RX subsystem and video timing detector"
regs "PIO_IN=0xB0010064" "VTD_STATUS=0xB00100D0" "VTD_HACT=0xB00100D4" "VTD_VACT=0xB00100D8" \
     "VTD_TOTAL=0xB00100DC" "ERR_VTD=0xB00101D4"
say "RXSS PIO_IN=${PIO_IN:-?} vtd_status=${VTD_STATUS:-?} hact=${VTD_HACT:-?} vact=${VTD_VACT:-?} total=${VTD_TOTAL:-?} err=${ERR_VTD:-?}"
# Bit test, not a text pattern.  A fully locked 2 PPC stream reads 0x000003FF on this
# card (measured 2026-11-16 with hdmi_status = Signal Locked 3840x2160p 594 MHz, VTD
# geometry valid and the error counter at 0); the previous regex only accepted 0x1xx and
# so reported a locked subsystem as failed.  Required: bit0 cable, bit1 GTLNKRDY,
# bit2 VID_RDY, bit8 SCDC.
PIO=$(( ${PIO_IN:-0} ))
if (( (PIO & 0x107) == 0x107 )); then
    stage rxss 0 "PIO_IN=${PIO_IN} (cable + GTLNKRDY + VID_RDY + SCDC; other bits 0x$(printf '%x' $((PIO & ~0x107)))) and VTD status=${VTD_STATUS:-?}"
else
    stage rxss 1 "PIO_IN=${PIO_IN:-?} - missing $( (( PIO & 1 ? 0 : 1 )) && printf 'cable ' )$( (( PIO & 2 ? 0 : 1 )) && printf 'GTLNKRDY ' )$( (( PIO & 4 ? 0 : 1 )) && printf 'VID_RDY ' )$( (( PIO & 256 ? 0 : 1 )) && printf 'SCDC' )"
fi
say "sc7f0ctl status: $(host "timeout 40 sudo -n $CTL status" | head -3 | tr '\n' ' ')"
say

say "## 6. host capture on $DEV"
FMT=$(host "v4l2-ctl -d $DEV --list-formats-ext" | grep -c "RGB3")
say "RGB3 (24-bit RGB 8-8-8) size entries on $DEV: $FMT"
# The frame lands under /home/rd/sc7f0/ because that is the only place new files
# may appear on this test host; 4K RGB3 is ~25 MB per frame so two frames is plenty.
# --stream-buffers is not accepted by this v4l2-ctl, and a bounded timeout matters:
# with no locked source the driver accepts STREAMON and simply never delivers a
# buffer, so an unbounded run would sit holding the queue open.
REMOTEDIR=/home/rd/sc7f0/tmp/rx-acceptance-$STAMPS
CAPLOG="$OUT/stream.log"
# The fabric side of the same attempt, sampled on both sides of it.  These are
# the read-only taps that Defect 3 cost a full RTL trace to find
# (docs/sc7f0_defect3_c2h_zero_payload_rootcause_20261116.md §1.4/§5.3):
#   0xA0000088/0x8C/0x90  engine-accepted SOF / EOL / beats at the packer output
#   0xA00000E0            SGL entries, seg_valid, pl_seg_ready, engine state,
#                         armed/locked/sof_locked, burst_start, video_busy
#   0xA00000E4            packer avail, tvalid, tready, sgl_wr_en, sgl_pop_ready,
#                         SGL source FIFO empty
#   0xA00000E8/EC/F0      bytes_committed / drop_count / frames_completed
#   0xA00000F4            sticky bits, desc_valid/ready, SGL source FIFO entries
FABRIC_ADDRS=(0xA0000088 0xA000008C 0xA0000090 0xA00000E0 0xA00000E4
              0xA00000E8 0xA00000EC 0xA00000F0 0xA00000F4)
card "for a in ${FABRIC_ADDRS[*]}; do printf '%s=' \$a; devmem \$a; done" > "$OUT/fabric-before.txt"
host "mkdir -p $REMOTEDIR && timeout 30 v4l2-ctl -d $DEV --set-fmt-video=width=$WIDTH,height=$HEIGHT,pixelformat=RGB3 --stream-mmap --stream-count=2 --stream-to=$REMOTEDIR/frame.rgb 2>&1; echo rc=\$?; ls -l $REMOTEDIR/frame.rgb 2>/dev/null | awk '{print \$5}'" | tee "$CAPLOG" | head -8
card "for a in ${FABRIC_ADDRS[*]}; do printf '%s=' \$a; devmem \$a; done" > "$OUT/fabric-after.txt"
cat "$OUT/fabric-before.txt" | sed 's/^/FABRIC_BEFORE /' | tee -a "$OUT/fabric.log"
cat "$OUT/fabric-after.txt"  | sed 's/^/FABRIC_AFTER  /' | tee -a "$OUT/fabric.log"
python3 - "$OUT/fabric-before.txt" "$OUT/fabric-after.txt" >> "$OUT/fabric.log" <<'PY'
import re, sys
from pathlib import Path

def load(p):
    d = {}
    for line in Path(p).read_text().splitlines():
        m = re.match(r'^(0x[0-9A-Fa-f]+)=0x([0-9A-Fa-f]+)', line.strip())
        if m:
            d[int(m.group(1), 16) & 0xFFF] = int(m.group(2), 16)
    return d

b, a = load(sys.argv[1]), load(sys.argv[2])
E0, E4, E8, EC, F0, F4 = 0xE0, 0xE4, 0xE8, 0xEC, 0xF0, 0xF4

def bit(v, i):
    return (v >> i) & 1

ent, seg_v, seg_rdy = a.get(E0, 0) & 0x7F, bit(a.get(E0, 0), 9), bit(a.get(E0, 0), 8)
state = (a.get(E0, 0) >> 10) & 7
busy = bit(a.get(E0, 0), 27)
tready, tvalid = bit(a.get(E4, 0), 13), bit(a.get(E4, 0), 12)
sgl_wr_en, pop_rdy = bit(a.get(E4, 0), 19), bit(a.get(E4, 0), 20)
dbytes = a.get(E8, 0) - b.get(E8, 0)
dframes = a.get(F0, 0) - b.get(F0, 0)
drops = a.get(EC, 0) - b.get(EC, 0)
beats = a.get(0x090, 0) - b.get(0x090, 0)
print(f'FABRIC_DELTA bytes={dbytes} frames={dframes} drops={drops} engine_beats={beats}')
print(f'FABRIC_LIVE after: entries={ent} seg_valid={seg_v} pl_seg_ready={seg_rdy} '
      f'state={state} video_busy={busy} tvalid={tvalid} tready={tready} '
      f'sgl_wr_en={sgl_wr_en} sgl_pop_ready={pop_rdy} '
      f'sgl_src_entries={(a.get(F4, 0) >> 12) & 0x3FF}')
if dbytes > 0:
    print('FABRIC_VERDICT payload_moved')
elif not pop_rdy and not sgl_wr_en:
    # what 0x26111503 showed: the engine said "not ready" while its walker was
    # empty, so not one SGL entry ever reached it
    print('FABRIC_VERDICT no_sgl_entry_delivered (sgl_pop_ready low / sgl_wr_en never pulsed)')
elif not seg_rdy or not seg_v:
    print('FABRIC_VERDICT armed_without_active_segment (walker has no segment)')
elif not tready:
    print('FABRIC_VERDICT engine_not_accepting_payload (tready low with a live segment)')
else:
    print('FABRIC_VERDICT accepting_beats_but_nothing_committed')
PY
tail -4 "$OUT/fabric.log"
FV=$(grep -oE 'FABRIC_VERDICT .*' "$OUT/fabric.log" | tail -1 | cut -d' ' -f2-)
if [[ $FV == payload_moved ]]; then
    stage fabric 0 "$FV ($(grep -oE 'FABRIC_DELTA .*' "$OUT/fabric.log" | tail -1))"
else
    stage fabric 1 "$FV ($(grep -oE 'FABRIC_LIVE .*' "$OUT/fabric.log" | tail -1))"
fi
BYTES=$(awk '/^[0-9]+$/{v=$1} END{print v+0}' <<< "$(grep -oE '^[0-9]+$' "$CAPLOG" | tail -1)")
if grep -q "rc=0" "$CAPLOG" && [[ ${BYTES:-0} -ge $((WIDTH*HEIGHT*3)) ]]; then
    scp -o BatchMode=yes -q "$HOST:$REMOTEDIR/frame.rgb" "$OUT/frame.rgb" 2>/dev/null
    NUNIQ=$(head -c 1048576 "$OUT/frame.rgb" > "$OUT/frame-head.bin"; python3 -c "import sys;print(len(set(open(sys.argv[1],'rb').read())))" "$OUT/frame-head.bin")
    say "first 1 MiB distinct byte values: $NUNIQ"
    stage capture 0 "$WIDTH x $HEIGHT RGB3, $BYTES bytes of frame data returned"
    # A frozen buffer and a genuinely solid-colour source are indistinguishable by
    # entropy alone, so this stays a separate gate: fail means go look at the file.
    if (( NUNIQ > 16 )); then
        stage pixels 0 "frame is not constant ($NUNIQ distinct byte values in the first MiB)"
    else
        stage pixels 1 "first MiB has $NUNIQ distinct values - no video moved, or the source really is a solid colour; inspect $OUT/frame.rgb"
    fi
else
    stage capture 1 "no complete frame returned (rc bytes=$BYTES, see stream.log); with the RX subsystem locked this is the fabric capture path delivering no payload rather than an absent source - look at host perf_stats (Payload Transmitted / Total TLPs Sent) and whether dmesg shows STREAMON accepted"
fi
host "rm -f $REMOTEDIR/frame.rgb; rmdir $REMOTEDIR 2>/dev/null" >/dev/null 2>&1
say

say "## 7. GStreamer"
GSTLOG="$OUT/gstreamer.log"
# The caps name is not the fourcc: the driver advertises V4L2 'RGB3' (24-bit RGB
# 8-8-8), which GStreamer calls format=RGB, and asking for RGB24 fails to link.
if (( DISPLAY_SINK )); then
    WD=$(host 'echo ${WAYLAND_DISPLAY:-none}'); XD=$(host 'echo ${DISPLAY:-none}')
    if [[ $WD != none ]]; then SINK=waylandsink; elif [[ $XD != none ]]; then SINK=ximagesink; else SINK=autovideosink; fi
    say "host session: WAYLAND_DISPLAY=$WD DISPLAY=$XD -> sink=$SINK"
    host "timeout $((SECONDS_CAP+8)) gst-launch-1.0 v4l2src device=$DEV do-timestamp=true num-buffers=$((SECONDS_CAP*30)) ! 'video/x-raw,format=RGB,width=$WIDTH,height=$HEIGHT' ! queue max-size-buffers=8 leaky=2 ! $SINK sync=false 2>&1" > "$GSTLOG"
    tail -6 "$GSTLOG"
    if grep -qiE "ERROR|not-negotiated|could not link|Cannot open|failed" "$GSTLOG"; then
        stage display 1 "$SINK pipeline errored (see gstreamer.log)"
    else
        stage display 0 "ran ${SECONDS_CAP}s into $SINK with no pipeline error (operator confirms what the screen showed)"
    fi
else
    host "timeout $((SECONDS_CAP+8)) gst-launch-1.0 v4l2src device=$DEV do-timestamp=true num-buffers=$((SECONDS_CAP*30)) ! 'video/x-raw,format=RGB,width=$WIDTH,height=$HEIGHT' ! fpsdisplaysink video-sink=fakesink text-overlay=false sync=false 2>&1" > "$GSTLOG"
    grep -oE "[0-9]+\.[0-9]+ fps.*" "$GSTLOG" | tail -3
    FPS=$(grep -oE "[0-9]+\.[0-9]+ fps" "$GSTLOG" | tail -1 | awk '{print $1}')
    if awk -v f="${FPS:-0}" 'BEGIN{exit !(f>20)}'; then
        stage display 0 "GStreamer pulled ${FPS} fps of $WIDTH x $HEIGHT RGB from $DEV (pass --display for a screen)"
    else
        stage display 1 "GStreamer measured ${FPS:-0} fps (see gstreamer.log); a streamless source yields no buffers, so fix the lock first"
    fi
fi
say
say "evidence: $OUT"
say "RESULT: $([[ $FAILS == 0 ]] && echo PASS || echo "$FAILS stage(s) FAILED")"
} > >(tee "$OUT/acceptance.txt")

exit "${FAILS:-0}"
