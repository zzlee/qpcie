# SC7F0 MCU v1.1.14：I2C 串行化與 checked proxy 驗證

## 最新結果（2026-10-21 10:50 +08:00）

**使用者確認後，MCU v1.1.14 已燒錄並讀回指定版本。I2C 存取可靠性修正及有限實機回歸完成；IT6663 實體 RX 仍未鎖定。**

- 實機 FPGA `0x26102007` 不變；MCU `v1.1.14 (0x1262010E)`。
- 三組 checked RX 樣本及 100 組輪讀均為 `RXP0 13=01,14=01,19=20`：5V 有，clock stable／symbol lock／SCDT 都未成立。
- MCU status=0x3f，寬高 0，與原始 status 一致，未恢復假 lock／4K。
- 700/700 筆 checked reads 的 downstream status=0，100/100 晶片 ID 正確。
- 真實 downstream 地址 NACK、32-byte 回覆、無效長度拒絕、錯誤後讀取恢復皆通過。
- PCIe 8 GT/s x4，endpoint UESta／CESta 未設位，LaneErrStat=0；這不是負載／長時間回歸。
- HDMI source／接法維持原狀，未切換 EQ／SCDC／TX 控制政策，未改 FPGA、driver 或重啟 host。
- 更新 MCU 本身會重啟 MCU，執行既有 GPIO／IT6663 reset、EDID 初始化及 HPD toggle；不是無擾動部署。

這些證據支持「修正了具體 I2C 程式碼缺口，新的錯誤回覆可用，這輪讀取未再出現非預期 FF」，**不證明舊的偶發 FF 必然由競爭造成，也不證明競爭是 HDMI 失鎖根因**。

## 本輪變更

### MCU

- 新增 `test_mcu_nuc1262/i2c1_bus.c`：所有 I2C1 transaction 使用單一 executor；main 與 proxy ISR 不再交錯操作 controller。
- 單筆 transaction 前保存 I2C0 IRQ enable state，只遮蔽 **I2C0_IRQn**，STOP 完成或有界失敗後恢復原狀。不是整段 polling／TX setup／EDID 流程全域關中斷；啟動時原本未啟用的 IRQ 不會被錯誤開啟。
- START、repeated START、SLA+W ACK、data ACK、SLA+R ACK、每個 RX ACK／最後 NACK 狀態逐步檢查；SI 與 STOP 等待都有有限迴圈。
- 錯誤清除 partial receive data 為 FF，返回明確錯誤。沒有任意硬體 reset 或自動重送配置操作。
- `it6663_set()` 在 RMW 讀取失敗時不再寫出由 FF 產生的設定；這是錯誤路徑安全修正，不變更成功交易的設定值。
- 新增 `i2c1_plan.h`：實際 executor 共用的純 transaction planner；新增 `i2c_proxy_response.h`：實際 ISR 共用的資料／狀態回覆函式。
- `i2c0_slave.c/.h`：將本筆 downstream 結果追加於資料之後，拒絕零長度／超過 32 bytes 的讀取請求，不再默默 truncate。
- `board.h` 版本增加為 0x1262010E。Makefile 加入 executor 與純 helper 測試，保留 8192-byte 限制。

### Host 工具

`scripts/sc7f0_it6663_dump.py` 預設使用 checked reply：要求多讀一個 status byte，逐筆驗證，不接受舊版 proxy 尾端的 FF。SSH／Linux I2C／downstream error 均 exit=1，不當作「沒訊號」exit=2。

Raw counters／lock／geometry 解碼未改；仍不代入標準解析度、推定 fps／VIC 或寫入 bank。JSON 加上 `proxy_protocol=data+status-v1` 與 `downstream_i2c_status_checked=true`。

舊的任意 raw proxy clients 若只讀 N bytes，仍可取得原有資料，但**不會自動得到錯誤驗證**；請使用 checked protocol 或新版工具，不把舊 client 的 exit=0 等同下游成功。

## Checked proxy protocol

MCU upstream 7-bit address=0x33。原有 request 不變：

```text
READ:  [downstream_7bit_address << 1 | 1, N, optional_register_pointer...]
WRITE: [downstream_7bit_address << 1, data...]
```

讀取請求有效 N=1..32。回覆為 `N data bytes + 1 status byte`；無效請求或 write 的 status 在第一個回覆 byte。Request 和 response 必須放在同一個 combined I2C transaction，避免分開讀 stale response；目前未提供跨交易 sequence 保護。

| Status | 意義 |
| --- | --- |
| 0 | 本筆 downstream transaction 成功 |
| 1 | SI 等待 timeout |
| 2 | 非預期 state／NACK |
| 3 | STOP 未完成 |
| 4 | 無效 proxy request |
| FF | 不支援的舊版回覆／讀取超出回覆範圍，不是成功 |

讀 RX 0x13 範例（資料與狀態一起讀）：

```bash
sudo -n /home/rd/sc7f0ctl exec \
  'i2ctransfer -y 0 w3@0x33 0x71 0x01 0x13 r2@0x33'
# 本輪實測：0x01 0x00
```

其中 data=01 是未鎖定狀態，status=00 是 downstream read 成功，兩者不可混淆。合法資料 FF 並不自動代表錯誤，須看獨立 status。

超長上游 read 在 data+status 後只返回 FF，不會 index wrap 再洩漏舊資料。協定不是 checksum／硬體 atomic snapshot，也不證明訊號品質。

## 控制政策未變的證據

相對本輪備份 v1.1.13，以下函式逐字相同：

- `it6663_init()`
- `it6663_poll_status()`
- `it6663_tx_setup()`
- `it6663_tx_scdc_write()`
- `it6663_update_edid()`
- 純 RX observation／TX policy header `it6663_rx_state.h`

比對結果：`unchanged-policy.json`。注意底層 I2C executor 及 RMW error handling 已改，所以**不宣稱所有硬體時序／失敗行為相同**。本輪未同時試 EQ、放寬 lock gate 或強制配置 TX。

## 建置、測試與映像身分

- `make -C test_mcu_nuc1262 test all` PASS。
- 純 production transaction／response helpers：write、read、combined repeated START、address-only probe、1..32-byte receive、各階段所有不符預期的 8-bit status、回覆尾端 status 與長讀 index 飽和測試 PASS；不是假 peripheral／mock firmware。
- RX observation／TX-hold policy tests PASS。
- 上述兩份 C tests 的 ASan／UBSan PASS。
- Python IT6663 工具 19 tests PASS，MCU flash safety 10 tests PASS。既有 transport unit harness 不代替本輪實機結果。
- Cortex-M23 GCC 13.2.1，`-Os -flto`；text=7832、data=0、bss=672；未放寬 staging limit。
- 檢視實際 ARM `i2c1_transfer` assembly：I2C0 bit 18 的 NVIC mask／restore、DSB／ISB，沒有全域 `cpsid`。不以 assembly 審核代替時脈拉伸實測。

```text
version  0x1262010E
size     7832 bytes
CRC32    10b22dae
SHA256   c108d31924ec0506cdd01af1c6712fd5649d52e0506f33366819e87be88e23bc
```

部署前，新工具在真實 v1.1.13 上 exit=1，明確報 `unchecked/legacy proxy reply`；沒有把缺少狀態的讀取當成可信。

## 部署與實機驗證

使用者明確選擇「部署並實機驗證」。10:48 +08:00 實際執行：

```bash
python3 -u scripts/sc7f0_mcu_flash.py \
  --bin build/validation/sc7f0-mcu-i2c-v1.1.14-20261021/mcu-v1.1.14.bin \
  --expected-version 0x1262010E
```

245 chunks，BEGIN／每筆 CHUNK／COMMIT ACK 檢查通過、傳送 script hash 檢查通過，讀回指定版本；exit=0。沒有 APROM 全內容獨立 hash readback 介面，不宣稱全 flash byte-for-byte 驗證。

10:49:57–10:50:13 +08:00 的有限回歸：

| 項目 | 實測 |
| --- | --- |
| SW identity checked read | `54 49 63 66 A0` + status 0 |
| 最大 32-byte 成功 reply | IT6663 EDID，正確 `00 FF FF FF FF FF FF 00` header + status 0 |
| Downstream NACK | 對 inventory 未出現的 0x77 只發 SLA+R，32 個 FF + status 2；沒有對未知裝置寫 register／data |
| 無效 read length=0 | status 4 |
| 錯誤後恢復 | 下一筆 ID 正確 + status 0 |
| 100 輪 × 7 欄位 | 700/700 status 0，包含每輪 19-byte timing；ID 全正確 |
| RX44／TX08 | 各 100/100 為 19／01，未再出現先前偶發 FF |
| RX13／14／19 | 各 100/100 為 01／01／20，未 lock |
| 官方 hdmi_info | 三次均 No input stream detected |
| 官方 vphy_info | RX idle、reference clock 0；CPLL／MMCM 設定為 0，僅為本輪讀值 |
| MCU／host telemetry | 三次 timing invalid，H/V=0；daemon active/running |

追加真實 0x77 單 byte NACK 回覆，直接交由 production parser 處理：正確產生 `downstream I2C status=0x02`。沒有 mock transport 或改接線。

## 尚未驗證與接續邊界

- 未以實體故障強制觸發 SI timeout／STOP stuck；這兩條有界錯誤路徑僅程式碼審核，不能列硬體 PASS。
- 未量得最長 upstream clock-stretch 時間、未做無限高負載或所有 IRQ 排程覆蓋。700 筆讀取為有限回歸，不是消除所有競爭／電氣錯誤的證明。
- `it6663_init`／TX setup 的既有呼叫端仍不是完整 transactional rollback；RMW 現在拒絕失敗讀值，但本輪未全面重設所有初始化錯誤政策。
- 來源、線材與接法不變。下一個調查應針對 **IT6663 RX 初始化／clock detection／EQ 的實際狀態與昨天曾 lock 的配置差異**，以 checked reads 記錄；設定實驗另行明確界定，不先強制 TX 或改 FPGA 掩蓋前端未鎖。
- FPGA probe 背壓／CDC 修正仍未做；真實 capture／影像正確性／STREAMON-OFF 仍 NOT RUN／BLOCKED。

## 證據與回復

目錄：`/home/zzlee/qpcie/build/validation/sc7f0-mcu-i2c-v1.1.14-20261021/`

- `before-sha256.json`、`v1.1.13-backup/`：舊 source、bin、ELF 與舊診斷工具。
- `candidate-identity.json`、`mcu-v1.1.14.bin`、`flash.json/log`。
- `unit-build.log`、`sanitizers.log`、`unchanged-policy.json`、`i2c1_transfer-arm-disassembly.txt`。
- `pre-checked-tool-rejects-legacy.json`、`post-proxy-smoke.json`、`post-proxy-repeat-100.json`、`post-repeat-summary.json`。
- `post-manifest.json` 與每筆 `.json`：命令 argv、UTC 起訖、stdout、stderr、exit code。
- `post-real-nack-parser.json`、`post-real-nack-parser-result.txt`。
- `after-sha256.json`：本輪 source／image 身分；候選檔與現有 binary 相同，舊備份 hash 亦已核對。

舊 v1.1.13 binary SHA256=`8a06a8f161d8ae607ae0db0fe222bac7285806730423a51f9d6730c3d889add1`，可用同一 flasher 指定備份 binary 及 `--expected-version 0x1262010D`；回復也會觸發 MCU／IT6663 初始化。目前**未回復，實機保持 v1.1.14**。若回復 v13，新版 checked 工具將拒收舊協定，診斷時須明確使用備份舊工具並保留其可靠性限制。
