# Wiki - Linux V4L2 視訊與 ALSA 音訊 PCIe 驅動程式指南

本專案提供完整的 **Linux Kernel 原生驅動程式 (Production-Grade C Driver)**，位於目錄 [`driver/`](file:///home/zzlee/qpcie/driver/) 下。

該驅動程式精確對接本 PCIe 硬體架構，包含 **V4L2 Multi-Planar 視訊擷取子系統** 與 **ALSA AES3 音訊子系統**。

---

## 1. 驅動程式目錄與檔案結構

- **[`driver/qpcie_driver.h`](file:///home/zzlee/qpcie/driver/qpcie_driver.h)**：驅動程式核心標頭檔、BAR0 暫存器定義、64-Byte 2D Multi-Planar Descriptor 結構體與資料結構。
- **[`driver/qpcie_main.c`](file:///home/zzlee/qpcie/driver/qpcie_main.c)**：PCIe 驅動程式核心主入口（處理 `pci_driver` 註冊、`pci_enable_device`、Dual-BAR `pci_iomap` 映射、MSI-X 中斷與 Coherent 描述符記憶體分配）。
- **[`driver/qpcie_v4l2.c`](file:///home/zzlee/qpcie/driver/qpcie_v4l2.c)**：Video4Linux2 多通道多平面視訊驅動程式（採用 `videobuf2-dma-sg`，支援 `V4L2_PIX_FMT_YUV420M` 與 `V4L2_PIX_FMT_NV12M`）。
- **[`driver/qpcie_alsa.c`](file:///home/zzlee/qpcie/driver/qpcie_alsa.c)**：ALSA 多通道音訊驅動程式（支援 32-bit AES3/IEC 60958 格式子訊框 (Subframe) 讀寫與 `snd_pcm_period_elapsed` 中斷通知）。
- **[`driver/Makefile`](file:///home/zzlee/qpcie/driver/Makefile)**：Kernel Module 編譯 Kbuild 檔案。

---

## 2. 驅動程式核心架構圖 (Driver Architecture)

```
                                  Linux Userspace Applications
                                 (FFmpeg, GStreamer, v4l2-ctl, aplay/arecord)
                                               |
                     +-------------------------+-------------------------+
                     | V4L2 IOCTLs (video0..3)                           | ALSA PCM API (pcm0..3)
                     v                                                   v
+---------------------------------------------------+   +---------------------------------------------------+
|               driver/qpcie_v4l2.c                 |   |               driver/qpcie_alsa.c                 |
| (videobuf2-dma-sg Multi-Planar Buffer Mgmt)       |   | (ALSA Sound Card & PCM Ring Management)           |
+---------------------------------------------------+   +---------------------------------------------------+
                     |                                                   |
                     +-------------------------+-------------------------+
                                               |
                                               v
+-----------------------------------------------------------------------------------------------------------+
|                                           driver/qpcie_main.c                                             |
|   - Dual-BAR Remapping (BAR0 -> DMA Regs, BAR1 -> User IP Cores Interconnect)                             |
|   - Coherent DMA Memory Allocation (dma_alloc_coherent for 64B Extended 2D Descriptors)                  |
|   - MSI-X / Shared IRQ Dispatcher                                                                         |
+-----------------------------------------------------------------------------------------------------------+
                                               | (PCIe Bus)
                                               v
+-----------------------------------------------------------------------------------------------------------+
|                                        custom_pcie_dma_top                                                |
+-----------------------------------------------------------------------------------------------------------+
```

---

## 3. 視訊子系統 (V4L2) 特色說明

1. **`videobuf2-dma-sg` 頁面映射**：
   - 使用 Linux 核心標準的 Scatter-Gather 頁面映射機制。
   - `qpcie_buf_queue()` 自 `vb2_dma_sg_plane_desc()` 自動提取實體 DMA 位址（Plane 0 Y, Plane 1 U/UV, Plane 2 V），填入 64-Byte 硬體 Extended Descriptor。
2. **多平面格式支援 (Multi-Planar Formats)**：
   - **`V4L2_PIX_FMT_YUV420M`** (3 平面獨立記憶體段)
   - **`V4L2_PIX_FMT_NV12M`** (2 平面 Y + UV 記憶體段)

---

## 4. 音訊子系統 (ALSA) 特色說明

1. **AES3 Subframe 音訊格式**：
   - 支援 32-bit AES3/IEC 60958 格式（包含 24-bit LPCM + Preamble Sync + Status Bits）。
2. **零延遲中斷處理**：
   - 硬體觸發中斷後，`qpcie_alsa_irq_handler()` 自動推進 `buffer_pos` 並發送 `snd_pcm_period_elapsed()`，確保流暢播放/錄音無爆音。

---

## 5. 編譯與載入測試指南 (Compilation & Test Commands)

### 5.1 編譯 Linux 核心模組

```bash
cd driver/
make
```

### 5.2 載入驅動程式

```bash
sudo insmod custom_pcie_av.ko
```

### 5.3 驗證裝置節點 (Check Devices)

```bash
# 檢查 V4L2 視訊裝置節點
ls -l /dev/video*

# 檢查 ALSA 音訊卡裝置節點
aplay -l
arecord -l
```

### 5.4 測試 V4L2 畫面擷取 (v4l2-ctl)

```bash
# 查詢 Channel 0 裝置能力
v4l2-ctl -d /dev/video0 --all

# 設定 1920x1080 YUV420M 解析度並擷取 10 張 Frame
v4l2-ctl -d /dev/video0 --set-fmt-video=width=1920,height=1080,pixelformat=YUV420M --stream-mmap --stream-count=10
```

### 5.5 測試 ALSA AES3 音訊錄音 (arecord)

```bash
# 從 Channel 0 錄製 48kHz 24-bit / 32-bit AES3 音訊
arecord -D hw:1,0 -f S32_LE -r 48000 -c 2 test_audio.wav
```
