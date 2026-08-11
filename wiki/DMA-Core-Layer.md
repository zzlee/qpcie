# Wiki - DMA 資料搬移核心層 (DMA Core Layer)

本層模組負責 Scatter-Gather (SG) 環形佇列處置與 Host 與 FPGA 間雙向 AXI4 Memory Mapped 資料搬移。

---

## 1. `desc_fetch_engine.v` (Descriptor 抓取與派發引擎)
- **檔案位置**：[`rtl/desc_fetch_engine.v`](file:///home/zzlee/qpcie/rtl/desc_fetch_engine.v)
- **主要用途**：
  - 維護 Descriptor Ring 的 `head_ptr` 與 `tail_ptr`。
  - 當 Host 更新 Tail Pointer 且 `head_ptr != tail_ptr` 時，主動透過 `rq_tx_encoder` 向 Host Memory 發送 32-Byte (8 DW) 的 MRd 請求。
  - 接收來自 `rc_rx_decoder` 的 CplD payload，解析出以下 Descriptor 結構：
    - `src_addr` [63:0] (來源記憶體位址)
    - `dst_addr` [63:0] (目的記憶體位址)
    - `len` [31:0] (傳輸位元組長度)
    - `ctrl` [31:0] (控制與方向標記)
  - 根據 `src_addr[0]` 判定傳輸方向，派發給 `h2c_dma_engine` 或 `c2h_dma_engine`，並推進 Head Pointer。

---

## 2. `h2c_dma_engine.v` (Host-to-Card DMA 引擎)
- **檔案位置**：[`rtl/h2c_dma_engine.v`](file:///home/zzlee/qpcie/rtl/h2c_dma_engine.v)
- **主要用途**：
  - 處理資料從 **Host 記憶體搬移至 FPGA DRAM/On-chip RAM** 的傳輸。
  - 運作流程：
    1. 接收派發之 H2C Descriptor，向 `pcie_tag_manager` 申請分配獨占 Tag。
    2. 透過 `rq_tx_encoder` 發起對 Host 記憶體的 Read (MRd) 請求。
    3. 自 `rc_rx_decoder` 接收 Host 傳回的 Completion (CplD) Payload 寫入內部 FIFO。
    4. 控制 AXI4 Master Write 控制器（`m_axi_awaddr`, `m_axi_wdata`, `m_axi_wlast`），將資料寫入 FPGA 內部 AXI4 MM 記憶體。
    5. 寫入完成後更新完成計數，並觸發完成 Flag。

---

## 3. `c2h_dma_engine.v` (Card-to-Host DMA 引擎)
- **檔案位置**：[`rtl/c2h_dma_engine.v`](file:///home/zzlee/qpcie/rtl/c2h_dma_engine.v)
- **主要用途**：
  - 處理資料從 **FPGA DRAM/On-chip RAM 搬移至 Host 記憶體** 的傳輸。
  - 運作流程：
    1. 接收派發之 C2H Descriptor。
    2. 驅動 AXI4 Master Read 控制器（`m_axi_araddr`, `m_axi_rready`），從 FPGA 內部 AXI4 MM 記憶體讀取資料。
    3. 將讀取之 AXI 資料傳送給 `rq_tx_encoder` 組裝成 Memory Write (MWr) TLP。
    4. 送出 PCIe MWr 封包至 Host 記憶體並更新傳輸完成狀態。
