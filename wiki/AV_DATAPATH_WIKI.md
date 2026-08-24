# A50T AV Datapath：TPG YUV444 → NV12M → Host DDR

> 本文描述 commit `2450dcb7` 的目前 A50T 視訊路徑。ALSA 與額外 video channels 在 bring-up 階段停用；歷史 multi-channel/audio 架構不是目前實體交付範圍。

## 1. Clock 與資料流

```text
PCIe user clock 125 MHz
 ├─ BAR0 DMA/register logic
 ├─ BAR1 AXI crossbar
 ├─ NV12 converter / C2H packetizer
 └─ PCIe requester

125 MHz ──MMCM──> 150 MHz video clock
                     ├─ AXI-Lite clock converter downstream
                     └─ Xilinx v_tpg_0, 4 PPC, YUV444
```

完整視訊流：

```text
Host V4L2 controls
  │
  ├─ BAR1 @125 MHz → AXI Clock Converter → TPG AXI-Lite @150 MHz
  │
  ▼
Xilinx TPG YUV444, 4 PPC @150 MHz
  │ 96-bit: 4 × 24-bit pixels
  ▼
Top-level pad/pack → 128-bit: 4 × {Y,Cb,Cr,pad}
  │
  ▼
2048-entry xpm_fifo_axis, independent clocks
  │ 150 MHz write / 125 MHz read
  ▼
nv12_capture_engine
  ├─ Y extraction
  ├─ 2-line chroma processing
  ├─ rounded 2×2 Cb/Cr box filter
  ├─ Y/UV decoupling FIFOs
  └─ stride-aware address generators
  │
  ▼
128-byte MWr packetizer → rq_tx_encoder → pg054 bridge
  │
  ▼
PCIe Gen2 x4 → Host VB2 DMA-contiguous NV12M planes
```

## 2. 為何 TPG 使用 150 MHz

4K60 active pixel rate：

```text
3840 × 2160 × 60 = 497.664 Mpixel/s
```

4 PPC @125 MHz 的理論值僅 500 Mpixel/s，幾乎沒有 backpressure/blanking/控制餘裕。實機只達 683.68 MiB/s。改成 150 MHz 後 source 上限為 600 Mpixel/s，實測 NV12 payload 提升至 713.47 MiB/s。

`video_clock_gen.v` 以 MMCM 產生 150 MHz。TPG control 經 Xilinx AXI Clock Converter；video payload 經 2048-entry XPM asynchronous AXI-Stream FIFO 回到 PCIe 125 MHz domain。

Reset 採同步解除；BAR0 `VIDEO_CTRL(0x80).bit0` 經兩級 synchronizer 後，同步 reset TPG 與 video CDC FIFO，供 mode switch 清除舊半幀。

## 3. TPG 格式與 pixel packing

TPG 設定：

- `SAMPLES_PER_CLOCK=4`。
- `MAX_COLS=3840`。
- `MAX_ROWS=2160`。
- `colorFormat=1`：`XVIDC_CSF_YCRCB_444`。
- `tuser[0]`：SOF。
- `tlast`：EOL。

Top-level 把四個 24-bit YUV444 pixels 補成四個 32-bit pixels。`nv12_capture_engine` 看到的每 pixel byte order 為：

```text
byte 0 = Y
byte 1 = Cb
byte 2 = Cr
byte 3 = padding
```

## 4. YUV444 → NV12M

### 4.1 Y plane

每個 input pixel 的 Y byte 直接依序寫入 Y plane。四個 input beats（16 pixels）組成一個 128-bit Y FIFO word。

### 4.2 UV plane

Even row 的水平 chroma sums 存進 `960×36` block RAM。Odd row 到達時，對同一 2×2 pixel block 計算：

```text
Cb_out = (Cb00 + Cb01 + Cb10 + Cb11 + 2) >> 2
Cr_out = (Cr00 + Cr01 + Cr10 + Cr11 + 2) >> 2
```

四捨五入後輸出 interleaved `Cb,Cr` bytes。Y 與 UV 各有一個 `128×128-bit` FIFO，讓 converter 每 clock 接收一個 4-PPC beat，同時讓 PCIe packetizer 獨立 drain。

## 5. PCIe output

每個 MWr payload 為 128 bytes：

```text
32 DW = 8 × 128-bit AXI payload beats
```

packetizer 只在 FIFO 至少有完整 8 beats 時啟動，避免 underflow。Y/UV 都 ready 時使用 round-robin；各 plane 有獨立 line、offset、address counter，支援 `stride >= width`。Requester 在整個 TLP 期間鎖定 owner，並遵守 RQ backpressure。

## 6. NV12M memory layout

### 1080p

```text
Y:  1920 × 1080 = 2,073,600 bytes
UV: 1920 ×  540 = 1,036,800 bytes
Total:             3,110,400 bytes
```

### 4K

```text
Y:  3840 × 2160 = 8,294,400 bytes
UV: 3840 × 1080 = 4,147,200 bytes
Total:            12,441,600 bytes
```

V4L2 format 為 `V4L2_PIX_FMT_NV12M`：Y、UV 是兩個獨立 DMA planes，不是單一 contiguous allocation 的 NV12。

## 7. Buffer completion 與 pacing

- Descriptor 接受後，engine 等待下一個 SOF。
- frontend 完成後仍需等待 Y/UV FIFO 與目前 MWr 全部 drain。
- 完整 frame DMA 完成後產生 IRQ，driver 設 timestamp/sequence 並呼叫 `vb2_buffer_done()`。
- paced mode 使用 125 MHz domain 的 `2,083,333 clocks/frame`。
- benchmark mode 透過 private pacer control 關閉等待，但不改解析度、格式或 TLP 大小。
- STREAMOFF 先關 pacer並等待 hardware idle、head=tail，再停止 descriptor fetch 與回收 buffers。

## 8. 已驗證結果與邊界

- 1080p60 correctness：實機通過，彩條正確。
- 150 MHz checkpoint：實機 713.47 MiB/s，data errors 0。
- 4K performance simulation：16.589 ms/frame、random RQ ready、input stalls 0。
- 最新 4K V4L2 checkpoint：尚待實機 600-frame gate。

Audio pattern generator、ALSA、channel 1–3、DMABUF/GPU P2P 與 slice DMA 仍保留於專案，但目前不應列為已驗證功能。
