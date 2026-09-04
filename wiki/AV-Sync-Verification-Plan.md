# 影音同步 (Audio/Video Synchronization) 驗證計畫

## 1. 背景與驗證目標

在多媒體視訊擷取與 PCIe DMA 傳輸系統中，影音同步（AV Sync / Lip Sync）是衡量系統即時性與資料對齊精確度的核心指標。
依據國際廣播電視標準（如 ITU-R BT.1359-1）：
- **聽覺超前視覺（Audio Leads Video）**：應控制在 **-20 ms** 以內。
- **聽覺落後視覺（Audio Lags Video）**：應控制在 **+40 ms** 以內。
- **高標準專業廣播級系統**：目標維持在 **±5 ms (或 1 視訊幀 / ~16.6ms)** 以內。

本計畫旨在建立 QPCIe 系統在 Jetson Orin NX / Linux 平台上的全鏈路影音時間基準與驗證方法，確保在長時間高負載運作下無漂移、無亂序、左右聲道相位鎖定，並能精確量化視訊與音訊間的延遲差。

---

## 2. 硬體架構與時間戳 (PTS) 機制

QPCIe FPGA 內部具備統一的全域時間基準計數器與硬體取樣閉環機制：

### 2.1 全域時間戳計數器 (`global_timestamp`)
- **時鐘源**：PCIe 用戶時鐘 `user_clk`（125.000 MHz，週期 8.000 ns）。
- **計數寬度**：64-bit free-running counter。
- **讀取介面**：BAR0 暫存器 `0x50`（低 32 位元）與 `0x54`（高 32 位元）。
- **溢位週期**：約 4,680 年，無溢位翻轉疑慮。

### 2.2 視訊影格時間戳 (`reg_last_video_pts`)
- **觸發時刻**：當視訊輸入端（AXI-Stream TPG / Video Pipeline）出現 SOF（Start of Frame，即 `s_axis_tuser[0] == 1` 且首個 pixel beat 握手成立）的瞬間。
- **暫存器映射**：BAR0 `0x58`（[31:0]）與 `0x5C`（[63:32]）。
- **精度**：單個 clock cycle（8 ns），記錄在 `v_pts[0]`。

### 2.3 音訊取樣時間戳 (`reg_last_audio_pts`)
- **觸發時刻**：當 AES3 / I2S 音訊子影格（Subframe / Sample）產生或音訊 DMA 發起時鎖存。
- **暫存器映射**：BAR0 `0x60`（[31:0]）與 `0x64`（[63:32]）。
- **精度**：單個 clock cycle（8 ns）。

---

## 3. 兩種驗證方法設計

### 方法一：雙串流硬體時間戳統計關聯法 (Timestamp Correlation Method)
此方法適用於自動化回歸測試與長時間穩定性驗證（如 1 小時連續擷取）：

```
+-------------------------------------------------------------+
|                     QPCIe Artix-7 FPGA                      |
|                                                             |
|   +-----------------------+     +-----------------------+   |
|   |   Video TPG (60Hz)    |     |   Audio Gen (48kHz)   |   |
|   |   SOF Event Trigger   |     |   Sample Clock Event  |   |
|   +-----------+-----------+     +-----------+-----------+   |
|               |                             |               |
|               v                             v               |
|        [Latch PTS @ SOF]           [Latch PTS @ Sample]     |
|               |                             |               |
+---------------+-----------------------------+---------------+
                | PCIe DMA Ring               | PCIe DMA Buffer
                v                             v
     /dev/video0 (V4L2)               /dev/snd/pcmC* (ALSA)
   buf->vb2_buf.timestamp          snd_pcm_status.audio_tstamp
                |                             |
                +--------------+--------------+
                               |
                               v
               [av_sync_analyzer 使用者空間測試工具]
               計算 Δt = PTS_video - PTS_audio
```

1. **原理**：
   - 視訊幀率固定為 60.000 Hz（週期 16.666 ms，2,083,333 個 125MHz cycles）。
   - 音訊採樣率固定為 48.000 kHz（每秒 48,000 個 stereo samples）。
   - 理論上每 1 視訊影格對應剛好 800 個立體聲音訊取樣點 ($48000 / 60 = 800$)。
2. **軟體收集**：
   - 使用者空間應用程式透過 V4L2 取得每一幀的 DMA 完工時間戳與硬體 PTS。
   - 同時透過 ALSA API 取得對應音訊環形緩衝區的指針與硬體 PTS。
   - 計算兩者之相對差值 $\Delta t = PTS_{video} - PTS_{audio}$。
3. **判定準則**：
   - $\Delta t$ 必須呈水平線性分佈，無斜率（若有斜率代表視訊時鐘與音訊時鐘存在漂移 Drift）。
   - 抖動（Jitter）應落在 $\pm 1$ audio sample 週期（約 $20.83\ \mu\text{s}$）以內。

---

### 方法二：聲畫閉環脈衝法 (Flash-and-Beep Closed-Loop Verification)
此方法為廣播電視工業界的黃金標準（Gold Standard），完全排除驅動或作業系統層的時間戳插補誤差。

1. **測試 Pattern 設計**：
   - **視訊**：TPG 平時輸出黑畫面（Black Frame）；每隔固定間隔（如每 120 影格，剛好 2.0 秒），插入連續 2 影格的純白畫面（Flash，全白 100% IRE）。
   - **音訊**：平時音訊輸出靜音（Silence）；在該純白畫面出現的第 1 個 cycle（SOF），音訊硬體立即同步觸發一段 1 kHz 正弦波脈衝（Beep，持續 20 ms）。
2. **分析與檢驗流程**：
   - 使用單一測試程式或 GStreamer pipeline 同步錄製 `.nv12` 視訊流與 `.wav` 音訊流。
   - 離線分析軟體自動檢測：
     - 視訊流中全白畫面的精確影格編號與微秒級時間位置 $T_{flash}$。
     - 音訊流中 1 kHz 音波振幅超過門檻的第 1 個取樣點時間位置 $T_{beep}$。
   - 計算偏差值：
     $$\text{Skew} = T_{flash} - T_{beep}$$
3. **驗證規格要求**：
   - $\text{Skew} \le \pm 1\ \text{frame} = \pm 16.6\ \text{ms}$。
   - 左右聲道相位差 $= 0\ \text{samples}$（已由實機測試驗證 100% 無聲道混淆）。

---

## 4. 實施步驟清單 (Roadmap)

- [ ] **Step 1: 驅動層 PTS 傳遞支援**
  - 在 `driver/qpcie_v4l2.c` 的 buffer completion 中，讀取暫存器 `0x58/0x5C` 並填入 `v4l2_buffer.timestamp`。
  - 在 `driver/qpcie_alsa.c` 的 period elapsed 中，讀取暫存器 `0x60/0x64` 並填入 `snd_pcm_substream->runtime->status->hw_ptr` 與對應硬體時間戳。
- [ ] **Step 2: FPGA Pattern Generator 擴充 Flash-and-Beep**
  - 在 TPG 模組或暫存器控制層加入 Flash-and-Beep 同步連動開關。
- [ ] **Step 3: 撰寫 `test_app/av_sync_test` 驗證工具**
  - 同步啟動 `/dev/video0` 與 `/dev/snd/pcmC2D0c`。
  - 統計並繪製 10 分鐘長時間運作之 AV Skew 分佈曲線圖與直方圖。
