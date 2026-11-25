#!/usr/bin/env bash
# Run on host after cold-start attestation. No peer/driver/overlay is uploaded.
# Usage: capture-leg.sh host-tools-dir fresh-leg-dir hevc|avc cbr|vbr 8|16 irregular|ball60|audit
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
bin=$(realpath "$1");out=$(realpath -m "$2");codec=$3;rate=$4;range=$5;load=$6
[[ $bin == "$HOME/sc7f0/"* && $out == "$HOME/sc7f0/"* && ! -e $out && $codec =~ ^(avc|hevc)$ && $rate =~ ^(cbr|vbr)$ && $range =~ ^(8|16)$ && $load =~ ^(irregular|ball60|audit)$ ]]
exec 9<>"$HOME/sc7f0/tmp/.upgrade.lock";flock -n 9
mkdir -p "$out/tmp";export TMPDIR=$out/tmp;cd "$out";ctl(){ sudo -n "$HOME/sc7f0/bin/sc7f0ctl" --timeout 90 exec "$1"; };sys=/sys/bus/pci/devices/0000:03:00.0;P=$(ctl "mktemp -d /run/sc7f0-qualification-$(basename "$out").XXXXXXXX");printf "%s\n" "$P" >ps-workspace;[[ $P =~ ^/run/[a-zA-Z0-9_.-]+$ ]];envfile=/etc/default/sc7f0-vcud
ctl "test -z \"\$(systemctl show sc7f0-vcud -p DropInPaths --value)\" && test -c /dev/sc7f0-stage2 && test \"\$(readlink -f /proc/\$(systemctl show sc7f0-vcud -p MainPID --value)/exe)\" = /usr/bin/sc7f0_vcud && cp '$envfile' '$P/original' && sha256sum /usr/bin/sc7f0_vcud '$P/original'" >packaged-initial
raw=;enc=;mon=;wp=$(systemctl --user is-active wireplumber || :);restore(){ local rc=$?;trap - EXIT;set +e;for pid in "$raw" "$enc" "$mon";do [[ -z $pid ]]||{ kill "$pid" 2>/dev/null;wait "$pid"; };done;ctl "cp '$P/original' '$envfile' && systemctl restart sc7f0-vcud && cmp '$P/original' '$envfile' && systemctl is-active sc7f0-vcud sc7f0-modetest" >restore-card || rc=1;if [[ $wp == active ]];then systemctl --user start wireplumber || rc=1;fi;exit "$rc";};trap restore EXIT
systemctl --user stop wireplumber
fmt=H264;[[ $codec == avc ]]||{ fmt=HEVC;export HEVC=1; };mode=1;peak=40000000;[[ $rate == cbr ]]||{ mode=0;peak=60000000; };sec=625;frames=38400;reps=21;extra=;[[ $load != audit ]]||{ sec=42;frames=3000;reps=1;extra=INTEGRITY=1; }
ctl "printf '%s\\n' SC7F0_CODEC=$codec RATE=$rate SC7F0_AVC_P_RANGE=$range AUDIT=$P/trace EVS=$P/events $extra >'$envfile' && systemctl restart sc7f0-vcud";sleep 3
pid=$(ctl 'systemctl show sc7f0-vcud -p MainPID --value');ctl "journalctl -b _PID=$pid --no-pager | tail -120" >setup;grep -F 'slices=4 IDR=30 prefetch=1' setup;grep -F 'seen=fff' setup;grep -F "component=OMX.allegro.$([[ $codec == avc ]] && echo h264 || echo h265).hardware.encoder" setup;grep -q "mode=$([[ $rate == cbr ]] && echo 2 || echo 1) target=40000 max=$((peak / 1000))" setup
# Management mailbox access retains a maintenance lease until an idle rebind.
# Use the exact module installed by flash, not the build-preflight binary.
ko=$HOME/sc7f0/bin/qpcie.ko
[[ $(readelf -n "$ko" | awk '/Build ID:/ {print $NF}') == $(tail -c20 /sys/module/qpcie/notes/.note.gnu.build-id | xxd -p) ]]
[[ $(cat /sys/module/qpcie/refcnt) == 0 ]];sudo -n grep -qx '[[:space:]]*active=0' /sys/kernel/debug/dri/0000:03:00.0/state
if sudo -n fuser /dev/video0 /dev/video1 /dev/dri/card0 /dev/qpcie-*;then exit 1;fi
sudo -n rmmod qpcie;sudo -n insmod "$ko" kms=1;sudo -n udevadm settle --timeout=15
v4l2-ctl -d /dev/video1 --set-fmt-video=width=3840,height=2160,pixelformat=$fmt -c video_bitrate_mode=$mode,video_peak_bitrate=$peak,video_bitrate=40000000
v4l2-ctl -d /dev/video0 --verbose --set-fmt-video=width=3840,height=2160,pixelformat=NM16 --stream-mmap=4 --stream-count="$frames" --stream-to=/dev/null >raw.log 2>&1 & raw=$!;"$bin/sc7f0_record_trace" "$sec" host.es dq >capture.log 2>&1 & enc=$!;sleep 5;kill -0 "$raw" "$enc";cat "$sys"/{version,hdmi_status,vcu_encoder_config} >runtime
python3 "$here/sample_bus.py" & mon=$!
if [[ $load == ball60 ]];then "$bin/sc7f0_kms_ball" /dev/dri/card0 ball60 >flips.log 2>&1;else { for ((i=0;i<reps;i++));do sleep 3;printf B;sleep 8.5;printf C;sleep .4;printf DE;sleep 12;printf A;sleep 5;done;printf q; }|"$bin/sc7f0_kms" /dev/dri/card0 >flips.log 2>&1;fi
wait "$enc";enc=;wait "$raw";raw=;ctl 'systemctl stop sc7f0-vcud';for n in trace events;do sudo -n "$HOME/sc7f0/bin/sc7f0ctl" --timeout 180 exec "gzip -c '$P/$n'"|gzip -dc >"$n";done;ctl "journalctl -b _PID=$pid --no-pager|tail -30" >end;sudo dmesg|grep 'C2 close'|tail -1 >drain
