# A50T Control Layer：BAR0 / BAR1

本文件以 commit `2450dcb7` 的實際 register decode 為準。

## 1. BAR hit 與 address normalization

7-Series core 提供 `m_axis_rx_tuser[9:2]` one-hot BAR hit：

- `tuser[2]`：BAR0 DMA/register space。
- `tuser[3]`：BAR1 user-IP space。

`cq_rx_decoder.v` 會先把 host absolute PCIe address 轉成 BAR-relative offset，再送給各 AXI-Lite slave/master。這避免 BAR1 peripheral 收到含 BAR base 的錯誤地址。

## 2. BAR0 register map

| Offset | 名稱 | 權限 | 目前用途 |
|---:|---|:---:|---|
| `0x00` | `DMA_CTRL` | R/W | bit0：SG/video DMA run；bit1：audio start（audio 目前停用） |
| `0x04` | `DMA_STATUS` | R | bit0 video busy、bit1 audio busy、bit2 video done、bit3 audio done、bit10 SG H2C busy、bit11 SG C2H busy |
| `0x08` | `H2C_RING_ADDR_L` | R/W | descriptor ring base `[31:0]` |
| `0x0C` | `H2C_RING_ADDR_H` | R/W | descriptor ring base `[63:32]` |
| `0x10` | `H2C_RING_CFG` | R/W | `[15:0] ring_size`、`[31:16] tail` |
| `0x14` | `C2H_RING_ADDR_L` | R/W | C2H ring base `[31:0]` |
| `0x18` | `C2H_RING_ADDR_H` | R/W | C2H ring base `[63:32]` |
| `0x1C` | `C2H_RING_CFG` | R/W | `[15:0] ring_size`、`[31:16] tail` |
| `0x20` | `IRQ_CTRL` | R/W | bit0：legacy H2C / SG-H2C 或 video-frame-done enable；bit1：legacy C2H / SG-C2H 或 audio-done enable |
| `0x24` | `IRQ_STATUS` | W1C/R | bit0：SG H2C 或 video completion；bit1：SG C2H 或 audio completion |
| `0x28` | `COMPLETED_H2C` | R | retained H2C completion count |
| `0x2C` | `COMPLETED_C2H` | R | retained C2H completion count |
| `0x30` | `VERSION_ID` | R | `0x02010001` |
| `0x34` | `GIT_COMMIT_HASH` | R | build 時注入；最新 `0x2450DCB7` |
| `0x38` | `BUILD_TIMESTAMP` | R | build date |
| `0x3C` | `HARDWARE_CAPS` | R | `0x0004040F` |
| `0x40` | `H2C_RING_PTR` | R | `[15:0] head`、`[31:16] tail` |
| `0x44` | `C2H_RING_PTR` | R | `[15:0] head`、`[31:16] tail` |
| `0x50/54` | `GLOBAL_TIMESTAMP` | R | 64-bit 125 MHz global timer |
| `0x58/5C` | `LAST_VIDEO_PTS` | R | 64-bit video SOF timestamp |
| `0x60/64` | `LAST_AUDIO_PTS` | R | 64-bit audio timestamp |
| `0x68` | `DEBUG_LAST_WDATA` | R | 最近 BAR0 write data |
| `0x6C` | `DEBUG_LAST_WADDR` | R | 最近 BAR0 write offset |
| `0x70` | `LATENCY_MAX_NS` | R | telemetry peak request latency |
| `0x74` | `PACER_CTRL` | R/W | bit0：1=60 FPS pacer，0=uncapped benchmark |
| `0x78` | `SLICE_HEIGHT` | R/W | 0=full-frame IRQ；slice mode 目前未驗證 |
| `0x7C` | `VIDEO_ERRORS` | R | NV12 AXI-video framing/configuration error counter |
| `0x80` | `VIDEO_CTRL` | R/W | bit0：reset TPG 與 video CDC FIFO |

> 歷史文件曾把 `0x68/0x6C/0x7C` 標成 frame-drop/bandwidth；上述表格才是目前 RTL 實際 decode。

## 3. BAR1 map

| Range | IP | 說明 |
|---:|---|---|
| `0x0000–0x0FFF` | Xilinx Video TPG | 透過 AXI Clock Converter 進入 150 MHz domain |
| `0x1000–0x1FFF` | Audio Pattern Generator | RTL 存在，ALSA bring-up 停用 |
| `0x2000–0x2FFF` | EDID/HPD register/RAM | 實驗性 peripheral |

TPG 重要 offsets：

| Offset | 欄位 |
|---:|---|
| `0x00` | AP control；`0x81` = START + AUTO_RESTART |
| `0x10` | active rows / height |
| `0x18` | active columns / width |
| `0x20` | pattern ID |
| `0x40` | color format；目前必須為 1 (YUV444) |

## 4. Mode switch reset

Driver 在 `S_FMT` 或 test-pattern 變更前寫 `VIDEO_CTRL.bit0=1`，維持至少 1 ms，再清為 0。此 request 從 125 MHz 經兩級 ASYNC_REG synchronizer 進入 150 MHz，並共同 reset TPG 與 XPM AXIS FIFO。解除 reset 後 driver 重新設定 TPG並驗證 width、height、pattern、format 與 AUTO_RESTART。

## 5. Retained register 注意事項

FPGA 不會因 Linux module reload 自動 reset head/completion counters。driver 必須從 `0x40/0x44` 讀出 retained head，以它作為新 descriptor/tail 起點；不可假設 head 為 0。
