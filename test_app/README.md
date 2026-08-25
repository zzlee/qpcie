# QPCIe NV12M V4L2 Test Application

The capture node exposes two discrete 60 FPS modes:

- `1920x1080 NV12M` — Y 2,073,600 bytes, UV 1,036,800 bytes;
- `3840x2160 NV12M` — Y 8,294,400 bytes, UV 4,147,200 bytes.

The FPGA pipeline is:

```text
Xilinx TPG YUV444, 4 pixels/clock @ 150 MHz
  -> asynchronous AXI-Stream CDC FIFO
  -> rounded 2x2 chroma downsample @ 125 MHz
  -> NV12M Y and UV planes
  -> 256-byte PCIe C2H MWr DMA
```

The 256-byte MWr payload requires the host to negotiate `MaxPayloadSize >= 256`.
On Jetson, add `pci=pcie_bus_perf` to the kernel command line; the driver refuses
to register V4L2 when the negotiated MPS is lower.
```

Only `V4L2_MEMORY_MMAP` is enabled during bring-up. ALSA and additional video
channels remain disabled. Format changes reset the TPG and video CDC FIFO so a
partial frame from the previous mode cannot enter the next DMA buffer.

## Build

```bash
make -C test_app v4l2_test_app
```

## Enumerate modes

```bash
v4l2-ctl -d /dev/video0 --list-formats-ext
```

Expected discrete modes are `1920x1080@60` and `3840x2160@60`, format `NM12`.

## Control-plane probes

```bash
./test_app/v4l2_test_app --dev /dev/video0 \
    --width 1920 --height 1080 --probe --pattern 9 --fps 60

./test_app/v4l2_test_app --dev /dev/video0 \
    --width 3840 --height 2160 --probe --pattern 9 --fps 60
```

The kernel log must report matching TPG dimensions, YUV444 format `1`, and the
selected hardware pattern.

## Paced correctness tests

1080p60:

```bash
./test_app/v4l2_test_app --dev /dev/video0 \
    --width 1920 --height 1080 --frames 60 --pattern 9 --fps 60 \
    --out /tmp/qpcie-1080p-nv12.yuv
```

The output file must be exactly 3,110,400 bytes.

4K60:

```bash
./test_app/v4l2_test_app --dev /dev/video0 \
    --width 3840 --height 2160 --frames 60 --pattern 9 --fps 60 \
    --out /tmp/qpcie-4k-nv12.yuv
```

The output file must be exactly 12,441,600 bytes. The tests validate two-plane
payload sizes, continuous sequences, static-frame hashes, sample variation,
frame rate, and complete STREAMOFF drain behavior.

## Uncapped DMA benchmark

```bash
./test_app/v4l2_test_app --dev /dev/video0 \
    --width 1920 --height 1080 --benchmark --frames 600 --pattern 9

./test_app/v4l2_test_app --dev /dev/video0 \
    --width 3840 --height 2160 --benchmark --frames 600 --pattern 9
```

The first eight frames are excluded as warm-up. Full-frame hashing is skipped
after the first frame so userspace work does not limit buffer recycling. The
4K60 payload requirement is 746,496,000 bytes/s, or approximately 711.91
MiB/s. The application reports an explicit pass/fail against that threshold.

After every run, verify the ring drained and no video protocol or SMMU errors
occurred:

```bash
dmesg | grep 'NV12M STREAMOFF' | tail -1
dmesg | grep -Ei 'smmu|context fault|decode error|protocol errors'
```

Required STREAMOFF state: `drained=1`, `head == tail`, and `video_errors=0`.
