# A50T 實機測試進度與硬體驗證日誌

本文件記錄 QPCIe Artix-7 A50T 在 Jetson Orin NX 上的實體 bring-up、失敗現象、修正方式與量測數據。最新整體狀態請搭配 [A50T NV12M 實作總結](A50T-NV12M-Implementation-and-Results.md)。

## 1. 實機驗證矩陣

| 項目 | 狀態 | 實機結果 |
|---|---:|---|
| PCIe Gen2 x4 / `12AB:E380` | ✅ | Link up、枚舉正常 |
| BAR0 version/caps | ✅ | `0x02010001` / `0x0004040F` |
| BAR0/BAR1 MMIO | ✅ | 4-DW MWr/MRd 與 relative BAR decode 正確 |
| SG C2H/H2C | ✅ | 4 pages × 4096 bytes，完整 golden pattern |
| 1080p60 paced NV12M | ✅ | 60/60、59.394 FPS、sequence 0..59、彩條正確 |
| 128-byte requester | ✅ | SG 與 video benchmark 實機通過 |
| 150 MHz TPG + CDC | ✅ | 240.526 FPS / 713.47 MiB/s / data errors 0 |
| 16-tag H2C 4K loopback | ✅ | 600/600、78.77 FPS、934.60 MiB/s each direction、100% bit-exact |
| Host SGL fetch linked pages | ⏳ | 實測planes均為`nents=1` direct IOVA DMA；尚待強制SGL測試 |

## 2. 重大除錯歷程

### 2.1 pg054 byte order

修正前 BAR0 version 讀為 `0x01000102`。原因是 pg054 將 PCIe byte 0 放在 AXI `[31:24]`。最後在 `pcie_7x_axi_bridge.v` 邊界統一 byte swap，driver 不再做 `swab32()`。修正後 version 為 `0x02010001`。

### 2.2 64-bit host 的 4-DW MWr

Jetson `iowrite32()` 使用 4-DW MWr：beat 0 只有 64-bit address header，payload 位於 beat 1。Bridge 現在保存 address beat，並把 beat 1 payload 正確送到 CQ/AXI-Lite。

### 2.3 CplD Tag/Requester ID

錯誤的 pg054 RC 欄位切片曾讓 descriptor CplD 被誤當 H2C payload，DMA 永遠停在 descriptor wait。修正 Tag、Requester ID、Lower Address、Byte Count 後，64-byte descriptor fetch 通過。

### 2.4 ARM64 cache ordering

CPU 填好 descriptor 後必須在 doorbell 前執行 `dma_wmb()`；讀取 FPGA 回寫資料前使用 `dma_rmb()`。否則 ARM store buffer/cache ordering 可能讓 FPGA 讀到尚未發布的 descriptor。

### 2.5 Retained head 造成 SMMU fault

Linux module reload 不會重置 FPGA head/counters。舊 driver 把新 tail 固定設為 4，可能形成 retained `head=8`、`tail=4`，讓 FPGA 讀取無效 descriptor，Jetson 回報：

```text
arm-smmu ... Unhandled context fault
```

現在 descriptor 與 tail 都從硬體 retained head 起算，並以 retained completion counter 為 baseline。

### 2.6 BAR1 absolute address

BAR1 曾回讀：

```text
TPG0 readback: 3737181724x3737181724 ... ctrl=0xDEC0DE1C
```

`cq_rx_decoder.v` 現在依 BAR hit 將 absolute PCIe address 正規化為 BAR-relative offset；TPG/audio/EDID 分別映射到 `0x0000/0x1000/0x2000`。

### 2.7 TPG color format

TPG 必須設定 `XVIDC_CSF_YCRCB_444` (`colorFormat=1`)。driver 對 width、height、pattern、format 與 AUTO_RESTART readback 做 fatal validation；不再允許錯誤 readback 後繼續 STREAMON。

## 3. SG DMA 實機結果

完整驗證四個 4096-byte pages；C2H pattern 開頭包含：

```text
page 0: 0xC2000000 ... 0xC2000003
page 1: 0xC2010000 ... 0xC2010003
page 2: 0xC2020000 ... 0xC2020003
page 3: 0xC2030000 ... 0xC2030003
```

descriptor address、length、tag、completion count、head/tail 與全部 payload bytes 均通過，沒有 DMA timeout 或 SMMU fault。

## 4. 視訊實機結果

### 4.1 初版 1080p60 correctness

```text
Captured: 60/60
Sequence: 0..59
Measured: 59.394 FPS
Payload: 176.18 MiB/s
Frame bytes: 3,110,400
Static-frame errors: 0
STREAMOFF: drained=1, head=7, tail=7, video_errors=0
```

使用者目視確認彩條正常。

### 4.2 舊 16-byte MWr benchmark

```text
600/600
80.135 FPS
237.71 MiB/s
15.578 million 16-byte MWr/s
Data errors: 0
```

此數據促成 requester 改為 128-byte multi-beat TLP。

### 4.3 128-byte pipeline，125 MHz source

```text
230.482 FPS
683.68 MiB/s
Data errors: 0
```

仍低於 4K60 所需 711.91 MiB/s，因此新增 150 MHz TPG domain。

### 4.4 150 MHz TPG + async CDC

```text
Captured: 600/600
Measured: 592 frames in 2.461 s
240.526 FPS
713.47 MiB/s
5.845 million 128-byte MWr/s
Data errors: 0
```

已超過 4K60 payload 門檻，但只有 0.22% 餘裕，仍必須測試真正 3840×2160 buffers。

### 4.5 16-tag H2C direct-I/O-VA loopback

```text
Build ID: 0x14CEA1AD
Bitstream SHA256: d7e3b29f517837177af373cc32544889b4abc58ad7677c12693842d89704633c
600/600 frames
78.77 FPS
934.60 MiB/s each direction (1.869 GiB/s bidirectional)
RTT average: 83.707 ms
100% BIT-EXACT MATCH PASS
```

driver log顯示每個NV12 plane均為`nents=1`，故本次走direct DMA且未啟用host SGL fetch。Jetson IOMMU/SMMU仍處於strict DMA mapping；詳見[Host SGL Fetch 驗證與實施計畫](Host-SGL-Validation-Plan.md)。

## 5. 下一個驗證 checkpoint

```text
Baseline commits: `88f534b`, `14cea1a`, `330b251`
Baseline build ID: 0x14CEA1AD
Baseline bitstream SHA256:
d7e3b29f517837177af373cc32544889b4abc58ad7677c12693842d89704633c
```

下一個實機gate是`force_sgl_fetch=1`下的host SGL fetch linked-page correctness，而非重複direct-DMA benchmark。要求詳見[Host SGL Fetch 驗證與實施計畫](Host-SGL-Validation-Plan.md)。
