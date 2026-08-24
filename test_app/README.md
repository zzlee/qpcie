# QPCIe Stage-2 V4L2 Test Application

The validated Stage-2 configuration exposes one capture node with a fixed
`1920x1080@60 NV12M` format. The FPGA pipeline is:

```text
Xilinx TPG YUV444 (4 pixels/clock)
  -> rounded 2x2 chroma downsample
  -> NV12M Y and UV planes
  -> PCIe C2H DMA
```

Only `V4L2_MEMORY_MMAP` is enabled during this bring-up stage. ALSA and the
additional video channels remain intentionally disabled.

## Build

```bash
make -C test_app v4l2_test_app
```

## Control-plane probe

```bash
./test_app/v4l2_test_app \
    --dev /dev/video0 --probe --pattern 9 --fps 60
```

## Paced 60 FPS correctness test

```bash
./test_app/v4l2_test_app \
    --dev /dev/video0 \
    --frames 60 \
    --pattern 9 \
    --fps 60 \
    --out /tmp/qpcie-tpg-nv12.yuv
```

The output file contains one contiguous NV12 frame and must be exactly
3,110,400 bytes. The test validates two-plane payload sizes, buffer sequence,
static-frame hashes, sample variation, frame rate, and DMA drain behavior.

## Uncapped C2H DMA write benchmark

The benchmark disables only the NV12 engine's 60 FPS frame pacer. Resolution,
pixel conversion and descriptor format remain unchanged. The pipelined engine
packs eight 16-byte FIFO beats into each 128-byte PCIe Memory Write, so this
measures the maximum sustained payload rate of the current capture/DMA
implementation rather than the theoretical Gen2 x4 link rate.

```bash
./test_app/v4l2_test_app \
    --dev /dev/video0 \
    --benchmark \
    --frames 600 \
    --pattern 9
```

The first eight frames are excluded as warm-up. Full-frame hashing is skipped
after the first frame in benchmark mode so userspace checksum work does not
limit buffer recycling. The report includes:

- frames per second;
- NV12 payload write throughput in MiB/s;
- 128-byte PCIe MWr requests per second;
- payload/sequence errors.

RTL simulation completes an uncapped 1080p frame in 518,425 PCIe user clocks
(4.147 ms), corresponding to approximately 241.1 FPS, 715.2 MiB/s of NV12
payload, and 5.86 million 128-byte MWr requests/s before physical PCIe
backpressure. A 4K frame completes in 2,073,636 clocks (16.589 ms) under the
simulated random-ready profile, within the 2,083,333-clock 60 FPS budget.

After testing, verify the driver drained the ring and saw no video errors:

```bash
dmesg | grep 'NV12M STREAMOFF' | tail -1
dmesg | grep -Ei 'smmu|context fault|decode error|protocol errors'
```
