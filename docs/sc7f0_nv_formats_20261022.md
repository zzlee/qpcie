# SC7F0 NV12 / NV16 correction and upgrade validation (2026-10-22)

## Status

This is the historical acceptance record for rev04 on 2026-10-22, not a claim
about the card's current running image or liveness.

**`0x26102204` deployed and hardware accepted.** Real HDMI RGB8 -> NV12M / NV16M
3840x2160 capture, PCIe C2H into host RAM, raw-frame PNG inspection and actual
Wayland rendering all pass. RGB24 remains working. No x86 reboot was performed.
Evidence: `build/validation/sc7f0-nv-formats/`; test-host evidence:
`rd@sc7f0-test.local:/home/rd/sc7f0-nv-formats/`.

## Corrected diagnosis of the earlier flashing failures

`sc7f0-test.local` is the **x86 host**, not the card PS. The card runs aarch64
PetaLinux. Commands on PS must go through:

```sh
ssh rd@sc7f0-test.local "sudo /home/rd/sc7f0ctl exec 'uname -a; ps -ef'"
ssh rd@sc7f0-test.local "sudo /home/rd/sc7f0ctl exec 'tail -n 50 /var/log/messages'"
```

All three PS services are active: `qpcie-debugd`, `qpcie-hdmi-daemon`,
`qpcie-upgrade-daemon`. Querying `journalctl -t qpcie_upgrade_daemon` alone misses
this image's BusyBox syslog output; the daemon's messages are in
**PS `/var/log/messages`**. Missing host processes / empty journal do NOT prove a
missing PS daemon. An aarch64 binary cannot execute directly on the x86 host.
The prior claims that SD flashing was necessary or that PL timeout produced E1
were unsupported and are withdrawn.

Reproduced old `build/hdmi08-26102203/update_raw.tar`, VERIFY only:

```
VERIFY: CRC32 OK (0xED7F6492, 48711680 bytes); staging tarball
VERIFY: invalid archive (only bounded ustar files allowed)
```

The archive contains only `BOOT.BIN` and `image.ub`, missing mandatory
`boot.scr` (and has no SHA manifest). E1 is a generic verify failure here,
**not evidence of a DMA CRC mismatch or protocol incompatibility**.

New `scripts/package_sc7f0_upgrade.py` requires BOOT.BIN, image.ub, boot.scr,
adds manifest.sha256, writes deterministic ustar with bare allowlisted regular
file names only, and refuses empty/oversized/missing files or output overwrite.
Raw `.tar` or `.tar.gz` are supported. Tests use the actual C daemon parser.
The host C tool now rejects incomplete `-b/-k/-c` combinations before card access.

Proof on the same running `0x26102201` PS daemon: a newly packed **known-good
rollback01** bundle reaches `VERIFIED 0x05`, CRC32 `0x732E364A`, and all SHA hashes
match. This was **VERIFY only; no COMMIT and no eMMC modification**.

## Capture code corrections

- Correct V4L2 formats: `NV12M` (NM12) and `NV16M` (NM16), two independent memory
  planes, Y followed by interleaved Cb/Cr in plane1. Neither is YUV420/I420 or
  YUV444. NV16 is **4:2:2**, not full 4:4:4 chroma.
- Plane sizes: NV12 Y=`stride*height`, UV=`stride*height/2`; NV16 both
  `stride*height`. The earlier edit broke the default NV12M UV allocation.
- NV12 keeps the rounded 2x2 chroma box filter. NV16 averages adjacent horizontal
  chroma samples on **every row**; no vertical decimation. Its thin-descriptor
  fetcher must consume a full-height UV plane, not the old half-height target.
- Restore Y line-stride advancement. The previous uncommitted change ignored
  padding. Tests verify padding stays untouched in both linear and SG modes.
- Remove unconditional debug `$display` loops from synthesizable RTL.
- The previous `sim_nv12_engine.tcl` named a nonexistent top and did not enforce
  PASS. It now runs twelve fail-closed byte-exact regressions.
- Real source is RGB8. A planar descriptor alone cannot convert RGB into YUV.
  Add an elastic 4-PPC, three-stage RGB -> limited-range BT.709 YUV444 converter
  before the RX FIFO; CH0_CTRL[9] selects it. Output RGB bypasses with identical
  marker/data latency. Mode bits use XPM CDC. NV12/NV16 subsampling follows.
- Driver permits RGB-input NV capture only on FPGA >=`0x26102204`, sets bit9
  only for live RGB input, and advertises NV16M only for channel0 capture on
  compatible hardware. No silent TPG fallback.
- Still unsupported: native YUV422/420 input expansion, deep color, interlace,
  YUV input -> RGB conversion. Do not reinterpret those streams as YUV444.

At 3840x2160:

| Format | Y / RGB plane | UV plane | 60 FPS payload |
|---|---:|---:|---:|
| RGB24 | 24,883,200 | 0 | 1,492,992,000 B/s |
| NV12M | 8,294,400 | 4,147,200 | 746,496,000 B/s |
| NV16M | 8,294,400 | 8,294,400 | 995,328,000 B/s |

## Verification completed before deployment

- `bash scripts/test_sc7f0_nv_formats.sh`: 12 PASS. Byte-exact Y/UV including
  chroma rounding/overflow, pre-SOF discard, payload stalls, 256/128-byte
  requests, tight/padded stride, linear/SG; CSC colors/bypass/markers under
  backpressure; NV12/NV16 thin-ring plane lengths and backpressure.
- `python3 -m unittest discover -s scripts/tests`: 42 PASS.
- `python3 tb/qpcie_archive_verify_tb.py`: strict archive/manifest/tamper PASS.
- `scripts/sim_zu4ev_ps_axi_protocol.tcl`: actual protocol converter PASS.
- `scripts/test_sc7f0_cdc.tcl`: CDC payload/backpressure/EOF/reset PASS.
- Driver builds for host kernel `7.0.0-38-generic`; new driver loaded with
  explicit videobuf2 dependencies after modprobe removal unloaded them.
- New bounded tester `test_app/v4l2_capture_verify.c` actually STREAMONs,
  polls, checks each plane's returned bytesused, sequence and error flags,
  STREAMOFFs, and optionally saves one complete frame. Earlier tester omitted
  STREAMON and used incorrect mplane structures; its output was not valid proof.
- Running old FPGA with new driver: NV12 TPG120 completes with correct plane
  sizes; real HDMI RGB120 completes at ~59.93 FPS / ~1.49 GB/s. NV16 remains
  unadvertised until new FPGA is activated.
- Actual-XPM 4K60 RGB / NV12 / NV16: two frames each PASS, zero overflow/errors;
  payload totals 49,766,400 / 24,883,200 / 33,177,600 bytes. All include the new
  CSC/bypass stream stage. Old125MHz negative control loses218132beats.
- Routed setup +0.805ns, hold +0.010ns, zero failing setup/hold/pulse endpoints;
  BRAM127.5/128, LUT75546/87840, DSP82/728. Bus skew all MET. DRC0errors with
  112 warnings, including DSP pipelining advisories (not a warning-free claim).
  New pack/CSC mode CDC paths are recognized CDC-3, four destination flops.
  Existing FIFO/reset/vendor diagnostic advisories retain the baseline review.
- PetaLinux4418tasks PASS, XSA/bit byte-identical; rootfs retains debug exec,
  HDMI telemetry and upgrade services. Package parser/SHA offline gate PASS.

## Rollback and deployment policy

No x86 reboot is performed. Host boot ID before this work:
`0cad2c04-587c-429c-8bd7-3e7dfdd22db4`.

Known-good 26102201 BOOT/image/script are backed up on card at
`/run/media/BOOT-mmcblk0p1/.backup_hdmi08_26102201/` and SHA verified. Existing
HDMI07 backups are retained. Host home/installed kernel modules are backed up in
`/home/rd/sc7f0-nv-formats/qpcie-{home,installed}-before.ko`.

All gates completed before deployment. `scripts/sc7f0_package.sh` and
`scripts/sc7f0_flash.sh` were executed on the frozen `build/sc7f0-26102204/`
release: VERIFIED05 -> COMMIT04 -> independent eMMC SHA readback -> card-only
POR/rescan -> active26102204, all three PS daemons running. Host boot ID unchanged.
Remote upgrade log/module backups: `/home/rd/sc7f0-upgrade.NhYqnSi3/`.
Installed/home host module SHA:
`b32a79463e9bcf067d05ca2ac4057f5b8e672655e193c348362919d25f7715f6`.

Payload SHA:
- BOOT.BIN `f8bb8530a1572fc34612862a33cadfdcc99a187e156b917ff28f79574081cfee`
- image.ub `417d786ec3099fc4ec67ad8211237256552f47f6f33d4ea62f3ec393498a3022`
- boot.scr `14c14ececc4b35eb6ac10253f06a0f3dad10b7750d7283a7892676288df3bad6`

## Hardware acceptance

| Source / capture format | Frames | Elapsed | FPS | Payload |
|---|---:|---:|---:|---:|
| Real HDMI RGB8 -> NV12M | 1800 | 30.011s | 59.977 | 0.746GB/s |
| Real HDMI RGB8 -> NV16M | 1800 | 30.011s | 59.978 | 0.995GB/s |
| Real HDMI RGB8 -> RGB24 | 300 | 5.020s | 59.767 | 1.487GB/s |

Every dequeued plane has the correct bytesused, sequence continuity and no
V4L2 buffer error. In-stream telemetry shows running=1, overflow=0, ch0_drops=0
for all formats. NV12 UV=4,147,200 bytes; NV16 UV=8,294,400 bytes.

Saved complete native4K frames to `hdmi-NV12.raw`, `hdmi-NV16.raw`, `hdmi-RGB.raw`,
converted with GStreamer BT709 to matching PNGs. **NV12/NV16 PNGs visually
inspected**: actual source mountain/climbing footage, complete geometry and
natural color, not TPG, not caps/STREAMON-only evidence.

Wayland300-buffer tests reach normal EOS in ~5.03s for both NV formats.
Actual fpsdisplaysink rendered counts reach274(NV12) /276(NV16) at the last
periodic sample, steady ~60FPS. GUI sink startup drops2/1 respectively; do not
confuse those with DMA drops (zero). No continuous preview left running.

TPG RGB/NV12/NV16 120 buffers each PASS. Three RGB->NV12->NV16 restart cycles
(9 STREAMON/OFF runs, 15 frames each) PASS after TPG; live source remains locked.

## Three operator scripts

See `docs/sc7f0_build_package_flash.md` for the three-command sequence:
`sc7f0_build.sh`, `sc7f0_package.sh`, `sc7f0_flash.sh`.
The compile wrapper has syntax/dry-run checks and encapsulates the actual
completed compile/regression commands; the package and flash wrappers were
fully exercised by this deployment. A fresh full wrapper build was not repeated
solely to retest packaging of the same hardware. The validated NV-format source
and matching rev04 XSAs are now recorded in a separate video-only commit.
Hardware acceptance predates that commit: BAR git hash7B98A034 is the build's
base commit. Frozen bit/XSA/driver hashes identify the tested candidate.

A pre-deployment MCU **runtime** restart (not firmware flashing) restored the
existing RGB HDMI lock. Warm-reboot downstream recovery remains a separate
known limitation; do not confuse it with capture-format or archive failures.
