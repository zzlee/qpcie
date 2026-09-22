# A50T Control Layer：BAR0 / BAR1 (Canonical v3.0 Release)

本文件定義 **QPCIe Artix-7 A50T Canonical v3.0.0** 之實際 register decode 架構（Phase 6 完工版本）。

---

## 1. BAR Hit 與 Address Normalization

7-Series PCIe Integrated Block (`pcie_7x_0`) 提供 `m_axis_rx_tuser[9:2]` One-Hot BAR Hit：

- `tuser[2]`：**BAR0** DMA / Register Space（1MB Aperture，12-bit 解碼 `0x000–0xFFF`）。
- `tuser[3]`：**BAR1** User-IP Space（Video TPG、Audio Generator、EDID/HPD）。

`cq_rx_decoder.v` 會將 Host 64-bit/32-bit PCIe 實體位址轉為 BAR-relative offset（保留低 12 位元），送給內部 AXI-Lite 暫存器空間，徹底防止位址混疊。

---

## 2. BAR0 Canonical v3.0 Region 分區總表

BAR0 採用嚴格模組化 Region 架構，消除歷史混疊與重疊：

| Range | Region | 說明 |
|---|---|---|
| `0x0000–0x00FF` | **GLOBAL** | 卡片身分認證、版本、能力旗標、全域重置、三層中斷彙總、AV Sync 對錶時基 |
| `0x0100–0x04FF` | **VIDEO CH0–CH3** | 每通道 stride `0x100`；幾何設定、Thin SG 描述符 Ring0–3、統計與通道中斷 |
| `0x0500–0x08FF` | **AUDIO DEV0–DEV3** | 每裝置 stride `0x100`；ALSA 參數、硬體指標、XRUN 黏滯標記、Ring0–7 |
| `0x0900–0x09FF` | **DEBUG** | 診斷迴路、Pattern 產生器、Pacer Override、寫入除錯擷取 |

---

### 2a. GLOBAL Block（`0x0000–0x00FF`）

| Offset | 名稱 | 權限 | 說明 |
|---|---|:---:|---|
| `0x00` | `ID / DMA_CTRL` | R/W | **Read**: 魔數 `0x12AB_E380`（Sanity Check）；**Write**: 全域 DMA 控制（bit0: run） |
| `0x04` | `VERSION` | R | Major.Minor.Patch.Variant（Canonical `0x0300_0000` = v3.0.0） |
| `0x08` | `CAPS` | R | 能力位元（`0x0004_041F` 或 `0x0001_041F`，`[4]=NEW_MAP_PRESENT`） |
| `0x0C` | `GIT_HASH` | R | Git Commit Hash 低 32 位元（例：`0x01D6_A9C5`） |
| `0x10` | `BUILD_TIME` | R | Build Timestamp（例：`0x2026_0821`） |
| `0x14` | `GLOBAL_RESET` | W（pulse） | 全域 DMA / CDC 重置脈衝（寫入 1 自動清除） |
| `0x18` | `IRQ_TOP` | R/W1C | **頂層中斷彙總**（bit0: CH0, bit4: AUD0, bit5: ERR；W1C） |
| `0x1C` | `TIMESTAMP_L` | R | 64-bit 125 MHz 全域時間戳 `[31:0]`（AV Sync 對錶） |
| `0x20` | `TIMESTAMP_H` | R | 64-bit 125 MHz 全域時間戳 `[63:32]` |
| `0x24` | `IRQ_STATUS` | R/W1C | 傳統中斷狀態（向後相容鏡像） |
| `0x28` | `DMA_STATUS` | R | 全域 DMA 引擎狀態（bit8: video idle, bit9: desc idle） |
| `0x30` | `MIRROR_VERSION` | R | 相容鏡像：VERSION_ID（`0x0300_0000`） |
| `0x34` | `MIRROR_GITHASH` | R | 相容鏡像：GIT_COMMIT_HASH |
| `0x38` | `MIRROR_BUILDTIME`| R | 相容鏡像：BUILD_TIMESTAMP |
| `0x3C` | `MIRROR_CAPS` | R | 相容鏡像：HARDWARE_CAPS |
| `0x74` | `PACER_CTRL` | R/W | bit0：1 = 60 FPS Pacer 節流，0 = Uncapped Benchmark 無上限模式 |
| `0x78` | `SLICE_HEIGHT` | R/W | 次幀切片中斷行數（0 = 完整幀中斷） |
| `0x7C` | `FRAME_DROP_COUNT`| R | 視訊掉幀累計計數器 |
| `0x80` | `VIDEO_CTRL` | R/W | bit0：重置 TPG 與視訊 CDC 跨時脈 FIFO |
| `0x84` | `VIDEO_SUB_RESET`| R/W | 視訊子域重置（bit0: TPG 重置, bit1: NV12 引擎重置） |
| `0xA0` | `PERF_CTRL` | R/W | 性能監控器控制（bit0: enable, bit1: reset） |

---

### 2b. VIDEO Channel Block（`CH0 = 0x0100–0x01FF`）

| Offset | 名稱 | 權限 | 說明 |
|---|---|:---:|---|
| `+0x00` | `CH_CTRL` | R/W | `[0]=enable, [1]=direction(0:cap, 1:out), [7:4]=format, [8]=irq_en` |
| `+0x04` | `CH_STATUS` | R/W1C | `[0]=running, [15:0]=dma_status, [31]=overflow(W1C)` |
| `+0x08` | `WIDTH` | R/W | 畫面寬度（像素數，例：1920） |
| `+0x0C` | `HEIGHT` | R/W | 畫面高度（像素數，例：1080） |
| `+0x10` | `STRIDE0` | R/W | Plane 0 跨距（Byte 數，RGB24 為 width*3） |
| `+0x14` | `STRIDE1` | R/W | Plane 1 跨距（NV12M UV 跨距） |
| `+0x20` | `RING0_BASE_L` | R/W | Thin SG Ring0 主機實體位址 `[31:0]`（C2H 擷取環） |
| `+0x24` | `RING0_BASE_H` | R/W | Thin SG Ring0 主機實體位址 `[63:32]` |
| `+0x28` | `RING0_CFG` | R/W | `[15:0]=size, [31:16]=tail doorbell`（按鈴寫入） |
| `+0x2C` | `RING0_HEAD` | R | 硬體讀取指標 Head `[15:0]`（RO） |
| `+0x30` | `RING1_BASE_L` | R/W | Thin SG Ring1 主機實體位址 `[31:0]`（H2C 回路環） |
| `+0x34` | `RING1_BASE_H` | R/W | Thin SG Ring1 主機實體位址 `[63:32]` |
| `+0x38` | `RING1_CFG` | R/W | `[15:0]=size, [31:16]=tail doorbell` |
| `+0x3C` | `RING1_HEAD` | R | 硬體讀取指標 Head `[15:0]`（RO） |
| `+0x60` | `FRAMES` | R | 本通道成功傳輸幀數（RO） |
| `+0x64` | `DROPS` | R | 本通道掉幀數（RO） |
| `+0x68–0x6C` | `PTS` | R | 64-bit 視訊幀時間戳（RO） |
| `+0x70` | `CH_IRQ_STATUS` | R/W1C | `[0]=frame_done, [1]=overflow, [2]=desc_err, [3]=fifo_err`（全 W1C） |

---

### 2c. AUDIO Device Block（`DEV0 = 0x0500–0x05FF`）

符合 Linux ALSA 標準框架之硬體加速暫存器：

| Offset | 名稱 | 權限 | 說明 |
|---|---|:---:|---|
| `+0x00` | `DEV_CTRL` | R/W | `[0]=enable, [8]=irq_en, [31]=xrun_inject`（軟體注入除錯） |
| `+0x04` | `DEV_STATUS` | R/W1C | `[0]=running(RO), [1]=xrun_sticky(W1C 斷流黏滯)` |
| `+0x08` | `RATE` | R/W | 採樣率（Hz，例：48000） |
| `+0x0C` | `PERIOD_BYTES` | R/W | 週期中斷大小（Byte 數，例：4096） |
| `+0x10` | `BUFFER_BYTES` | R/W | 環形緩衝區總長（Byte 數，例：65536） |
| `+0x14` | `POSITION` | R | **硬體即時寫入指標**（Byte 精度，ALSA `pointer` 回調依據） |
| `+0x20` | `RING0_BASE_L` | R/W | 音訊 DMA 環形緩衝區實體位址 `[31:0]` |
| `+0x24` | `RING0_BASE_H` | R/W | 音訊 DMA 環形緩衝區實體位址 `[63:32]` |
| `+0x28` | `RING0_CFG` | R/W | 音訊環形配置（保留擴充） |
| `+0xA4` | `PTR` | R | POSITION 之別名讀取埠 |
| `+0xA8` | `DEV_IRQ_STATUS`| R/W1C | `[0]=period_done, [1]=xrun`（全 W1C） |

---

### 2d. DEBUG Block（`0x0900–0x09FF`）

| Offset | 名稱 | 權限 | 說明 |
|---|---|:---:|---|
| `0x00` | `LOOPBACK_CTRL` | R/W | 多通道音訊迴路控制（bit0..2: pacer enable） |
| `0x04` | `PATTERN_GEN` | R/W | 除錯 Pattern 產生器配置 |
| `0x08` | `PACER_OVERRIDE`| R/W | Pacer 覆寫控制 |
| `0x0C` | `LAST_WDATA` | R | 最近一次寫入 BAR0 之 32-bit Data 觀測值（硬體除錯） |
| `0x10` | `LAST_WADDR` | R | 最近一次寫入 BAR0 之 12-bit Address 觀測值 |

---

## 3. BAR1 Map（User IP Space）

| Range | IP 模組 | 說明 |
|---:|---|---|
| `0x0000–0x0FFF` | Xilinx Video TPG | 透過 AXI Clock Converter 進入 150 MHz 視訊像素時脈域 |
| `0x1000–0x1FFF` | Audio Pattern Generator | 硬體音訊產生器（AES3 / I2S） |
| `0x2000–0x2FFF` | EDID / HPD Controller | HDMI/DP 顯示端沉積與熱插拔控制 |

---

## 4. Thin SG Descriptor 規格（16-Byte）

```text
+---------------------------------------------------------------+
|                      host_addr [63:0]                         |
+---------------------------------------------------------------+
|                      len_bytes [31:0]                         |
+---------------------------------------------------------------+
|                      flags     [31:0]                         |
+---------------------------------------------------------------+
```

- **host_addr**：`sg_dma_address(sg)` 直行填入，支援 64-bit 實體/IOVA 位址。
- **len_bytes**：`sg_dma_len(sg)` 直行填入（最大支援單頁 4096 或大頁 64KB/2MB）。
- **flags**：保留擴充（中斷策略標記）。
- **硬體按鈴**：寫入 `RING_CFG` 之高 16 位元 (`tail << 16 | size`) 即完成 Doorbell。
