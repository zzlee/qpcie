#!/usr/bin/env bash
# sc7f0_signal_poll.sh - 定期 polling IT6663 / MCU HDMI 信號狀態
#
# 用法: ./sc7f0_signal_poll.sh [interval_sec] [duration_sec]
# 預設: 每 2 秒取樣，持續 60 秒
#
# 需要:
#   - 本機可免密 ssh 到 rd@sc7f0-test.local
#   - 卡片端有 /home/rd/sc7f0ctl (MCU I2C proxy)

set -euo pipefail

INTERVAL="${1:-2}"
DURATION="${2:-60}"

REMOTE="rd@sc7f0-test.local"
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=5 -o ServerAliveCountMax=2"

echo "SC7F0 IT6663 signal poll"
echo "Remote: ${REMOTE}"
echo "Interval: ${INTERVAL}s, Duration: ${DURATION}s"
echo "Press Ctrl-C to stop early"
echo "----------------------------------------------------------------------"

END_TS=$(( $(date +%s) + DURATION ))
SAMPLE=0
while (( $(date +%s) < END_TS )); do
    SAMPLE=$((SAMPLE + 1))
    TS=$(date "+%H:%M:%S")

    # MCU raw 36-byte status block (format: 0xNN 0xNN ...)
    MCU_RAW=$(ssh $SSH_OPTS "$REMOTE" \
        "sudo -n /home/rd/sc7f0ctl exec 'i2ctransfer -y 0 w1@0x32 0x00 r36'" \
        2>/dev/null || echo "i2c_fail")

    if [[ "$MCU_RAW" == "i2c_fail" || -z "$MCU_RAW" ]]; then
        echo "$TS [${SAMPLE}] I2C_FAIL"
        sleep "$INTERVAL"
        continue
    fi

    # Normalize: "0x0f 0x01 ..." -> "0f 01 ..."
    MCU_RAW=$(echo "$MCU_RAW" | sed 's/0x//g; s/0X//g')
    IFS=' ' read -ra bytes <<< "$MCU_RAW"
    if (( ${#bytes[@]} < 36 )); then
        echo "$TS [${SAMPLE}] MCU_SHORT(${#bytes[@]})"
        sleep "$INTERVAL"
        continue
    fi

    st="${bytes[4]}"
    st_dec=$((16#${st}))
    five_v=$(( (st_dec >> 1) & 1 ))
    hpd_gpio=$(( (st_dec >> 2) & 1 ))
    locked=$(( (st_dec >> 6) & 1 ))
    hdmi_mode=$(( (st_dec >> 7) & 1 ))

    h_lo="${bytes[14]}"; h_hi="${bytes[15]}"
    v_lo="${bytes[32]}"; v_hi="${bytes[33]}"
    h_active=$(( (16#${h_hi} * 256) + 16#${h_lo} ))
    v_active=$(( (16#${v_hi} * 256) + 16#${v_lo} ))

    # IT6663 RXP0 bank0 r13/r14/r19 via MCU proxy (one read each, each returns one line)
    R13=$(ssh $SSH_OPTS "$REMOTE" \
        "sudo -n /home/rd/sc7f0ctl exec 'i2ctransfer -y 0 w3@0x33 0x71 0x01 0x13 r1@0x33'" \
        2>/dev/null | sed 's/0x//g' || true)
    R14=$(ssh $SSH_OPTS "$REMOTE" \
        "sudo -n /home/rd/sc7f0ctl exec 'i2ctransfer -y 0 w3@0x33 0x71 0x01 0x14 r1@0x33'" \
        2>/dev/null | sed 's/0x//g' || true)
    R19=$(ssh $SSH_OPTS "$REMOTE" \
        "sudo -n /home/rd/sc7f0ctl exec 'i2ctransfer -y 0 w3@0x33 0x71 0x01 0x19 r1@0x33'" \
        2>/dev/null | sed 's/0x//g' || true)
    it6663_str="${R13:--} ${R14:--} ${R19:--}"

    # Xilinx official HDMI RX status
    XIL=$(ssh $SSH_OPTS "$REMOTE" \
        "sudo -n /home/rd/sc7f0ctl exec 'cat /sys/devices/platform/amba_pl@0/b0010000.hdmi-rx/hdmi_info'" \
        2>/dev/null || echo "xil_fail")

    if [[ "$XIL" == "xil_fail" || -z "$XIL" ]]; then
        xil_str="N/A"
    elif grep -q "No input stream" <<< "$XIL"; then
        xil_str="NO_STREAM"
    else
        RES=$(grep -oP 'Resolution:\s*\K\S+' <<< "$XIL" || true)
        PCLK=$(grep -oP 'Pixel Clock:\s*\K\d+' <<< "$XIL" || true)
        xil_str="${RES:-?} pclk=${PCLK:-?}Hz"
    fi

    echo "$TS [${SAMPLE}] 5v=${five_v} hpd=${hpd_gpio} lock=${locked} mode=${hdmi_mode} ${h_active}x${v_active} it6663=(${it6663_str}) xilinx=${xil_str}"

    sleep "$INTERVAL"
done

echo "----------------------------------------------------------------------"
echo "Polling complete (${SAMPLE} samples over ${DURATION}s)"
