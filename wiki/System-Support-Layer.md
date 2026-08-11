# Wiki - 中斷與頂層整合 (System Support Layer)

## 1. `interrupt_ctrl.v` (中斷控制器)
- **檔案位置**：[`rtl/interrupt_ctrl.v`](file:///home/zzlee/qpcie/rtl/interrupt_ctrl.v)
- **主要用途**：
  - 監控 H2C 及 C2H DMA 引擎的完成 (`h2c_done`, `c2h_done`) 與錯誤訊號。
  - 比對 `IRQ_CTRL` 暫存器的致能遮罩 (Interrupt Enable Mask)。
  - 若致能，發起 MSI / MSI-X 中斷請求：
    - 透過 `rq_tx_encoder` 向 Host 送出 Interrupt Message TLP (`irq_req_code`)。
    - 同時拉高實體中斷線 (`usr_irq_req`)，並維護 `IRQ_STATUS` 暫存器之 Pending 位元。

---

## 2. `custom_pcie_dma_top.v` (頂層整合模組)
- **檔案位置**：[`rtl/custom_pcie_dma_top.v`](file:///home/zzlee/qpcie/rtl/custom_pcie_dma_top.v)
- **主要用途**：
  - 頂層 Wrapper，負責將所有 10 個子模組內部匯流排與控制線進行點對點連接。
  - **對外對接介面**：
    1. **PCIe IP AXI4-Stream 介面** (`s_axis_cq`, `m_axis_cc`, `m_axis_rq`, `s_axis_rc`)
    2. **AXI4 MM Master 介面** (對接 FPGA 側 DRAM, BRAM 或 User Logic)
    3. **實體中斷訊號線** (`usr_irq_req`, `usr_irq_ack`)
