# Wiki - 仿真驗證與測試指南 (Verification & Simulation Guide)

本專案採用 **Self-Checking (自我檢查)** 單元測試與全系統級仿真環境，確保每個模組與全系統符合 PCIe Spec 與 AXI4 協定。

---

## 1. 測試套件列表 (Testbench Suite)

| 測試檔名稱 | 測試對象 | 驗證重點 |
| :--- | :--- | :--- |
| [`tb_pcie_tag_manager.v`](file:///home/zzlee/qpcie/tb/tb_pcie_tag_manager.v) | `pcie_tag_manager` | Tag 分配/回收/重複釋放防護/Tag 0 保留機制 |
| [`tb_cq_rx_decoder.v`](file:///home/zzlee/qpcie/tb/tb_cq_rx_decoder.v) | `cq_rx_decoder` | Host CQ MWr/MRd TLP 解碼轉 AXI4-Lite 讀寫 |
| [`tb_cc_tx_encoder.v`](file:///home/zzlee/qpcie/tb/tb_cc_tx_encoder.v) | `cc_tx_encoder` | AXI4-Lite Read 轉 CC CplD 封包標頭與 Payload 組裝 |
| [`tb_axil_reg_space.v`](file:///home/zzlee/qpcie/tb/tb_axil_reg_space.v) | `axil_reg_space` | BAR0 控制/狀態/Ring Base/Tail Pointer 暫存器存取 |
| [`tb_rq_tx_encoder.v`](file:///home/zzlee/qpcie/tb/tb_rq_tx_encoder.v) | `rq_tx_encoder` | MRd/MWr/Msg 封包組裝與 4 路優先權仲裁 |
| [`tb_rc_rx_decoder.v`](file:///home/zzlee/qpcie/tb/tb_rc_rx_decoder.v) | `rc_rx_decoder` | RC CplD 封包 Tag 解析、標頭剝離與 Descriptor/FIFO 資料分流 |
| [`tb_desc_fetch_engine.v`](file:///home/zzlee/qpcie/tb/tb_desc_fetch_engine.v) | `desc_fetch_engine` | SG Descriptor 抓取、欄位解析與 H2C/C2H 派發握手 |
| [`tb_h2c_dma_engine.v`](file:///home/zzlee/qpcie/tb/tb_h2c_dma_engine.v) | `h2c_dma_engine` | Tag 申請、Host MRd 發起、CplD 接收與 AXI4 Master Write |
| [`tb_c2h_dma_engine.v`](file:///home/zzlee/qpcie/tb/tb_c2h_dma_engine.v) | `c2h_dma_engine` | AXI4 Master Read、Host MWr 發起與傳輸完成狀態 |
| [`tb_interrupt_ctrl.v`](file:///home/zzlee/qpcie/tb/tb_interrupt_ctrl.v) | `interrupt_ctrl` | DMA 完成觸發、MSI Msg TLP 產生與遮罩邏輯 |
| [`tb_pcie_dma_system.v`](file:///home/zzlee/qpcie/tb/tb_pcie_dma_system.v) | `custom_pcie_dma_top` | **全系統端到端測試**（Host Root Complex BFM + FPGA DRAM BFM） |

---

## 2. 一鍵式自動化測試執行 (Automated Regression)

專案提供腳本 [`sim/run_sim.sh`](file:///home/zzlee/qpcie/sim/run_sim.sh)，可以自動呼叫 Vivado 工具鏈 (`xvlog`, `xelab`, `xsim`) 執行所有測試：

```bash
cd /home/zzlee/qpcie
./sim/run_sim.sh
```

### 執行結果範例：
```
=================================================================
 Building & Simulating Custom PCIe AXI4-Stream DMA Project
=================================================================
Running tb_pcie_tag_manager ... [PASS]
Running tb_cq_rx_decoder ... [PASS]
Running tb_cc_tx_encoder ... [PASS]
Running tb_axil_reg_space ... [PASS]
Running tb_rq_tx_encoder ... [PASS]
Running tb_rc_rx_decoder ... [PASS]
Running tb_desc_fetch_engine ... [PASS]
Running tb_h2c_dma_engine ... [PASS]
Running tb_c2h_dma_engine ... [PASS]
Running tb_interrupt_ctrl ... [PASS]
Running tb_pcie_dma_system ... [PASS]
=================================================================
 Simulation Summary: 11 Passed, 0 Failed
=================================================================
```
