# Wiki - 多路 2D Multi-Planar 視訊與多路 Audio 系統配置指南

在多通道影音擷取/處理卡（例如 **4 路或 8 路 PCIe HDMI/SDI 擷取卡、視訊會議卡、IP Camera NVR 處理卡**）中，系統需要同時處理多路的高頻寬 2D Multi-Planar 視訊（YUV420P/NV12）與低延遲多路 PCM 音訊 (Audio)。

本文說明如何在 PCIe DMA 架構中配置多路 Video 與 Audio 佇列、仲裁策略、記憶體對齊與 **硬件 A/V 影音同步 (AV Sync / PTS)**。

---

## 1. 多路影音 PCIe DMA 架構圖 (Multi-Channel Architecture)

```
+---------------------------------------------------------------------------------------------------------+
|                                        custom_pcie_dma_top                                              |
|                                                                                                         |
|  +------------------------+   +------------------------+   +-------------------+   +------------------+ |
|  | Ch0 Video Ring (2D)    |   | Ch0 Audio Ring (1D)    |   | Ch1 Video Ring    |   | Ch1 Audio Ring   | |
|  +-----------+------------+   +-----------+------------+   +---------+---------+   +--------+---------+ |
|              |                            |                      |                      |           |
|              v                            v                      v                      v           |
|  +--------------------------------------------------------------------------------------------------+ |
|  |                 Multi-Channel Descriptor Fetch & Channel Arbitrator                              | |
|  +------------------------------------------------+-------------------------------------------------+ |
|                                                   |                                                   |
|                                                   v                                                   |
|  +--------------------------------------------------------------------------------------------------+ |
|  |  RQ TX Encoder (帶 Priority & Bandwidth Shaping: Audio 低延遲優先 / Video 高頻寬 2D Burst)         | |
|  +------------------------------------------------+-------------------------------------------------+ |
|                                                   |                                                   |
|                                                   v                                                   |
|  +--------------------------------------------------------------------------------------------------+ |
|  |                            Hardware AV Sync / PTS Timestamp Generator                            | |
|  +--------------------------------------------------------------------------------------------------+ |
+---------------------------------------------------------------------------------------------------------+
```

---

## 2. 三大配置核心策略

### 策略一：多通道獨立環形佇列 (Multi-Ring Architecture)
為避免視訊的大資料量 Burst 堵塞音訊的即時性，建議在暫存器層級為每個 Channel 與音視訊種類分配獨立的 Descriptor Ring：

- **Channel 0**:
  - `CH0_VIDEO_RING_BASE` (`0x100`), `CH0_VIDEO_TAIL` (`0x108`)
  - `CH0_AUDIO_RING_BASE` (`0x110`), `CH0_AUDIO_TAIL` (`0x118`)
- **Channel 1**:
  - `CH1_VIDEO_RING_BASE` (`0x120`), `CH1_VIDEO_TAIL` (`0x128`)
  - `CH1_AUDIO_RING_BASE` (`0x130`), `CH1_AUDIO_TAIL` (`0x138`)

---

### 策略二：音視訊流量 QoS 與仲裁策略 (Traffic Class & Arbitration)

影音傳輸具備不同的 QoS (Quality of Service) 需求：

| 串流類型 (Stream Type) | 頻寬需求 (Bandwidth) | 延遲敏感度 (Latency Sensitivity) | 描述符類型 (Descriptor) | 仲裁優先權 (Arbitration Priority) |
| :--- | :--- | :--- | :--- | :--- |
| **多路 Audio (PCM)** | 低 (例如 48kHz 24-bit 8ch ≈ 9.2 Mbps/ch) | **極高** (Buffer Underrun 會導致爆音) | 1D Continuous Ring | **High Priority (絕對優先)** |
| **多路 Video (2D)** | **極高** (4K60 YUV420P ≈ 6 Gbps/ch) | 中 (容忍 1~2 Frame 緩衝) | 2D Multi-Planar (64B) | Weighted Round-Robin (頻寬配額) |

#### 仲裁邏輯 (`rq_tx_encoder.v` 擴充邏輯)：
- **Audio DMA Request** 採用 **Strict Priority (嚴格優先權)**，只要 Audio Buffer 有資料即立即插入 PCIe MWr/MRd TLP。
- **Video DMA Request** 在 Audio 空閒時，以 **2D Scanline Burst (例如每次傳輸 1 行 3840 Bytes)** 為單位進行通道間的 Round-Robin 輪巡。

---

### 策略三：硬件級影音同步 (AV Sync / PTS Timestamping)

為使 Linux 側 **V4L2 (視訊)** 與 **ALSA (音訊)** 驅動程式能完美影音對齊 (Lip-Sync)，DMA 控制器內建 64-bit **STC/PTS (Presentation Time Stamp) 計數器**：

```
+-----------------------------------------------------------------------------------+
| 64-bit Hardware System Time Counter (STC @ 90kHz or 27MHz)                        |
+-----------------------------------------------------------------------------------+
                                   |
         +-------------------------+-------------------------+
         | (Latch on Video Frame EOP)                        | (Latch on Audio Block Done)
         v                                                   v
+-----------------------------------+               +-----------------------------------+
| Video Descriptor Completion PTS   |               | Audio Descriptor Completion PTS   |
+-----------------------------------+               +-----------------------------------+
```

- 當 Video 畫面 2D 傳輸完成 (`EOP`) 或 Audio 區塊傳輸完成時，硬體自動將當前 64-bit PTS 時間戳記寫入完成描述符或暫存器。
- Linux 驅動將此 PTS 分別回報給 `v4l2_buffer.timestamp` 與 `snd_pcm_mmap`，達成微秒級影音同步。

---

## 3. 多路影音 Descriptor 結構配置範例 (Extended Descriptor)

```c
/* 多路影音通用 64-Byte 描述符結構體 */
struct pcie_av_dma_desc {
    u64 plane0_src_addr;  /* Video Y Base Addr 或 Audio PCM Buffer Base Addr */
    u64 plane0_dst_addr;
    u64 plane1_src_addr;  /* Video U / UV Base Addr (Audio 未使用) */
    u64 plane1_dst_addr;
    u64 plane2_src_addr;  /* Video V Base Addr (Audio 未使用) */
    u24 plane2_dst_addr;

    u16 line_width;       /* Video: Row Width (Bytes) | Audio: PCM Block Length */
    u16 line_count;       /* Video: Row Height (Lines)| Audio: 設為 1 (1D) */
    u16 src_stride;       /* Video: Line Stride       | Audio: 設為 0 */
    u16 dst_stride;

    u8  channel_id;       /* 通道編號: 0 ~ N */
    u8  stream_type;      /* 0: Video YUV420P, 1: Video NV12, 2: Audio LPCM */
    u16 control;          /* Bit 0: Valid, Bit 3: IRQ_EN */

    u64 hw_pts_timestamp; /* 硬體自動填入之 64-bit AV Sync 時間戳記 */
} __packed __aligned(64);
```

---

## 4. Linux 驅動層配置架構 (V4L2 + ALSA Subsystem)

在 Linux Kernel 驅動中，此硬體架構可拆分為兩個標準子系統架構：

1. **V4L2 Subsystem (`videobuf2-dma-sg`)**：
   - 負責綁定 `CHx_VIDEO_RING`，處理 2D Multi-Planar 畫面擷取。
2. **ALSA Subsystem (`snd-pcm`)**：
   - 負責綁定 `CHx_AUDIO_RING`，以 PCM Period 為單位做迴路 DMA 傳輸。
