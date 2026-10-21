# SC7F0 HDMI RX 無訊號根因與 MCU v1.1.15 修正（2026-10-21）

## 結論（先講結果）

**根因已確認並修好：MCU 韌體從未執行 IT6663 的內部 RX HPD 斷言，來源端因此從未開始送 TMDS。**
不是線材、不是來源、不是零件錯、也不是過熱。

- 修正：MCU v1.1.15 (`0x1262010F`) 新增 vendor 等價的 `it6663_rx_hpd()`，在初始化與 5V 插拔邊緣
  寫入 IT6663 bank3 `0xAB=0xCA`、bank0 `0x26=0x00`、`0x55=0xFF`。
- 驗證：燒錄後第一次 MCU 重啟、以及不重燒的第二次 MCU 重啟，IT6663 都**自行**鎖定，
  Xilinx 官方 HDMI RX 都解出 **3840x2160@60、VIC 97、HDMI、scrambled、594 MHz**。
- 沒有任何手動暫存器寫入、沒有改 FPGA、沒有改線路。

## 證據鏈

### 1. 修正前：來源看得到 5V，但 TMDS 沒開始

修正前 IT6663（v1.1.14，冷啟動後）：

| 暫存器 | 值 | 意義 |
| --- | --- | --- |
| RXP0 `0x13` | `0x01` | 只有 5V；clock stable / symbol lock 未成立 |
| RXP0 `0x14` | `0x01` | 無 SCDT lock |
| RXP0 `0x19` | `0x20` | 無有效 timing |
| bank3 `0xAB` | `0x0A` | vendor HPD deassert 狀態（非 `0xCA`） |
| bank0 `0x26` | `0xFF` | vendor HPD deassert 狀態 |
| bank0 `0x55` | `0x00` | vendor HPD deassert 狀態 |

同時：`cable_5v=1`、`hpd_asserted=1`（MCU 只把 PA.11 拉高）、
Xilinx `hdmi_info` 為 `No input stream detected`、`Rx Ref Clk: 0 Hz`。

### 2. 官方 vendor code 的要求

`/home/zzlee/llm-wiki/raw/SC6F0_HDMI_6663/6663/IT6664_hdmi2_rx.c:SetRxHpd()`

```c
if (sts) {
    if (h2rxrd(0x13) & 0x01) {           // 必須有 5V
        chgrxbank(3);
        if (h2rxrd(0xAB) != 0xCA) h2rxwr(0xAB, 0xCA);
        chgrxbank(0);
        h2rxwr(0x26, 0x00);
        h2rxwr(0x55, 0xFF);
    }
} else {
    chgrxbank(3);
    if (h2rxrd(0xAB) == 0xCA) {
        h2rxwr(0xAB, 0x4A);
        h2rxwr(0xAB, 0x00);
        h2rxwr(0xAC, 0x00);
    }
    chgrxbank(0);
    h2rxwr(0x26, 0xFF);
    h2rxwr(0x55, 0x00);
}
```

原韌體只做了 `0x26=0xFF`（deassert），從未寫 `0xAB`、從未寫 `0x55=0xFF`，
所以 IT6663 對來源呈現的 HPD 一直是低。`board_hdmi_hpd(true)` 只驅動板級
MCU0_HPD / H0_P1TXHPD GPIO，並不等於 IT6663 內部 HPD 狀態機。

### 3. 單變數暫存器實驗（先於韌體修改，可逆）

在 PA.11 維持高、來源與線材不動的前提下，只依 vendor 序列寫入
`AB=CA`、`26=00`、`55=FF`：

- 1 秒內 IT6663 鎖定：`0x13=0xBF`、`0x14=0xFF`、`0x19=0xB0`。
- HDMI mode、scrambled、3840x2160 raw counters 成立。
- 證明因果：差異只在 IT6663 內部 HPD 三個暫存器。

當時 Xilinx 官方 RX 仍顯示 idle（CPLL 已配置、ref clk 57 MHz）。該次只補了 HPD，
且讀取發生在寫入後數秒內，尚未等到輪詢政策完成 TXP1 設定與下游重新初始化；
本輪未進一步拆分這兩個因素。v1.1.15 完整開機後此現象消失，見下節。

### 4. 修正後：兩次 MCU 重啟都自行鎖定

燒錄 v1.1.15 後（第一次重啟），以及再對 MCU 寫 `0x32:0x06=0x01` 觸發第二次重啟
（不重燒、不手動碰 IT6663），量測結果一致：

| 項目 | 第一次重啟後（終端觀測） | 第二次重啟後（完整存檔） |
| --- | --- | --- |
| MCU | v1.1.15 `0x1262010F` | v1.1.15 `0x1262010F` |
| IT6663 `0x13/0x14/0x19` | `BF / FF / B0` | `BF / FF / B0` |
| IT6663 `AB / 26 / 55` | `CA / 00 / FF` | `CA / 00 / FF`（直接讀回） |
| IT6663 lock | clock+symbol+SCDT 全成立 | 同左 |
| Xilinx `hdmi_info` | 3840x2160@60, VIC 97, HDMI, scrambled | 同左 |
| Xilinx pixel clock | 594,000,000 Hz | 594,000,000 Hz |
| `Rx Ref Clk` | 148,482,048 Hz | 148,482,048 Hz |
| EDID | header `00 FF FF FF FF FF FF 00` | C9=`A7`、CA=`3A` 與 RAM payload 一致 |

證據檔案：`build/validation/sc7f0-hpd-fix-v1.1.15-20261021/`。
連續 60 秒取樣 12 次，12/12 維持 `BF/FF/B0` 與 3840x2160 timing。

## 修改內容

`test_mcu_nuc1262/it6663.c`

- 新增 `it6663_rx_hpd(bool)`：vendor 等價 assert/deassert，5V gating，
  失敗時仍還原 bank 0，避免把 bank3 狀態留在 bank0 讀取路徑。
- `it6663_update_edid()`：更新 EDID 時同時拉低/拉高板級與 IT6663 內部 HPD。
- `it6663_init()`：EDID 寫完後在初始化流程中斷言內部 HPD。
- `it6663_poll_status()`：偵測 5V 插拔邊緣，補做 assert/deassert（steady state 不重寫）。
- 版本：`board.h` → `0x1262010F`（v1.1.15）。

限制與回滾：

- 映像 8088 bytes，低於 8192 bytes 上限；`make test all` 通過。
- v1.1.14 備份仍在 `build/validation/sc7f0-mcu-i2c-v1.1.14-20261021/mcu-v1.1.14.bin`。
- 回滾：`python3 scripts/sc7f0_mcu_flash.py --bin <v1.1.14.bin>`。

## 硬體問題排查結論（給硬體團隊）

目前沒有硬體故障證據，建議先不要換件：

1. **零件正確性**：I2C 讀回 VenID `0x5449` ("TI")、DevID `0x6366` ("6663")、Rev `0xA0`，
   與 IT6663 家族一致。修正前後皆可正常讀寫所有 sub-address（`0x2c/0x34..0x38/0x4b/0x6c`）。
2. **過熱**：NCT7717 讀值 53–57 °C，且 schematic 標註該 sensor 位置「Close to Xilinx」，
   不是 IT6663 本體溫度；沒有過熱 shutdown 或讀值跳變證據。
3. **HPD 電路**：schematic 中 MCU0_HPD 經 SQ1（標註 `NC(PMBS3904...)`，未置件）
   才到 H0_RXHPD；因此 MCU GPIO 無法單獨產生來源可見的 HPD，實際 HPD 由 IT6663
   `RXHPDCBUS` 內部狀態機輸出。這正是原韌體只拉 GPIO 卻無效的硬體原因。
4. **供電**：`H0_RX_EN`（PF.6）與 `H0_RX_DET` 經 U23 AND 產生 IT6663 `RXPWR`，
   5V 與供電序列正常，無須改動。

時間線也支持「韌體回歸」而非硬體老化：10/20 15:58、16:13 曾有 `13=BF/14=FF/19=B0`
的鎖定紀錄（早於 17:03 的 v1.1.7），20:46 之後才持續失鎖。現有備份沒有更早的原始碼可 diff，
因此只列為一致性證據，不宣稱是哪一版移除 HPD 寫入；但本輪已直接證明缺少該寫入即無法鎖定。

若後續還要懷疑硬體，應先重現「v1.1.15 + 兩次冷啟動」仍失敗，再進行量測；
目前兩次重啟皆成功，沒有此證據。

## 實體拔插驗證（2 次）

2026-10-21 14:00 +08:00 由使用者實際拔插 HDMI source 兩次，監控每 0.4 秒取樣
MCU 狀態、每 4 秒取樣 Xilinx RX：

| 事件 | 時間 | 結果 |
| --- | --- | --- |
| 第一次拔除 | 17:41:14 | IT6663 lock 掉；Xilinx 17:41:16 `No input stream detected` |
| 第一次插回 | 17:41:21 | 7 秒後 IT6663 重新鎖定；Xilinx 17:41:24 回到 3840x2160@60、594 MHz |
| 第二次拔除 | 17:41:31 | 再次掉鎖／NO_STREAM |
| 第二次插回 | 17:41:39 | 8 秒後完整恢復 4K60 |

兩次都**沒有** MCU 重啟、沒有手動暫存器寫入。日誌：`hotplug-test-3.log`、
`hotplug-test-3-summary.txt`。

重要限制：MCU 的 5V 狀態位（PB.2 `H0_RX_DET`）在整個拔插過程都維持 1，
所以 v1.1.15 的「5V 邊緣 HPD deassert/assert」分支實際上沒有被觸發。
本次能恢復是因為內部 HPD 一直保持 asserted，來源插回後自行重新協商。
也就是說：

- 已驗證：HPD 在開機時斷言後，實體 replug 可自動恢復 4K60。
- 未驗證：5V 掉落時的主動 HPD deassert 路徑；此板 `H0_RX_DET` 看起來不是
  來源端 5V（可能由板端 EDID 電源供電），需要硬體確認。

若之後遇到某些來源在 replug 後不重送 TMDS，再考慮用「lock 遺失後延遲 toggle HPD」
補強；目前沒有這個需求，先不增加行為變更。

## 尚未驗證 / 後續

- 5V 掉落時的主動 HPD deassert 路徑（見上節；此板 5V 偵測位不會隨拔線下降）。
- Loopout TXP2、HDCP、音訊（目前 ACR N/CTS 讀值為 0）與 V4L2 實際抓幀尚未驗收。
- 建議下一步：用 `v4l2-ctl` 對 `/dev/video*` 做 STREAMON 並確認 frame 計數/內容，
  再測拔插與 1080p/4K30 切換。
