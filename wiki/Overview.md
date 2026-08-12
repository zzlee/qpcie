# Custom PCIe DMA Controller Wiki - 系統總覽 (Overview)

本專案實作了一套基於 **Xilinx UltraScale+ / PCIe Gen3/Gen4 原生 4 個 AXI4-Stream 介面（CQ, CC, RQ, RC）** 的客製化 PCIe Scatter-Gather DMA 控制器，支援 AXI4-Lite 控制暫存器空間與 AXI4 Memory Mapped 主控（Master）資料通道。

---

## 1. 系統整體架構圖 (Architecture Diagram)

```
+---------------------------------------------------------------------------------------------------+
|                                        custom_pcie_dma_top                                        |
|                                                                                                   |
|   +--------------------------+   +--------------------------+   +-----------------------------+   |
|   |      CQ RX Decoder       |   |      RQ TX Encoder       |   |    Interrupt Controller     |   |
|   | (Completer Request RX)   |   | (Requester Request TX)   |   |   (MSI / MSI-X / Legacy)    |   |
|   +------------+-------------+   +------------+-------------+   +--------------+--------------+   |
|                |                              ^                                ^                  |
|                v                              |                                |                  |
|   +------------+-------------+                |                                |                  |
|   |     AXI4-Lite Slave      |                |                                |                  |
|   |  Register Space (BAR0)   |                |                                |                  |
|   +------------+-------------+                |                                |                  |
|                |                              |                                |                  |
|                v                              |                                |                  |
|   +------------+-------------+   +------------+-------------+                  |                  |
|   |     Descriptor Fetch     |-->|     pcie_tag_manager     |                  |                  |
|   |          Engine          |   |   (Tag Alloc & Recycle)  |                  |                  |
|   +------------+-------------+   +------------+-------------+                  |                  |
|                |                              |                                |                  |
|                v                              v                                |                  |
|   +------------+-------------+   +------------+-------------+                  |                  |
|   |      H2C DMA Engine      |   |      C2H DMA Engine      |------------------+                  |
|   |      (Host -> FPGA)      |   |      (FPGA -> Host)      |                                     |
|   +------------+-------------+   +------------+-------------+                                     |
|                ^                              ^                                                   |
|                |                              |                                                   |
|   +------------+------------------------------+-------------+                                     |
|   |                    RC RX Decoder / Demux                |                                     |
|   |                (Requester Completion RX / CplD)         |                                     |
|   +---------------------------------------------------------+                                     |
|                                                                                                   |
|   AXI4-Lite Slave                 AXI4 MM Master                   PCIe IRQ                       |
|  (Control Registers)           (FPGA Memory Mapped)           (Interrupt Request)                 |
+---------------------------------------------------------------------------------------------------+
```

---

## 2. 四大核心介面對照表

| 介面名稱 | 全名 | 方向 (主體為 FPGA) | 主要作用 / 處理 TLP 類型 |
| :--- | :--- | :--- | :--- |
| **CQ** | Completer Request | PCIe IP → FPGA User Logic | 接收 Host 發起存取 BAR0 暫存器的讀寫請求（MRd, MWr） |
| **CC** | Completer Completion | FPGA User Logic → PCIe IP | 回應 Host 對 BAR0 讀取請求，回傳 Completion 封包（CplD） |
| **RQ** | Requester Request | FPGA User Logic → PCIe IP | FPGA 主動發起對 Host Memory 的讀寫請求（MRd, MWr）與中斷訊息 (Msg) |
| **RC** | Requester Completion | PCIe IP → FPGA User Logic | 接收 Host 回應對 RQ Read 請求的資料封包（CplD），根據 Tag 派發資料 |

---

## 3. Wiki 目錄結構 (Wiki Navigation)

- [1. 系統總覽 (Overview)](Overview.md)
- [2. TLP 封包解析與組裝層 (TLP Layer)](TLP-Layer.md)
- [3. 控制與暫存器層 (Control Layer)](Control-Layer.md)
- [4. DMA 資料搬移核心層 (DMA Core Layer)](DMA-Core-Layer.md)
- [5. 中斷與頂層整合 (System Support Layer)](System-Support-Layer.md)
- [6. 透過 Control-Layer 控制其他 IP Cores (Controlling Other IP Cores)](Controlling-Other-IP-Cores.md)
- [7. Linux Scatterlist 填入 Descriptor 範例指南 (Linux Driver Scatterlist Guide)](Linux-Driver-Scatterlist-Guide.md)
- [8. 仿真驗證與測試指南 (Verification Guide)](Verification-and-Simulation.md)
