# SC7F0 26102702 BRAM 實際使用明細

2026-10-27，唯讀分析；未修改RTL／IP、未synth/place/route、未重寫bit或部署。

## 來源與計數方法

- Routed DCP：`build/qpcie_zu4ev_live_proj/qpcie_zu4ev_live.runs/impl_1/zu4ev_pcie_card_top_routed.dcp`。
- 同一implementation目錄的bit與凍結26102702 bit SHA均為
  `8eae04ead796f01dbd28f8ce5772669f60ebf489bede555b6d893fe8a5aff962`。
- Vivado2023.2只執行open_checkpoint／report_utilization及primitive查詢。
- 葉節點共120個RAMB36E2、14個RAMB18E2：`120 + 14/2 = 127`等效BRAM36 tiles。
  半個tile為RAMB18，不代表已保證後續placement可任意拼接。
- 階層report亦確認目前URAM使用0，凍結device utilization提供URAM可用48；VCU使用0。

證據：`build/validation/sc7f0-vcu-bram-review.f43jJWG5/`，
指標 `build/.sc7f0-vcu-bram-latest`。
其中含`inputs.sha256`、完整`utilization_hierarchical.rpt`、
逐個BRAM的`ram_primitives.tsv`及Vivado log。輸入SHA在分析後再次讀檔核對一致。

## 不重複計數的明細

| 模組／群組 | 等效BRAM36 | 說明 |
|---|---:|---|
| PCIe IP `u_pcie_ip` | 22 | PCIe core內部buffer |
| SG fetch `u_dma_top/u_sg_host_fetch_engine` | 21 | H2C Y7.5、H2C UV2、C2H Y7.5、C2H UV4 |
| ILA `u_dma_top/u_ila_ps_axi` | 19.5 | PS AXI邏輯分析儀，4096-depth，非影像功能必需buffer |
| 四個video request CDC | 16 | `u_video_req_cdc`、`_ch1`、`gen_vch2`、`gen_vch3`，各4 |
| HDMI RX subsystem | 8 | 其中video-in→AXIS部分7，其餘1 |
| Video TPG | 6 | 測試畫面產生器 |
| 三個audio stream FIFO | 6 | ch0/ch2/ch3各2 |
| 三個loopback CDC | 6 | ch1/ch2/ch3各2 |
| HDMI RX video CDC | 4 | `u_hdmi_rx_video_cdc_fifo` |
| HDMI TX subsystem | 4 | 主要是AXIS→video-out buffer |
| HDMI TX video bridge | 4 | TX video CDC |
| SGL Y/UV CDC | 4 | 各2 |
| Debug mailbox | 2 | 控制／管理面，與ILA不同，不能把兩者混為一談 |
| SG DMA H2C reorder | 2 | `u_sg_dma_engine/u_h2c_reorder_buffer` |
| Native NV12 chroma line | 1 | `u_nv12_capture_engine` |
| 兩個audio H2C FIFO | 1 | 各0.5 |
| HDMI TX audio bridge | 0.5 | TX audio CDC |
| **合計** | **127** | 與凍結report完全相符 |

上述DMA top子項合計78.5；不要再與78.5重複相加。
Video PHY、PS wrapper、AXI crossbar等在此次primitive清單沒有額外BRAM；不表示它們不使用其他資源。

## 回收順序建議（僅討論，尚未修改）

1. **先ILA**：完整移除可釋出等效19.5 tiles，或development profile縮depth。
   只改depth時實際節省量以新綜合為準，不宣稱必然線性縮放。
2. **評估48個未用URAM**：SG table FIFO為單clock大buffer，適合優先研究；
   仍須適配URAM latency與讀取握手，不是只改一個`ram_style`就保證完成。
3. **按需求評估未使用多通道／loopback及PL HDMI TX**：TX subsystem＋bridges共8.5，TPG另6。
   未經同意不刪功能；PL TX與IT6663用於餵PL RX的TXP1不是同一個東西。
4. 保留真正需要的PCIe／RX／CDC buffers；不為了省BRAM盲目縮depth。

尤其SG fetch的Y depth2048／UV depth1024，是為完整4K NV12 SGL table（約2025／1013 entries）設定。
現有全表緩存打破prefetch與consumer之間的等待環，任意縮小可能重新造成deadlock；
可改儲存資源或重新設計流式prefetch，但必須有對應ownership／forward-progress設計。

**結論：BRAM接近滿是真的，但不是無法加入VCU的結論。**
先處理19.5-tile ILA與可用URAM，之後才評估新增capture／encoded DMA的資源與時序。
LUT也已有86.24%且WNS僅+0.076ns，不能只看BRAM空間就保證新設計可route。
