# VCU + PS encode daemon — next authorized phase

## Latest: test host ONLINE; deployment/testing authorized after gates

Operator reports the test machine online again and requests direct flashing/testing once the build is ready. Read-only SSH succeeded: host kernel7.0.0-38-generic, bootID `c7915db6-0a6d-4917-93bc-7e8045d54270`, qpcie driver bound, deployed FPGA still `26102702`. No board/host reboot, firmware write, client quiesce or MCU operation was performed. Prior offline restrictions below are historical; no MCU update or host reboot is authorized.

R5 `26102803` is FINISHED, exit1, not running. Synthesis/route/bit generation and setup/hold pass: WNS+0.698ns, WHS+0.010ns, TNS/THS0; LUT69810/87840, BRAM89.5/128, URAM0. Gray checks pass before opt and after route. Strict CDC/methodology gate REJECTED: CDC10Critical29/CDC12Critical10, unreviewed warnings2628, I/O coverage/methodology findings. No XSA/hardware.ok or matching PS package. Result: `build/dual-video-26102803-r5-logs/result.json`. Do not flash that rejected bit.

An exact-path CDC inventory against frozen deployed26102702 has been generated:5084 current paths,3438 exact clock/path matches,1206 removed baseline paths. All39 Critical rows are catalogued as32 asynchronous-reset synchronizer entry paths and7 probe-level diagnostic paths. Those categories are NOT approvals: reset cone/release, diagnostic source/use, FIFO ownership and collision evidence still require review. `scripts/audit_sc7f0_cdc_delta.py` verifies complete summary/detail counts and preserves exact identities/multiplicity;5 tests PASS. Evidence: `build/.r5-cdc-review-latest` points to complete `paths.csv`/`review.json` and read-only host status. No gate was weakened or new waiver added.

Follow-up:25 routed four-stage reset synchronizers have now been structurally checked. A PS teardown error-path bug was also fixed: tap drain failure must block before graph shutdown, DMA reset and VB2 buffer release. Updated ARM64 objects and14 native tests pass (including a posted-start/stale-idle fail-stop guard), not full image/runtime acceptance. Permanently stuck hardware can deliberately leave STREAMOFF/close blocked (fail-stop, not bounded recovery). Details: `docs/sc7f0_reset_cdc_and_drain_review.md`.

Next: close exact CDC/I/O/methodology findings, build matching XSA/kernel/rootfs/package, then quiesce clients → VERIFY → backup → single COMMIT → independent eMMC SHA readback → PS reboot/boot-ID proof → scoped capture/raw/audio/packet acceptance. VCU/PS daemon is authorized but not yet implemented; it remains the subsequent integration task, not a claimed feature of R5.

## Operator direction (2026-10-28, previous offline period)

The SC7F0 test machine is OFFLINE. Do not attempt SSH/probing, deployment, PS/host reboot or MCU operations. Finish the current capture/three-path hardware build stage, then prioritize VCU and its PS apps/daemon. This supersedes the previous decision to defer all VCU work. Hardware runtime acceptance stays pending until the operator restores the test environment.

Final routes remain:

1. HDMI → existing raw RGB24/NV12M/NV16M → PCIe → host.
2. HDMI → official PS V4L2 NV12 capture → VCU encoder → timestamped packet C2H → host.
3. HDMI LPCM → existing raw PCM Front L/R → PCIe → host.

VCU failure, buffer starvation or absent host credits must not stall route 1 or 3. No CPU software encoder fallback, forced PPC change, HDMI TX, TPG or decoder requirement.

## Current prerequisite status

R4 `26102802` finished synthesis/route/bit generation, but FAILED its timing gate: WNS −2.020 ns / TNS −193.700 ns /128 endpoints; WHS +0.001 ns. Resources fit: 69,814 LUT /87,840, 89.5 BRAM36-equivalents /128, URAM0. The production linked-cell audit passed. No accepted XSA/package.

Root cause of those 128 setup endpoints: Vivado ignored `if`/`foreach` in the Gray timestamp XDC. The intended max-delay and bus-skew commands inside the loop were not applied. The source-registered Gray counter and its two 64-bit, four-stage receivers now have unrolled XDC commands; ordinary implementation Tcl separately requires 64 direct bits per receiver and effective 6 ns max-delay. The 6 ns bound is less than the 6.666 ns source period; no clock-group blanket false path is added.

Read-only routed-R4 diagnostic with corrected constraints passed all128 endpoint checks and reported WNS +0.959 ns, WHS +0.001 ns, TNS/THS0. This is a counterfactual diagnostic, NOT a rebuilt/released R4 bit. Its CDC report still contains unreviewed critical/warning structures; positive setup/hold does not resolve that gate. First diagnostic failure (checker incorrectly expected launch Q rather than Vivado's launch C pin) remains preserved.

R5 `26102803` fresh build is running with the XDC fix and pre-opt/post-route checks, under `XILINXD_LICENSE_FILE=2101@192.168.200.112`. Project: `build/dual-video-26102803-r5`, logs sibling `-logs`, wrapper PID1608583. Do not change its live RTL/build inputs while running. Complete resource/timing/CDC records before starting the next VCU hardware revision. Do not automatically package/deploy a bitstream that fails signoff.

## Verified local vendor stack

- Vivado 2023.2 contains `xilinx.com:ip:vcu:1.2`, with separate `ENABLE_ENCODER`, `ENABLE_DECODER`, `PLL_CLK`, `CORE_CLK`, `MCU_CLK`, AXI clocks and optional encoder-buffer configuration. Encoder-only is the target. No decoder datapath is needed.
- Existing PS BD has HP0 for upgrade/management and HP1 for capture/packet DMA. VCU should use currently unused memory ports, not compete through the capture's one-outstanding read arbiter. Exact HP2/HP3/MCU routing, clocks and DDR/QoS must be validated; theoretical DDR bandwidth is not acceptance.
- Existing `vcu.dtsi` is only an unused fixed-clock placeholder with commented nodes; it is NOT integrated VCU hardware. Its old 33.333 MHz clock must not be assumed to match a new clock source.
- Local 2023.2 recipes provide `kernel-module-vcu` (pinned `689c8d823b383e2a8a5249be49de627f866cfaf2`), `libvcu-xlnx` (`84b0856cad7844d69f57ac4d9447c20930875475`), `libomxil-xlnx` (`3a04b5adc661a0eced626c1373dbbfe699ae6fe0`), firmware and GStreamer OMX integration.
- The GStreamer bbappend selects `zynqultrascaleplus` / `libOMX.allegro.core.so.1` only when MACHINE_FEATURES contains `vcu`. Current branch rootfs has GStreamer OMX disabled. Do not select packages merely by name without the matching hardware/DT/firmware.
- Installed vendor OMX headers expose `OMX_ALG_IndexPortParamBufferMode`; that is only API evidence. Actual DMA-BUF import, stride/slice-height rules, ownership and output behavior must be checked against the pinned implementation.

## Implementation order

### 1. Hardware/DT and isolated build

- New hardware revision after R5 completes; keep R5 frozen artifacts/rejection evidence.
- Add encoder-only VCU, real reference/control/memory clocks, reset/IRQ and complete memory address spaces. VCU control must not collide with existing PS CSR `0xa0000000`, HDMI/control `0xb0000000...`, or DDR. Assign and validate addresses rather than copying another board's defaults.
- Use unused PS memory ports with compatible widths/clock crossings. Preserve existing HP0/HP1 and reset behavior. Measure encoder-buffer URAM/BRAM choices, whole-card resource/timing and DDR contention; do not assume OOC counts prove fit.
- Generate matching DT from the new XSA; enable encoder/firmware/clocks and required memory allocator/CMA only for that profile. Account for capture pool + encoder references/output + packet staging before selecting CMA size. The current capture-only 256 MiB is not a proven VCU budget.
- Retain fail-closed timing/CDC gates. Review exact reset/FIFO/vendor/new paths; do not blanket waive the R4/R5 findings.

### 2. PS daemon and encoding contract

Planned app name: `sc7f0_vcud` (not implemented yet). Prefer the supported Xilinx OMX stack, directly or through GStreamer after checking the pinned plugin's input/output buffer APIs. Discover capture/media/encoder devices by identity, not hardcoded `/dev/video0`.

Provisional, configurable bring-up profile: native3840×2160 NV12/8-bit, source-rate capture, HEVC50 Mbps, GOP≈1 s, no B frames. These are engineering defaults, not finalized product requirements or measured capability. H.264 may use the same transport later. No raw-frame CPU colorspace conversion/resize as an unannounced substitute for the hardware capture path.

- Prefer explicit V4L2 capture ownership plus OMX, or appsrc/encoder/appsink with an external frame map. A plain v4l2src pipeline may translate timestamps or lose source IDs; GstMeta is not assumed to survive encoding. Preserve hardware SOF-derived V4L2 PTS and source sequence; never replace it with dequeue/encode-completion time. Track stream epoch and source-ID wrap/restart. Maintain input→encoded-AU association through encoder callbacks; codec-config buffers do not fabricate source frame IDs or PTS.
- Return a captured buffer to V4L2 only after the encoder releases it. EXPBUF success alone does not prove import, compatible alignment or zero-copy. Start/stop/error cleanup must not recycle an active DMA/encoder buffer.
- Respect real encoded byte length, codec-config/keyframe/discontinuity/EOS flags and AU boundaries. AU, OMX/GStreamer buffer, packet segment and PCIe TLP boundaries are not interchangeable. If OMX uses microsecond timestamps, preserve an explicit mapping to the original V4L2 SOF timestamp and report conversion precision. V4L2 timeval already quantizes to microseconds; expressing it in ns does not restore raw150MHz tick precision. Identify the PS monotonic clock/timebase and epoch to the host rather than assuming it equals the host/audio clock.
- Permit a clearly reported compressed-only copy into DMA-managed packet staging if necessary. Do not DMA userspace virtual pointers, guessed physical addresses or arbitrary codec malloc buffers. Output-DMA-BUF support must be proven, not inferred from input import.
- Bounded state machine: preflight → configured → capture/encode → drain → stopped; explicit NO_SOURCE, NO_CREDITS, DEGRADED and ERROR states. Expose status, counts, drops, AU sizes, timestamps/epoch and stop/reconfigure controls.

### 3. Packet transport ownership

The RTL reader handles one contiguous segment, arbitrary valid tails and a separate completion record; software-managed buffer/host-credit exchange is still missing.

- Add a proper PS kernel interface for DMA-managed source buffers and packet submission/completion, plus a matching host buffer/credit interface and consumer test app. No `/dev/mem` replacement for allocator/ownership management.
- Validate source rounding/alignment/40-bit range and host DMA segments/capacity. Split registered SG spans in software as required; do not advertise a hardware SGL walker.
- Reserve sufficient host ownership for a complete AU before publishing segments. Handle partial errors, completion ordering, disconnect/backpressure, epoch changes and buffer lifetime explicitly. Do not overwrite unconsumed host buffers or treat local RQ acknowledgement as host application consumption.
- A congestion/drop policy must discard only unstarted whole frames/AUs, mark discontinuity and request an IDR as required. Already-started DMA must drain safely. Capture starvation simply removes PS admission credits; original raw/audio continue.

### 4. Service safety

Provide an opt-in Peta recipe and systemd service only once an executable/backend exists. Do not install a fake daemon or enable a service against R5 hardware without VCU.

Use existing main-loop progress/health conventions where applicable, but keep VCU **out of the required board-watchdog health set**: an encoder daemon fault should stop/restart the optional service, not reset the board and interrupt raw video/audio. Never open `/dev/watchdog` or modify the established watchdog ownership. No timer feeder thread may hide a blocked encode/DMA operation. Drain and retain ownership safely before freeing buffers; do not force-reset active AXI transactions.

## Offline and later hardware acceptance

Offline: vendor API/source audit, native and ARM64 `-Werror` builds, state/ownership/metadata/error-path models, kernel objects, DT/XSA consistency, official IP simulations, full implementation/signoff and source/artifact manifests. Build images in isolation; do not invoke the legacy hardware stage. Disk is ~19 GiB free: reuse legitimate caches, avoid duplicate full projects, preserve failures.

When the operator restores the machine: actual VCU firmware/device identification, standard PS capture, verified encoder import/layout, decodable output/source-image inspection, SOF/sequence association, real byte lengths/tails/credits, start-stop/EOS/reconfigure, starvation/congestion and concurrent raw video/raw audio. No throughput, zero-copy, latency, audible/lip-sync or end-to-end acceptance claim before those measurements.
