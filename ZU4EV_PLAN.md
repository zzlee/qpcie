# XCZU4EV MPSoC PCIe Video Plan

## Objective

Port the verified single-channel RGB24 video path from the Artix-7 A50T
platform to an AMD Zynq UltraScale+ MPSoC XCZU4EV platform. The MPSoC will
operate as a PCIe Gen3 x4 Endpoint and will later support both video capture
and video output.

The first bring-up source is the PL TPG. External HDMI, SDI, or MIPI video
interfaces are deferred until the TPG-to-host path is verified.

## Reference Platform

Use the following project as the board-level and PS configuration reference:

```text
~/docker/sc6f0-dante/vivado/recovery-v2023.2
```

Known reference configuration:

- FPGA: `xczu4ev-fbvb900-2-e`
- PCIe controller: Zynq UltraScale+ PS PCIe controller
- PCIe role: Endpoint
- PCIe link target: Gen3 x4
- Root Port: disabled
- PCIe reset: active-low
- PCIe reference clock: 250 MHz
- Primary project TCL: `recovery-v2023.2.tcl`
- XSA and bitstream build TCL: `build_xsa_bitstream.tcl`

The reference project's QSPI peripheral is disabled. Initial bring-up uses
JTAG/bitstream/XSA; persistent QSPI boot is a later milestone.

## Architecture

The A50T `pcie_7x_0` native PCIe implementation will not be ported directly.
The XCZU4EV design uses the PS PCIe controller and a new adapter between the
PS PCIe/DMA interfaces and PL video engines.

Initial capture direction:

```text
PL TPG -> PL capture engine -> PS DDR -> PS PCIe Gen3 x4 -> host V4L2 buffer
```

Future output direction:

```text
Host PCIe DMA -> PS DDR -> PL output engine -> video transmitter
```

The PS DDR frame-buffer architecture supports both future capture and output
without changing the host-visible buffer lifecycle.

## Phase 1: Recovery Baseline

- Rebuild the recovery project without modification.
- Record PS configuration, PCIe Endpoint configuration, clocks, resets, and
  hardware handoff artifacts.
- Identify the PS-to-PL AXI interfaces suitable for video frame buffers and
  control registers.
- Keep the recovery project unchanged; it remains the hardware reference.

Exit criteria:

- The reference bitstream and XSA can be reproduced.
- The board boots or programs through the established recovery flow.

## Phase 2: QPCIe ZU4EV Skeleton

- Add an independent ZU4EV Vivado project and build scripts to this repository.
- Reuse the required PS configuration from the recovery project.
- Instantiate a minimal PL AXI-Lite register block for identity, version, and
  diagnostics.
- Configure PCIe BAR access to the PL register aperture.
- Initially retain PCI Vendor ID `0x12AB` and Device ID `0xE380` to minimize
  Linux driver probe changes.

Exit criteria:

- The host enumerates the PCIe Endpoint at Gen3 x4.
- BAR register reads and writes work reliably.
- MSI completion interrupts reach the host.

## Phase 3: PCIe DMA Bring-Up

- Implement the PS PCIe/DMA to PL adapter; do not reuse the A50T native
  `pcie_7x_axi_bridge.v` interface.
- Establish device-to-host and host-to-device DMA through PS DDR.
- Validate 64-bit IOVA handling, buffer mapping, descriptor completion,
  interrupt behavior, and memory ordering.
- Start with deterministic pattern buffers before video traffic.

Exit criteria:

- Repeated host-to-device and device-to-host pattern transfers pass.
- DMA completion maps one-to-one with submitted host buffers.
- No IOVA truncation, descriptor wrap, or interrupt loss is observed.

## Phase 4: TPG RGB24 Capture

- Add a PL TPG source and RGB24 capture path.
- Store frames in PS DDR and publish them through the PCIe DMA path.
- Port the diagnostic overlay used on A50T:
  - Fixed RGB corner and center markers.
  - Per-frame 16-bit watermark.
  - Accepted AXI stream telemetry.
- Reuse the host V4L2 RGB24 test application and its `-W` and `-M` tests.
- Validate 1920x1080 before 4096x2160.

Exit criteria:

- `-W` reports 600 continuous frame watermarks.
- `-M` verifies all fixed marker locations for 600 frames.
- V4L2 sequence and hardware error/drop counters remain continuous.
- 4K RGB24 reaches the required 60 FPS without drops.

## Phase 5: Capture and Output Expansion

- Replace the TPG source with HDMI, SDI, or MIPI capture interfaces.
- Add host-to-device DMA and a PL output engine for video transmission.
- Preserve the PS DDR frame-buffer and descriptor lifecycle for both paths.
- Add per-period sequence, CRC, and timestamp sideband diagnostics for audio.
- Add frame sequence, marker, and watermark diagnostics for all video paths.

## Validation Matrix

| Area | Required validation |
| --- | --- |
| PCIe | Gen3 x4 enumeration, BAR MMIO, MSI, link stability |
| D2H DMA | Pattern transfer, 64-bit IOVA, descriptor wrap, completion ordering |
| H2D DMA | Pattern transfer, memory ordering, completion ordering |
| RGB24 | 1080p then 4K, RGB byte order, stride, frame size |
| Frame integrity | 600-frame watermark continuity and fixed marker verification |
| Performance | Paced 4K60 and uncapped throughput with no frame drops |
| Audio | Period sequence, CRC, timestamp continuity |

## Initial Implementation Order

1. Create the ZU4EV project skeleton from the recovery PS configuration.
2. Bring up PCIe Endpoint enumeration and BAR0 identity registers.
3. Implement PS DDR-backed PCIe DMA pattern transfers.
4. Add PL TPG RGB24 capture and host V4L2 delivery.
5. Port watermark and marker diagnostics.
6. Expand to external video capture and output after TPG validation passes.
