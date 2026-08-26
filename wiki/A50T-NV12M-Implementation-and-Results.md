# A50T NV12M 實作總結與驗證結果

> **文件基準：commit `2450dcb7`**  
> 本文件是目前 A50T 實作、驗證結果與限制的唯一摘要來源。歷史設計文件若與本文衝突，以本文及目前 RTL/driver 原始碼為準。

## 1. 目前交付狀態

| 項目 | 狀態 | 結果 |
|---|---:|---|
| PCIe Gen2 x4 枚舉、BAR0/BAR1 MMIO | ✅ 實機通過 | `12AB:E380`，版本 `0x02010001`，Caps `0x0004040F` |
| 4-page C2H/H2C SG DMA | ✅ 實機通過 | `4 × 4096 bytes` 完整 pattern 驗證，無 SMMU fault |
| 1080p60 NV12M paced capture | ✅ 實機通過 | 60/60 frames、sequence 連續、`video_errors=0`、彩條目視正確 |
| 128-byte MWr requester | ✅ 仿真與實機通過 | 4 KiB boundary 自動切割、多 beat backpressure 正確 |
| Pipeline NV12 frontend | ✅ 仿真與實機通過 | 1080p benchmark `240.526 FPS / 713.47 MiB/s` |
| 150 MHz TPG + CDC | ✅ 實機通過 | 1080p benchmark 超過 4K60 payload 門檻 |
| V4L2 1080p60/4K60 modes | ✅ 已實作 | commit `2450dcb7`，等待最新 bitstream 實機驗證 |
| 4K60 600-frame capture | ⏳ 待實機驗證 | 仿真達標；尚不可宣稱實機 4K60 已通過 |
| ALSA、Video channel 1–3 | 暫停 | bring-up 階段刻意停用 |

## 2. 目標平台與固定規格

- FPGA：AMD/Xilinx Artix-7 A50T，`xc7a50t-csg325-2`。
- PCIe：7-Series Integrated Block for PCIe (`pg054`)，Gen2 x4，128-bit AXI-Stream。
- PCI ID：Vendor `0x12AB`、Device `0xE380`。
- Host 驗證平台：ARM64 NVIDIA Jetson Orin NX。
- 視訊輸出格式：V4L2 multi-planar `NV12M` (`NM12`)。
- 已實作 modes：`1920×1080@60`、`3840×2160@60`。
- 目前只註冊一個 capture node；只啟用 `V4L2_MEMORY_MMAP` 與 `vb2_dma_contig_memops`。

## 3. 最終視訊資料路徑

```text
BAR1 AXI-Lite @125 MHz
        │
        ▼
AXI Clock Converter
        │
        ▼
Xilinx TPG YUV444, 4 PPC @150 MHz
        │ 96-bit AXI4-Stream
        ▼
4×32-bit Y/Cb/Cr/pad packing
        │ 128-bit
        ▼
2048-entry XPM asynchronous AXI-Stream FIFO
        │ 150 MHz → 125 MHz
        ▼
nv12_capture_engine @125 MHz
  ├─ Y：每 pixel 取 Y
  ├─ UV：rounded 2×2 box filter
  ├─ 960×36 chroma line BRAM
  ├─ 128×128-bit Y FIFO
  └─ 128×128-bit UV FIFO
        │
        ▼
Round-robin 128-byte C2H MWr packetizer
        │ 8 payload beats / TLP
        ▼
rq_tx_encoder → pg054 bridge → PCIe Gen2 x4
        │
        ▼
Host contiguous NV12M Y / UV planes
```

Chroma 計算公式：

```text
Cb = (Cb00 + Cb01 + Cb10 + Cb11 + 2) >> 2
Cr = (Cr00 + Cr01 + Cr10 + Cr11 + 2) >> 2
```

此為帶 rounding 的 2×2 box filter。UV plane 依 NV12 規格交錯存放 `Cb, Cr, Cb, Cr...`。

## 4. PCIe/TLP 與 DMA 重大修正

### 4.1 pg054 byte ordering

7-Series PCIe RX/TX stream 的 PCIe byte 0 位於 AXI bits `[31:24]`。修正集中在 `rtl/pcie_7x_axi_bridge.v` 邊界完成，driver 內不再使用 `swab32()` workaround。修正前版本號會讀成 `0x01000102`；修正後實機為 `0x02010001`。

### 4.2 64-bit address 4-DW MWr

ARM64 `iowrite32()` 會產生 4-DW MWr：beat 0 是完整 64-bit address header，beat 1 才是 payload。Bridge 會保存 beat 0 address，並把 beat 1 payload 正確交給 CQ decoder。

### 4.3 BAR demux 與 BAR-relative address

- `m_axis_rx_tuser[2]`：BAR0。
- `m_axis_rx_tuser[3]`：BAR1。
- `cq_rx_decoder.v` 將 PCIe absolute BAR address 正規化成 BAR-relative offset。
- BAR1 目前配置：TPG `0x0000`、Audio Pattern `0x1000`、EDID/HPD `0x2000`。

### 4.4 CplD 欄位與 descriptor fetch

依 pg054 修正 RC/CplD 的 Tag、Requester ID、Lower Address 等切片，讓 Tag 0 descriptor completion 能正確路由到 `desc_fetch_engine`。

### 4.5 Retained ring state

FPGA ring head/counters 在 Linux module reload 後仍可能保留。driver 現在以硬體 retained head 為 descriptor/tail 起點，並檢查 completion baseline，避免舊 head 搭配固定 tail 造成 DMA 寫入錯誤位址與 ARM SMMU fault。

### 4.6 128-byte multi-beat MWr

- 預設 payload：128 bytes = 32 DW = 8 個 128-bit data beats。
- requester 在 payload streaming 中無 bubble，並提供 `c2h_req_data_ready` backpressure。
- transaction owner 在整個 TLP 完成前鎖定。
- 自動在 PCIe 4 KiB boundary 切割請求。
- 結構保留未來 256-byte payload 擴充能力，但目前已驗證設定固定為 128 bytes。

## 5. NV12M plane 與 descriptor 參數

| Mode | Y plane | UV plane | Frame bytes | Stride |
|---|---:|---:|---:|---:|
| 1920×1080 | 2,073,600 | 1,036,800 | 3,110,400 | 1920 |
| 3840×2160 | 8,294,400 | 4,147,200 | 12,441,600 | 3840 |

每個 VB2 buffer 使用兩個 DMA-contiguous planes。64-byte descriptor 的關鍵欄位：

```text
plane0_dst_addr = Y plane DMA address
plane1_dst_addr = UV plane DMA address
line_width      = width
line_count      = height
src_stride      = width
dst_stride      = stride
plane12_width   = width
plane12_count   = height / 2
format          = 0x2 (NV12M)
plane_count     = 2
control         = Valid | C2H | IRQ
```

## 6. V4L2 control plane

`driver/qpcie_v4l2.c` 提供：

- `VIDIOC_ENUM_FRAMESIZES`：離散 1080p、4K。
- `VIDIOC_ENUM_FRAMEINTERVALS`：兩個 mode 都只提供 `1/60`。
- `TRY_FMT` / `S_FMT` / `G_FMT`：NV12M 2-plane。
- `V4L2_CID_TEST_PATTERN`：TPG generated patterns；pass-through 因無 TPG input stream 而停用。
- Private `V4L2_CID_QPCIE_PACER_ENABLE`：只供 throughput benchmark 使用。

切換 mode 時 driver 會：

1. 確認 VB2 queue 不 busy。
2. 寫 BAR0 `VIDEO_CTRL(0x80).bit0=1`。
3. 同步 reset TPG 與 asynchronous video FIFO。
4. 解除 reset，再寫入 TPG width/height/pattern/YUV444/AUTO_RESTART。
5. 驗證所有 readback；失敗時復原軟體 mode 並回傳錯誤。

此流程避免前一解析度的半幀殘留在 CDC FIFO。

## 7. 實機效能結果

### 7.1 初始 paced 1080p60

```text
60/60 frames
sequence 0..59
59.394 FPS
176.18 MiB/s
Static-frame errors: 0
video_errors=0
STREAMOFF drained=1, head=tail
```

使用者已確認輸出彩條色彩正確。

### 7.2 舊 16-byte MWr requester

```text
600/600 frames
80.135 FPS
237.71 MiB/s
15.578 million 16-byte MWr/s
Data errors: 0
```

此結果證明瓶頸是過小且序列化的 TLP，而不是 Gen2 x4 link。

### 7.3 128-byte pipelined engine，TPG 仍受 125 MHz 限制

```text
230.482 FPS
683.68 MiB/s
Data errors: 0
```

因 4K60 需要 497.664 Mpixel/s，而 125 MHz × 4 PPC 理論值只有 500 Mpixel/s，實體餘裕不足。

### 7.4 150 MHz TPG + CDC checkpoint

```text
600/600 frames
Measured: 592 frames in 2.461 s
240.526 FPS
713.47 MiB/s
5.845 million 128-byte MWr/s
Data errors: 0
```

4K60 NV12 payload 需求：

```text
3840 × 2160 × 1.5 × 60 = 746,496,000 bytes/s
                             = 711.91 MiB/s
```

目前等效餘裕只有約 `1.56 MiB/s`（`0.22%`），所以最新 4K mode 必須通過直接實機測試，不能只以 1080p 等效吞吐量宣稱完成。

### 7.5 NV12 引擎遷入 150 MHz video domain checkpoint（最新，已實機通過）

commit `ffff925` 把 `nv12_capture_engine` 從 125 MHz PCIe domain 搬進既有 150 MHz
video domain（TPG 同域直連），C2H request 經 `rtl/video_req_cdc.v` 跨回 125 MHz。
理論天花板從 60.28 FPS 提升至 72.3 FPS（4K）。

遷移過程中發現並修正四個缺陷（commits `21d6b79`、`3d9c228`）：

| # | 缺陷 | 修正 |
|---|---|---|
| 1 | `REQ_DWORDS=64` 同時被當成 DW 數與 128-bit 拍數；writer 等 64 拍但引擎只送 16 拍 | 以 `PAYLOAD_BEATS = REQ_DWORDS/4` 區分單位 |
| 2 | writer ack 為 registered，回到 IDLE 時引擎的 `s_req_valid` 尚未降，同一請求被重複接受、位址滯後一包 | 新增 `WR_DRAIN`：等 `!s_req_valid` 才回 IDLE |
| 3 | xpm_fifo_async FWFT 的 `dout` 落後 pop 一拍，「邊彈邊讀」在 back-to-back 必錯位 | 讀端改為整包 burst 讀入 16×128 分散式緩衝，隨機存取服務 requester（天然耐受 PCIe backpressure） |
| 4 | `eng_frame_done`（6.67 ns pulse）以 level synchronizer 跨 150→125 會漏採且 edge-detect 雙觸發；`interrupt_ctrl` 在 MSI in-flight 時丟失新 completion | completion 改 source-toggle CDC；interrupt controller 改 pending counter 依序補發 |

driver 另修正：STREAMON 讀回 `REG_PACER_CTRL` 驗證（不符即 `-EIO`）、移除
`S_PARM` 對 pacer 的隱式覆寫（uncapped benchmark 不再被悄悄改回 60 FPS）。

實機結果（bitstream SHA256 `8ada057d…`，Jetson Orin NX，Gen2 x4，MPS 256B）：

```text
1080p60 uncapped : 600/600 frames, 270.095 FPS, 801.18 MiB/s, errors 0
                   （back-to-back 第二輪 270.086 FPS / 801.16 MiB/s 完全再現）
4K60 uncapped    : 600/600 frames,  67.534 FPS, 801.30 MiB/s, errors 0
```

對 4K60 需求 711.91 MiB/s 的餘裕從 `0.22%` 提升為 **`12.6%`**。

## 8. 仿真與 timing 結果

完整 regression：`19/19 PASS`（含 `tb_video_cdc_system` 整合 TB 與
`tb_interrupt_ctrl` MSI in-flight 回歸測試）。

關鍵性能仿真：

| Mode | Clocks/frame | Time @125 MHz | Requests/frame | 結果 |
|---|---:|---:|---:|---|
| 1080p | 518,425 | 4.147 ms | 24,300 | 約 241.1 FPS / 715.2 MiB/s |
| 4K | 2,073,632 | 16.589 ms | 97,200 | 小於 2,083,333-clock 60 FPS budget |

4K test 使用約 75% random RQ ready，input stalls 為 0。

最新 implementation（commit `2450dcb7`）：

```text
WNS  +0.069 ns
TNS   0.000 ns
WHS  +0.041 ns
Critical warnings: 0
Errors: 0
LUT: 10,212 / 32,600 (31.33%)
FF:  10,439 / 65,200 (16.01%)
BRAM tiles: 27.5 / 75 (36.67%)
DSP: 38 / 120 (31.67%)
MMCM: 2 / 5 (40%)
```

Bitstream：

```text
build/qpcie_a50t_proj/qpcie_a50t_card.runs/impl_1/a50t_pcie_card_top.bit
SHA256: 52b4b02c6fa747bd9f5e1a340e395c18322b4fb5adf884654a36730eb61f7a81
Firmware hash: 0x2450DCB7
```

## 9. 實作提交歷程

| Commit | 內容 |
|---|---|
| `2f606b2` | pg054 payload byte order 修正，移除 driver byte-swap workaround |
| `e7987f5` | 單一固定 1080p60 NV12M V4L2 control-plane bring-up |
| `5c8d5c0` | retained ring head 與 BAR1 relative decode 修正 |
| `66923f1` | 初版 YUV444→NV12M engine、VB2 capture、IRQ completion |
| `8ef9ad9` | Linux 6.8 VB2 API 與 C89 相容性 |
| `5f66f12` | uncapped benchmark 與 private pacer control |
| `894abc4` | 128-byte multi-beat requester、backpressure、4 KiB split |
| `0aae5bf` | pipelined NV12 engine、Y/UV FIFOs、4K RTL support |
| `0950aa6` | 150 MHz TPG domain、AXI-Lite CDC、AXIS async FIFO |
| `2450dcb` | switch-safe 1080p60/4K60 V4L2 modes 與完整 app 驗證 |
| `ffff925` | NV12 引擎遷入 150 MHz video domain、`video_req_cdc` |
| `21d6b79` | CDC 拍數/重複接受/FWFT 潛後修正、completion toggle CDC、pacer readback |
| `3d9c228` | interrupt pending counter（MSI in-flight 不丟 completion）、S_PARM 覆寫移除 |

## 10. 最新 checkpoint 驗證步驟

請勿由自動化代理直接燒錄；由使用者執行：

```bash
cd ~/qpcie
sudo rmmod custom_pcie_av 2>/dev/null || true
./scripts/flash_a50t.sh
```

燒錄後需完整斷電重啟，再執行：

```bash
make -C driver clean && make -C driver
make -C test_app v4l2_test_app
sudo insmod driver/custom_pcie_av.ko
v4l2-ctl -d /dev/video0 --list-formats-ext
```

4K correctness：

```bash
./test_app/v4l2_test_app --dev /dev/video0 \
  --width 3840 --height 2160 --frames 60 --pattern 9 --fps 60 \
  --out /tmp/qpcie-4k-nv12.yuv
```

4K 600-frame gate：

```bash
./test_app/v4l2_test_app --dev /dev/video0 \
  --width 3840 --height 2160 --benchmark --frames 600 --pattern 9
```

必要條件：

- `Captured: 600/600`。
- sequence 連續。
- `Data errors: 0`。
- throughput `>= 711.91 MiB/s`。
- `drained=1`、`head == tail`、`video_errors=0`。
- 無 SMMU/context fault/decode error。

## 11. 目前限制與未完成項目

1. 150 MHz 引擎遷移 checkpoint 已實機通過（§7.5）：1080p uncapped 270 FPS /
   801 MiB/s、4K60 uncapped 67.5 FPS / 801.30 MiB/s、back-to-back 再現、
   data errors 0。
2. ALSA、channel 1–3、USERPTR、DMABUF import/export、slice DMA 與 GPU P2P 都不是目前已驗證交付範圍。
3. 目前 capture bring-up 只保證 DMA-contiguous MMAP buffers。
