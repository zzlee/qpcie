# PS V4L2 capture application (integration WIP)

`test_app/sc7f0_ps_capture.c` uses only standard V4L2 ioctls. Unlike the host-specific validator, it does not write QPCIe source/pacer controls or map MMIO. It is not an encoder.

## Build

```
make -C test_app sc7f0_ps_capture
```

The explicit target uses AARCH64_CC (2023.2 Vitis compiler by default). Recipe: `petalinux/qpcie-zu4ev/project-spec/meta-user/recipes-apps/sc7f0-ps-capture/sc7f0-ps-capture.bb`. The recipe has no autostart service and is not yet selected in a matched final rootfs.

## Intended use on PS, AFTER the new media graph is implemented/configured

```
sc7f0_ps_capture /dev/videoX NV12 3840 2160 120 /tmp/frame.nv12
# If the configured video node exposes separate-plane NV12:
sc7f0_ps_capture /dev/videoX NV12M 3840 2160 120 /tmp/frame.nv12m
```

Device numbering is discovered, not assumed. PS /dev/videoX is distinct from x86 host /dev/video0. The current deployed26102702 does not contain the new framebuffer pipeline; do not infer that these commands can work on that image. Media-link and subdevice format setup must precede the app; it does not silently reconfigure HDMI/RX or other clients.

- QUERYCAP, exact geometry/format/field validation, single-planar or multi-planar MMAP.
- Four queued buffers; every mapped plane must export a DMA-BUF fd with VIDIOC_EXPBUF.
- Checks all DQBUF indices, flags, sequence continuity, bytesused/data_offset and monotonic timestamps. Error/timeout/short payload/STREAMOFF failure cannot print CAPTURE_PASS.
- Final frame is copied while owned by userspace, then file output/checksum happen only after STREAMOFF. No expensive per-frame full checksum in the live DQ loop.
- Printed PLANE stride/sizeimage describe the raw dump; stride padding is retained, not silently removed.
- Timestamp source reports actual EOF/SOE flags. EOF is not relabelled SOF. Hardware SOF/frame-ID association remains a pipeline integration task.
- DMA-BUF export is checked, NOT VCU import/alignment/zero-copy encoding. Summary always says vcu_import_verified=false.
- Timestamp-derived fps is reported, not automatically accepted as4K60 throughput or image correctness. Real image inspection, source-rate measurement and raw/audio concurrency are separate acceptance gates.

## Local evidence

`build/ps-capture-tests.TZt4UxOz/`: native/API-model tests and statically linked ARM64 build, -Wall -Wextra -Werror. Five test methods cover3 legal API layouts and18 modeled failure paths, plus argument checks. The model wraps userspace syscalls and is NOT a mock kernel/DMA acceptance bypass. Actual PS runtime capture remains untested.

Official IP evidence:

- `build/frmbuf-probe.JhpW1NgO`: v_frmbuf_wr2.5,4PPC,NV12-only,128-bit AXIMM,64-bit addresses; OOC synthesis PASS,2943 adjusted synthesis LUTs,6 BRAM36,0 DSP.
- `build/csc-probe.oHqkGgbf`: VPSS2.3 CSC-only,4PPC,8-bit,RGB/YUV444/422/420; OOC synthesis PASS. Hierarchy6153 total LUTs (not placed/adjusted full-card usage),7 BRAM36,48 DSP.
- `build/official-capture-sim.XUmECpdS`: actual two official IPs connected,64x64 RGB black/red/white to NV12 at stride96; every visible pixel within1 code of BT.709 reference, padding unchanged,6144 enabled write bytes per frame, AXI stalls, no memory read request. Strict simulator PASS gate reached.
- Initial failed red test in `build/official-capture-sim.RBGpWwxt` is retained: testbench passed negative coefficient divisions through unsigned SV task context. Fixed explicit signed coefficients matching kernel C arithmetic; no weakened pixel/padding checks.

OOC resource counts and small-frame IP simulation do not prove whole-card fit/timing, full4K official-pipeline behavior, branch isolation, Linux graph registration or working PS V4L2 capture. Those remain required before final acceptance/deployment.
