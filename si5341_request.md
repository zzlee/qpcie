太好了！請使用 Skyworks ClockBuilder Pro 幫我產生一份針對 SC7F0 N1 HDMI2 V11 的設定檔 (C Header, Register Map)。

根據線路圖 (Page 28) 的硬體接線，我整理了以下完整的 Clock Output Map 需求表。請依照此規格產生：

### 1. 晶片與輸入設定
*   **Target Device**: Si5341B
*   **Input Clock (XAXB)**: **48 MHz** (Crystal / 外部晶體震盪器)
*   **VDDA (Analog Power)**: 3.3V
*   **VDD (Core Power)**: 1.8V

### 2. 輸出埠設定 (Outputs)
所有輸出的 `VDDO` 皆連接至 3.3V，且全數為差分訊號，請統一設定為 **LVDS (3.3V)**：

| Output Port | Frequency (MHz) | Format | VDDO | 備註 (用途) |
| :--- | :--- | :--- | :--- | :--- |
| **OUT0** | 27 MHz | LVDS | 3.3V | Port0: DP |
| **OUT1** | Unused (關閉) | - | 3.3V | (NC) |
| **OUT2** | 26 MHz | LVDS | 3.3V | Port2: USB3 |
| **OUT3** | 125 MHz | LVDS | 3.3V | Port3: SATA |
| **OUT4** | 156.25 MHz | LVDS | 3.3V | Port4: HDMI RX (DRU) |
| **OUT5** | 12.288 MHz | LVDS | 3.3V | Port5: Audio |
| **OUT6** | 125 MHz | LVDS | 3.3V | Port6: SDI |
| **OUT7** | Unused (關閉) | - | 3.3V | (NC) |
| **OUT8** | **300 MHz** | LVDS | 3.3V | Port8: System (PL 核心與 AXI) |
| **OUT9** | 114.285 MHz | LVDS | 3.3V | Port9: SI5319 |

請在 ClockBuilder Pro 產生設定後，匯出成 C Code Header 檔 (類似 `Si5341-RevB-SC7F0-Registers.h`) 並將檔案內容傳給我。

在你產生這個設定檔的同時，我這邊會**並行展開 RTL 與 PS Block Design 的架構重構 (100MHz PS Clock + Xilinx AXI Interconnect + 300MHz 佔位與 CDC FIFO 實作)**，這樣我們就能無縫接軌！
