# SC7F0 HDMI08 live capture investigation (2026-10-21; validated 2026-10-22)

## Scope and acceptance

Target: **HDMI source → IT6663 TXP1 → GTH/VPHY → HDMI RX SS → PL capture → PCIe C2H → x86 host memory → V4L2 → GStreamer display**.
The PS owns HDMI/VPHY control and publishes telemetry; PS DDR is **not** the live capture destination.

**Validated 2026-10-22:** native 4K60 RGB HDMI capture reaches x86 host memory and renders through GStreamer/Wayland. Native PNG inspected; this is not just lock, caps, PLAYING or STREAMON. A card-PS warm-reboot/IT6663 renegotiation limitation remains, documented below.

## Baseline on the test host

- Test host `rd@sc7f0-test.local`, PCI device `0000:03:00.0`, kernel `7.0.0-38-generic`.
- Before this task: FPGA `0x26102007`, MCU v1.1.15. MCU firmware remains v1.1.15; only its runtime was restarted during recovery.
- Official RX and host telemetry: 3840×2160p60, RGB, 8 bpc, pixel rate 594 MHz.
- HDMI RGB GStreamer fakesink: caps/STREAMON succeed, frame completion times out.
- TPG RGB GStreamer fakesink: 120 buffers, about 60 FPS, normal EOS.
- HDMI perf counters show 24,883,200 payload bytes (one RGB frame), then no progress.
- Accepted capture counts showed malformed raster boundaries (e.g. 42 SOFs, 2129 EOLs), not a completed frame.

Raw evidence: `build/validation/sc7f0-live-capture/` (`rgb-baseline.log`, `tpg-baseline.log`, `tpg-rgb-bandwidth.log`).

## Rate mismatch, not simply average PCIe bandwidth

`pcie4_uscale_plus_0.xci` and HDMI07 timing report confirm **125 MHz PCIe user_clk**.
The old top connected both the HDMI ingress FIFO read clock and `video_clk` (capture engine) to that clock. Comments claiming a separate 150 MHz engine were not accurate for this top.

HDMI 4-PPC active pixels arrive at 148.5 MHz. For a 4K60 raster:

- 960 active beats per line; 1100 total beats per line.
- 2160 active lines; 2250 total lines.
- Active-raster duration: `2160 × 1100 / 148.5 MHz = 16 ms`.
- Beats produced: 2,073,600; maximum 125 MHz beats drained in that interval: 2,000,000.
- Backlog: **73,600 padded beats (~1.2 MB)** before even considering DMA stalls. The old FIFO holds only 1024 beats.
- Full-frame RGB payload requirement is **1,492,992,000 B/s (~11.94 Gbit/s)**. PCIe Gen3 x4 theoretical encoded payload ceiling is ~3.94 GB/s before TLP overhead; earlier conversation claims of 8 Gbit/s RGB or 12.8 Gbit/s Gen3 x4 were incorrect.

Even forcing the idle mux to drain HDMI continuously, hardware showed only ~3.4M AXIS valid beats/s and ~3500 EOL/s, instead of ~124.4M and 129600. This supports the native-to-AXIS bridge overflowing during the active raster. Existing probe SOF/beat counters before redeployment count TVALID without TREADY and cannot be used as accepted-transfer counts.

## Rejected software-only experiment

Temporarily resetting the video bridge before descriptor launch did not restore capture. The experimental driver was reverted locally and replaced on the host by the final source-built driver. No MCU or PS HDMI/VPHY changes were made.

## HDMI08 implementation

Deployed hardware version **0x26102201** (updated after the 2026-10-22 CDC review):

- Derive a 150 MHz capture clock with BUFGCE_DIV(2) from Si5341 OUT8's 300 MHz input. The FSBL clock table already enables OUT8 at 300 MHz.
- HDMI ingress crosses RX video clock → capture150, not PCIe125.
- TPG/overlay stay on PCIe125 and cross into capture150 via a 32-beat distributed-RAM AXIS FIFO.
- Reuse `video_req_cdc` for capture150 → PCIe125, retaining 128-bit engine data and 256-bit requester data.
- Drain unowned live HDMI frames continuously. The engine discards a partial raster until the next accepted SOF.
- XPM synchronizers for source selection, RGB pack mode, busy and Gray-coded stream counters.
- Include capture/owner busy in the DMA drain indication, rather than considering an empty packet FIFO sufficient while more writes may still be produced.
- HDMI RGB packing follows the official driver's `MEDIA_BUS_FMT_RBG888_1X24`: R:B:G bus fields become R,G,B host bytes. YUV444 V:U:Y remains Y,U,V for NV12 conversion. No CSC or 422/420 expander is added.
- Host refuses incompatible live formats/depth/interlace instead of calling RGB bytes NV12. Live S_FMT no longer resets/reprograms the TPG; source changes during streaming are refused; STREAMOFF preserves mux selection while disabling descriptor fetch.

### Resource correction

The first candidate used a 4096-beat HDMI FIFO plus a block-RAM TPG FIFO. Placement failed DRC: RAMB resources exceeded ZU4EV capacity. HDMI07 was already at **127.5/128 BRAM tiles**.
The final candidate keeps the HDMI FIFO at 1024 and uses distributed RAM for TPG. No functional channels were removed to make it fit. The failed candidate was not deployed.

## Tests

- Initial actual-XPM 4K60 RGB and NV12 tests: 2 frames each, zero overflow/protocol errors.
- Negative control with the old 125 MHz / 1024 FIFO loses 218132 beats in the same simulation.
- Final-size regression `scripts/test_sc7f0_live_video.tcl` includes the 32-beat TPG CDC as well as HDMI FIFO, converter, request CDC and 256-bit RQ encoder. Check logs for TB_PASS; do not infer success from simulator exit code alone.
- `tb/sc7f0_hdmi_pack_tb.sv`: all four pixels' RGB/YUV component and PPC order verified with Icarus.
- Python diagnostics/preview tests: 38 passed on the final source (scratch directory `/tmp/opencode` must exist).
- Host driver compiled against the test host's current kernel. Missing BTF/vmlinux warning is unrelated to module functionality.

## Build and deployment procedure

```sh
source /opt/Xilinx/Vivado/2023.2/settings64.sh
vivado -mode batch -source scripts/test_sc7f0_live_video.tcl
SC7F0_TEST_NV12=1 vivado -mode batch -source scripts/test_sc7f0_live_video.tcl
vivado -mode batch -source scripts/build_sc7f0_hdmi_08.tcl
```

HDMI08 uses a separate `build/qpcie_zu4ev_live_proj` (`qpcie_zu4ev_live.runs`), leaving HDMI07 artifacts intact. The build refuses XSA export when setup/hold fails.

User explicitly approved backing up HDMI07, updating card eMMC and rebooting card PS using the existing PCIe two-stage upgrade procedure. Do not reboot the x86 host unnecessarily. Preserve `upgrade_hdmi07.tar.gz` and the installed driver backup before any persistent change.

The boot packager now accepts `SC7F0_IMPL_DIR` and `SC7F0_IMG_DIR` so the new `.runs` directory cannot silently cause packaging of the old bitstream. Match the packaged `.bit` with the XSA's included `.bit` before deployment. Import the final XSA into PetaLinux through the project Docker make helper, then rebuild/package the matching boot components.

## Preview on the host desktop

```sh
python3 scripts/sc7f0_hdmi_preview.py
# bounded headless DMA check
python3 scripts/sc7f0_hdmi_preview.py --sink fake --frames 120 --timeout 15
# explicit local Wayland desktop (avoids SSH X11 forwarding)
XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 \
  python3 scripts/sc7f0_hdmi_preview.py --sink wayland --timeout 30
```

The script forces HDMI and disables the TPG pacer. It selects RGB for RGB8 or NV12 for YUV444/8, with no TPG fallback. Display is scaled to at most 1920×1080; capture/DMA remain native size. A deadline returns 124 and is not itself a success assertion.

## 2026-10-22 timing / CDC correction

The first resource-fitting candidate completed implementation, but failed setup timing (WNS −3.866 ns, 1104 endpoints); XSA export was withheld. Its 150 MHz capture domain itself passed (+1.014 ns setup, +0.014 ns hold). The failures exposed actual old CDC problems, not a reason to blanket-disable clock checks:

- Probe asynchronous stream pin levels went directly into CSR read logic; now individually synchronized. Probe counters now use independent XPM Gray CDCs; frequency-meter request/ack toggles use XPM single-bit CDC. The held frequency snapshot retains its bounded bundled-data max-delay constraint.
- `video_req_cdc` encoded binary→Gray combinationally before synchronizing. It now uses registered XPM Gray transfer with skew/delay constraints.
- Request FSMs shared an asynchronous combined reset. Each domain now releases its reset synchronously; async FIFO reset release is synchronized to its write clock. The SGL/loopback FIFOs received the same write-clock reset correction.
- Hardware/probe version bumped to 0x26102201; no failing candidate was deployed.

Additional regression `scripts/test_sc7f0_cdc.tcl` passed: complete 128/256-byte payload checks, read-side stalls, EOF, spurious ready while idle, reset with the source clock stopped, and probe backpressure counting.

Host driver safety checks passed on HDMI07 before FPGA deployment: attempts to switch source while streaming return EBUSY; NV12-on-RGB STREAMON is refused. Pre-enable rejection now cancels queued descriptor doorbells before returning buffers. Two rejected starts left head/tail at zero, followed by successful TPG RGB capture of 120 GStreamer buffers (`failed-start-recovery.log`). WirePlumber was restored after module reload.

## Final deployment / display results

### Implementation and packaging

- Routed setup **+0.750 ns**, hold **+0.009 ns**; zero setup/hold/pulse-width failing endpoints, zero unclocked registers or unconstrained internal endpoints.
- BRAM **127.5/128 tiles**. Bitgen: zero errors/critical warnings; vendor/advisory warnings remain. CDC findings were reviewed, not blanket-waived; see `build/validation/sc7f0-live-capture/hdmi08-cdc-review.md`.
- Final XSA imported through the Docker PetaLinux helper; all 4418 build tasks succeeded (4236 cached). Rebuilt boot components, enabled existing lab debug/HDMI/upgrade services in the rootfs, and packaged in isolated `build/hdmi08-26102201/images/` without publishing over the HDMI07 installer.
- XSA `.bit`, implementation `.bit` and packaged `.bit` match byte-for-byte. Packaged DT bindings/interrupts checked against expected addresses.
- `BOOT.BIN` SHA-256: `0ad4ad62d9dae7b59a747dc58a1de148028cf15173b9f59b32af64d83a9a7594`.
- `image.ub` SHA-256: `716518020be5d72da87d121841c0c34fcc20389ba49e82ef1e3af06264829f60`.
- `build/upgrade_hdmi08.tar` includes BOOT.BIN, image.ub, boot.scr and manifest.sha256. VERIFY reached 0x05 without eMMC writes; COMMIT reached 0x04; explicit eMMC SHA-256 readback matched before reboot.
- Card PS POR/rescan activated **0x26102201** with build date 20261022. x86 host boot ID remained `96c23592-33af-4211-96f5-8f7752b2716b`; no host reboot occurred.

### Actual host capture and rendering

| Test | Result |
|---|---|
| TPG RGB24 3840×2160, 120 buffers | normal EOS, 2.104 s, drop counter 0 |
| HDMI RGB24 3840×2160, 300 buffers | normal EOS, 5.016 s, steady 60 FPS, drop counter 0 |
| HDMI RGB24, 1800 buffers | normal EOS, 30.017 s, steady 60 FPS, sink dropped 0, DMA drops 0, overflow 0 |
| Measured live PCIe payload | 1423.24 MiB/s, approximately 1.49 GB/s |
| Hardware source/format during live capture | CTRL 0x00200111: forced HDMI=2, RGB24=1 |
| Wayland preview, 300 source buffers | actual waylandsink render notifications, steady approximately 60 FPS, normal EOS; 2 compositor/sink drops reported during this run |
| Native PNG | 3840×2160 RGB image saved and visually inspected: real HDMI source UI, not TPG; no apparent tearing/component-order error |
| TPG NV12 1920×1080, pacer enabled, 120 buffers | normal EOS, 2.015 s, approximately 60 FPS |
| HDMI STREAMON/OFF | 10 consecutive runs ×30 buffers passed |
| Source switch during live capture | EBUSY; hardware source stayed forced HDMI |
| Invalid NV12-on-RGB start/retry | twice rejected, ring heads/tails zero; subsequent valid HDMI capture passed |

Hardware frame counters may be one ahead of requested `num-buffers` when a queued next frame completes during pipeline shutdown; GStreamer delivered the requested count and normal EOS. This is not counted as a rendered frame.

Native image: [hdmi08-source.png](../build/validation/sc7f0-live-capture/hdmi08-source.png). Evidence logs: `hdmi08-live-300.log`, `hdmi08-wayland-300.log`, `hdmi08-long.log`, `hdmi08-long-gst.log`, `hdmi08-restarts.log`, `hdmi08-final-host.log`. Visual inspection is not a calibrated colorimetry test.

The tested driver was installed in `/lib/modules/7.0.0-38-generic/extra/qpcie.ko` and `/home/rd/qpcie.ko`, with depmod run. Both and the tested isolated build have SHA-256 `4e74fd47a51a00051a2d429e6d5a43082db247a193eabe3aceede3f0ec9e4b50`. Original installed/home modules remain backed up separately in `/home/rd/sc7f0-live-test/`.

### Remaining warm-reboot limitation / recovery

After the card-PS reboot, the IT6663 upstream remained locked, but downstream TXP1 C0 read 0x23 instead of the configured HDMI2 clock-ratio/scrambling bits. Probe RX ref was approximately 594 MHz; the Xilinx PHY remained idle. MCU firmware polling only reconfigures TXP1 on source-policy changes and does not currently recover a downstream FPGA/PS restart automatically.

A **runtime MCU restart**, without flashing/changing v1.1.15, restored downstream negotiation; RX ref/RX video/RXOUT settled to approximately 148.487 MHz and official RX/host telemetry returned to RGB 4K60. The five-second early sample was still unlocked; wait for actual `Status: Signal Locked`, not a fixed sleep.

If this recurs after card-PS reboot, stop capture and run on the x86 test host:

```sh
sudo /home/rd/sc7f0ctl exec 'i2ctransfer -y 0 w2@0x32 0x06 0x01'
# Wait until this reports Signal Locked, then start preview:
cat /sys/bus/pci/devices/0000:03:00.0/hdmi_status
```

This is a documented recovery requirement, not a claim that automatic warm-reboot recovery is fixed. Full cold-boot recovery and runtime source format changes have not been revalidated here. Audio was not part of this display acceptance.

### Active desktop preview / rollback

Preview was left running as a transient **user** service, `sc7f0-hdmi08-preview.service`, on `rd@sc7f0-test.local`. It is not enabled at login/boot. Capture remains native 3840×2160; the desktop window is scaled to 1920×1080. At 11:42 the live service had rendered 13,189 frames at average 59.98 FPS with six GUI-sink drops; hardware DMA drops/overflow remained zero (`hdmi08-preview-active.txt`). Source stayed forced HDMI and WirePlumber was active.

```sh
systemctl --user status sc7f0-hdmi08-preview
journalctl --user -u sc7f0-hdmi08-preview -n 10
systemctl --user stop sc7f0-hdmi08-preview
# Restart manually from the desktop terminal if needed:
python3 /home/rd/sc7f0-live-test/sc7f0_hdmi_preview.py --sink wayland
```

HDMI07 rollback archive `build/upgrade_hdmi07.tar.gz` and `/home/rd/upgrade_hdmi07.tar.gz` match the pre-upgrade eMMC files by SHA-256. A separate `.backup_hdmi07_20261022/` copy remains on the card's boot partition, in addition to the upgrade daemon transaction backup. Original BOOT.BIN SHA-256 is `dbf021cf61f8047d8653b6731df1e545dbaab62ecca1529d38182dfa8929780a`. Use the same verified two-stage upgrade procedure to roll back if required; do not reboot the host.
