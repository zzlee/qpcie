# SC7F0 HDMI RX 接手紀錄（2026-10-21）

> 最新（13:40 +08:00）：**根因已確認並修正，MCU v1.1.15 已部署。**
> 原韌體從未執行 IT6663 內部 RX HPD 斷言（bank3 `0xAB=0xCA`、bank0 `0x26=0x00`、`0x55=0xFF`），
> 來源端因此從未送 TMDS。修正後兩次 MCU 重啟（一次燒錄、一次不重燒）IT6663 都自行鎖定，
> Xilinx 官方 HDMI RX 解出 3840x2160@60、VIC 97、HDMI、scrambled、594 MHz。
> 沒有手動暫存器寫入、沒有改 FPGA 或線路；目前無硬體故障證據。
> 實體拔插 2 次亦驗證：掉鎖 7–8 秒後自行恢復 4K60，無須重啟 MCU。
> 詳見 [HPD 根因與 v1.1.15 修正](sc7f0_hpd_fix_v1.1.15_20261021.md)。
>
> 先前（10:50 +08:00）：使用者確認後已部署 MCU v1.1.14，讀回 0x1262010E。
> I2C1 單筆 transaction 串行化、checked proxy status、真實 NACK／錯誤後恢復通過；
> 700 筆 checked reads status=0，100 次 ID 正確。EQ／TX 政策與 FPGA 未改。
> IT6663 仍為 13=01、14=01、19=20，尚未 lock；不能宣稱實體 RX 問題已修好。
> 詳見 [v1.1.14 部署與驗證](sc7f0_mcu_i2c_v1.1.14_validation_20261021.md)。
>
> 先前（10:26 +08:00）：冷啟動後 IT6663 直接 status 三組及追加 30 組仍未鎖。
> 核實昨天確有 lock bits 成立的原始樣本，也有 v1.1.13 之前失鎖證據；
> v13 改了 EQ／TX gate，且 MCU main／proxy ISR 共用 I2C1 未串行化，影響待實驗區分。
> 詳見 [MCU 影響／讀取路徑審核](sc7f0_mcu_impact_audit_20261021.md)。本輪未燒錄或改設定。
>
> 先前（10:07 +08:00）：Phase 1 三組實機基線重新取樣完成。
> FPGA 仍為 0x26102007、MCU v1.1.13；PCIe Gen3 x4，endpoint AER totals 前後為 0。
> IT6663 本身三組 clock／symbol／SCDT 皆未鎖，官方 HDMI 仍無 stream；假 lock／4K 未再現。
> 使用者確認來源未改變、維持輸入；尚不能歸因來源或 IT6663 設定。Probe RTL 尚未修正。
> 詳見 [Phase 1 基線報告](sc7f0_phase1_baseline_20261021.md)，證據位於
> `build/validation/sc7f0-phase1-20261021-1006/`。本輪未燒錄、改設定或重啟。
> 以下保留先前接手基線、討論與部署過程。

## 來源與操作界線

- MCP `http://127.0.0.1:3000/mcp` 已可使用，透過 `vault_get_session` 找到 agy conversation `805bc03f-e692-491e-99cf-1bb0697bae41`，並讀取本機 vault JSON 的使用者要求與最後執行紀錄。
- 實際原始碼：`/home/zzlee/qpcie`；工作入口：`/home/zzlee/vibecoding/sc7f0-bringup`。
- 沿用使用者要求：不加入 mock、不把推論寫成硬體事實；先看官方 driver device attributes、暫存器與 probe；有疑慮先討論，遇到卡死需 cold reboot 時通知使用者，不自行重啟 host。
- 前次已授權修改、建置、燒錄與測試；接手基線階段只做狀態查詢與診斷，未寫入設定暫存器、未清 probe、未燒錄或重載 driver。使用者確認後的 MCU v1.1.13 部署另記於文末。I2C proxy 查詢會寫入讀取命令，但不是更改 IT6663 設定。
- 保留現有全部未提交修改；未 commit/push，也未假設工作樹等於已部署映像。
- 已知 Vivado license 設定：`XILINXD_LICENSE_FILE=2101@192.168.200.97`。本輪未檢驗授權服務。

## 任務目標

真實 HDMI → IT6663 → Xilinx Video PHY / HDMI RX → capture / CDC → PCIe DMA → Host V4L2，包含真實 timing/color 遙測，以及安全、可重複的 STREAMON/OFF。TPG 或 driver probe 成功不代表端到端完成。

## 本輪實機基線（約 06:03 +08:00）

測試機 `rd@sc7f0-test.local` 可 SSH 與非互動 sudo；host kernel `7.0.0-38-generic`。

| 項目 | 實測 |
| --- | --- |
| PCIe | `0000:03:00.0`，`12ab:e380`，Gen3 x4，qpcie-dma |
| FPGA version | `0x26102007`，不是舊文件的 HDMI06 |
| Upgrade | `0x00 IDLE` |
| AER | 此次讀取 UESta/CESta 均未見設定位，LaneErrStat=0；不代表已跑負載回歸 |
| MCU version | 由 `0x32` offset 0 讀取版本 bytes `0c 01 62 12` → `0x1262010C`（v1.1.12） |
| Cable / HPD | Host 工具顯示 5V present、HPD high |
| Telemetry | ABI `0x00010000`，daemon active，Timing Valid=NO |
| HDMI RX sysfs | Mode DVI，No input stream detected |
| VPHY sysfs | RX CPLL，RX state idle；M=1 N1=5 N2=8 D=2 |
| VPHY log | 反覆 CPLL lock → RX reset done → RX frequency event → CPLL lost lock → reconfigure |
| IT6663 RXP0 | 三次讀值皆 `0x13=0x01`、`0x14=0x01`、`0x19=0x20`；依現有 vendor 位元定義，clock stable / symbol lock / SCDT 皆未成立 |
| RX video clock probe | 三次皆 `0 Hz`；SOF/EOL/pixel 累積值在三次取樣間未增加 |
| RX reference clock | 三次 sysfs 約 76.6 MHz；另一次先期讀取為 0，不能宣稱穩定 |
| Link quality | 先期讀取 CH0/1=65535，後三次均為 0；未鎖定時不可由 0 推論線路品質優良 |

IT6663 原始 `0x98..0xAA`：

```text
00 14 80 03 00 d1 01 58 03 00 c2 08 70 08 0a 00 00 28 01
```

按目前 vendor timing 解碼，Htotal=3、Hactive=465、Vtotal=2242、Vactive=2160；水平幾何不合理，而且 RX 未鎖定，所以這些是無效／可能殘留的暫存器內容，不能回報為已偵測到 4K60。

MCU status byte 此次為 `0xff`，且保留寬高 3840x2160，與直接 RXP0 未鎖定狀態不一致。必須審查 MCU status 發布／清除與 I2C 讀取一致性，不能只採信 MCU 快取。

卡端時鐘仍是 2022 年；journal 只可當作相對歷史，不能與 host 的 2026 年時間直接比較。最後的 daemon 4K60 訊息緊接著就是 signal lost，不代表現在仍鎖定。

## 前次最後工作

- 前次 task-5424 log 確認 MCU v1.1.12 寫入完成並讀回版本，不是仍在燒錄中。
- 該版移除輪詢中的 CDR kicking，但前次最後仍在調查 RX frequency event/reconfigure 迴圈。
- 沒有真實 HDMI 持續擷取或 STREAMON/OFF 全程通過的證據。
- 舊 `SC7F0_HDMI_CAPTURE_TASK.md` §7 與 validation log 開頭已過時；不能據此重跑 HDMI06 部署。

## 先修正診斷可信度，不能直接沿用舊結論

### IT6663 讀取工具

`scripts/sc7f0_it6663_dump.py` 目前：

1. 以 Htotal / Vactive 猜標準模式並覆寫顯示 Hactive，非純原始量測。
2. 未鎖定時仍列解析度，易把殘留暫存器誤當有效訊號。
3. 只讀 18 bytes（0x98..0xA9），卻嘗試引用 0xAA；VFP/VSync 亦缺少 0xA8 高位解碼。
4. 沒有量到 pixel clock / frame rate 就由幾何宣稱 60 Hz / VIC，證據不足。
5. 缺值預設 0，且未完整處理錯誤與 timeout，需 fail-closed。

### Probe RTL

`rtl/sc7f0_hdmi_probe.v` 目前：

1. Video SOF/EOL/pixel 只看 TVALID，沒有 TREADY。停在背壓中的同一 SOF beat 可被重複計數；pixel 欄位其實是 valid-cycle 計數，不是實際 pixels。
2. Beat/video 多位元二進位計數直接在 ref-clock domain 取樣，沒有一致快照 handshake / Gray CDC。
3. `probe_ctrl[0]` 只清 pin/IRQ/DDC 計數，不清 beat/video 計數；歷史累積量不能當作當下健康狀態。
4. Frequency meter 對停鐘、恢復、reset、漏過 request 與第一筆 sample 的時間區間須補測；尚未證明其對間歇時脈仍可直接標 Hz。
5. CH0/1/2 valid beat 增加只代表數位介面活動，不能單獨證明 TMDS 信號品質、解碼成功或 frame 完整。

這些是程式碼審查發現的量測限制，**不是已證實造成 RX 掉鎖的根因**。也不能僅由 CPLL 的 N1×N2 判定 HDMI *10/*40；還需參考時脈、輸出分頻、SCDC 與官方驅動狀態共同核對。

## 接續順序

1. 先消除診斷工具的模式推定／無效資料誤報，補錯誤與解碼測試；保留 raw bytes 與有效性。
2. 審核 probe 時脈接線與 CDC，補停鐘／恢復／背壓測試；改 RTL 時依 AGENTS.md 更新 C_VERSION，完整建置、審查配對 XSA/映像後才部署。
3. 同步觀察 IT6663 RX/TX 實體狀態、官方 hdmi_info/vphy_info/vphy_log、可靠 probe 的時間增量，檢驗單一假設；每次暫存器實驗保存原值並回復。
4. 在證據足夠前，不盲目調寬 PHY threshold、遮蔽 frequency IRQ 或再改 MCU reset 策略。
5. 穩定 RX lock 後才跑真實 HDMI capture、影像正確性與重複 STREAMON/OFF；所有未跑項目維持 NOT RUN/BLOCKED。

## 證據

`/home/zzlee/qpcie/build/validation/sc7f0-takeover-20261021/`：

- `host-baseline.log`：firmware / telemetry / PCIe-AER。
- `mcu-status.log`：36-byte 原始 MCU status。
- `rx-sample-1.log` 至 `rx-sample-3.log`：官方 attrs、IT6663 原始 bytes、probe 值。
- `daemon-and-logs.log`：daemon 與 VPHY log（讀取 vendor log 可能消耗環形紀錄）。
- `source-diff-stat.log`：既有工作樹 diff 規模。

每個遠端 log 保存 host 端取樣時間、完整命令、stdout、stderr 與退出碼。複合命令的退出碼只代表最後命令；各子命令仍須核對 stderr/回傳資料，不能把整份 log 的 exit=0 等同全部檢查 PASS。

## 續作：診斷工具修正與 MCU 誤報定位（約 06:07–06:08 +08:00）

### 已修改與驗證

- 完整重寫 `scripts/sc7f0_it6663_dump.py`：保留原始 counters，不代入標準解析度，不由幾何推定 60Hz/VIC；讀取 0x98..0xAA，補齊垂直 porch/sync 高位與 polarity。
- 前後讀 status/bank，連讀兩組 timing；要求兩端均鎖定、bank 0、timing 相符且幾何合理，否則明確 INVALID。這只是保守的取樣檢查，不是硬體 atomic snapshot，也不是實體訊號品質驗證。
- 工具加入 deadline、嚴格長度/byte/缺欄位/重複欄位檢查、SSH/I2C 錯誤處理與 JSON。退出碼：0=取樣檢查通過、2=未鎖定/無效、1=傳輸或格式錯誤。現有 MCU proxy 沒有回傳 downstream I2C error，這個限制仍存在。
- 新增 `scripts/tests/test_sc7f0_it6663_dump.py`，17 個單元測試 PASS。測試 fixture 與受控 transport 替身僅供單元測試，不代替實機驗收。
- 實機新工具回報 exit=2：bank 0，clock/symbol/SCDT 均未鎖定，Htotal=3、Hactive=465、Hbackporch=-553。證據 `it6663-corrected.json`。
- Clock stable 依 vendor AutoEQ/TX polling 使用 `0x13[4]`；vendor 某 IRQ 分支另用 bit3，故保留原始 byte，未以 bit3 單獨認定鎖定。當前兩位都是 0，這個差異不影響本輪未鎖定結論。

### MCU status 矛盾的具體程式碼路徑

`test_mcu_nuc1262/it6663.c` 的 `it6663_poll_status()`：

1. 即使 clock/SCDT/symbol 都沒鎖，只要有 5V 就讀 timing。
2. 若 v_active>=2160、v_total>=2200 或 h_total>=4000，就直接將輸出改成 3840×2160 並把 `is_hdmi20` 設為 true，未驗證合法 geometry 或幀率。
3. `currently_locked` 使用 `clk_stb || scdt || sym_lock || (h_active>0 && v_active>0)`；因此殘留寬高即可使 `clock_locked=true`。
4. 這個推定的 `is_hdmi20` 亦用來切換 EQ 與 TX/SCDC 設定，不只是 UI 誤報。
5. loss 分支僅在 5V 消失滿 20 polls 才清 timing/lock；cable 保持接上而失鎖時可能保留舊值。

同一次遠端查詢的 `mcu-vs-rxp0.log`：MCU status=0xff、3840×2160；緊接著直接 RXP0 仍 0x13=01、0x14=01、0x19=20。原始值與程式碼共同支持「MCU 可錯誤回報 lock/4K」，但**尚未證明這就是實體掉鎖的根因**。

### Probe 背壓問題的可重現測試

新增 `tb/sc7f0_hdmi_probe_backpressure_tb.sv`，未修改 RTL 或 hardware version；本測試只是模擬 testbench，不改 Vivado BD/IP/RTL。

```bash
iverilog -g2012 -s sc7f0_hdmi_probe_backpressure_tb \
  -o build/validation/sc7f0-takeover-20261021/probe-backpressure.vvp \
  rtl/sc7f0_hdmi_probe.v tb/sc7f0_hdmi_probe_backpressure_tb.sv
vvp build/validation/sc7f0-takeover-20261021/probe-backpressure.vvp
```

編譯 exit=0；現行 RTL 執行 exit=1，回歸測試**尚未通過**：

```text
BACKPRESSURE_FAIL: no transfer but SOF=8 EOL=8 VALID_COUNT=8
```

刺激為 TVALID/TUSER/TLAST=1、TREADY=0 持續 8 個 video clocks，實際 accepted beats=0。這證明舊 counter 不能當作接收的 frame 數；不是一次實機擷取結果，也沒有修好 CDC/frequency meter。

### 當時提出的修改邊界（後續已獲使用者確認）

尚未修改或燒錄 MCU/FPGA。建議下一步分開處理：

1. MCU 將「原始 RX 觀測、有效 timing」與「TX 保持／重配置狀態」分離；移除標準解析度代入和由殘留 geometry 推定 HDMI2/lock。無法可靠讀取或失鎖時上報 invalid，不保留假有效資料。
2. 暫時失鎖不立即 reset/power-down TX；保留已知配置，待可靠新模式與 debounce 條件滿足才重配置。這是待討論的控制政策，尚未實作；避免在修誤報時意外重啟 reset 迴圈。
3. EQ／SCDC 控制不得再依虛構的 4K 推定；但在未鎖定時該維持哪個 EQ，以及初始化流程如何取得第一個 lock，需對照 vendor 序列與實測單獨驗證，不能混在純遙測修正中悄悄改動。
4. Probe 的 accepted-beat/CDC 修正另開配對 FPGA revision，完整建置審查後部署，不在仍使用舊 probe 的板卡上宣稱計數已修好。

當時遵循「有疑慮先討論」要求，暫停硬體改動並提問；使用者隨後選擇「分離 MCU 遙測與控制，分階段驗證」。沒有成功的真實 HDMI capture 可宣告。

## 已確認方案落地：MCU v1.1.13（約 06:18 +08:00）

### 實作範圍

- 新增 `test_mcu_nuc1262/it6663_rx_state.h`：production 與 host unit tests 共用的純觀測／控制政策函式。
- `it6663.c` 透過有回傳碼檢查的 I2C 讀取 bank/status、兩組 timing 與前後 status。I2C 失敗、非 bank 0、狀態不一致、lock 未成立或 geometry 不合理時，不發布有效寬高；不再用殘留寬高推定 lock、3840×2160 或 HDMI2。
- 實際 lock 與有效 timing 分開：clock/symbol/SCDT 均成立才能回報 lock；timing 還需兩次一致與完整 porch/sync 幾何檢查。色彩／deep-color 尺寸正規化尚未實作，寬高明確是 raw counters，不宣稱支援所有模式。
- 失鎖或讀取失敗立即清有效寬高，與保留的 TX 配置分離；保持 5V 時不因失鎖呼叫 TX reset/power-down，不再輪詢改 EQ/CDR。boot EQ 保持既有初始化值，本輪未宣稱它是正確校準值。
- 可靠 mode bits／有效 geometry 連續 25 polls 才允許進入既有 TX setup；並非每次重配，同模式已配置時不重跑。持續實體 5V 消失 20 polls 才關閉已配置 TX。
- TX electrical/setup 函式本身、loopout HPD 政策與 SCDC 寫入機制仍為舊實作，不等於已驗證其正確性；valid-mode 切換／拔插硬體測試仍待執行。
- MCU 燒錄重啟會跑既有 GPIO／IT6663 初始化及 HPD toggle，**不是跨重啟無擾動保留 TX 設定**；這裡的保留指的是輪詢期間遇到暫時失鎖不反覆重置。
- 版本更新 `board.h MCU_FW_VERSION=0x1262010D`。Makefile 補本地 header dependencies、host `test` target 與 8192-byte 映像上限檢查。
- 初次編譯 8264 bytes 超限，未嘗試燒錄；以相同邏輯的 byte equality helper 取代通用 libc memcmp，並避免清零從未完成讀取時不會被 decoder 使用的陣列，最終 8152 bytes。未放寬 staging limit 或移除觀測有效性檢查。

### 燒錄工具安全修正

`scripts/sc7f0_mcu_flash.py`：

- SSH shell quoting 改用 shlex；傳送 script 用逐行 printf，保留 `$` 與引號，不在 host 提前展開。
- 檢查 BEGIN／每個 CHUNK／COMMIT 的 MCU ACK，不再只看 Linux i2ctransfer exit code。
- 燒錄前對 card 上的完整 script 做 SHA-256 比對，並檢查每批 mailbox 大小。
- 新增 `--expected-version`，必須讀回指定版本才宣稱 upgrade successful；版本不符或結果不明不自動重送 COMMIT。
- status 要求完整 36 bytes 與 NUC1262 identity；未鎖定時 protocol 顯示 UNKNOWN，寬高為無效，另保留 raw 欄位。

### 編譯／測試

- IT6663 Python decoder／transport：17 tests PASS。
- MCU flash safety：10 tests PASS（含 ACK rejection 不進入 COMMIT、舊版本不假成功、最大 payload、shell quoting；僅 unit harness，未存取硬體）。
- `make -C test_mcu_nuc1262 test`：`MCU_RX_STATE_PASS`。
- 同一 C production helper tests 以 ASan／UBSan 編譯執行 PASS。
- `make -C test_mcu_nuc1262 all`：Cortex-M23 GCC 13.2.1、`-Os -flto` 編譯成功，text=8152、bss=672。映像 8152 bytes，小於 8192-byte staging limit。
- Probe 背壓回歸仍是已知 FAIL；本輪沒有修改 FPGA RTL、C_VERSION、XSA 或 PetaLinux。

### 映像辨識與部署

候選 `test_mcu_nuc1262/nuc1262_bringup.bin`：

```text
size   8152
CRC32  09c727b9
SHA256 8a06a8f161d8ae607ae0db0fe222bac7285806730423a51f9d6730c3d889add1
```

實際命令（exit=0）：

```bash
python3 -u scripts/sc7f0_mcu_flash.py \
  --bin test_mcu_nuc1262/nuc1262_bringup.bin \
  --expected-version 0x1262010D
```

255 chunks，全數 ACK 檢查通過、script hash 相符、COMMIT ACK=0，等待 MCU reset 後讀回 `v1.1.13 (0x1262010D)`。此為 staging 校驗與版本確認；沒有獨立 APROM 全內容讀回雜湊介面，不宣稱完成了全 flash byte-for-byte readback。

### 實機結果（不是端到端採集 PASS）

| 項目 | 部署前 v1.1.12 | 部署後 v1.1.13（三次） |
| --- | --- | --- |
| MCU status | 0xff | 0x3f |
| MCU lock | 錯誤 True | False |
| MCU timing | 錯誤 3840×2160 | 無效，H/V=0 |
| 直接 RXP0 | 13=01, 14=01, 19=20 | 相同，仍未鎖定 |
| FPGA／PCIe | 0x26102007、Gen3 x4 | 不變，UESta/CESta 未見設定位 |
| Host telemetry | timing invalid | 維持 timing invalid，daemon heartbeat 有推進 |

Xilinx `hdmi_info` 仍 No input stream detected；RX video clock probe=0。TXP1 raw 03=03、83=00、C0=21，為本次初始化後的狀態，不因原本殘留 2160 行就強制套用 1/40。**本次只修正錯誤上報與不可靠的控制觸發，尚未找出／修好實體 RX 掉鎖根因。**

來源輸出是否仍持續、IT6663 初始化／EQ／TX/DDC 設定、MCU I2C master 與 proxy ISR 的串行化，以及 probe CDC/frequency 行為仍需各自驗證；不可把這些待查項目寫成已證實根因。

### 證據與回復方式

前述 evidence directory 新增：

- `mcu-v1.1.13-flash.log`：實際更新命令與退出碼。
- `mcu-v1.1.13-status-1..3.log`、`mcu-v1.1.13-rx-1..3.json`、`mcu-v1.1.13-final-status.log`。
- `mcu-v1.1.13-vphy.log`、`mcu-v1.1.13-host.log`。
- `mcu-tests.log`、`mcu-sanitizers.log`、`mcu-flasher-tests.log`。
- `mcu-v1.1.13-sources.sha256`、candidate／rollback identity logs。

舊 v1.1.12 binary、ELF、it6663.c、board.h 保存在 `mcu-v1.1.12-backup/`。舊 binary CRC32=3d6e5433 與前次成功燒錄 log 相符，SHA256=f68094aa5a95e2ec45a9141258c0a52fccb1d69f3dca1bd1771f52b1f5ef6c8a。
如確認需要回復，可使用相同工具指定該 binary 及 `--expected-version 0x1262010C`；目前**未回復**，保持 v1.1.13，因它已如實回報未鎖定。舊版仍有假 lock／4K 問題，不能把回復舊版當成恢復正確採集。
