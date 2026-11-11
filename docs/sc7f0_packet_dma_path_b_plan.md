# SC7F0 Packet C2H DMA (Path B) 架構與實作計畫書

> **文件狀態**：規劃審批完成（Authorized for Implementation）  
> **目標硬體**：SC7F0 PCIe 採集卡（Xilinx Zynq UltraScale+ ZU4EV + Artix-7 A50T + NUC1262 MCU）  
> **核心宗旨**：為 ZU4EV VCU 輸出之變動長度 H.264/H.265 壓縮碼流，打通由板卡主動推入 Host RAM 之 Packet C2H DMA 通道，補齊硬體級 PCIe MSI 完成中斷，並在 PL 植入 10 組硬體除錯探針（Debug Probes），實現零 Host CPU 佔用、微秒級延遲之雙流旗艦採集卡架構。

---

## 1. 系統背景與設計動機 (Background & Motivation)

### 1.1 為什麼需要獨立的 Packet DMA？
* **Raw Video DMA (Ch0 / /dev/video0)**：走 PL 專屬光柵視訊 DMA 引擎，依賴固定寬高（如 3840×2160）與固定 Stride，由硬體換頁定時打入 Host 記憶體。
* **VCU 壓縮碼流 (Ch1 / /dev/video1)**：VCU 硬體編碼產出的是變動長度（Variable Bitrate）之 Access Units (NALUs)。IDR 關鍵幀可達 300~600 KB，P 幀僅 20~50 KB，且包含 SPS/PPS 等短 Header。既有的固定 Stride 光柵 DMA 無法處理動態長度。
* **Path A（非 DMA / 共享記憶體）之盲點**：
  1. 卡端現有 PCIe BAR0 空間僅有 1MB，無法開闢可容納 4K 壓縮幀環形隊列之緩衝區（至少需 32MB~64MB）。
  2. PCIe Host-Pull（Inbound Non-Posted Read）會引發 Host CPU 同步停頓（CPU Stall），讀取頻寬低落且消耗大量主機效能。
* **Path B 核心價值**：
  由卡端 PL 硬體發起 PCIe Posted Write (MWr TLP)，以數 GB/s 之線速將壓縮封包直接推入 Host RAM，搬移完畢由硬體發出 PCIe MSI 中斷，Host 零拷貝、零 CPU 負擔。

---

## 2. 硬體架構與修改規範 (Hardware Architecture & RTL Plan)

```mermaid
flowchart TD
    subgraph Card_PS ["ZU4EV PS (ARM A53 Linux)"]
        VIPP["V4L2 VIPP (/dev/video0)"] -->|NV12| VCU["ZU4EV VCU Hard IP (H.264/H.265)"]
        VCU -->|NAL 碼流| PSDDR["PS DDR4 (cma,vcu @ 0x54000000)"]
        PSDDR -->|位址 & 長度| VCUD["sc7f0_vcud (Daemon)"]
        VCUD -->|AXI-Lite 寫入 24-word Descriptor| CSR["PL CSR @ 0xB0040080"]
        VCUD -->|Doorbell 觸發| DOORBELL["Doorbell @ 0xB0040014"]
    end

    subgraph Card_PL ["ZU4EV PL (FPGA Logic)"]
        DOORBELL --> READER["sc7f0_ps_packet_reader"]
        READER -->|AXI HP1 突發讀取| PSDDR
        READER -->|4KB 切割 / 尾端 BE| CDC["sc7f0_packet_cdc"]
        CDC -->|PCIe 125MHz| ARB["custom_pcie_dma_top (RQ Arbiter)"]
        ARB -->|Payload TLPs| TLPOUT["PCIe MWr TLP 輸出"]
        READER -->|傳輸完畢發射| DPC1["64-byte DPC1 Completion Record"]
        DPC1 --> TLPOUT
        DPC1 -->|完成脈衝| IRQ_GEN["【新增】Packet Done MSI 觸發連線"]
        
        subgraph Probes ["【新增】硬體除錯探針池 (10 組 32-bit 計數器)"]
            P_SUB["PKT_SUBMIT_CNT"]
            P_DONE["PKT_DONE_CNT"]
            P_ERR["PKT_ERR_CNT"]
            P_MSI["PKT_MSI_CNT"]
            P_BYTES["PKT_BYTES_LO/HI"]
            P_STATE["PKT_FSM_STATE"]
            P_PTS["PKT_LAST_PTS_LO/HI"]
            P_LEN["PKT_LAST_LEN"]
        end
    end

    subgraph Host_PC ["x86 PCIe Host PC"]
        TLPOUT -->|直接寫入| HOST_RAM["Host RAM (VB2 Pre-allocated Coherent Buffers)"]
        IRQ_GEN -->|PCIe MSI (IRQ 149)| ISR["qpcie_irq_handler (Bit 1: Video CH1)"]
        ISR -->|喚醒| V4L2_VCH1["Host /dev/video1 (V4L2_PIX_FMT_H264)"]
        V4L2_VCH1 -->|零拷貝取幀| APP["OBS Studio / FFmpeg / GStreamer"]
        Probes -.->|BAR0 0x01C0..0x01E4| SYSFS["/sys/bus/pci/.../packet_stats"]
    end
```

### 2.1 核心 RTL 補齊：PCIe MSI 中斷連線
* **問題根因**：原 `sc7f0_dualpath.v` 中的 `dp_irq` 僅連至卡端 PS GIC SPI 92，未連接 PCIe MSI 產生器。
* **修改方案**：
  在 `rtl/custom_pcie_dma_top.v` 中，將 `sc7f0_dualpath` 送出 `DPC1` 後產生的 `packet_done_pulse` 同步至 `pcie_clk` 領域，接至內部 `v_done_ch[1]`。
  - 當 `v_done_ch[1]` 觸發時，硬體置位 `vch1_irq_status_w[0]`。
  - 連帶觸發頂層 `irq_top_status_w[1]`（Video CH1 Done）。
  - 自動發動 `usr_irq_req` 向 Host 發射 PCIe MSI 訊息中斷。

---

## 3. 除錯探針（Debug Probes）暫存器規格

為了在帶板與軟體整合初期具備 100% 透明之觀測能力，於硬體中實作 10 組 32-bit 即時診斷計數器：

| 暫存器名稱 | 位址偏移 (PS AXI-Lite) | 位址偏移 (Host BAR0) | 屬性 | 描述與除錯用途 |
| :--- | :---: | :---: | :---: | :--- |
| **`PKT_SUBMIT_CNT`** | `0xB0040100` | `0x01C0` | RO | **PS 提交封包總數**：卡端每敲一次 Doorbell (`0x014`) 加 1。 |
| **`PKT_DONE_CNT`** | `0xB0040104` | `0x01C4` | RO | **硬體完成封包總數**：Payload 與 DPC1 均確認打入 Host RAM 後加 1。 |
| **`PKT_ERR_CNT`** | `0xB0040108` | `0x01C8` | RO | **硬體異常計數**：位址未對齊、AXI 錯誤、長度超標（>8MB）加 1。 |
| **`PKT_MSI_CNT`** | `0xB004010C` | `0x01CC` | RO | **PCIe MSI 發送總數**：硬體對 Host 發出中斷脈衝之累計次數。 |
| **`PKT_BYTES_LO`** | `0xB0040110` | `0x01D0` | RO | **累計傳輸 Byte 數（低 32 位元）**。 |
| **`PKT_BYTES_HI`** | `0xB0040114` | `0x01D4` | RO | **累計傳輸 Byte 數（高 32 位元）**。 |
| **`PKT_FSM_STATE`** | `0xB0040118` | `0x01D8` | RO | **硬體狀態快照**：<br>`[3:0]`: Reader 狀態 (0:IDLE, 1:PREP, 2:AR, 3:READ, 4:SEND, 5:WAIT, 6:REC, 7:REP)<br>`[4]`: busy<br>`[5]`: cmd_ready<br>`[6]`: done_valid<br>`[7]`: pcie_arb_owner |
| **`PKT_LAST_LEN`** | `0xB004011C` | `0x01DC` | RO | **前一幀實際 Payload Byte 數**（如 `245,820`）。 |
| **`PKT_LAST_PTS_LO`** | `0xB0040120` | `0x01E0` | RO | **前一幀 PTS 時戳（低 32 位元）**。 |
| **`PKT_LAST_PTS_HI`** | `0xB0040124` | `0x01E4` | RO | **前一幀 PTS 時戳（高 32 位元）**。 |

---

## 4. 64-Byte Host 完成記錄結構 (DPC1 Wire Format)

每筆封包資料搬移完畢後，硬體保證自動發射一筆 64-byte 之完成結構體至 Host 指定之 Completion 物理位址：

```text
Offset  0: 0x44504331 (Magic: "DPC1")
Offset  4: Status (0=Success, Bit0=Invalid Job, Bit1=AXI R Error, Bit2=Length Error)
Offset  8: Sequence Number (64-bit uint)
Offset 16: Source Frame ID (64-bit uint)
Offset 24: PTS - Presentation Timestamp (64-bit uint, 150MHz capture ticks or monotonic us)
Offset 32: DTS - Decoding Timestamp (64-bit uint)
Offset 40: Transferred Payload Bytes (32-bit uint)
Offset 44: Flags (Bit0=AU_START, Bit1=AU_END, Bit2=KEYFRAME, Bit3=CODEC_CONFIG, Bit6=EOS)
Offset 48: Stream Epoch (32-bit uint)
Offset 52: Cookie (32-bit uint, echo from descriptor)
Offset 56: Timebase Numerator (32-bit uint)
Offset 60: Timebase Denominator (32-bit uint)
```

---

## 5. 實施路線與里程碑 (Milestones & Verification Gates)

### 里程碑 1：RTL 修改與 Testbench 模擬驗證
* 修改 `rtl/sc7f0_ps_packet_reader.v`、`rtl/sc7f0_dualpath_regs.v` 增加 10 組 Probes。
* 修改 `rtl/custom_pcie_dma_top.v` 接通 MSI 中斷脈衝至 `v_done_ch[1]`。
* 更新 `tb/sc7f0_dualpath_tb.sv` 執行仿真：
  - 驗證單一封包、連續連續封包、4K 巨量封包（1B ~ 65KB ~ 2MB）。
  - 斷言驗證 `PKT_SUBMIT_CNT == PKT_DONE_CNT == PKT_MSI_CNT`。
  - 驗證尾端 DWORD 不越界寫入（Zero Tail Corruption）。
* **驗收標準**：`scripts/sim_sc7f0_dualpath.tcl` 仿真通過，回傳 `DUALPATH_SIM_GATE_PASS`。

### 里程碑 2：Vivado 硬體合成、繞線與位元流簽核
* 透過 Vivado 2023.2 執行完整實施（帶入授權 `2101@192.168.200.112`）。
* **時序門禁（Timing Gate）**：WNS > 0, WHS > 0, TNS/THS = 0。
* **CDC 門禁**：通過跨時鐘域檢查，無新增 Critical CDC。
* 產出新 XSA、`zu4ev_pcie_card_top.bit` 與 `BOOT.BIN`。

### 里程碑 3：Host 驅動 Video Node 1 啟用與 Sysfs Probes
* 在 `driver/qpcie_v4l2.c` 中註冊 `/dev/video1`（標記 `V4L2_PIX_FMT_H264`）。
* 在 `driver/qpcie_main.c` 的 `top & BIT(1)` 中斷服務常式中：
  - 讀取 DPC1 完成記錄。
  - 設定 `vb2_buffer` 之 `timestamp`、`bytesused` 與 `flags`。
  - 呼叫 `vb2_buffer_done(vb, VB2_BUF_STATE_DONE)` 喚醒應用程式。
* 新增 sysfs 節點 `/sys/bus/pci/devices/0000:03:00.0/packet_stats`，直接打印 10 組 Probe 計數器。

### 里程碑 4：卡端 PS VCU 發送服務與端到端實機驗收
* 撰寫卡端輕量 daemon `sc7f0_vcud`，接軌 VIPP `/dev/video0` $\to$ VCU 硬體編碼 $\to$ Packet DMA 描述符佇列。
* 在 Host PC 透過 `qpcie_upgrade` 進行 PCIe 線上熱更新（Zero-Host-Reboot）。
* 在 Host PC 執行驗收：
  ```bash
  gst-launch-1.0 v4l2src device=/dev/video1 ! h264parse ! avdec_h264 ! autovideosink
  ```
* 驗收標準：4K60 壓縮串流流暢播放，PTS 平滑無抖動，`PKT_ERR_CNT == 0`。
