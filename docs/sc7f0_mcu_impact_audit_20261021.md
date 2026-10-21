# SC7F0 MCU 更新影響與 IT6663 直接讀取核查（2026-10-21）

> 後續（10:50 +08:00）：已依使用者確認部署 v1.1.14，修正 I2C 串行化並加入 checked proxy。
> 700 筆 checked reads／100 次 ID、真實 NACK／錯誤後恢復通過，但 IT6663 仍未 lock。
> 最新：[v1.1.14 部署驗證](sc7f0_mcu_i2c_v1.1.14_validation_20261021.md)。以下為修正前審核。

## 結論

來源／HDMI 接法維持使用者確認的既有配置，本輪不要求更換或拔插。

1. **有直接讀 IT6663**：經 PCIe mailbox → 板上 Linux I2C0 → MCU 0x33 proxy → MCU I2C1 → IT6663，與讀 MCU 0x32 快取不同。直接 ID 三次皆 `54 49 63 66 A0`，RXP0 bank 0，三次 status `01/01/20`；追加 30 組皆相同。讀值支持目前未 lock，但 proxy 沒有 downstream error 回報，不能視為完全獨立、無誤的硬體分析儀。
2. **昨天曾有 lock 證據**：原始 archive tool output 曾記錄 `13=BF, 14=FF, 19=B0`，符合 vendor lock bits 成立；不是只有 MCU 宣告 4K。但單筆 status 不證明長時間穩定或端到端成功。
3. **失鎖早於 v1.1.13**：昨天在仍為 v1.1.8 的時段亦有直接未鎖紀錄；今天 06:03–06:08 的 v1.1.12 基線也未鎖，之後才部署 v1.1.13。不能認定失鎖首次由 v1.1.13 引入。
4. **不能排除 MCU 控制政策的影響**：v1.1.13 改了 EQ／TX 觸發，不只是 UI。它保留 boot EQ、不再按殘留 geometry 切換 EQ，並要求有效 geometry 連續 25 polls 才配置 TX。這可能改變後端 TX 啟動／恢復行為，尚未做 valid-mode／插拔硬體驗收；不能把「修誤報」等同「硬體控制零影響」。
5. **找到 MCU I2C1 的未串行化缺口**：main polling 與 I2C0 proxy ISR 都直接操作同一 I2C1 controller；沒有 ownership／busy gate。這是具體程式碼風險，尚未實驗證明它就是 RX 失鎖根因。

本輪只讀取與審核，未修改 production source／映像，未燒錄、回復舊 MCU、改 EQ／SCDC、重啟或進入 FPGA Phase 2。

## 實際路徑與命令

```text
Host SSH → sc7f0ctl exec（PCIe mailbox）→ PS Linux i2ctransfer bus 0
  → MCU I2C0 slave 0x33（proxy）
  → MCU i2c1_transfer(target=0x38, tx=[0x13], rxlen=1)
  → IT6663 RXP0 0x13
```

實際讀取範例：

```bash
ssh -o BatchMode=yes -o ConnectTimeout=8 rd@sc7f0-test.local \
  'sudo -n /home/rd/sc7f0ctl exec "i2ctransfer -y 0 w3@0x33 0x71 0x01 0x13 r1@0x33"'
```

- `0x33` 是 MCU proxy，不是 IT6663 address。
- proxy payload 的 `0x71` = `(0x38 << 1) | 1`，`0x01` 是讀取長度，`0x13` 是 downstream offset。
- `i2c0_slave.c:242–266` 解碼並呼叫 I2C1；不是從 `g_i2c0.regs` 回傳。
- 對照 MCU 快取查詢：`i2ctransfer -y 0 w1@0x32 0x00 r36`。
- 以上會寫 register pointer／mailbox 讀取請求，但不改 IT6663 設定；本輪未切 bank。

## 原始歷史證據（+08:00）

來源：`/home/zzlee/agent-vault-data/data/sessions/agy/agy_zzlee-X299-UD4-Pro-dc0a_805bc03f-e692-491e-99cf-1bb0697bae41.json`。

| 時間 | 原始記錄 | 可支持的結論 |
| --- | --- | --- |
| 10/20 15:58:09 | tool output `13=BF,14=FF,19=B0`，Htotal=4400、Hactive=3840、Vtotal=2250、Vactive=2160 | 曾讀到符合 lock／geometry 的資料；原始 tool args 未保存在此 archive，不虛構完整命令 |
| 10/20 16:13:09 | tool output 再讀到 `BF/FF/B0` | 又一筆 lock bits 成立的歷史樣本 |
| 10/20 17:54:28 | 舊直接診斷工具回報三項 lock 成立 | 可作補充；舊工具的標準解析度／fps 推定不採信為量測 |
| 10/20 20:46:04 | 同一工具顯示 clock unstable `01`、SCDT unlocked `20` | 昨天也曾直接未鎖 |
| 10/20 21:21:05 | MCU status 版本仍 `v1.1.8` | 上述未鎖發生於後續 v1.1.9／10／11／12／13 更新前；不是證明 v1.1.8 穩定 |
| 10/21 06:03–06:08 | v1.1.12 接手原始 bytes 與修正後 decoder 均未鎖 | v1.1.13 部署前已有失鎖證據 |

已將關鍵歷史 messages、archive index／message ID／timestamp 及來源檔案 hash 保存為 `historical-evidence.json`。不能把 archive 中先前助理的「已穩定／根因確認」文字當成實驗結論。

## v1.1.12 → v1.1.13 原始碼比對

比對 v1.1.12 部署備份 `build/validation/sc7f0-takeover-20261021/mcu-v1.1.12-backup/it6663.c` 與目前 `test_mcu_nuc1262/it6663.c`。

- `i2c1_write/read/transfer`、`it6663_rd`、TX setup／SCDC write、EDID update 函式逐字相同。
- `it6663_init()` 從 `I2C_Open(I2C1,100000)` 到結尾的硬體初始化序列逐字相同；新增的是前置 policy／telemetry 清零。因此本次 v12→v13 沒有直接更改 boot reset、EDID 或 boot EQ 序列；**這不等於該序列已對照昨天較早的所有版本驗證正確**。
- v12 輪詢會按 `is_hdmi20` 在 EQ 0x87／0x9F 間切換，而且 `is_hdmi20` 受到無效 timing 的 4K 推定影響；v13 移除這條 RX EQ 寫入路徑。
- v12 可由非零寬高進入 TX setup；v13 要求 clock／symbol／SCDT、有效幾何與 25 次連續 valid samples。錯誤 geometry 即使有 lock 亦會阻擋 TX setup，屬於需硬體驗證的控制政策。
- v13 平常 RX 觀測改成前後 status 與兩組 19-byte timing；比 v12 的逐 byte 觀測讀取更多資料，I2C1 busy window 因此改變。這只指出可能影響競爭機率，不把機率變化寫成已量得事實。

完整 diff：`v1.1.12-to-v1.1.13-it6663.diff`；函式相同比對：`function-comparison.json`。

## 本輪直接讀取（10:26 +08:00）

- FPGA `0x26102007`、MCU v1.1.13；host uptime 約 7 分鐘，符合使用者剛完成冷啟動的時間線。
- 三組 SW ID `54 49 63 66 A0`；SW `F0=71,F1=97,08=0F,0D=00`，與既有初始化的子位址／routing 設定相符。
- RXP0 bank=0，`13=01,14=01,19=20`。Status 前後一致；各組 19-byte burst、逐 byte 及後一次 burst 完全相同。這次沒有重現「burst 解碼與 single-byte 不一致」。Timing 無效，不能報解析度。
- TXP1 `83=00,C0=21,88=54,C1=C0`；不能把 TX 狀態等同 RX lock，也不由這些值宣稱已執行完整 TX setup。v13 valid-mode gate 未驗收，維持 OPEN。
- 一組 RX `44` 偶發讀回 `FF`，另一組 TX1 `08` 偶發 `FF`；相鄰樣本分別為 `19`／`01`。由於 proxy 不回傳 downstream status，不能將單筆 FF 解釋成設定真的改變，也不能直接宣稱一定是競爭。
- 追加 30 組低負載輪讀：SW ID 30/30 正確，RX44=19、TX08=01、RX13=01、RX14=01、RX19=20 全為 30/30。未再現 FF，未看見 lock 恢復；不是無競爭保證，也不宣稱為壓力測試。

## MCU I2C 審核缺口與下一步

`main.c:53` 在 thread context 呼叫 `it6663_poll_status()`；`i2c0_slave.c:260` 在 `I2C0_IRQHandler()` 呼叫同一 `i2c1_transfer()`。目前 I2C1 master functions 未對兩個 context 做互斥，proxy ISR 可以在 main 的 I2C1 transaction 中途重新送 START／改 DAT／STOP。即使目前從 host 依序執行讀取，也不能防止與 MCU background polling 競爭。

另有以下限制：

- proxy 忽略 I2C1 return code，仍設定預期 rx length，無法把 NACK／timeout 明確傳給 host。
- `it6663_rd()` 忽略 return code；用它做 read-modify-write 的既有控制路徑可能在讀取失敗後使用 FF。
- `i2c1_transfer()` 對 START／repeated START／每個 receive state 的驗證不完整，亦未驗證 STOP 完成；單靠 Linux `i2ctransfer` exit=0 不能補足它。
- 本輪看見的 FF 及上述程式碼缺口尚未形成因果證明；RX lock 三項持續為 0 的事實與 proxy 可靠性缺口需分開處理。

建議下一個單一變更實驗：**先修 MCU I2C1 ownership／transaction 串行化與 downstream error 可見化，保持 boot EQ、TX 電氣設定及 v13 telemetry 政策不變**，通過實際 MCU 編譯／8192-byte 限制與錯誤路徑測試後，再討論燒錄與前後對比。避免長時間全域關中斷造成上游 I2C timeout，不能直接把整個 polling 包在 `__disable_irq()` 中。

之後再分別比較 boot RX 初始化／EQ、valid-mode TX gate 的影響；若需要舊版 A/B，必須有可辨識的候選映像及回復方案，且以 IT6663 raw lock bits 判定，不能用舊版假 4K 狀態作成功標準。本輪未執行任何這類部署或設定實驗。

證據目錄：`/home/zzlee/qpcie/build/validation/sc7f0-mcu-impact-20261021/`。相關 production source／binary 的 hash 本輪前後未變。
