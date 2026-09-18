# Future Register Map & SG Descriptor Spec（重規劃定稿）

> **Status**: design approved, breaking change accepted. 實驗版位址全搬，舊 driver 不相容。
> 上游追蹤：`Handoff-RGB24-and-Phase2-Roadmap.md` Goal 3。現況快照見 `Control-Layer.md`（BAR0 實作）與 `DMA-Core-Layer.md` §1（64B 胖 descriptor）。
> 設計鐵律：**driver 零計算**——enumerate `sg_table` 直行填表，不做幾何、不設幀尾、不分平面。

## 1. 為何打掉重練

- BAR0 按開發階段 accretion：Day-1 骨架 → 身分證 → 音訊外掛（`0x48` 與 `0x100` 雙份 ch0 alias）→ AV sync → 08-21 debug 劫持（`0x68/0x6C`）→ NV12 期 → perfmon 附掛 → 頁表。無 region 概念、讀寫混雜。
- 64B 胖 descriptor 身兼 DMA descriptor＋video frame work order，是「沒有 per-channel register，只好全塞 descriptor」的結果；固定幾何場景下 per-frame 可變彈性備而未用。
- 無 per-video-channel BAR：4 套 NV12 engine 共用一條 H2C/C2H ring，分派靠 `custom_pcie_dma_top` 內部仲裁，無隔離保證。

## 2. Region 總表

| Range | 區 | 說明 |
|---|---|---|
| `0x0000–0x00FF` | GLOBAL | ID/VERSION/CAPS、GLOBAL_RESET、IRQ_TOP(W1C)、64-bit TIMESTAMP |
| `0x0100–0x04FF` | VIDEO CH0–CH3（stride `0x100`） | 見 §3 |
| `0x0500–0x08FF` | AUDIO DEV0–DEV3（stride `0x100`，每 device 最多 8 planes） | 見 §4 |
| `0x0900–0x09FF` | DEBUG（圍籬區，正式版可整區拿掉） | 寫入擷取、loopback、pattern gen、pacer override |

## 3. VIDEO channel block（`CHn_BASE = 0x0100 + n*0x100`）

| Offset | 名稱 | 說明 |
|---|---|---|
| `+0x00` | `CH_CTRL` | `[0]=enable [1]=dir（0:capture 1:output） [7:4]=format [8]=irq_en` |
| `+0x04` | `CH_STATUS` | `[0]=running [15:8]=fifo_level [31]=overflow（W1C）` |
| `+0x08/+0x0C` | `WIDTH/HEIGHT` | 幀幾何（STREAMON 配一次） |
| `+0x10–0x18` | `STRIDE0–3` | per-plane stride，不綁 Y/UV 名稱 |
| `+0x20–0x5C` | `RING0–RING3` | 每組 16B：`BASE_L/H`＋`CFG（[15:0]=size [31:16]=tail doorbell）`＋`HEAD` |
| `+0x60/+0x64` | `FRAMES/DROPS` | 本通道統計（RO） |
| `+0x68–0x6C` | `PTS` | 本通道時間戳（RO） |
| `+0x70` | `CH_IRQ_STATUS` | bit0 frame_done、bit1 overflow、bit2 desc_error、bit3 fifo_error，全 W1C |

Ring↔plane 由 `FORMAT` 查表（名字不綁語義）：

| FORMAT | RING0 | RING1 | RING2 | RING3 |
|---|---|---|---|---|
| RGB24 | packed | — | — | — |
| NV12M | Y | UV | — | — |
| YV12 | Y | U | V | — |
| Y/U/V/A（未來） | Y | U | V | A |

## 4. AUDIO device block（`DEVn_BASE = 0x0500 + n*0x100`）

此處 channel＝device 內聲道平面（最多 8），不同於舊 map 的 ch0–ch3 獨立 device（breaking）。

| Offset | 名稱 | 說明 |
|---|---|---|
| `+0x00` | `CTRL` | enable/方向/format/`channels` 1–8 |
| `+0x04` | `STATUS` | running/xrun（W1C，斷流黏住） |
| `+0x08/+0x0C/+0x10` | `RATE/PERIOD_BYTES/BUFFER_BYTES` | 採樣率、period 節拍、中斷迴繞模數 |
| `+0x14` | `POSITION` | RO，byte 精度 hw_ptr＝已傳輸總位元組 mod BUFFER；`pointer` 回調＝POSITION÷frame_bytes |
| `+0x20–0x9F` | `RING0–RING7` | 每組 16B：BASE_L/H＋CFG＋HEAD |
| `+0xA0/+0xA4/+0xA8` | `SAMPLE_CNT/PTR/IRQ` | W1C：period-done/xrun |

interleaved＝1 個 host buffer→只用 RING0（聲道拆分在 audio engine fabric，DMA 只當 byte pipe）；non-interleaved＝N 個 buffers→RING0–N-1（ALSA per-channel sgt 直行填入）。

## 5. Thin SG descriptor（16B，全 plane 通用）

```text
[63:0]   host_addr    sgl->dma_address 直行
[95:64]  len_bytes    sgl->length 直行
[127:96] flags        保留（IRQ policy 未來用）
```

- 無 src/dst 雙位址（方向是 channel 屬性，FPGA 端隱式）、無 SOF/EOF（framing 改 byte count：數滿 `FRAME_BYTES` 即一幀，可多幀連排）、無 plane_id（表歸屬即平面）。
- 4K 頁裝 256 條（`head*16` 位移）；建議 ring depth＝每幀 entry 數 × 在外幀數（例：4K NV12 一幀 810 entries，triple-buffer→配 2560，取 2 冪次 4096），**不繼承**現行 `RING_BUFFER_SIZE=128`。
- 三權分立：driver 填表、video engine 管形狀（含 stride padding 發射）、DMA 管搬運。

## 6. Doorbell、中斷、driver 對應

- **Doorbell**：寫 `tail` 即按鈴（`tail<<16|size` 一次 MMIO）；`HEAD==tail` 表 idle；`dma_wmb()` 在按鈴前是鐵律。
- **中斷三層**：MSI 單 vector → `IRQ_TOP` 分源 → `CH_IRQ` 分事件，全 W1C；先讀分機、再清分機、最後清 TOP；error bit 永遠 bypass、不可屏蔽；MSI-X 留待 UltraScale+ 再議。
- **Driver**：`vch` 一對一綁 channel block（刪全域 tail）；`buf_queue` 填本通道 ring＋敲本通道 doorbell；timeout 讀本通道 HEAD＋STATUS；sysfs 按 channel 拆分；CH0 capture 設置順序（幾何→descriptor→`dma_wmb()`→ring base→tail→CTRL）為驗收依據。

## 7. Acceptance

1. 單路 1080p60/4K60 回歸通過；
2. CH0＋CH1 並發 capture 互不擋（今日架構做不到的新驗收）；
3. 舊位址 map 廢棄，`axil_reg_space.v` 重寫。
