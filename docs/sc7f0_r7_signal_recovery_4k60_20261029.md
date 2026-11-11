# SC7F0 R7 (0x26102901) 實機訊號鎖定復原 + 4K60 NV12 PS 擷取記錄

- 執行時間：2026-10-29 02:46–02:53 UTC（host 本地 10:46–10:53 +0800）
- Host：`rd@sc7f0-test.local`（`sc7f0-test`, kernel `7.0.0-38-generic`）
- 板端 PS：`qpcie-zu4ev`, kernel `6.1.30-xilinx-v2023.2`
- 證據目錄：`build/r7-signal-recovery-20261029/`
- 結論：**MCU runtime restart 成功復原 IT6663 → FPGA 握手，4K60 NV12 PS 擷取通過，不需要 cold reboot**

## 1. 前置硬體狀態（復原前）

| 項目 | 讀值 | 證據 |
|---|---|---|
| Host boot-ID | `c7915db6-0a6d-4917-93bc-7e8045d54270`（與 R7 部署時相同 → host 未重啟） | `00-baseline-host.txt` |
| PCI | `0000:03:00.0 12ab:e380`，8.0 GT/s x4 | 同上 |
| Hardware Version | `0x26102901 (Date 2026-10-29 Rev 01)`，Git `0x2BCE1D81`，Caps `0x1001011F`，Upgrade Status `0x00 IDLE/Ready` | `01-hw-status.txt` |
| PS boot-ID | `4cd341d2-1571-4843-80e8-44edb9439861`（R7 部署後那次 PS warm reboot，之後未再重啟） | `00-baseline-host.txt` |
| IT6663 RXP0 | bank0 穩定、`cable_5v/clock_stable/symbol_lock/scdt_lock/hdmi_mode/scrambled = 1`，geometry 3840×2160（4400×2250, +hsync +vsync）→ **來源已鎖定在 IT6663** | `02-it6663-before.json` |
| IT6663 兩次 timing 讀取 | 僅 0x99 相差 1 LSB（自由計數抖動），腳本 fail-closed 回 `timing counters changed`，非失鎖 | 同上 |
| 官方 RX (`hdmi_status`) | `Status: No Locked Timing` | `00-baseline-host.txt` |
| PS `v4l2-ctl --query-dv-timings` | `VIDIOC_QUERY_DV_TIMINGS: failed: Link has been severed`，全 0 | `03-ps-dvtimings-before.txt` |
| Probe `0x684 RX_CLK` | 593.948 MHz（IT6663 已轉發 594 MHz TMDS） | `05-probe-before.txt` |
| Probe `0x68C RXOUTCLK` / `0x690 RX_VIDEO_CLK` | **0 Hz / 0 Hz**（VPHY 未產 RXOUTCLK） | 同上 |
| Probe RX SS Video | `valid=0`，`RX_VIDEO_SOF/EOL/PIXELS = 0` | 同上 |
| 中斷 | `xilinx-vphy` 2、`xilinx-hdmi-rx` 2（僅開機初始化） | `04-ps-irq-before.txt` |

即 R7 部署後既有症狀：來源在 IT6663 端鎖定，但下游 VPHY/RX SS 未重新握手（AGENTS.md 記載的 warm-reboot 後 TX/SCDC 未自動復原問題）。

## 2. MCU runtime restart 執行結果與耗時

```
sudo sc7f0ctl --timeout 5 exec 'i2ctransfer -y 0 w2@0x32 0x06 0x01'
```

| 項目 | 結果 |
|---|---|
| 交易內容 | 僅 runtime restart（I2C 寫 MCU 0x32 暫存器 0x06=0x01），**未燒錄 APROM/BOOT、未改 IT 組態** |
| 第一次執行 | `2026-10-29T02:47:14Z` 起訖同一秒，SSH 端 `real 0m0.015s`，回傳碼 0（`08-mcu-restart.txt`） |
| 第二次執行（退出碼驗證） | 同一指令重發（冪等 restart），`restart_rc=0`；同批以 `exec 'false'` 驗證 exec 會回傳遠端退出碼（`exec_false_rc=1`）→ restart 的 0 代表 i2ctransfer 在 PS 端成功 |
| 等待策略 | 未採固定 sleep；每 3 s 輪詢 host `hdmi_status`（`09-hdmi-status-poll.txt`） |
| 鎖定時刻 | `02:47:34Z` → `Status: Signal Locked`（restart 後 ≤20 s；02:47:25/28/31 三次仍 `No Locked Timing`） |
| DDC 佐證 | Probe DDC 計數由 `SCL_Falls=0, SDA_Edges=1` 變成 `SCL_Falls=28, SDA_Edges=19`，`RX_IRQs` 由 2 → 2827、`PHY_IRQs` 2 → 16 → 實際重跑了 SCDC/EDID 交握 |

## 3. FPGA HDMI RX 鎖定狀態（復原後）

| 項目 | 讀值 | 證據 |
|---|---|---|
| Host `hdmi_status` | `Signal Locked` / `3840x2160p` / `Pixel clock: 594000000 Hz` / `fmt=0x00800200 mbus=0x100e`（RGB888_1X24） | `09`、`24` |
| PS `v4l2-ctl -d /dev/v4l-subdev2 --query-dv-timings` | Active 3840×2160、Total 4400×2250、progressive、`+vsync +hsync`、**Pixelclock 594000000 Hz (60.00 fps)**、porch 176/88/296、8/10/72、`CTA-861 / CE-video` | `10-ps-dvtimings-after.txt` |
| IT6663 RXP0（重讀） | `timing_valid=true`、bank0、clock/symbol/SCDT lock、4400×2250 → 3840×2160 | `23-it6663-after.json` |
| Probe `0x684 RX_CLK` | **148,487,015 Hz（148.487 MHz）** | `11-probe-after.txt` |
| Probe `0x68C RXOUTCLK` | **148,487,014 Hz（148.487 MHz）** | 同上 |
| Probe `0x0690 RX_VIDEO_CLK` | **148,487,014 Hz（148.487 MHz）** | 同上 |
| Probe RX SS Video | `valid=1 ready=1`，`RX_VIDEO_SOF=674`、`EOL=1,453,828`、`PIXELS=1,395,674,943` | 同上 |
| 中斷（復原後） | `xilinx-vphy` / `xilinx-hdmi-rx` 計數與 probe IRQ 計數同步成長（`PHY_IRQs=16`、`RX_IRQs=2827`，擷取後 `RX_IRQs=7267`） | `11`、`22` |
| Host driver 遙測 | `[V4L2 HDMI RX] Source change detected! ... res: 0x00000000 -> 0x0f000870, tlm: 0x00000000 -> 0x0003100e`（R7 部署後原本缺的事件已出現） | `24-host-post.txt` |
| PCIe AER | correctable / fatal / nonfatal 全 0 | `24-host-post.txt` |

註：`594 MHz / 4 PPC = 148.5 MHz`，與 2026-10-21 已驗證的復原特徵（RX ref/RX video/RXOUT ≈148.487 MHz）一致。舊 probe RTL 的 `CH0/1/2_VALID_BEATS`（三個相同值）為已知背壓誤計數欄位，不作為訊號依據。

## 4. 4K60 NV12 擷取測試結果

Media graph（`/dev/media0`，link 全 `ENABLED`）：
`b0010000.hdmi-rx:0 → b0070000.frame-tap:0/1 → b0060000.vpss-csc:0/1 → video-capture output 0 (/dev/video0)`

圖形設定過程（`15`/`16`/`17`）：

1. 開機預設 vpss-csc 為 1280×720，需改為 3840×2160。
2. `media-ctl -V` 一次設兩 pad 時，結果兩 pad 都變成 `RBG888_1X24`，且 `Field: Any` → STREAMON 回 `-EPIPE`（`v4l2_subdev_link_validate_default()` 因 field/size 不相符而拒絕）。這是 **設定順序/工具限制問題，不是硬體問題**。
3. 解法：sink、source 分次設定，且 source 最後設，並用 `v4l2-ctl --set-subdev-fmt ... ,field=none`（`code=0x100e`/`0x2100`）。最終全部 pad：3840×2160、`Field: None`，csc source = `VYYUYY8_1X24`，`/dev/video0` 才出現 `NM12/NV12`。

擷取結果（PS 端 `sc7f0_ps_capture`，只走標準 V4L2 ioctl）：

| Run | 指令 | 影格數 | CAPTURE_EXIT | 摘要 |
|---|---|---|---|---|
| A（任務指定） | `sc7f0_ps_capture /dev/video0 NV12 3840 2160 8 /tmp/ps-r7-test.nv12` | `frames=8` | **0** | `CAPTURE_PASS frames=8 bytes=99532800 timestamp_fps=60.000857 dmabuf_exports=4 timestamp_source=SOE`；`PLANE index=0 stride=3840 sizeimage=12441600` |
| B | `... NV12 3840 2160 300` | `frames=300` | **0** | `timestamp_fps=60.000558`，WALL 6 s |
| C | `... NV12 3840 2160 900` | `frames=900` | **0** | `bytes=11197440000`、`timestamp_fps=60.000558`，WALL 15 s |

- 檔案：`/tmp/ps-r7-test.nv12`（PS）= **12,441,600 bytes** = 3840×2160 NV12 單frame（`3840*2160*1.5`），SHA256 `993c47f548e39796d1baed16bb23cd59531e997165cac2271074610907a78bef`。
  注意：`sc7f0_ps_capture` 依設計只把「最後一張影格」寫入 DUMP 檔（STREAMOFF 後才寫檔），因此檔案大小是 1 frame 而非 8 frames；8 是 **實際 DQBUF 完成的影格數**，app 回報的累計 `bytes=99532800` 才是 8×12,441,600。
- 影格內容為真實視訊（非補黑）：Y 平面取樣 min 0 / max 217~220、mean 110~151；UV 平面 min 0 / max ~141、mean ~131（全黑 NV12 會是 Y 固定 0/16、Cb/Cr 固定 0x80）。

### R7 256-bit AXIMM（frmbuf）核心修復驗證

| 檢查 | 結果 |
|---|---|
| `CAPTURE_EXIT` | 三次 run（8 / 300 / 900）全部 **0**（`CAPTURE_PASS`，含 STREAMOFF/REQBUFS 釋放皆成功） |
| frame-tap metadata flags（暫存器 0x4c） | **0**。驅動 `sc7f0_tap_finish()` 只在 `flags != 0` 時印 `Capture source=%u flags=0x%08x (fill=1 eol=2 stop=4 reset=8)` 並回 `-EIO`；擷取後 `TAP_FLAG_WARN_COUNT=0`，且新增 dmesg 為空 → 無 FIFO overflow / 補黑（fill）、無 eol/stop/reset 異常 |
| V4L2 buffer flags | 1200 幀全部 `flags=0x12001`（PREPARED\|TIMESTAMP_MONOTONIC\|TSTAMP_SRC_SOE），**未出現 `V4L2_BUF_FLAG_ERROR (0x4)`**；app 本身會拒絕帶 ERROR flag / sequence 不連續 / 非遞增 timestamp 的 buffer |
| sequence 連續性 | 300-frame run：hardware frame-ID `sequence` 16094→16393 **逐幀 +1、0 個缺口**；900-frame run：16410→17309 **0 個缺口**；相鄰影格間隔 16,666,000~16,667,000 ns（=60.0006 fps，無掉幀/無重複） |
| timestamp source | `SOE`（非 EOF 標示），fps 由 SOE 時間戳算得 60.0006 |
| 擷取後訊號 | `hdmi_status` 仍 `Signal Locked`，Probe `RXOUTCLK=148.487 MHz`、`RX_VIDEO_SOF` 15912 → 17952 持續前進 |
| 板端健康 | 4 服務 active、`sc7f0_ps_watchdog --check-health` = healthy、`PL_BASE_VERSION=0x26102901` |
| 身分 | host boot-ID 前後相同（未重啟 x86）、PS boot-ID 前後相同（本輪未重啟 PS） |

## 5. 是否需要 cold reboot 之專業判定

**判定：不需要 cold reboot 測試機。**

理由：

1. 既有且驗證過的 runtime restart（`w2@0x32 0x06 0x01`）在 ≤20 s 內重建 IT6663 → FPGA 的 SCDC/HPD 交握，VPHY RXOUTCLK / RX_VIDEO_CLK 由 0 Hz 恢复到 148.487 MHz，官方 RX 回報 3840×2160p60 / 594 MHz。
2. 下游 PS 擷取鏈路（frame-tap → VPSS CSC → v_frmbuf_wr 256-bit AXIMM）在 8/300/900 幀共 1208 張 4K60 NV12 影格下全數 `CAPTURE_EXIT=0`、metadata flags=0、無 overflow 補黑、無 dmesg 錯誤，PCIe AER 全零 → 不存在「殘留需靠 POR 清除」的卡死狀態。
3. 本輪唯一失敗（STREAMON `-EPIPE`）已定位為 media graph 的 subdev `field=Any` 與設定順序問題，屬軟體設定，非硬體鎖死。

後續建議（非本次範圍，需另外排程）：

- warm reboot 後 IT6663→FPGA 的 TX/SCDC 交握仍需**人工** restart 一次才恢復；真正的修復是在 PS/daemon 端做自動 re-handshake（AGENTS.md 已列為 open item）。建議把本次 `sc7f0ctl exec 'i2ctransfer -y 0 w2@0x32 0x06 0x01'` + 輪詢 `Signal Locked` 寫成正式復原腳本/服務。
- media graph 4K60 NV12 設定目前靠 shell 指令（`build/r7-signal-recovery-20261029/ps-capture-run.sh`），應固化為開機 script 或 app 內建（含 `field=none`、source pad 後設的順序），否則每次重開機都要重設。
- 影格影像目前只在 PS 端做統計取樣驗證（無黑-frame、有色度變化）；尚未把 4K 原圖取回 host 做 PNG 目視/色彩比對（debug mailbox 不適合拉 12 MB 檔）。若要正式影像驗收，需要走 host 端擷取路徑或另設檔案通道。
- TX（TXP1）時鐘暫存器仍為 0，本輪未宣稱 TX link 已驗證。

## 6. 邊界遵循

- 僅使用 runtime restart，未燒錄/更新 MCU 韌體（v1.1.15 未動）。
- 未重啟 x86 host（boot-ID 前後一致 `c7915db6-…`）。
- 未做 PS 重啟、未重載 `qpcie.ko`、未再發 COMMIT、未觸碰 hdmi-rx timing/EDID 寫入、未做非文件化 MMIO（probe 0x680–0x06DC 為文件化診斷區塊）。
- PS 上留存：`/tmp/ps-r7-test.nv12`（12 MB，證據檔）、`/tmp/ps-capture-run.sh`、`/tmp/ps-endurance2.sh`、`/tmp/ps-graph-setup.sh`、`/tmp/ps-graph-probe.sh`；vpss-csc pad 由開機預設 1280×720 改為 3840×2160（重開機即恢復預設）。
