# QPCIe Project Handoff Document: Scheme A (Packed RGB24) & Phase 2 Roadmap

> **Date**: 2026-09-07  
> **Target FPGA**: AMD/Xilinx Artix-7 A50T (`xc7a50t-csg325-2`)  
> **PCIe Spec**: Gen2 x4, 128-bit AXI-Stream interface (Device ID: `0x12AB:0xE380`)  
> **Current Git Head**: `3451a14` on `origin/master`

---

## 1. Executive Summary & Current Status

In this milestone, we accomplished full support for **Scheme A: Native Packed 24-bit RGB (RGB24)** capture up to **4096×2160 (4K DCI)** resolution without dummy padding, maintaining maximum PCIe bandwidth and memory efficiency. Furthermore, we resolved critical Artix-7 A50T slice congestion issues via BRAM CDC FIFO balancing and verified that the bitstream, kernel driver, and user-space test suite all compile and pass timing checks cleanly.

### Current Status Matrix
| Component | Status | Artifact / Location |
| :--- | :--- | :--- |
| **FPGA Bitstream** | **Built & Passed Timing** | `./build/qpcie_a50t_proj/qpcie_a50t_card.runs/impl_1/a50t_pcie_card_top.bit` |
| **Vivado Project & TCL** | Up-to-date (TPG MAX_COLS=4096) | [`scripts/build_a50t.tcl`](file:///home/zzlee/qpcie/scripts/build_a50t.tcl) |
| **RTL Logic** | Packed RGB24 Gearbox & Single-Plane DMA | [`rtl/nv12_capture_engine.v`](file:///home/zzlee/qpcie/rtl/nv12_capture_engine.v), [`rtl/custom_pcie_dma_top.v`](file:///home/zzlee/qpcie/rtl/custom_pcie_dma_top.v) |
| **Linux Kernel Driver** | Built (`custom_pcie_av.ko`) | [`driver/qpcie_v4l2.c`](file:///home/zzlee/qpcie/driver/qpcie_v4l2.c), [`driver/custom_pcie_av.ko`](file:///home/zzlee/qpcie/driver/custom_pcie_av.ko) |
| **Test Application** | Built & Ready | [`test_app/v4l2_rgb24_test_app.c`](file:///home/zzlee/qpcie/test_app/v4l2_rgb24_test_app.c), [`test_app/v4l2_rgb24_test_app`](file:///home/zzlee/qpcie/test_app/v4l2_rgb24_test_app) |

---

## 2. Technical Implementation Details

### 2.1 Scheme A Native Packed 24-bit Gearbox (`rtl/nv12_capture_engine.v`)
- **Pixel Clock Domain**: 150 MHz video clock, 4 Samples Per Clock (4-PPC).
- **Incoming Data Width**: 4 pixels $\times$ 24 bits = 96 bits (`s_axis_video_tdata[95:0]`).
- **Outgoing PCIe FIFO Width**: 128 bits (`m_axis_video_tdata[127:0]`).
- **Gearbox Mechanics**:
  - The ratio is $96 : 128 = 3 : 4$.
  - Every 4 beats of incoming 96-bit TPG data produce exactly 3 beats of 128-bit packed data with zero wasted padding bytes.
  - Cycle 0: accumulates 96 bits (needs 32 bits from Cycle 1 to emit Beat 0).
  - Cycle 1: emits Beat 0 (128 bits), holds remainder 64 bits.
  - Cycle 2: takes 64 bits + remainder 64 bits $\to$ emits Beat 1 (128 bits), holds remainder 32 bits.
  - Cycle 3: takes 96 bits + remainder 32 bits $\to$ emits Beat 2 (128 bits), remainder empty.
  - State machine flushes out final residual words cleanly at end-of-line (`s_axis_video_tlast`).

### 2.2 Single-Plane C2H DMA Flow
- When `desc_format == 4'd1` (`FORMAT_RGB24`):
  - UV chroma subsampling & UV FIFO write logic are completely bypassed.
  - `uv_ready_to_send` is hardwired to 0.
  - The DMA engine operates strictly in single-plane mode (`c2h_plane_count == 1`).
  - Total byte count per frame: $\text{Width} \times \text{Height} \times 3$ Bytes (e.g. $4096 \times 2160 \times 3 = 26,542,080$ Bytes).

### 2.3 FPGA Resource Rebalancing (`rtl/custom_pcie_dma_top.v`)
- **Problem**: Previously, `place_design` failed with `[Place 30-487]` due to overflowing slice count by only 17 slices (30,302 LUTs used, LUT as Distributed RAM consumed 4,586 LUTs, while 34 Block RAMs were sitting idle).
- **Solution**:
  - Converted the 5 largest asynchronous CDC FIFOs from Distributed RAM to Block RAM:
    - `u_sgl_y_cdc` (SGL descriptor transfer FIFO for Y/RGB plane)
    - `u_sgl_uv_cdc` (SGL descriptor transfer FIFO for UV plane)
    - `u_ch1_loopback_cdc`, `u_ch2_loopback_cdc`, `u_ch3_loopback_cdc` (Audio loopback FIFOs)
  - Set `FIFO_MEMORY_TYPE("block")` and increased depth to 512.
  - Saved over 1,700 LUTs, bringing Slice utilization well under device capacity. The routed netlist reports: `GTPE2=4, DSP48E1=46, RAMB=81`, with **0 timing errors** and full routing completion.

### 2.4 Linux Driver & User Space
- **`driver/qpcie_v4l2.c`**:
  - Registered `V4L2_PIX_FMT_RGB24`.
  - Added resolution entry `{ 4096, 2160 }` to `qpcie_video_modes[]` alongside `3840×2160` and `1920×1080`.
  - Configures `desc_format = 4'd1` and 1 buffer plane upon user stream configuration.
- **`test_app/v4l2_rgb24_test_app.c`**:
  - Accepts parameters: `-w <width> -h <height> -n <frames> -o <raw_out.rgb>`.
  - Calculates real-time FPS and PCIe throughput in MB/s.
  - Automatically inspects the first RGB frame for color gradient/color-bar sanity checks.

---

## 3. How to Test on Target Hardware (Next Steps for User/Agent)

When validating on the target Linux machine with the PCIe card installed:

### Step 1: Flash Bitstream to SPI Flash
```bash
./scripts/flash_a50t.sh
```
*Reboot or power cycle the machine after flash verification completes.*

### Step 2: Reload Driver
```bash
cd /home/zzlee/qpcie/driver
sudo rmmod custom_pcie_av 2>/dev/null || true
sudo insmod custom_pcie_av.ko
dmesg | tail -n 30
```

### Step 3: Run Video Capture Tests
```bash
cd /home/zzlee/qpcie/test_app

# 1. Capture 4096x2160 RGB24 (Target test case)
./v4l2_rgb24_test_app -w 4096 -h 2160 -n 60 -o output_4096x2160.rgb

# 2. Capture 3840x2160 RGB24
./v4l2_rgb24_test_app -w 3840 -h 2160 -n 60

# 3. Capture 1920x1080 RGB24
./v4l2_rgb24_test_app -w 1920 -h 1080 -n 60

# 4. View captured frame using ffplay
ffplay -f rawvideo -pixel_format rgb24 -video_size 4096x2160 output_4096x2160.rgb
```

---

## 4. Phase 2 Roadmap & Next Tasks

The user previously outlined two major Phase 2 goals to be tackled:

### Goal 1: AV Synchronization Verification (影音同步驗證)
- **Concept**:
  - The hardware TPG generates video frames while the hardware Audio Generator emits AES3 audio subframes simultaneously.
  - Video VSYNC / Frame Start timestamps and Audio Frame sample counters share the same hardware reference clock or are latched with a common 64-bit hardware tick counter.
- **Next Agent Task**:
  1. Inspect the latching mechanism of the hardware 64-bit monotonic timer in `custom_pcie_dma_top.v`.
  2. Implement an integrated test app `test_app/av_sync_test_app.c` that concurrently captures from `/dev/video0` and `/dev/snd/pcmC2D0c`, correlating the V4L2 buffer `timestamp` with ALSA sample timestamps to verify zero drift over time.

### Goal 2: SGL DMA Stride Handling (SGL 模式下 Stride 處理)
- **Concept**:
  - In Scatter-Gather DMA, host buffers (e.g., allocated by user space or GPU DMABUF) often require line padding (`stride > width * bytes_per_pixel`).
  - The hardware C2H engine currently transfers contiguous buffers. If `stride != line_bytes`, the DMA descriptor or SGL generator must either:
    - Advance the destination address by `stride` at the end of each line, OR
    - Decompose the transfer into multi-entry SGLs where each SG entry corresponds to a line or a continuous chunk.
- **Next Agent Task**:
  1. Audit `sgl_dma_engine.v` and `nv12_capture_engine.v` regarding line-stride boundaries.
  2. Confirm whether the SGL SMMU page translation interacts with line-stride (as discussed earlier: SMMU translates 4KB/64KB pages; stride is a raster line offset within the buffer, orthogonal to page mapping).
  3. Support configurable `bytesperline` in driver `qpcie_v4l2.c` and hardware descriptor registers.

---

## 5. File Inventory & Key References

- **Top-Level Verilog**: [`rtl/a50t_pcie_card_top.v`](file:///home/zzlee/qpcie/rtl/a50t_pcie_card_top.v)
- **DMA Engine Top**: [`rtl/custom_pcie_dma_top.v`](file:///home/zzlee/qpcie/rtl/custom_pcie_dma_top.v)
- **Video Capture Engine**: [`rtl/nv12_capture_engine.v`](file:///home/zzlee/qpcie/rtl/nv12_capture_engine.v)
- **Driver**: [`driver/qpcie_v4l2.c`](file:///home/zzlee/qpcie/driver/qpcie_v4l2.c), [`driver/qpcie_main.c`](file:///home/zzlee/qpcie/driver/qpcie_main.c)
- **Test App**: [`test_app/v4l2_rgb24_test_app.c`](file:///home/zzlee/qpcie/test_app/v4l2_rgb24_test_app.c)
- **Flash Script**: [`scripts/flash_a50t.sh`](file:///home/zzlee/qpcie/scripts/flash_a50t.sh)
- **Build Script**: [`scripts/build_a50t.sh`](file:///home/zzlee/qpcie/scripts/build_a50t.sh)
