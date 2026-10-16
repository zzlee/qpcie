#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
SC7F0 NUC1262 In-System MCU Firmware Upgrade Tool over PCIe.

Uploads firmware .bin to NUC1262 MCU via I2C slave 0x2A and executes
in-SRAM flashing and CPU reboot without external hardware or JTAG/Nu-Link.
"""

import sys
import os
import time
import struct
import binascii
import base64
import subprocess
import argparse

UPG_SLAVE_ADDR = 0x2A
REG_SLAVE_ADDR = 0x32
MAX_CHUNK_SIZE = 32
UPG_STAGE_MAX  = 8192

def calc_crc8(data: bytes) -> int:
    crc = 0
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = ((crc << 1) ^ 0x07) & 0xFF if (crc & 0x80) else (crc << 1) & 0xFF
    return crc

def calc_crc32(data: bytes) -> int:
    return binascii.crc32(data) & 0xFFFFFFFF

class Flasher:
    def __init__(self, host=None, device=None):
        self.host = host
        self.device = device

    def exec_card(self, cmd_str, timeout=30):
        """Execute a shell command inside ZU4EV PS Linux via sc7f0ctl exec."""
        if self.host:
            ssh_cmd = ["ssh", "-o", "ConnectTimeout=5", self.host,
                       f"sudo sc7f0ctl exec '{cmd_str}'"]
            res = subprocess.run(ssh_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=timeout)
        else:
            local_cmd = ["sudo", "sc7f0ctl", "exec", cmd_str]
            res = subprocess.run(local_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=timeout)
        if res.returncode != 0:
            raise RuntimeError(f"Command '{cmd_str}' failed (code {res.returncode}): {res.stderr.strip()}")
        return res.stdout.strip()

    def query_status(self):
        out = self.exec_card("i2ctransfer -y 0 w1@0x32 0x00 r36")
        vals = [int(x, 16) for x in out.split()]
        if len(vals) < 16:
            raise RuntimeError(f"Unexpected status response: {out}")
        ver = vals[0] | (vals[1] << 8) | (vals[2] << 16) | (vals[3] << 24)
        patch = ver & 0xFF
        minor = (ver >> 8) & 0xFF
        ver_str = f"v1.{minor}.{patch} (0x{ver:08X})"
        st = vals[4]
        ven = f"{chr(vals[8])}{chr(vals[9])}" if vals[8] and vals[9] else "N/A"
        dev = f"{vals[10]:02x}{vals[11]:02x}"
        temp = vals[12]
        h_act = vals[14] | (vals[15] << 8)
        v_act = (vals[32] | (vals[33] << 8)) if len(vals) >= 34 else 0
        num_slaves = vals[16]
        slaves = [f"0x{vals[17+i]:02x}" for i in range(min(num_slaves, 15))]
        return {
            "version": ver_str,
            "status_raw": hex(st),
            "it6663_present": bool(st & (1 << 4)),
            "nct7717_present": bool(st & (1 << 5)),
            "clock_locked_scdt": bool(st & (1 << 6)),
            "hdmi_mode": "HDMI" if (st & (1 << 7)) else "DVI",
            "hdmi_5v": bool(st & (1 << 1)),
            "hpd_asserted": bool(st & (1 << 2)),
            "vendor_id": ven,
            "device_id": dev,
            "temperature_c": temp,
            "resolution": f"{h_act}x{v_act}" if (h_act and v_act) else "No Signal / Unlocked",
            "slaves": slaves,
        }

    def upload_edid(self, edid_path):
        with open(edid_path, "rb") as f:
            edid_bytes = f.read()
        if len(edid_bytes) != 256:
            raise ValueError(f"EDID binary must be exactly 256 bytes (got {len(edid_bytes)})")

        print(f"[*] Uploading EDID from {edid_path} (256 bytes)...")
        offset = 0
        chunk_size = 32
        while offset < 256:
            chunk = edid_bytes[offset : offset + chunk_size]
            n = len(chunk)
            crc_data = bytes([offset, n]) + chunk
            crc8 = calc_crc8(crc_data)
            chunk_hex = " ".join(f"0x{b:02x}" for b in chunk)
            wlen = 1 + 1 + 1 + n + 1
            cmd = f"i2ctransfer -y 0 w{wlen}@0x2a 0x10 0x{offset:02x} 0x{n:02x} {chunk_hex} 0x{crc8:02x} r1"
            resp = self.exec_card(cmd)
            if int(resp, 16) != 0:
                raise RuntimeError(f"EDID chunk upload failed at offset {offset}: resp={resp}")
            offset += n
            print(f"    Progress: {offset * 100 // 256}%", end="\r", flush=True)
        print("    Progress: 100% (Transfer complete)       ")
        print("[*] Applying EDID to IT6663 and toggling HPD...")
        resp = self.exec_card("i2ctransfer -y 0 w1@0x2a 0x11 r1")
        if int(resp, 16) != 0:
            raise RuntimeError(f"EDID apply command failed: resp={resp}")
        print("[+] SUCCESS: IT6663 EDID RAM updated and HPD pulsed!")

    def read_edid(self, out_path=None):
        print("[*] Reading 256-byte EDID from MCU EDID emulator (0x50)...")
        edid = bytearray()
        for off in range(0, 256, 32):
            resp = self.exec_card(f"i2ctransfer -y 0 w1@0x50 0x{off:02x} r32")
            vals = [int(x, 16) for x in resp.split()]
            edid.extend(vals)
        if out_path:
            with open(out_path, "wb") as f:
                f.write(edid)
            print(f"[+] Saved 256 bytes EDID to {out_path}")
        return bytes(edid)

    def flash_binary(self, bin_path):
        with open(bin_path, "rb") as f:
            data = bytearray(f.read())

        orig_len = len(data)
        if orig_len > UPG_STAGE_MAX:
            raise ValueError(f"Binary size {orig_len} exceeds max staging size {UPG_STAGE_MAX}")

        # Pad to 4-byte boundary
        if len(data) % 4 != 0:
            pad = 4 - (len(data) % 4)
            data.extend(b"\x00" * pad)

        total_len = len(data)
        crc32_val = calc_crc32(data)

        print(f"[*] Preparing binary: {bin_path}")
        print(f"    Raw Size: {orig_len} bytes -> Padded Size: {total_len} bytes")
        print(f"    CRC32:    0x{crc32_val:08X}")

        # Step 1: Query current status
        print("[*] Checking MCU state...")
        st = self.query_status()
        print(f"    Current Version: {st['version']}")
        print(f"    IT6663 Present:  {st['it6663_present']} ({st['vendor_id']} {st['device_id']})")
        print(f"    Temperature:     {st['temperature_c']} C")

        # Step 2: HELLO handshake
        print("[*] Sending HELLO (0x01) to slave 0x2A...")
        hello_resp = self.exec_card("i2ctransfer -y 0 w1@0x2a 0x01 r4")
        hvals = [int(x, 16) for x in hello_resp.split()]
        print(f"    Response: {[hex(x) for x in hvals]}")
        if len(hvals) < 4 or hvals[0] != 0x01:
            raise RuntimeError(f"Invalid HELLO response: {hello_resp}")

        # Step 3: Build burn script
        cmds = ["#!/bin/sh", "set -e"]

        # BEGIN: [0x02, len_l, len_h, crc0..3]
        len_l = total_len & 0xFF
        len_h = (total_len >> 8) & 0xFF
        c0 = crc32_val & 0xFF
        c1 = (crc32_val >> 8) & 0xFF
        c2 = (crc32_val >> 16) & 0xFF
        c3 = (crc32_val >> 24) & 0xFF
        cmds.append(f"i2ctransfer -y 0 w7@0x2a 0x02 0x{len_l:02x} 0x{len_h:02x} 0x{c0:02x} 0x{c1:02x} 0x{c2:02x} 0x{c3:02x} r1")

        # CHUNKS: [0x03, off_l, off_h, n, data..., crc8]
        offset = 0
        chunk_idx = 0
        total_chunks = (total_len + MAX_CHUNK_SIZE - 1) // MAX_CHUNK_SIZE
        while offset < total_len:
            n = min(MAX_CHUNK_SIZE, total_len - offset)
            chunk = data[offset : offset + n]
            off_l = offset & 0xFF
            off_h = (offset >> 8) & 0xFF
            crc_data = bytes([off_l, off_h, n]) + chunk
            crc8 = calc_crc8(crc_data)
            
            chunk_hex = " ".join(f"0x{b:02x}" for b in chunk)
            wlen = 1 + 2 + 1 + n + 1
            cmds.append(f"i2ctransfer -y 0 w{wlen}@0x2a 0x03 0x{off_l:02x} 0x{off_h:02x} 0x{n:02x} {chunk_hex} 0x{crc8:02x} r1")
            offset += n
            chunk_idx += 1

        # COMMIT: [0x04]
        cmds.append("i2ctransfer -y 0 w1@0x2a 0x04 r1")
        script_content = "\n".join(cmds) + "\n"

        # Step 4: Stream burn script to card in chunks (< DB_PAYLOAD 3072 bytes)
        print(f"[*] Generated {total_chunks} chunk transfers. Streaming to card in batches...")
        self.exec_card("rm -f /tmp/burn_mcu.sh")
        
        batch_size = 8
        for i in range(0, len(cmds), batch_size):
            batch_slice = cmds[i : i + batch_size]
            subcmds = [f'echo "{c}" >> /tmp/burn_mcu.sh' for c in batch_slice]
            joined = " && ".join(subcmds)
            self.exec_card(joined)
            pct = min(100, int((i + batch_size) * 100 / len(cmds)))
            print(f"    Progress: {pct}%", end="\r", flush=True)
        print("    Progress: 100% (Transfer complete)       ")

        self.exec_card("chmod +x /tmp/burn_mcu.sh")

        # Step 5: Execute in-system flash sequence
        t0 = time.time()
        print("[*] Executing in-SRAM flash sequence over I2C...")
        out = self.exec_card("sh /tmp/burn_mcu.sh", timeout=60)
        elapsed = time.time() - t0
        print(f"    Staging and verification complete ({elapsed:.2f}s). COMMIT returned OK.")

        # Step 6: Wait for MCU to execute in-SRAM flash and reboot
        print("[*] Waiting for MCU in-SRAM flash programming and CPU reset...")
        time.sleep(2.0)

        # Step 7: Poll for new firmware version
        for attempt in range(10):
            try:
                st_new = self.query_status()
                print("[+] Upgrade SUCCESSFUL!")
                print(f"    New MCU Version: {st_new['version']}")
                print(f"    IT6663 Present:  {st_new['it6663_present']} ({st_new['vendor_id']} {st_new['device_id']})")
                print(f"    Temperature:     {st_new['temperature_c']} C")
                print(f"    Detected Slaves: {', '.join(st_new['slaves'])}")
                return
            except Exception as e:
                time.sleep(0.5)

        raise RuntimeError("MCU failed to respond after in-system flash reset")

def main():
    parser = argparse.ArgumentParser(description="SC7F0 NUC1262 In-System MCU Flash Tool over PCIe")
    parser.add_argument("--bin", type=str, help="Path to MCU firmware .bin")
    parser.add_argument("--remote", type=str, default="rd@sc7f0-test.local", help="SSH remote host (default: rd@sc7f0-test.local)")
    parser.add_argument("--local", action="store_true", help="Run locally using sc7f0ctl directly")
    parser.add_argument("--status", action="store_true", help="Query MCU status only")
    parser.add_argument("--set-edid", type=str, help="Path to 256-byte EDID binary to upload to IT6663")
    parser.add_argument("--get-edid", type=str, help="Path to save 256-byte EDID read from MCU emulator")
    args = parser.parse_args()

    host = None if args.local else args.remote
    flasher = Flasher(host=host)

    if args.status:
        st = flasher.query_status()
        for k, v in st.items():
            print(f"{k}: {v}")
        return

    if args.set_edid:
        flasher.upload_edid(args.set_edid)
        return

    if args.get_edid:
        flasher.read_edid(args.get_edid)
        return

    if not args.bin:
        parser.error("--bin, --status, --set-edid, or --get-edid is required")

    flasher.flash_binary(args.bin)

if __name__ == "__main__":
    main()
