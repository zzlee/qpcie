# SC7F0 Phase 1：實機基線重新取樣（2026-10-21）

## 結論與範圍

**Phase 1 基線採集完成；不是 HDMI 接收或採集驗收通過。**

2026-10-21 10:07:21–10:07:40 +08:00，以 SSH 查詢 `rd@sc7f0-test.local`，取得三組依序執行、非 atomic 的樣本。使用者確認來源一直未改變、維持輸入狀態；本輪不切換來源、不拔插。IT6663 本身三組皆未鎖定，不只是 Xilinx RX 未鎖；無法僅由這些讀值區分來源／線材與 IT6663 初始化／接收設定等原因，也不能以 5V／HPD 代替有效影像證據。

本輪未修改 MCU／FPGA／driver／daemon 原始碼或設定，未燒錄、未重載、未清 probe、未重啟，未執行 STREAMON 或採集。I2C register pointer、MCU proxy、sc7f0ctl mailbox 的寫入只用於發送讀取命令，不是完全沒有 bus writes。`vphy_log` 只讀一次，讀取可能消耗 driver 環形紀錄。

## 證據與重現

證據目錄：`/home/zzlee/qpcie/build/validation/sc7f0-phase1-20261021-1006/`

- `capture.py`：本輪序列採集器，遇到 timeout、非預期 exit 或 stderr 即停止；IT6663 工具 exit=2 明確表示取樣 invalid／未鎖定，不算 transport failure。
- `manifest.json`：32 個命令的 argv、採集端 UTC 起訖時間、stdout、stderr 與 exit code；各命令另有同名 `.json`／`.log`。
- `host-identity`、`fpga-before/after`、`pci-before/after`：host、版本、PCIe／AER。
- `host-telemetry-1..3`、`official-rx-1..3`、`mcu-raw-1..3`、`mcu-status-1..3`、`it6663-rx-1..3`、`it6663-tx-1..3`、`probe-raw-1..3`：三組交叉核對。
- `card-services`、`vphy-log-once`、`daemon-journal`、`host-kernel-recent`：服務及歷史紀錄。
- `source-status-before/after`、`source-sha256.json`：工作樹與相關檔案身分。

所有命令 stderr 為空；三次 IT6663 工具 exit=2，其餘命令 exit=0。複合遠端命令使用 `set -eu`。成功讀取不代表下游 I2C 一定成功：既有 MCU proxy 未提供 downstream I2C error，這個限制仍存在。

卡端日期仍為 2022-11-09，不作為實測日曆時間；採集端／host 為 2026-10-21。卡端 uptime 約 57751–57766 秒。保留 monotonic journal，避免把舊 4K 訊息當成當下鎖定。

## 身分、PCIe、服務

| 項目 | 本輪結果 |
| --- | --- |
| Host | `sc7f0-test`，kernel `7.0.0-38-generic`，uptime 約 16 小時 |
| Card Linux | `6.1.30-xilinx-v2023.2` |
| PCIe | `0000:03:00.0`，`12ab:e380`，driver `qpcie-dma`，8 GT/s x4（Gen3 x4） |
| FPGA | 前後皆 `0x26102007`，magic `0x12ABE380`，upgrade `0x00 IDLE` |
| MCU | 三次皆 `v1.1.13 (0x1262010D)`，原始 36-byte status 已保存 |
| AER | Endpoint UESta／CESta 未設位，LaneErrStat=0；COR／FATAL／NONFATAL sysfs totals 前後皆 0 |
| Upstream | `0000:00:1d.0` 未提供 `aer_dev_*`，不宣稱 upstream AER 已完整檢驗 |
| Daemon | `active/running`，MainPID=585 |
| Telemetry | ABI=`0x00010000`；seq 115650→115664→115678；heartbeat 57825→57832→57839 |

`pci-before` 與 `pci-after` stdout 完全一致。這只支持本輪短時間讀取期間未見 endpoint AER 新增，不代表 DMA 負載／長時間穩定性 PASS。

## 三組 RX 核對

| 項目 | 樣本 1 | 樣本 2 | 樣本 3 |
| --- | --- | --- | --- |
| Host 5V／HPD | YES／HIGH | YES／HIGH | YES／HIGH |
| Host timing | INVALID | INVALID | INVALID |
| MCU status | `0x3f` | `0x3f` | `0x3f` |
| MCU lock／H／V | false／0／0 | false／0／0 | false／0／0 |
| IT6663 bank | 0 | 0 | 0 |
| IT6663 RXP0 `0x13/0x14/0x19` | `01/01/20` | `01/01/20` | `01/01/20` |
| IT6663 clock stable／symbol／SCDT | false／false／false | false／false／false | false／false／false |
| 官方 HDMI | No input stream detected | 同左 | 同左 |
| 官方 VPHY RX state | idle | idle | idle |
| 官方 VPHY RX reference clock | 0 Hz | 0 Hz | 0 Hz |
| 舊 probe RX_CLK 頻率欄位 | 80,156,356 | 79,048,960 | 78,688,646 |
| 舊 probe RXOUTCLK／RX_VIDEO_CLK 欄位 | 0／0 | 0／0 | 0／0 |

IT6663 每組前後 status 相同、兩組 timing 相同；但相同不代表有效。Clock stable 依 vendor polling 的 `0x13[4]`，另一 vendor IRQ 分支使用 bit3；本輪兩位皆為 0，不影響未鎖定結論。Symbol lock 檢查 `0x14[5:3]` 全為 1，SCDT 檢查 `0x19[7]`；本輪都不成立。

原始 timing 三組一致：

```text
0x98..0xAA: 00 14 80 03 00 d1 01 58 03 00 c2 08 70 08 0a 00 00 28 01
Htotal=3 Hactive=465 Hfront=3 Hsync=88 Hback=-553
Vtotal=2242 Vactive=2160 Vfront=0 Vsync=10 Vback=72
```

未鎖定且水平 geometry 不合理，不能將殘留的 2160 行當作 4K。Pixel clock／frame rate 未量得，維持 UNKNOWN。MCU 沒有恢復假 lock／4K 上報，與 IT6663 的未鎖定狀態一致。

IT6663 TXP1 三組 raw `0x03=03, 0x83=00, 0xC0=21`，與前次部署後記錄相同；本輪不據此宣稱 TX link 或 SCDC 政策已驗證。

## Probe 與歷史紀錄限制

- Probe version=`0x26102001`，仍是已知有背壓誤計數、CDC／停鐘量測待驗證的舊 RTL。
- 三組 pin levels=`0x0F00F8AF`，5V／HPD 高；瞬時 valid bits 高不能單獨證明傳輸。
- 約 14 秒的 probe 首尾取樣間，CH0/1/2 valid-beat、SOF、EOL、valid-cycle 欄位均無數值變化；RXOUTCLK／RX_VIDEO 原始計數也無變化。這是讀值觀察，不是可靠的完整 frame 計數。
- 舊 probe 的 RX_CLK 頻率欄位非零且變動，官方 VPHY RX reference clock 為 0；兩者量測來源／更新窗口及舊 probe 行為尚未核實，不能稱為正常或穩定 TMDS clock。
- DDC、IRQ、5V／HPD edge counters 在三次讀取間未變；不以歷史累積值宣稱本輪持續發生 IRQ／DDC 活動。
- `vphy-log-once` 含 CPLL lock→lost lock、frequency event／reconfigure 序列，但沒有逐筆時間戳；不將它全部歸到本輪採樣窗口。
- Daemon 最後一筆 journal monotonic 約 14642.87 秒，遠早於本輪卡端 uptime 約 57751 秒；裡面的 3840×2160／594 MHz 訊息隨即 signal lost，不能代表目前鎖定。Host kernel recent buffer 亦包含歷史事件，不以「最近 N 筆」代替「本輪時間區間」。

## Phase gate

- **DONE**：版本、PCIe／endpoint AER、5V／HPD、三組 MCU／IT6663／官方 HDMI／VPHY／probe 原始證據與對照。
- **RECORDED**：使用者確認來源未改變、維持輸入；沒有獨立來源端輸出 timing／電氣量測，不虛報來源已驗證。
- **OPEN**：IT6663 為何未鎖；來源／線材、接收初始化／EQ／TX／DDC 等尚未區分，不宣稱任一是根因。
- **NOT RUN**：RTL 修正、FPGA 建置／部署、暫存器設定實驗、真實 capture、STREAMON/OFF。
- **下一階段**：Phase 2 修正 probe accepted-beat 計數、CDC／快照／清零與停鐘／恢復回歸；依要求逐階段執行，本輪停在 Phase 1。
