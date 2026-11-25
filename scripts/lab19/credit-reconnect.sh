#!/bin/bash
# Exercise production credit timeout without linking fault injection into vcud.
set -euo pipefail
bin=$(realpath "$1");out=$(realpath -m "$2");[[ $out == "$HOME/sc7f0/"* && ! -e $out ]];mkdir "$out";cd "$out";exec 9<>"$HOME/sc7f0/tmp/.upgrade.lock";flock -n 9
ctl(){ sudo -n "$HOME/sc7f0/bin/sc7f0ctl" --timeout 30 exec "$1"; }
wp=$(systemctl --user is-active wireplumber || :);systemctl --user stop wireplumber
restore(){ local rc=$?;trap - EXIT;ctl 'systemctl kill -s CONT sc7f0-vcud' >/dev/null || rc=1;if [[ $wp == active ]];then systemctl --user start wireplumber || rc=1;fi;exit "$rc";};trap restore EXIT
pid=$(ctl 'systemctl show sc7f0-vcud -p MainPID --value');[[ $pid =~ ^[1-9][0-9]*$ ]];unit=sc7f0-credit-probe-$pid
ctl "test \"\$(readlink /proc/$pid/exe)\" = /usr/bin/sc7f0_vcud && systemd-run --unit=$unit --on-active=8s /bin/sh -c 'test \"\$(readlink /proc/$pid/exe)\" = /usr/bin/sc7f0_vcud || exit 1; kill -STOP $pid && sleep 4 && kill -CONT $pid'" >schedule.log
ko=$HOME/sc7f0/bin/qpcie.ko;[[ $(readelf -n "$ko"|awk '/Build ID:/ {print $NF}') == $(tail -c20 /sys/module/qpcie/notes/.note.gnu.build-id|xxd -p) && $(cat /sys/module/qpcie/refcnt) == 0 ]];sudo -n grep -qx '[[:space:]]*active=0' /sys/kernel/debug/dri/0000:03:00.0/state
if sudo -n fuser /dev/dri/card0 /dev/video0 /dev/video1 /dev/qpcie-*;then exit 1;fi
sudo -n rmmod qpcie;sudo -n insmod "$ko" kms=1;sudo -n udevadm settle --timeout=15
before=$(sudo dmesg|grep -c 'C2 timeout frozen' || true);set +e;HEVC=1 timeout 18 "$bin/sc7f0_record_trace" 14 interrupted.es interrupted.dq >interrupted.log 2>&1;bad=$?;set -e
# The scheduled process resumes vcud independently; don't take a management
# lease before the reconnect capture. Allow STOP/fence cleanup to finish.
sleep 4;[[ $bad == 2 ]];after=$(sudo dmesg|grep -c 'C2 timeout frozen' || true);[[ $after -gt $before ]];HEVC=1 timeout 18 "$bin/sc7f0_record_trace" 6 recovered.es recovered.dq >recovered.log 2>&1;test -s recovered.dq;sudo dmesg|grep -E 'C2 (close|timeout|quarantine)'|tail -8 >credit.log;grep 'C2 close' credit.log|tail -1|grep -q 'quarantine=0';ffmpeg -nostdin -v warning -xerror -f hevc -probesize 64M -analyzeduration 20000000 -i recovered.es -f null - 2>decode.log;test ! -s decode.log;sha256sum *.es *.dq credit.log >MANIFEST.sha256
