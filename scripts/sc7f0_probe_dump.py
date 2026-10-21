#!/usr/bin/env python3
"""
SC7F0 Hardware Probing and Diagnostic Inspection Tool
Reads the PL hardware probe registers exposed over AXI-Lite / BAR0 (0x0680 - 0x06DC)
to measure physical signals and clocks between IT6663, Video PHY, and HDMI RX IP.
"""

import sys
import subprocess
import time
import argparse

# Register Offsets in BAR0 (PS: 0xA0000000 + offset)
OFFSET_BASE = 0x0680

REGS = [
    (0x0680, "PROBE_VERSION", "Hex"),
    (0x0684, "RX_CLK_FREQ_HZ", "Freq"),
    (0x0688, "DRU_CLK_FREQ_HZ", "Freq"),
    (0x068C, "RXOUTCLK_FREQ_HZ", "Freq"),
    (0x0690, "RX_VIDEO_CLK_FREQ_HZ", "Freq"),
    (0x0694, "TX_CLK_FREQ_HZ", "Freq"),
    (0x0698, "TXOUTCLK_FREQ_HZ", "Freq"),
    (0x069C, "TX_VIDEO_CLK_FREQ_HZ", "Freq"),
    (0x06A0, "PIN_LEVELS", "Pins"),
    (0x06A4, "PULSE_COUNTERS", "Pulses"),
    (0x06A8, "DDC_COUNTERS", "DDC"),
    (0x06AC, "IRQ_COUNTERS", "IRQs"),
    (0x06B0, "CH0_VALID_BEATS", "Dec"),
    (0x06B4, "CH1_VALID_BEATS", "Dec"),
    (0x06B8, "CH2_VALID_BEATS", "Dec"),
    (0x06BC, "RX_VIDEO_SOF", "Dec"),
    (0x06C0, "RX_VIDEO_EOL", "Dec"),
    (0x06C4, "RX_VIDEO_PIXELS", "Dec"),
    (0x06C8, "RAW_RX_CLK_CNT", "Hex"),
    (0x06CC, "RAW_DRU_CLK_CNT", "Hex"),
    (0x06D0, "RAW_RXOUTCLK_CNT", "Hex"),
    (0x06D4, "RAW_RX_VID_CLK_CNT", "Hex"),
    (0x06D8, "RAW_REF100_CLK_CNT", "Hex"),
    (0x06DC, "PROBE_CTRL", "Hex"),
]

def read_card_mem(remote_host, addr):
    cmd = f"sudo sc7f0ctl exec 'devmem 0x{addr:X} 32'"
    if remote_host:
        res = subprocess.run(["ssh", remote_host, cmd], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    else:
        res = subprocess.run(["bash", "-c", cmd], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if res.returncode != 0:
        return 0
    val_str = res.stdout.strip()
    try:
        return int(val_str, 16)
    except ValueError:
        return 0

def format_pins(val):
    det5v = val & 1
    hpd = (val >> 1) & 1
    scl_i = (val >> 2) & 1
    sda_i = (val >> 3) & 1
    scl_o = (val >> 4) & 1
    scl_t = (val >> 5) & 1
    sda_o = (val >> 6) & 1
    sda_t = (val >> 7) & 1
    phy_irq = (val >> 8) & 1
    rx_irq = (val >> 9) & 1
    tx_hpd = (val >> 10) & 1
    tx_rdy = (val >> 11) & 1
    rx_clk_alive = (val >> 14) & 1
    dru_clk_alive = (val >> 15) & 1
    sb_data = (val >> 16) & 0xFF
    sb_valid = (val >> 24) & 1
    ch0_v = (val >> 25) & 1
    ch1_v = (val >> 26) & 1
    ch2_v = (val >> 27) & 1
    vid_v = (val >> 28) & 1
    vid_r = (val >> 29) & 1
    vid_sof = (val >> 30) & 1
    vid_eol = (val >> 31) & 1

    lines = [
        f"5V_Det: {det5v} | HPD_Out: {hpd} | DDC_SCL: {scl_i} (drv_t={scl_t}) | DDC_SDA: {sda_i} (drv_t={sda_t})",
        f"Clock Alive: RX_CLK={rx_clk_alive}, DRU_CLK={dru_clk_alive}",
        f"IRQs: VPHY_IRQ={phy_irq}, RX_IRQ={rx_irq} | TX: HPD={tx_hpd}, REFCLK_RDY={tx_rdy}",
        f"VPHY SB: valid={sb_valid}, data=0x{sb_data:02X} | GTH Valids: CH0={ch0_v}, CH1={ch1_v}, CH2={ch2_v}",
        f"RX SS Video: valid={vid_v}, ready={vid_r}, SOF={vid_sof}, EOL={vid_eol}",
    ]
    return "\n      ".join(lines)

def main():
    parser = argparse.ArgumentParser(description="SC7F0 Hardware Probing Tool")
    parser.add_argument("--host", default="rd@sc7f0-test.local", help="Remote SSH test rig")
    parser.add_argument("--watch", "-w", action="store_true", help="Continuously poll every second")
    args = parser.parse_args()

    print(f"=== Querying SC7F0 Hardware Probing Registers via {args.host} ===")

    while True:
        # Read batch of registers from PS address 0xA0000680 - 0xA00006DC
        # Batch command for faster readout
        offsets = " ".join([f"0x{0xA0000000 + off:X}" for off, _, _ in REGS])
        cmd = f"sudo sc7f0ctl exec 'for a in {offsets}; do devmem $a 32; done'"
        res = subprocess.run(["ssh", args.host, cmd], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if res.returncode != 0:
            print("Failed to read registers from card:", res.stderr)
            sys.exit(1)

        raw_vals = [int(line.strip(), 16) for line in res.stdout.strip().split() if line.strip()]
        if len(raw_vals) != len(REGS):
            print(f"Warning: Expected {len(REGS)} values, got {len(raw_vals)}")
            time.sleep(1)
            continue

        print("-" * 75)
        print(f"Timestamp: {time.strftime('%Y-%m-%d %H:%M:%S')}")
        print("-" * 75)

        for (off, name, fmt), val in zip(REGS, raw_vals):
            if fmt == "Freq":
                mhz = val / 1_000_000.0
                print(f"  [0x{off:04X}] {name:<24} : {val:>10} Hz ({mhz:>8.3f} MHz)")
            elif fmt == "Pins":
                print(f"  [0x{off:04X}] {name:<24} : 0x{val:08X}")
                print(f"      {format_pins(val)}")
            elif fmt == "Pulses":
                edges_5v = val & 0xFFFF
                edges_hpd = (val >> 16) & 0xFFFF
                print(f"  [0x{off:04X}] {name:<24} : 5V_Edges={edges_5v}, HPD_Edges={edges_hpd}")
            elif fmt == "DDC":
                scl_falls = val & 0xFFFF
                sda_edges = (val >> 16) & 0xFFFF
                print(f"  [0x{off:04X}] {name:<24} : SCL_Falls={scl_falls}, SDA_Edges={sda_edges}")
            elif fmt == "IRQs":
                phy_irqs = val & 0xFFFF
                rx_irqs = (val >> 16) & 0xFFFF
                print(f"  [0x{off:04X}] {name:<24} : PHY_IRQs={phy_irqs}, RX_IRQs={rx_irqs}")
            elif fmt == "Dec":
                print(f"  [0x{off:04X}] {name:<24} : {val:>10}")
            else:
                print(f"  [0x{off:04X}] {name:<24} : 0x{val:08X}")

        if not args.watch:
            break
        time.sleep(1)

if __name__ == "__main__":
    main()
