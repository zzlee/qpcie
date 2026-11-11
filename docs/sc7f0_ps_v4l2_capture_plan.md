# PS V4L2 capture requirement — supersedes custom-writer production interface

## Latest: test host ONLINE; deployment/testing authorized after gates

Operator reports the test machine online again and requests direct flashing/testing once the build is ready. Read-only SSH succeeded: host kernel7.0.0-38-generic, bootID `c7915db6-0a6d-4917-93bc-7e8045d54270`, qpcie driver bound, deployed FPGA still `26102702`. No board/host reboot, firmware write, client quiesce or MCU operation was performed. Prior offline restrictions below are historical; no MCU update or host reboot is authorized.

R5 `26102803` is FINISHED, exit1, not running. Synthesis/route/bit generation and setup/hold pass: WNS+0.698ns, WHS+0.010ns, TNS/THS0; LUT69810/87840, BRAM89.5/128, URAM0. Gray checks pass before opt and after route. Strict CDC/methodology gate REJECTED: CDC10Critical29/CDC12Critical10, unreviewed warnings2628, I/O coverage/methodology findings. No XSA/hardware.ok or matching PS package. Result: `build/dual-video-26102803-r5-logs/result.json`. Do not flash that rejected bit.

An exact-path CDC inventory against frozen deployed26102702 has been generated:5084 current paths,3438 exact clock/path matches,1206 removed baseline paths. All39 Critical rows are catalogued as32 asynchronous-reset synchronizer entry paths and7 probe-level diagnostic paths. Those categories are NOT approvals: reset cone/release, diagnostic source/use, FIFO ownership and collision evidence still require review. `scripts/audit_sc7f0_cdc_delta.py` verifies complete summary/detail counts and preserves exact identities/multiplicity;5 tests PASS. Evidence: `build/.r5-cdc-review-latest` points to complete `paths.csv`/`review.json` and read-only host status. No gate was weakened or new waiver added.

Next: close exact CDC/I/O/methodology findings, build matching XSA/kernel/rootfs/package, then quiesce clients → VERIFY → backup → single COMMIT → independent eMMC SHA readback → PS reboot/boot-ID proof → scoped capture/raw/audio/packet acceptance. VCU/PS daemon is authorized but not yet implemented; it remains the subsequent integration task, not a claimed feature of R5.

## Previous direction: offline host, then VCU/PS daemon

The test host is offline. R4 finished but failed timing; R5 `26102803` is rebuilding with corrected Gray constraints. R4 resource fit is proven (LUT69814, BRAM89.5), not hardware acceptance. Next authorized development is VCU plus PS apps/daemon, superseding earlier VCU deferral. No remote/deployment/reboot/MCU actions while offline. Current detailed status and next phase: `docs/sc7f0_vcu_daemon_plan.md`. Historical deferral/build-running statements below are superseded by this notice.

## Operator clarification

PS DDR capture must expose a real PetaLinux V4L2 capture application path, using the official Xilinx framebuffer writer/media pipeline as the preferred integration. This prepares VCU input; VCU encoder integration remains deferred. A custom CSR writer plus memory test is not completion of this requirement.

Current R2 is a hardware baseline only: custom NV12 writer/CSR queues, packet C2H, no PS capture video node. Do not package/deploy R2 merely because a bitstream exists or advertise it as VCU-ready. Existing conditional upgrade authorization applies to the complete validated deliverable; no MCU update or x86 reboot.

## Verified local 2023.2 components

- Vivado includes v_frmbuf_wr v2.5; metadata has SAMPLES_PER_CLOCK, HAS_Y_UV8_420 and AXIMM_DATA_WIDTH/ADDR_WIDTH. Defaults are not the selected board configuration; PPC/format/CSC/chroma support must be checked before integration.
- Kernel drivers/dma/xilinx/xilinx_frmbuf.c supports NV12/NV12M, NV16/NV16M and RGB24, subject to instantiated IP formats.
- drivers/media/platform/xilinx/xilinx-vipp.c binds xlnx,video and media graph.
- xilinx-dma.c provides VB2 DMA-contiguous buffers, MMAP/USERPTR/DMABUF and VIDIOC_EXPBUF, QBUF/DQBUF/STREAMON/OFF.
- Existing qpcie_v4l2_bridge only binds the HDMI RX subdevice/creates media and subdev nodes. It is NOT framebuffer capture.
- Existing qpcie_hdmi_daemon monitors the official HDMI2 RX subdevice. Keep its telemetry/health role and stable discovery, not a second hardware owner.
- The accepted external HDMI2 vendor driver's s_stream is currently a no-op; still verify PS STREAMOFF does not stop the raw branch after integration.
- Official xilinx-dma.c timestamps at DMA completion with ktime_get_ns(), marks TSTAMP_SRC_EOF. This is NOT a capture SOF timestamp. Preserve a hardware SOF/frame-ID anchor and explicitly map it to VB2 buffers/timebase; do not silently relabel EOF as SOF.

## Intended architecture

HDMI RX -> existing PCIe raw/audio path unchanged.
        -> independent frame-aware tap/CDC -> CSC/chroma as required
           -> official Video Frame Buffer Write -> HP1 -> PS DDR VB2 buffers.

Linux: HDMI RX subdevice -> format-processing subdevices -> Xilinx video composite/VIPP -> framebuffer DMAengine -> PS /dev/videoX.

Replace the minimal bridge's master binding with the capture media graph, rather than two asynchronous notifiers competing for the same HDMI subdevice. No new raw /dev/mem DMA capture ABI as the main user interface. Retain variable-packet PS-DDR C2H for later encoded output; it is separate from framebuffer capture.

## Implementation and acceptance gates

1. Resolve exact RGB/YUV media-bus input, CSC/chroma processing and NV12 plane/stride/alignment against the actual official IP. Framebuffer storage format alone does not imply RGB-to-NV12 conversion.
2. Implement frame admission/overflow handling around the official writer: DDR starvation must not backpressure raw RX. Never reset an outstanding AXI transaction merely to drop a frame. Incomplete frames need safe completion/discard and VB2 error reporting.
3. Add AXI-Lite, IRQ, reset/clock and DT graph endpoints, kernel config, CMA sizing, driver/daemon ownership and matched PS image. Measure resources/timing again; R2 usage is not the official-writer usage.
4. Provide a standard V4L2 capture app: QUERYCAP/format negotiation/REQBUFS/QBUF/STREAMON/DQBUF/requeue/STREAMOFF, per-buffer bytesused/sequence/timestamp/error checks and image extraction.
5. Verify actual NV12 images at 4K source rate, repeated stream start/stop, DMA-BUF export and layout/ownership. Do not claim later VCU zero-copy import until encoder-specific alignment/import is tested.
6. Test PS capture concurrently with original host raw/audio, including no available PS buffers. Packet DMA transport/metadata acceptance remains separate. No MCU fault testing or unrelated reset campaign.
7. Final release requires matched bit/XSA/PS package and post-upgrade real PS V4L2 capture, not merely a media node or successful STREAMON. Do not label intermediate R2 completion as final product acceptance.

## Historical R2 build (superseded; not deployment-ready)

R2 completed synthesis, route and bitstream: WNS+0.653ns/WHS+0.010ns, LUT81451/87840, BRAM119.5/128, URAM0. Strict CDC/methodology gate FAILED (CDC-10 Critical34, CDC-12 Critical8, additional methodology findings); XSA withheld, build.exit1, no deployment. Do not blanket waive these rows or infer all are unsafe from class alone; inspect exact baseline/new paths. Original sources remain snapshotted. Results: build/dual-video-26102703-r2-logs/result.json. Vivado marks HDMI licenses Purchased with operator2101 environment.

## Initial feasibility work (historical; see current status below)

- Official framebuffer4PPC/NV12-only/128-bitAXIMM/64-bitaddress OOC synthesis PASS:6 BRAM36,2943 adjusted synthesis LUTs. Official VPSS CSC-only4PPC/all required color formats OOC synthesis PASS:7 BRAM36,48DSP,6153 hierarchy total LUTs (not full-card placed usage). Scripts:create_sc7f0_frmbuf_ip.tcl/create_sc7f0_vpss_csc_ip.tcl and isolated probes. IP BRAM sum13 is not a whole-card feasibility result; the old capture writer/CSC must be replaced, not both retained.
- Actual two official IPs connected in simulation PASS:64x64 black/red/white RGB→NV12 at stride96, visible pixels within1 code of BT.709 reference, all padding intact,6144 enabled write bytes/frame, DDR stalls. No assumption that framebuffer alone converts RGB. Evidence:build/official-capture-sim.XUmECpdS. No official full4K or frame-isolation acceptance yet.
- Standard PS capture app implemented (sc7f0_ps_capture.c), native/API-model tests PASS and static ARM64 -Werror build PASS. Supports NV12/NV12M, MMAP single/multiplanar, EXPBUF, per-buffer sequence/length/timestamp/error checks, post-STREAMOFF dump. API-model tests do NOT prove runtime capture. Recipe added; not selected in rootfs yet.
- Kernel prerequisite fragment sc7f0-v4l2-capture.cfg prepared but NOT activated in SRC_URI. Existing HDMI2 modules retained; no HDMI21 substitution.
- Read docs/sc7f0_ps_capture_app.md for exact commands/evidence/scopes. Still required: independent frame-aware tap/overflow/metadata, actual whole-card RTL/BD/control/reset/IRQ wiring, DT graph/bridge replacement, kernel config activation/matched PS image, SOF→VB2 association, fresh full synthesis/route/CDC review, real PS capture and raw/audio concurrency. No new architecture bit/XSA/package or live upgrade yet.

## Current implementation / operator scope (2026-10-28, R4)

Final production scope is exactly three card-to-host streams: HDMI raw video, encoded video packets, and HDMI raw audio. Operator explicitly authorizes removing unused IP. VCU encoding itself is still deferred; retaining a packet reader is not an implemented encoder.

- R3 (`26102801`) integrated the passive frame tap, official VPSS CSC/framebuffer writer, HP1, control/IRQ/reset, Linux VIPP graph and credit/SOF metadata hooks. Synthesis passed but placement did not run: UTLZ-1 requires 91,512 LUTs versus 87,840 available. Hierarchical synthesis reports 127 BRAM36-equivalents. No DRC override, bitstream, XSA, package or deployment. Frozen inputs/result: `build/dual-video-26102801-r3-logs/`.
- R4 (`26102802`) compiles the full-card `SC7F0_C2H_ONLY` personality: no HDMI TX subsystem/video/audio bridges, video/audio TPG, TPG overlay/CDC, auxiliary video engines/loopback CDC, auxiliary audio engines or playback FIFOs. Source remains available for legacy/debug builds, but these instances are excluded from production. Shared Video PHY and its reference clocks remain unchanged to avoid destabilizing RX. Primary raw RGB24/NV12M/NV16M engine and SG table depths are unchanged; no speculative URAM conversion or PPC change.
- Upgrade H2C→PS writer, control/mailbox, watchdog support, HDMI RX/telemetry, official PS capture and packet C2H remain. Existing H2C descriptor injection was already upgrade-only. Removed TX/TPG apertures return bounded DECERR with independent AW/W acceptance, rather than leaving an unresponsive slave.
- CAPS=`0x1001011f`: bit28 denotes the C2H-only personality and channel fields advertise one raw video/one raw audio engine. Packet DMA remains its separate ABI. The matching host driver registers one HDMI raw video node, keeps HDMI ALSA DEV1, removes TPG/auxiliary diagnostic nodes and controls, and never probes/stops the absent TPG. It retains an HDMI-only source menu for existing Force-HDMI clients. Older hardware keeps its original behavior.
- Frame-tap simulation includes 4096×2160, overflow/stalls, stop/restart and no-credit admission. Whole official pipeline simulation with independent clocks/real vendor IP passed small-frame NV12 checks and credit/drain/metadata tests. These are not full-rate official 4K or real-card acceptance. Evidence: `build/frame-tap-sim.qF7qH7OP`, `build/capture-pipeline-sim.6Ehf71eq`.
- Linux tap/GPIO provider, opt-in VIPP DMA patch (one-shot DMA, credits, SOF frame IDs/timestamps, error completion), media graph, kernel fragment and capture app recipe are now activated in this branch. Two AArch64 kernel objects compile with `-Werror` against staged Xilinx 6.1.30 headers/source; this is not a full kernel/rootfs build. Evidence: `build/ps-kernel-stage.03xLZlGV/compile-r2.log`.
- DT graph/control/IRQ/reset checks compile and pass against generated IP configurations, using existing DTG PS sources rather than a new R4 XSA. API-model/source/profile tests pass (17 methods); matching x86 kernel 7.0.0-38 driver compiles with `-Werror`, 20 fast video cases and packet arbiter/RQ regressions pass. Evidence: `build/c2h-personality-tests.Mj84nP9h/`. Native tests do not validate kernel/DMA runtime.
- Fresh R4 Vivado is running under `XILINXD_LICENSE_FILE=2101@192.168.200.112`: project `build/dual-video-26102802-r4`, sibling `-logs`, wrapper PID1463639. It includes an explicit post-synthesis required/forbidden cell audit. Resource fit, timing, CDC/methodology, XSA, matching PS image/package, source-SOF runtime association, DMA-BUF capture, packet ownership and concurrent raw/audio acceptance remain gates. No MCU operation, flash or reboot performed.

