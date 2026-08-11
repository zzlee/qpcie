# Wiki - TLP 封包解析與組裝層 (TLP Layer)

TLP Layer 負責 PCIe AXI4-Stream 介面（256-bit 位寬）與內部邏輯訊號間的轉譯與處理。

---

## 1. `pcie_tag_manager.v` (PCIe Tag 管理器)
- **檔案位置**：[`rtl/pcie_tag_manager.v`](file:///home/zzlee/qpcie/rtl/pcie_tag_manager.v)
- **主要用途**：
  - PCIe 為非同步 Read 機制，FPGA 發起 Non-Posted Memory Read (MRd) 請求時需指派獨立 Tag。
  - 此模組動態管理可用的 Tag 池（預設保留 Tag 0 供 Descriptor Fetch 使用，Tag 1~63 供 DMA 資料傳輸使用）。
  - 支援同時分配 (`alloc_req`) 與回收 (`free_req`) 動作，具備溢位與 Full 狀態保護。

---

## 2. `cq_rx_decoder.v` (CQ RX 解碼模組)
- **檔案位置**：[`rtl/cq_rx_decoder.v`](file:///home/zzlee/qpcie/rtl/cq_rx_decoder.v)
- **主要用途**：
  - 監聽並解析 PCIe IP 送入的 CQ (Completer Request) 封包。
  - 當 Host 發起對 FPGA BAR0 的存取時，判斷 TLP 類型：
    - **Memory Write (MWr)**：轉譯為 AXI4-Lite Write Transaction（`awaddr`, `wdata`）寫入暫存器。
    - **Memory Read (MRd)**：轉譯為 AXI4-Lite Read Transaction（`araddr`），並透過 Sideband 訊號通知 `cc_tx_encoder` 準備組裝 Completion 封包。

---

## 3. `cc_tx_encoder.v` (CC TX 組包模組)
- **檔案位置**：[`rtl/cc_tx_encoder.v`](file:///home/zzlee/qpcie/rtl/cc_tx_encoder.v)
- **主要用途**：
  - 當 Host 讀取 FPGA 控制暫存器時，`cc_tx_encoder` 接收 AXI4-Lite 讀取回應資料 (`rdata`)。
  - 將資料與解碼資訊（Tag, Requester ID, Lower Address, Byte Count）組裝成符合 PCIe Spec 的 CplD (Completion with Data) TLP。
  - 透過 256-bit CC 介面將回應封包傳送回 PCIe IP。

---

## 4. `rq_tx_encoder.v` (RQ TX 發送仲裁與組包模組)
- **檔案位置**：[`rtl/rq_tx_encoder.v`](file:///home/zzlee/qpcie/rtl/rq_tx_encoder.v)
- **主要用途**：
  - 負責將 FPGA 發起的 DMA 請求與中斷訊息組裝成 Request TLP。
  - 內建 4 路固定優先權仲裁器（Arbitrator）：
    1. **Priority 1 (最高)**：中斷訊息 (Msg TLP)
    2. **Priority 2**：Descriptor 抓取讀取請求 (MRd TLP)
    3. **Priority 3**：H2C DMA 資料讀取請求 (MRd TLP)
    4. **Priority 4**：C2H DMA 資料寫入請求 (MWr TLP)
  - 處理多 Beat 封包 (Payload Data Stream) 的發送控制。

---

## 5. `rc_rx_decoder.v` (RC RX 解碼與分流模組)
- **檔案位置**：[`rtl/rc_rx_decoder.v`](file:///home/zzlee/qpcie/rtl/rc_rx_decoder.v)
- **主要用途**：
  - 接收 Host 回應的 RC (Requester Completion) 封包。
  - 解析 DW1 標頭中的 **Tag 欄位** 進行精確分流：
    - **Tag == 8'h00**：資料判定為 Descriptor 內容，剔除 96-bit RC 標頭後路由至 `desc_fetch_engine`。
    - **Tag > 8'h00**：資料判定為 H2C DMA payload，路由至 H2C Data FIFO，並同時向 `pcie_tag_manager` 發起 Tag 回收通知。
