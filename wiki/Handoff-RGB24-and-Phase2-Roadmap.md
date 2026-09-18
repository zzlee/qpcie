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

### Goal 3: BAR/Register & Descriptor Redesign (暫存器與描述子重規劃，打掉重練)

> 完整規格見 [`Future-Register-Map-and-Descriptor-Spec.md`](Future-Register-Map-and-Descriptor-Spec.md)。以下為摘要。

> **Status**: design approved, breaking change accepted. 實驗版位址全搬，舊 driver 不相容。

- **Motivation（為何今天的 map 不能留）**:
  - BAR0 是按開發階段逐步 accretion：Day-1 骨架 (`0x00–0x2C`) → 身分證 (`0x30–0x3C`) → 音訊外掛 (`0x48` 與 `0x100` 雙份 ch0 alias) → AV sync (`0x50–0x64`) → 08-21 debug 劫持 (`0x68/0x6C`) → NV12 期 (`0x70–0x90`) → perfmon 附掛 (`0xA0–0xDC`) → 頁表 (`0xE0–0xE8`)。無 region 概念、讀寫混雜。
  - 64B 胖 descriptor 身兼 DMA descriptor＋video frame work order（幾何/格式全塞每幀），是「沒有 per-channel register，只好全塞 descriptor」的結果。驗證場景固定幾何，per-frame 可變彈性備而未用。
  - 無 per-video-channel BAR：4 套 NV12 engine 共用一條 H2C/C2H ring，channel 分派靠 `custom_pcie_dma_top` 內部仲裁 (`nv12_chX_desc_select`＋`chX_owner_busy`)，軟體看不到也控制不了，無隔離保證。
- **Target Map（region 切分＋per-channel stride）**:
  - `0x0000–0x00FF` GLOBAL：ID/VERSION/CAPS、GLOBAL_RESET、IRQ_TOP(W1C)、64-bit TIMESTAMP。
  - `0x0100–0x04FF` VIDEO CH0–CH3（stride `0x100`）：CH_CTRL（enable/方向/capture-output/format/irq_en）、CH_STATUS、WIDTH/HEIGHT/STRIDE0–3、**RING0–RING3（每組 BASE_L/H＋CFG tail doorbell＋HEAD）**、FRAMES/DROPS/PTS、CH_IRQ(W1C)。
    - Ring 語義由 FORMAT 查表，不寫死在名字裡：NV12M→RING0=Y,RING1=UV；YV12→RING0=Y,RING1=U,RING2=V；RGB24→只用 RING0；未來 4-plane（如 Y/U/V/A）→啟用 RING3，不改 register map。
    - STRIDE 也按 plane 編號（STRIDE0–3），同理不綁 Y/UV 名稱。
  - `0x0500–0x08FF` AUDIO DEV0–DEV3（stride `0x100`，每 device 最多 8 planes；此處 channel＝device 內聲道平面，不同於舊 map 的 ch0–ch3 獨立 device，breaking）。
    - `+0x00` CTRL（enable/方向/format/`channels` 1–8）`+0x04` STATUS（running/xrun W1C）`+0x08` RATE `+0x0C` PERIOD_BYTES `+0x10` BUFFER_BYTES `+0x14` POSITION（RO，byte 精度 hw_ptr＝已傳輸總位元組 mod BUFFER）。
    - `+0x20–0x9F` RING0–RING7（每組 16B：BASE_L/H＋CFG＋HEAD）。interleaved＝1 個 host buffer→只用 RING0（聲道拆分在 audio engine fabric，DMA 只當 byte pipe）；non-interleaved＝N 個 buffers→RING0–N-1（ALSA per-channel sgt 直行填入）。
    - `+0xA0` SAMPLE_CNT `+0xA4` PTR `+0xA8` IRQ（W1C：period-done/xrun）。period 中斷節拍由 PERIOD_BYTES 定義（一 period 即一「幀」）；`pointer` 回調＝POSITION÷frame_bytes。
  - `0x0900–0x09FF` DEBUG（圍起來，正式版可整區拿掉）：寫入擷取、loopback、pattern gen、pacer override。
  - 範例流程見簡報 SG DESC／DRIVER 頁講稿；CH0 capture 設置代碼（幾何→descriptor→`dma_wmb()`→ring base→tail→CTRL）為驗收依據。
- **Thin Descriptor（瘦身，16B）**: `{host_addr[63:0], len[31:0], flags[31:0]=保留}`——driver enumerate sgl 直行填入，零計算。方向是 channel 屬性（`CH_CTRL[1]`），FPGA 端隱式（engine stream），故無需 src/dst 雙位址、無需 SOF/EOF（framing 改 byte count：數滿 `FRAME_BYTES` 即一幀，可多幀連排）。方向/幾何搬到 channel block，STREAMON 配一次。ring 仍為 head/tail 模型（tail 即 doorbell，`HEAD==tail` 表 idle）。
- **Per-plane Tables**: 每通道 RING0–RING3 各一張表（NV12M→RING0=Y,RING1=UV；YV12→+RING2=V；RGB24→只用 RING0；未來 Y/U/V/A→RING3）。Y/UV 並行 walk，各自 byte count（由 WIDTH/HEIGHT/STRIDE0–3＋FORMAT 推導），全到齊即一幀。driver 端 V4L2 multi-planar 本就是 per-plane sgt，一對一填入。
- **Driver Changes**:
  1. `vch` 一對一綁 channel block，刪除全域 `qdev->h2c_tail/c2h_tail`（改 per-channel）。
  2. `buf_queue` 填本通道 ring＋敲本通道 doorbell；timeout 讀本通道 HEAD＋STATUS。
  3. sysfs 控制面按 channel 拆分（`ch0_*` 前綴或 per-device attr 組）。
- **Acceptance**: 單路 1080p60/4K60 回歸通過；CH0＋CH1 並發 capture 互不擋（新驗收，今日架構做不到）；舊位址 map 廢棄，`axil_reg_space.v` 重寫。

---

## 5. File Inventory & Key References

- **Top-Level Verilog**: [`rtl/a50t_pcie_card_top.v`](file:///home/zzlee/qpcie/rtl/a50t_pcie_card_top.v)
- **DMA Engine Top**: [`rtl/custom_pcie_dma_top.v`](file:///home/zzlee/qpcie/rtl/custom_pcie_dma_top.v)
- **Video Capture Engine**: [`rtl/nv12_capture_engine.v`](file:///home/zzlee/qpcie/rtl/nv12_capture_engine.v)
- **Driver**: [`driver/qpcie_v4l2.c`](file:///home/zzlee/qpcie/driver/qpcie_v4l2.c), [`driver/qpcie_main.c`](file:///home/zzlee/qpcie/driver/qpcie_main.c)
- **Test App**: [`test_app/v4l2_rgb24_test_app.c`](file:///home/zzlee/qpcie/test_app/v4l2_rgb24_test_app.c)
- **Flash Script**: [`scripts/flash_a50t.sh`](file:///home/zzlee/qpcie/scripts/flash_a50t.sh)
- **Build Script**: [`scripts/build_a50t.sh`](file:///home/zzlee/qpcie/scripts/build_a50t.sh)
