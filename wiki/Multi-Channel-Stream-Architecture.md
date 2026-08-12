# Wiki - 多路 2D Video 及 AES3 Audio AXI4-Stream 原生架構

本專案已成功重構頂層架構，**完全取消原本的 AXI Memory Mapped (AXI MM) 記憶體對接方式**，改採用 **原生 AXI4-Stream 影音串流 (Native AXI4-Stream Video & AES3 Audio)**。

並且透過 Verilog `parameter` 與 `generate` 迴圈控制硬體例化，實現任意路數之 Multi-Channel 彈性配置。

---

## 1. 系統架構圖 (Native AXI4-Stream Video & Audio Architecture)

```
                                 custom_pcie_dma_top
 +----------------------------------------------------------------------------------+
 |                                                                                  |
 |  [Verilog Parameter Configuration]                                               |
 |  parameter NUM_VIDEO_CH = 4                                                      |
 |  parameter NUM_AUDIO_CH = 4                                                      |
 |                                                                                  |
 |  +----------------------------------------------------------------------------+  |
 |  | generate for (v_idx = 0; v_idx < NUM_VIDEO_CH; v_idx++)                    |  |
 |  |   video_stream_engine u_video_stream_engine (                              |  |
 |  |      .s_axis_video_* (C2H Video Input: SOF=tuser[0], EOL=tlast),           |  |
 |  |      .m_axis_video_* (H2C Video Output: SOF=tuser[0], EOL=tlast)            |  |
 |  |   );                                                                       |  |
 |  +----------------------------------------------------------------------------+  |
 |                                                                                  |
 |  +----------------------------------------------------------------------------+  |
 |  | generate for (a_idx = 0; a_idx < NUM_AUDIO_CH; a_idx++)                    |  |
 |  |   audio_stream_engine u_audio_stream_engine (                              |  |
 |  |      .s_axis_audio_* (C2H AES3 Audio Input: 32-bit Subframe),               |  |
 |  |      .m_axis_audio_* (H2C AES3 Audio Output: 32-bit Subframe)              |  |
 |  |   );                                                                       |  |
 |  +----------------------------------------------------------------------------+  |
 |                                                                                  |
 |  +--------------------+  +--------------------+  +----------------------------+  |
 |  | BAR0 (DMA Regs)    |  | BAR1 (User IP Mst) |  | RQ Multichannel Arbiter    |  |
 |  +--------------------+  +--------------------+  +----------------------------+  |
 +----------------------------------------------------------------------------------+
```

---

## 2. 介面規格說明

### 2.1 AXI4-Stream Video Signal 介面規格
- **`s_axis_video_tdata` / `m_axis_video_tdata`**：像素資料位元組。
- **`tuser[0]` (SOF - Start of Frame)**：第一行的第一個像素為 `1`，標記新畫面開頭。
- **`tlast` (EOL - End of Line)**：每一行的最後一個像素為 `1`，標記掃描線結束。

### 2.2 AXI4-Stream Audio AES3 (IEC 60958) 介面規格
- **`s_axis_audio_tdata` / `m_axis_audio_tdata`**：32-bit AES3/IEC60958 音訊子訊框 (Subframe)：
  - `Bits [3:0]`：Preamble Sync (B, M, W 導航訊號)
  - `Bits [27:4]`：24-bit LPCM 音訊採樣值
  - `Bit 28`：Validity bit (V)
  - `Bit 29`：User Data bit (U)
  - `Bit 30`：Channel Status bit (C)
  - `Bit 31`：Parity bit (P)
- **`tlast`**：標記 PCM 區塊結束 (End of Audio Block)。

---

## 3. Verilog `parameter` 與 `generate` 配置範例

可以在 Vivado 整合時直接更改參數：

```verilog
custom_pcie_dma_top #(
    .NUM_VIDEO_CH(8),     // 擴充至 8 路 Video 頻道
    .NUM_AUDIO_CH(8),     // 擴充至 8 路 AES3 Audio 頻道
    .VIDEO_DATA_WIDTH(32),
    .AUDIO_DATA_WIDTH(32)
) u_pcie_dma (
    .clk(clk),
    .rst_n(rst_n),
    // ...
);
```
