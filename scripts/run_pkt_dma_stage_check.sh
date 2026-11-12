#!/bin/bash
# Run one Packet DMA test pass with precise attribution of card TX, host RX
# and kernel messages.  dmesg is snapshotted by line count before the run so
# only messages produced by *this* pass are reported.
#
# usage: run_pkt_dma_stage_check.sh <tag> <host_count> <host_seconds> <card_count> <card_mode>
set -u
TAG=$1; HC=$2; HS=$3; CC=$4; CM=$5; CB=${6:-/tmp/sc7f0_pkt_dma_test}
DEV=/sys/bus/pci/devices/0000:03:00.0
CTL=/home/rd/sc7f0/bin/sc7f0ctl
# Everything below is written by *this host* (the PCIe test machine), so it goes under
# /home/rd/sc7f0/logs per AGENTS.md 測試機檔案放置規範 - no new files in that machine's
# /tmp or $HOME.  $CB is the *PS board's* /tmp (executed through sc7f0ctl) and is
# deliberately left alone.
LOGDIR=/home/rd/sc7f0/logs
mkdir -p "$LOGDIR"
HL=$LOGDIR/host_${TAG}.log
CL=$LOGDIR/card_${TAG}.log
DM0=$LOGDIR/dmesg_before_${TAG}.log
DM1=$LOGDIR/dmesg_after_${TAG}.log
PS0=$LOGDIR/pktstats_before_${TAG}.txt
PS1=$LOGDIR/pktstats_after_${TAG}.txt

N0=$(dmesg | wc -l)
dmesg > "$DM0"
cat "$DEV/packet_stats" > "$PS0" 2>/dev/null
for f in ch0_frames ch0_drops ch0_status; do printf '%s=%s ' "$f" "$(cat $DEV/$f 2>/dev/null | head -1)"; done; echo

# host receiver first, so credits are published before the card starts pushing
/home/rd/sc7f0/bin/host_pkt_dma_test /dev/video1 --buffers 16 --count "$HC" --seconds "$HS" \
    > "$HL" 2>&1 &
HPID=$!
sleep 0.5
# sc7f0ctl clamps --timeout to <=300 s, so the client flag and the outer
# timeout both stay just inside that ceiling.
timeout 300 "$CTL" --timeout 290 exec "$CB --count $CC --mode $CM" \
    > "$CL" 2>&1
CEXIT=$?
wait $HPID 2>/dev/null
HEXIT=$?

cat "$DEV/packet_stats" > "$PS1" 2>/dev/null
dmesg | tail -n +$((N0 + 1)) > "$DM1"

echo "CARD_EXIT=$CEXIT HOST_EXIT=$HEXIT"
echo "===== NEW KERNEL MESSAGES THIS PASS: $(wc -l < "$DM1") lines ====="
echo "DPC1 mismatch  : $(grep -c 'DPC1 mismatch' "$DM1")"
echo "timeout ERROR  : $(grep -c 'timed out (>3s)' "$DM1")"
echo "ring full park : $(grep -c 'Host Ring full' "$DM1")"
echo "WARN/BUG/Oops  : $(grep -icE 'warn|bug:|oops|call trace' "$DM1")"
echo "--- packet_stats before ---"; cat "$PS0"
echo "--- packet_stats after  ---"; cat "$PS1"
echo "--- kernel messages (first 12, filtered) ---"
grep -vE '^$' "$DM1" | head -12
