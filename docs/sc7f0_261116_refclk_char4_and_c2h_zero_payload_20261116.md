# SC7F0 0x26111503 Defect 2 解除（GT refclk 恢復 char/4）與 Defect 3（fabric 不交付影框）定位（2026-11-16）

執行者：本輪唯一地端代理（未 spawn 子代理）。**未** `git commit` / `git push`；**未**啟動 Vivado；
**未** `rmmod` / `rescan` / `reboot`（host boot_id 與卡 boot_id 全程未變）；**未**重燒 MCU、
**未**對 IT6663 下任何寫入。唯一對卡端的寫入是**恰一次**既有 runtime restart 指令（§3）。

Evidence 根目錄：`build/rx-refclk-defect2-20261116T050441Z/`（`logs/01`–`logs/32`、
`acceptance-after-mcu/`、`acceptance-corrected/`、`test-host-session/`）。
測試機產物：`/home/rd/sc7f0/captures/20261116T050441Z-rx-refclk/`（GStreamer log 整組保留；
`tmp/rx-acceptance-diag/` 的 0 byte 暫存檔已於本輪結束刪除）。

## 0. 結論總表

| 項目 | 結果 | 主要證據 |
|---|---|---|
| **A 唯讀基線**（MCU restart 前 IT6663 TX-port / 時脈比例） | **完成** | `STEP-A-baseline.md`、`logs/03`,`04`,`05`,`06b`,`06d` |
| **B 一次有界 MCU runtime restart** | **執行 1 次，rc=0、0.014 s**；t+10 s 起 `hdmi_status` = `Signal Locked` | `logs/11`,`12`,`13`,`14` |
| **Defect 2：GT refclk 57.08 MHz** | **已解除** → `0xB0000210 = 148,482,048 / 148,488,192 Hz = char/4`（需 148.5 MHz，誤差 0.003 %／0.008 %） | `logs/13`、`acceptance-corrected/clocks.txt`（`STAGE rxrefclk PASS`） |
| `PLL_LOCK` / `RX_INIT_STATUS` | `0x00000007`（CPLL0..2 全鎖）/ `0x00070707` | `logs/13` |
| `v_hdmi_rx_ss` 鎖定 3840x2160@60 | **是**：`PIO_IN=0x3FF`（cable+GTLNKRDY+VID_RDY+SCDC）、VTD `0xD4=4400 0xD8=3840 0xDC=2250`、錯誤計數器 `0xB00101D4=0`、PL 自身解析出的 pixel clock `0xA000060C=594,120,832 Hz`、卡與 host 的 `QUERY_DV_TIMINGS` 皆 3840x2160 total 4400x2250 +vsync/+hsync 594 MHz/60.00 fps | `logs/13`,`14`,`21` |
| `0xB000010C RX_TDLOCK` | **仍為 0x00000000**（見 §4：此暫存器在兩份 vphy 驅動中只有 `#define`，從未被讀取） | `logs/13`,`15`,`30` |
| **C2H RGB888 實際影框** | **未達成 → 新缺陷 Defect 3（fabric 交付 0 payload）** | `logs/17`,`18`,`19`,`23`,`30` |
| GStreamer 桌面顯示 | 顯示路徑本身可用（`videotestsrc → NV12/BGRA → waylandsink` 無錯誤、到 PLAYING/EOS）；`/dev/video0` 管線也到 **PLAYING 且無報錯**，但因 0 buffer 而無畫面 | `logs/26`,`27`,`29`、`test-host-session/.../video0-wayland.log` |
| 是否需要同步改 RTL / 重跑 Vivado | **需要（但本輪未啟動）**：Defect 3 在 fabric 擷取路徑，見 §6 | §5 量測 |

## 1. 運行身分（A/B/C 全程同一開機）

| | 值 |
|---|---|
| eMMC `image.ub` / `BOOT.BIN` | `e1e39ea2…58df02a2` / `90101818…21375c19`（= 已上線的 m26111503-r4-rxdtfix） |
| 卡 boot_id / uptime | `6fe3bb53-7409-4e3f-8eda-faae214078e4`（830 s → 1652 s，**未重啟**） |
| host boot_id | `fe876eaf-ce74-4a0e-a347-b28d3f41b669`（前後相同） |
| PL | `v38.17.21-variant3 Git C78C495E Date 20261115 Caps 0x1001011F`，`PL_BASE_VERSION=0x26111503` |
| live DT | phy `transceiver-width=2`、phy/rx/tx `input-pixels-per-clock=2`（缺陷一修復仍然成立） |
| 安全前提 | `qpcie refcnt=0`、`/dev/video0,1` 無人持有、無 capture/gst 程序、`ch0_status running=0`（`logs/10`） |

## 2. A：MCU restart 前的唯讀基線

時脈（`logs/03`）：

| 來源 | 值 |
|---|---|
| PL probe `0xA0000684`（IT TX → FPGA 的時脈路徑） | 593,948,397 Hz |
| PL probe `0xA0000688` DRU / VPHY `0xB000021C` | 156,234,867 / 156,237,824 Hz（差 0.0019 % ⇒ 偵測器刻度可信） |
| **VPHY `0xB0000210`（GT refclk）** | **57,081,856 Hz**，比例 **10.405**（需 4.000） |
| GT / RXSS | `PLL_LOCK=0`、`RX_INIT=0x00040404`、`TDLOCK=0`、`PIO_IN=0x1`（僅 cable）、VTD 全 0、host `No Locked Timing`、卡 `xilinx-hdmi-rx` IRQ 計數 2 |

IT6663 上游（`logs/04`）：bank0、`0x13=0xBF 0x14=0xFF 0x19=0xB0`，前後兩次一致、兩次時序一致，
cable/clock/symbol/SCDT 全鎖、`HDMI=1 scrambled=1`、幾何 3840×4400 × 2160×2250 ⇒ **來源是稳定的 HDMI 2.0 4K60**。

**本輪關鍵新觀測**——IT6663 TX-port 逐 port 唯讀（`logs/05`,`06b`,`06d`，每筆 transaction 都驗證 downstream status byte）：

| Port | `0x83`（bit3 HDMI2ONPLL：1 = 1/40） | `0xC0`（bit1 H2ClkRatio） | `0x03`（bit0 = sink/HPD） |
|---|---|---|---|
| **TXP1 → FPGA** | **`0x08` = bit3 已設** | **`0x23` = bit1 已設** | `0x9F` bit0=1 |
| TXP2 → loopout | `0x00`（1/10） | `0x21` bit1=0 | `0x80` bit0=0（無 sink，MCU 依政策不組態） |
| TXP0（未使用） | `0x00` | `0x20` | — |
| TXCOM `0x4B` | `0x00..0x02 = 54 49 64`（僅基準，不宣稱語意） | | |

⇒ 「TXP1 根本沒被要求 1/40」**不成立**：暫存器層面已要求 1/40，但**實際輸出不是**。
`test_mcu_nuc1262/it6663_tx_recover.h` 在 `current_ratio40 == wanted_ratio40` 時回 `IT_TX_KEEP`，
而 `s_tx1_is_hdmi20` 是 RAM 快取——一旦快取認定「已依 hdmi20 組態完成」，正常 polling 永不再跑
`it6663_tx_setup()` 的 power/VCLK-reset 序列。**所以這是運行期狀態漂移＋快取自證的組合，
只有重跑初始化（或來源真實斷連）會恢復；不是 RTL／IP／DTSI／驅動可控，也不是來源問題。**
前一個視窗在同一板/來源/bit 量過 `0x210 = 148,467,456`，證明此板此來源**能**輸出 char/4。

## 3. B：恰一次 MCU runtime restart 與其效果

```
sudo /home/rd/sc7f0/bin/sc7f0ctl --timeout 5 exec 'i2ctransfer -y 0 w2@0x32 0x06 0x01'
rc=0  real 0m0.014s          # logs/11（2026-11-16T05:07:11Z）
```
（MCU 0x32 暫存器 0x06=0x01 = runtime restart；非重燒、非 IT 組態寫入、不動 PL/eMMC。）

輪詢（每 5 s 一輪，`logs/12`）：**t+10 s 起 host `hdmi_status` = `Status: Signal Locked`** 並持續穩定。

| 暫存器 | restart 前 | restart 後 |
|---|---|---|
| `0xB0000210 CLKDET_FREQ_RX` | 57,081,856 Hz（比例 10.405） | **148,482,048 / 148,488,192 Hz = char/4（比例 1.000）** |
| `0xA0000684`（IT TX 時脈路徑） | 593,948,397 Hz（= 1/10 位準） | 148,487,098 Hz（= char/4） |
| `0xA000068C/690` RXOUTCLK / rx_video_clk | 0 / 0 | **296,974,195 / 296,974,194 Hz**（2 PPC × 297 MHz ⇒ 594 MPix/s ✓） |
| `0xB0000018 PLL_LOCK` | 0x0 | **0x7** |
| `0xB0000028 RX_INIT_STATUS` | 0x00040404 | **0x00070707** |
| `0xB000010C RX_TDLOCK` | 0x0 | 0x0（見 §4） |
| `0xB0010064 PIO_IN` | 0x1 | **0x3FF** |
| `0xB00100D4/D8/DC` VTD | 0/0/0 | 4400 / 3840 / 2250，`0x1D4` 錯誤計數 0 |
| 卡 `xilinx-hdmi-rx` IRQ | 2 | 25,260（結束時 162,744）＝活的中斷流 |
| host `hdmi_status` | No Locked Timing | **Signal Locked / 3840x2160p / 594 MHz / mbus=0x100e** |

不是整卡 reset 的獨立證據：卡 boot_id 不變、host boot_id 不變、`daemon card_epoch` 正常、AER 全 0。
⇒ **Defect 2 以一次有界 runtime restart 解除**（與 26111204 §12.1「重啟恢復 R6 FPGA RX」同型，本次是多量測了 refclk 那一層）。

## 4. `RX_TDLOCK (0xB000010C)` 仍為 0 的實測定位

- 此偏移確為 `XVPHY_RX_TDLOCK_REG`（`xvphy_hw.h:114/122`），但兩份本地 vphy 原始碼
  （`build/official-drm-contract/src/`、2023.2 `drivers/vphy/src/`）對它**只有 `#define`，沒有任何讀寫程式碼**；
  驅動真正使用的是 `0x028 RX_INIT_STATUS`（mask 見 `xvphy_hw.h:325-333` RESETDONE/PMARESETDONE/POWERGOOD）。
- 字元層鎖定的正面證據全部成立：`PLL_LOCK=0x7`、`RX_INIT=0x00070707`、`0xB0000104 RX_STATUS=0x00010101`、
  RXSS `GTLNKRDY`+`VID_RDY`+`SCDC`（`PIO_IN=0x3FF`）、VTD 穩定幾何、錯誤計數器 0、
  驅動 `hdmi_status` 與兩側 `QUERY_DV_TIMINGS` 給出完整 4K60 時序、`xilinx-hdmi-rx` 中斷 16 萬次。
- 本設計為 **GTHE4**（`xvphy_hw.h:244-253`），故不宣稱該狀態位在 GTHE4 組態下一定會置起；
  驗收腳本仍**如實報 FAIL**（不偷偷放行），只在訊息裡寫明上述依據。

## 5. C：RGB888 採集受阻 —— Defect 3（fabric 交付 0 payload）

已排除「來源/時脈/GT/RXSS」這整層（§2–§4），host 側驅動也**已接受**串流：

```
qpcie-dma 0000:03:00.0: STREAMON: HDMI RX source locked, RGB-to-YUV=0
qpcie-dma 0000:03:00.0: STREAMON: HDMI source, keeping RX video path out of reset
qpcie-dma 0000:03:00.0: NV12M STREAMON (Ch0 Capture): 4 buffers, ring tail=51, mode=3840x2160 60 FPS paced (pacer=0x1)
```

但影框永不完成（`logs/17`,`18`,`19`,`23`）：

| 觀察 | 實測 |
|---|---|
| `ch0_frames` / `ch0_drops` / `frame_drop_count` | 0 / 0 / `0 frames dropped`（從未遞增） |
| `ch0_head` vs `ch0_tail` | 串流中 `head=13, tail=51` ⇒ **描述子有被取走（正好一個 buffer 的 13 個），之後停住** |
| host `perf_stats` | `Payload Transmitted : 0 bytes`、`Total TLPs Sent: 13`、`TX Active 13 cycles`、`PCIe Backpressure Stall 0` |
| host `packet_stats` | `submit_cnt/done_cnt/err_cnt/msi_cnt/bytes_transferred` 全 0，`fsm_state=0x20` |
| PL 端 ch0 暫存器（卡側 devmem，`logs/21`） | CTRL `0x00200110`、STATUS `0x00000201`、W/H/stride `3840/2160/11520`（RGB3 幾何**正確**）、RING0_HEAD 0、FRAMES 0、DROPS 0 |
| 格式/解析度變體 | `RGB3 3840x2160`、`RGB3 1920x1080`、`NM12 3840x2160` **三者結果相同**（0 byte、timeout、drain timeout） |
| AER / DMA 錯誤 | correctable / fatal / nonfatal 全 0，`video_errors=0`、無 overflow |
| PL 自身遥測 | `0xA0000600=0x3`（locked）、`0x604/608=3840/2160`、`0x60C=594,120,832 Hz`、TLM `0x66C` 以 2 Hz 遞增 ⇒ PS/PL 遥測與時序全活 |

⇒ **瓶頸在 0x26111503（RGB-compositor 2PPC personality）的 fabric 擷取路徑**：
`rx_ss_video_* → sc7f0_rgb24_axis_pack → sc7f0_rgb24_capture_engine → thin C2H` 沒有把像素交付出去
（RX 已鎖、描述子已領、payload 0 bytes、且非幾体相關：1080p 同樣為 0）。
上一個有影框的實測（26111204 §12.3：18,489 影框、59.97–60.01 fps）是**另一個 bitstream**（Git `09C2C4F5`）；
本 personality 的 host 影框交付從未被證明過（r4 文件 §6.1 本就列為未驗證）。

除錯盲點（下一輪值得一併修）：`rtl/custom_pcie_dma_top.v:2666` 的 RGB 引擎 `.frames_completed()` **未接線**，
故 `ch0_frames` 只反映 thin 引擎的 `thin_frame_count`（`custom_pcie_dma_top.v:1359`）；
`drop_count`/`error_sticky`/`src_overflow_sticky`/`src_line_align_sticky`
（`custom_pcie_dma_top.v:2665,2671-2673`）也**沒有任何暫存器露出** ⇒ 目前無法用暫存器區分
「packer 沒收到 SOF」與「引擎主動丟棄整幅影框」。

## 6. 下一步（需授權後才啟動）

1. **Defect 3（第一優先）**：把 `rgb24_avail`、`rgb24_ovf_sticky`、`rgb24_line_align_sticky`、
   RGB 引擎 `drop_count`/`error_sticky` 接到可讀 CSR（並補 `frames_completed`），或直接在
   `rx_ss_video_tvalid/tuser` ↔ packer ↔ engine 這條路上放 ILA，區分「SOF 未出現」/「整幅棄框」/「engine 未 arm」。
   這是 RTL + Vivado 工作，本輪**未**啟動 Vivado、**未**改 RTL。
2. 若要繼續縮小範圍：卡端 PS 側那條同樣由 `rx_ss_video_*` 分支的擷取路徑（frame-tap → VPSS CSC → frmbuf_wr）
   能否取得影框，是「RX SS 像素輸出是否有出來」最直接的判別器；但需要 26111204 §12.2 那兩條
   `media-ctl -V`（pad 尺寸 1280x720 → 3840x2160）執行期設定，本輪未做（不屬於本輪授權範圍），
   且它改的是卡端 media graph，需先取得同意。
3. `0xB000010C` 若仍被當收門檻，需要 Xilinx PG230 對 GTHE4 組態下該狀態位的定義佐證；否則建議改以
   `GTLNKRDY+VID_RDY+VTD+驅動 hdmi_status` 為字元/影框層鎖定的判準（本輪已照實記錄兩邊）。

## 7. 本輪改動的檔案（僅驗收腳門的兩道**誤判**閘與說明，未動任何 production 程式碼）

| 檔案 | 修改 | 依據 |
|---|---|---|
| `scripts/sc7f0_rx_tdlock_acceptance.sh` | stage 3 的 char/4 期望值改用 **PL 自身解析出的 pixel clock（BAR0 `0x060C` = `REG_HDMI_RX_PIXEL_CLK`）**，`0xA0000684` 改標為「IT TX → FPGA 時脈路徑」並只列報不参与判定 | 實測同一 net 在錯誤狀態讀 593.9 MHz、正確狀態讀 148.487 MHz ⇒ 它不是「接頭 TMDS」，以它為基準會把已鎖定的狀態誤判成 FAIL |
| 同上 | stage 5 `PIO_IN` 由文字 regex 改成**位元測試**（要求 bit0/1/2/8） | 全鎖實測 `0x3FF`，舊 regex 只收 `0x1xx` ⇒ 鎖定被誤判為 FAIL |
| 同上 | stage 4 tdlock 的 FAIL 訊息補上「該暫存器在兩份驅動中從未被告知讀取」與正面鎖定證據；stage 6 的失敗訊息不再斷言「因 RX_TDLOCK=0」 | §4、§5 實測 |

修正後重跑（`logs/30`）：`boot-tree PASS`、`rxrefclk PASS`、`pll PASS`、`rxss PASS`、
`tdlock FAIL`（如實）、`capture FAIL`、`display FAIL`（後兩者＝Defect 3 的真實狀態）。
同輪 `source` 段曾出現一次 `INVALID: timing counters changed between reads`
（`h_total` 計數器雨次讀值 304/320 不同；`acceptance-corrected/it6663.txt`）——這是腳本**故意**的
fail-closed 行為，立即重讀即 `Timing valid: YES`（`logs/` 末次讀取），非來源故障。

## 8. 可直接複用的桌面顯示指令（測試機實際 Wayland session）

```bash
# rd uid 1000、gnome-shell + Xwayland、socket /run/user/1000/wayland-0
export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 \
       DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
# 注意：waylandsink 的 shm 不接受 3-byte RGB，必須先轉 BGRA（直接 format=RGB 會 not-negotiated）
gst-launch-1.0 v4l2src device=/dev/video0 do-timestamp=true \
  ! 'video/x-raw,format=RGB,width=3840,height=2160,framerate=60/1' \
  ! videoconvert ! 'video/x-raw,format=BGRA' \
  ! queue max-size-buffers=4 leaky=2 ! waylandsink sync=false
```
本輪實測：此管線可 `Setting pipeline to PLAYING`、無 ERROR/WARNING（`test-host-session/.../video0-wayland.log`），
但 0 buffer 可顯示（Defect 3）。參考對照組 `videotestsrc → NV12/BGRA → waylandsink` 同樣到 PLAYING/EOS 無錯誤
（`logs/26`,`27`），證明**顯示端已備妥，只等影框**。
（截圖：測試機無 `grim`/`gnome-screenshot`，GNOME Screenshot DBus 回 `AccessDenied`，故以 log＋pipeline 狀態為準。）
