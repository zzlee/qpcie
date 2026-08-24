# A50T TLP Layer：pg054 Bridge 與 128-byte Requester

## 1. 7-Series boundary

A50T `pcie_7x_0` 提供 128-bit RX/TX AXI-Stream，而共用 DMA core 使用內部分離的 CQ/CC/RQ/RC signals。`pcie_7x_axi_bridge.v` 負責：

- RX TLP type/header decode。
- BAR hit sideband forwarding。
- TX arbitration/adaptation。
- pg054 byte ordering conversion。
- 4-DW MWr 跨 beat payload handling。
- CplD header field extraction。

byte swap 只在 bridge boundary 進行，避免 driver/核心 RTL 出現重複 workaround。

## 2. CQ / BAR requests

`cq_rx_decoder.v` 支援 host BAR MRd/MWr：

- BAR0 → `axil_reg_space.v`。
- BAR1 → top-level AXI-Lite crossbar。
- 依 BAR hit 正規化 absolute address 為 relative offset。
- AXI read `rvalid` 或 write `bvalid` 出現後立即回 IDLE/ready，支援 back-to-back MMIO。

64-bit host 的 4-DW MWr beat 0 是 address header，beat 1 才是 32-bit payload；bridge 會正確重組。

## 3. CC / BAR read completion

`cc_tx_encoder.v` 使用 Requester ID、Tag、Lower Address、Byte Count 與 AXI read data 組出 CplD。BAR readback 實機已驗證 version `0x02010001`、caps `0x0004040F`。

## 4. RQ requester

`rq_tx_encoder.v` 接收：

- Descriptor MRd。
- H2C data MRd。
- C2H SG/video MWr。
- MSI request。

C2H MWr 支援 multi-beat payload streaming；目前驗證值為 128 bytes：

```text
32 DW / request
8 × 128-bit payload beats
```

`c2h_req_data_ready` 形成真正的 beat-level backpressure。仲裁 owner 在整個 TLP 完成前鎖定，不能在 payload 中途切換 SG/video/audio source。

## 5. RC completion decode

Bridge 完成 pg054 AXI byte ordering 正規化後，raw Cpl/CplD header 欄位為：

```verilog
lower_addr = rx_data[70:64];
byte_count = rx_data[43:32];
status     = rx_data[47:45];
tag        = rx_data[79:72];
requester  = rx_data[95:80];
```

Bridge 再把這些欄位 repack 到 internal RC sideband；下游 `rc_rx_decoder` 不應重新套用 raw pg054 slices。

- Tag 0：descriptor completion。
- 其他 Tag：H2C payload/tag recycle。

錯誤切片曾造成 descriptor completion 永遠無法到達 fetch engine；此問題已仿真及實機修正。

## 6. 4 KiB boundary

PCIe request 不得跨越 4 KiB boundary。SG engine 會依目前 address 計算 boundary 剩餘 bytes 並縮短 request；測試包含 `64B + 128B + 64B` split。

## 7. 實測效益

舊 16-byte MWr：237.71 MiB/s、15.578M requests/s。

新 128-byte MWr：713.47 MiB/s、5.845M requests/s。

提升來自較低 header/ack/arbiter overhead，而非更換 PCIe link；Gen2 x4 原本就足以承載單路 4K60 NV12 payload。
