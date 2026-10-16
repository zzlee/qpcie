#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
Live HDMI RX Signal Monitor for SC7F0 ZU4EV over PCIe.

Continuously polls IT6663 HDMI RX status via NUC1262 MCU and PL CSR registers
to guide physical HDMI RX/TX port identification and cable connection.
"""

import sys
import time
import subprocess
import argparse

def parse_mcu_status(hex_str):
    vals = [int(x, 16) for x in hex_str.strip().split()]
    if len(vals) < 16:
        return None
    st = vals[4]
    temp = vals[12]
    h_act = vals[14] | (vals[15] << 8)
    v_act = (vals[32] | (vals[33] << 8)) if len(vals) >= 34 else 0
    return {
        "hdmi_5v": bool(st & (1 << 1)),
        "hpd_asserted": bool(st & (1 << 2)),
        "clock_locked": bool(st & (1 << 6)),
        "hdmi_mode": "HDMI" if (st & (1 << 7)) else "DVI",
        "temp": temp,
        "width": h_act,
        "height": v_act,
    }

def main():
    parser = argparse.ArgumentParser(description="SC7F0 Live HDMI Signal Monitor")
    parser.add_argument("--remote", default="rd@sc7f0-test.local", help="SSH remote user@host")
    parser.add_argument("--timeout", type=int, default=60, help="Monitoring timeout in seconds")
    args = parser.parse_args()

    print("=" * 68)
    print(" 📡 SC7F0 Live HDMI RX Signal Monitor (Port Identification)")
    print("=" * 68)
    print(" Instructions:")
    print("  1. SC7F0 has two physical HDMI ports (TOP and BOTTOM).")
    print("  2. Plug your HDMI source (laptop, PC, camera, generator) into ONE port.")
    print("  3. If this monitor locks onto the signal -> That port is HDMI RX (IN).")
    print("  4. If no signal after 5 seconds -> Switch to the OTHER port.")
    print("-" * 68)

    t_end = time.time() + args.timeout
    last_locked = None

    while time.time() < t_end:
        cmd = f"sudo /home/rd/sc7f0ctl exec 'i2ctransfer -y 0 w1@0x32 0x00 r36; devmem 0xA0000600 32'"
        ssh = ["ssh", "-o", "ConnectTimeout=5", args.remote, cmd]
        res = subprocess.run(ssh, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if res.returncode == 0:
            lines = res.stdout.strip().split("\n")
            if len(lines) >= 2:
                mcu = parse_mcu_status(lines[0])
                pl_status = int(lines[1], 16) if lines[1].startswith("0x") else 0
                if mcu:
                    locked = mcu["clock_locked"] and (mcu["width"] > 0)
                    if locked:
                        print(f"\r \033[92m[LOCKED! HDMI RX ACTIVE]\033[0m Resolution: \033[1m{mcu['width']}x{mcu['height']}\033[0m | Mode: {mcu['hdmi_mode']} | Temp: {mcu['temp']}°C | 5V Det: {mcu['hdmi_5v']} | PL Stat: 0x{pl_status:04X}  ", flush=True)
                        if last_locked is not True:
                            print("\n" + "=" * 68)
                            print(" 🎉 成功偵測到 HDMI 輸入信號！")
                            print(f" -> 當前插入的孔位【確定為 HDMI RX (輸入孔)】！")
                            print(f" -> 解析度: {mcu['width']} x {mcu['height']}")
                            print(f" -> TMDS 5V 偵測: 正常 | 時脈鎖定: 正常 | 晶片溫度: {mcu['temp']}°C")
                            print("=" * 68 + "\n")
                            return 0
                    else:
                        print(f"\r [等候訊號] 5V偵測: {mcu['hdmi_5v']} | 時脈鎖定: {mcu['clock_locked']} | HPD: {mcu['hpd_asserted']} | 晶片溫度: {mcu['temp']}°C (若無信號請插另一個孔)...", end="", flush=True)
                    last_locked = locked
        time.sleep(1.0)

    print("\n\n[-] 監控超時，尚未偵測到鎖定信號。")
    return 1

if __name__ == "__main__":
    sys.exit(main())
