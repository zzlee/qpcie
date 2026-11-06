# SC7F0 MCU 驗收：離線 P0 結果與實板進入門檻（2026-10-27）

> 後續決定：唯讀確認v1.1.15管理介面／HDMI正常、PS官方RX為4K60，依使用者要求**停止MCU測試及候選升級**。
> 本文以下內容作離線工作存檔，不再把整套MCU故障恢復驗收列為新VCU目標的阻塞條件。

## 結論與操作邊界

**離線 P0 通過，不等於 MCU 已驗收；目前禁止據此直接部署。**

本輪只在開發機修改、編譯、模擬及檢查產物，沒有 SSH／實體 I2C／OpenOCD 操作，
沒有燒 MCU、重啟 MCU／PS／x86、停 watchdog services 或注入實機故障。
先前最後驗證的實機組合為 PL26102702、PS watchdog R2、MCU v1.1.15；本輪未重新連線證明其即時健康。
PS watchdog 的既有實板通過結果**不能移用**為 NUC1262 watchdog 驗收。

原始 v1.1.15 rollback、20261024-r1 bridge/recovery 產物未修改。
本輪候選仍暫用未曾部署的 v1.1.16／17 版本號，須以各自 SHA／source snapshot 區別，不能混用舊 r1 binary。
MCU 及 updater 修改仍為未提交 WIP，沒有 commit/push；已推送的 A/V／PS commit `2bce1d8` 不變。

## 已重現並修正的問題

| 問題 | 修正與離線證據 |
|---|---|
| FMC erase/program/readback 失敗後返回 Flash `main` | 舊 writer 實際 C/register-model 重現 erase fault 返回 `-3`。現在只有 **erase 前輸入拒絕**能返回；任何破壞性操作開始後的錯誤均鎖 IRQ、留在 SRAM。 |
| `NVIC_SystemReset()` 的 LTO Flash helper | 真正 recovery ELF 出現 SRAM → veneer → Flash `__NVIC_SystemReset`。新 writer 不呼叫 CMSIS helper，直接於 SRAM 寫 AIRCR `VECTKEY=0x5fa, SYSRESETREQ=1`。舊錯誤 ELF 被現行 checker 以 `Indirect writer jump ... bx ip` 拒絕。 |
| COMMIT ACK 後仍可重新 BEGIN／CHUNK | ACK 等候期間 checked staging 可能遭修改。現在 COMMIT handoff 後僅允許 HELLO／PROGRESS／CAPS；BEGIN、CHUNK、ABORT、重送 COMMIT 及其他 mutation 均拒絕。runtime reset／EDID／proxy 接收也不再干擾該窗口。 |
| CRC32 高位元組 signed shift UB | BEGIN CRC 組合每個 byte 先轉 `uint32_t`，由 UBSan 的高位 CRC 測試覆蓋。 |
| writer 邊界不足 | 先檢查 word count 再乘法；僅允許從保留 staging 寫 APROM base。檢查來源範圍／對齊、MSP 與 Thumb reset vector，拒絕時不得發出任何 FMC command。 |
| 多個 updater 共用 `/tmp/burn_mcu.sh` | 使用私有 `mktemp` 目錄、驗證 script SHA；同一 flock 涵蓋 BEGIN→COMMIT→重啟 identity polling；取得鎖後重新核對來源 identity、HELLO、CAPS。 |
| 遺失 COMMIT ACK 後可再次執行 | COMMIT 前先建立 `/run/lock/sc7f0-mcu.commit-uncertain`；遺失 ACK、執行失敗或 target identity 未出現均保留 marker，其他 uploader 拒絕執行，不自動重送。 |
| size gate 可被既存 `.bin`／override 繞過 | bridge hard cap8192、recovery cap12288；每次 `all` 均重查既存 binary。失敗的生成目標由 `.DELETE_ON_ERROR` 移除。故障前留下的過大 binary 也有負向測試。 |

初版加入檢查後 bridge 曾為8216／8204 bytes，正常被 gate 擋下，沒有放寬8192上限。
把「每個 FMC caller 判斷返回碼」改為 SRAM wait helper 直接進入 failure hold，並將 protocol reply buffer
作內部4-byte對齊，保留所有防護後得到8188 bytes。**剩餘只有4 bytes，未來任何變更都必須重編及重過 gate。**

## failure hold 的真實含義

- 正常執行時仍由真實 main-loop progress 餵狗；ISR 不餵狗。
- SRAM writer 在每次成功 FMC 操作後餵狗。
- **破壞性更新失敗是明確例外**：鎖 IRQ、留下 SRAM `WRF1` 診斷紀錄（command/address/error），
  並在 SRAM hold loop 持續 service WDT，避免 WDT 啟動半寫映像。這不是健康回報或一般故障恢復。
- hold 狀態不能靠原本 I2C ISR 修復；需要外部 MCU ICE／救援路徑。這不是一個 I2C 救援 bootloader。
- 斷電、外部 reset、NMI／HardFault 等仍可能離開此狀態或碰到 Flash vectors；**不具備 power-fail-safe／A/B**。
- FMC readback 比較的是實際 Flash `[0, padded_image_length)` 的每個 word，不是只驗 staging CRC，
  也不是整顆128KiB Flash／CONFIG／LDROM的獨立 SHA 驗證。

## WDT 與 SRAM 審核

依 BSP `NUC1262.h` WDT register notes：

- `CTL`／`ALTCTL` 的相關控制欄位有 write protection；初始化在 `SYS_UnlockReg()` 範圍內。
- `RSTCNT` 規定寫 `0x5aa5`，**沒有該 write-protection 標註**；正常 main 在 lock 後餵狗不因此無效。
- counter reset 命令有2個 WDT clock 同步延遲；模擬不能驗證這項電氣／時脈行為。
- BSP LIRC 名義10kHz、TOUTSEL7為2^18 clocks，名義timeout26.2144秒；reset delay3 clocks。
  **這不是已量測的實機期限**，須依 datasheet 容差、CONFIG0/CWDTEN 與實板時脈驗收。

實際 ELF 檢查了 startup-copied `.data` 內的 writer/functions/literal pool、直接 branch/call，
沒有依賴 Flash helper；檢查 `__HeapLimit`、stack與12KiB NOLOAD staging 不重疊。
`sc7f0_mcu_version` 是由 register initialization 同一 `MCU_FW_VERSION` macro 發出的 absolute ELF symbol，
不增加 bridge Flash bytes；它不是實機 boot generation。

Checker 是明確範圍的 ELF／branch／literal gate，**不是所有 CFG／memory access／exception 的形式化證明**。
實板仍須量測 stack high-water、WDT、Flash 操作時序及故障 hold 行為。

## 凍結的離線證據

主要產物：`build/sc7f0-mcu-offline.9BEdSDkf/`

- 指標：`build/.sc7f0-mcu-offline-latest`。
- `offline.ok=SC7F0_MCU_OFFLINE_PASS_NOT_HARDWARE_ACCEPTED`，`offline.exit=0`。
- `source.tar.gz`／`source.sha256`、外部 BSP／GCC libraries/startfiles/specs SHA、compiler version、
  真正 ELF／BIN／map／SRAM disassembly、`artifacts.sha256` 全部保留並重新讀檔驗證。
- base Git `2bce1d8176e644fa44eef520a94ca6fa31f51b3a`；source snapshot 明確包含未提交 MCU 候選，不能只拿 Git ID 重建。
- 另一次獨立 output directory `build/sc7f0-mcu-offline.2Wgcy5Ge/` 的兩個 BIN 與主要產物逐 byte 相同。
- 初始反例、被拒絕的 LTO Flash-reset ELF、第一次測試／編譯失敗及修正過程：
  `build/sc7f0-mcu-safety-20261027-r2.mNtEVR07/`，指標 `build/.sc7f0-mcu-safety-latest`。
  host harness 曾因在 script hash 前重寫 fixture 路徑而失敗，已修成只重寫 execution copy；沒有略過 hash gate。

| 候選 | bytes / 上限 | SHA256 |
|---|---:|---|
| bridge v1.1.16 | 8188 / 8192 | `60eab3a90691d4ff45b9707ae81acb0165b89c4a0866ed4a6e6afd039c6857d8` |
| recovery v1.1.17 | 9456 / 12288 | `f349a96dea86912df3eb2f1f7b4322b95080b7f591eec117bd2380be6f2612b3` |

兩者保留 staging `0x20001000–0x20004000`，stack `0x20004c00–0x20005000`。
bridge/recovery heap limit分別 `0x20000568`／`0x200005a8`，SRAM writer range分別
`0x20000008–0x20000194`／`0x20000008–0x200001a0`。

測試結果：

- 真實 writer C/register-model：**33項 × bridge/recovery**，涵蓋FMC fault、timeout、readback mismatch、
  overflow／range／vectors與成功 readback→SRAM reset。
- 真實 upgrade/receive C（不是重寫的協議模型）：**281項 × bridge/recovery**，包含全部256個opcode的COMMIT freeze。
- 原有 RX-state／I2C-plan/proxy helper native tests通過；新增 C tests 用 UBSan＋`-Wall -Wextra -Werror`。
- MCU Python **27 tests**：20個 updater/shell tests（含併發／lost ACK）＋7個 image negative/integration tests。
- repository Python 全部 **83 tests** 通過（已含上述27項，不重複加總）。
- shell syntax與指定變更的 `git diff --check` 通過。沒有新增實機 A/V、MCU reset或watchdog通過宣告。

可重跑純離線流程（會建立新 output directory，不操作硬體）：

```sh
./scripts/test_sc7f0_mcu_offline.sh
```

需要本地 ARM GCC／binutils、`raw/NUC1262BSP`、host C compiler、Python3、make、flock；缺少依賴不會假裝 gate 通過。
產生的 OpenOCD TCL 只是 build artifact，**未執行，也不表示外部救援已驗證**。

## 實板驗收的進入門檻：尚未通過

1. **MCU 外部救援**：確認 NUC1262 相容的 SWD／Nu-Link／ICE、實際接線與VTREF；
   先在備板／可救援環境證明 identify、Flash/CONFIG讀回、erase/program/verify及還原v15。
   既往沒有 PS JTAG／hw_server，不代表已檢查或已有 MCU SWD。
2. **V11 reset 電氣邊界**：SR17 33Ω耦合 MCU RESETn與PS POR；ICE 的NRST／connect-under-reset可能連帶重置PS。
   必須先量測／審核，不可當成隔離線；不可將PL並接SU4主動驅動輸出。
3. **升級安全基線**：quiesce capture、保留必要PS服務／硬體WDT，禁止其他MCU updater／EDID／runtime-reset mutation；
   讀回既有Flash/CONFIG、保存hash、PS/x86 boot ID及MCU基線。
4. **分開授權實板升級**：v15→8188-byte bridge，實讀12KiB CAPS後才可→9456-byte recovery；
   每階段都要有實際Flash讀回與新boot證據，不只版本號／HELLO。

Updater 現在還要求顯式、不同的 `--expected-version` 及 `--ack-in-place-risk`。
**risk acknowledgement 不是救援已驗證的證據或部署許可。** 同版ISP沒有boot-generation/readback ABI，故工具拒絕。
`commit-uncertain` marker只保證同一PS `/run`生命週期的禁止重試；PS reboot可能清掉它，不能因此認定安全。
不得未查明就刪marker或重送COMMIT；timeout也不能保證救回所有AXI/I2C硬體stall。

## 通過救援門檻後的實板矩陣（本輪未執行）

| 項目 | 合格證據 |
|---|---|
| 正常啟動／管理介面／CAPS | 新鮮main progress、真實reset reason與協議相容性，不以READY／版本號當boot證明。 |
| main卡住但ISR持續；IRQ關閉／HardFault | 不由ISR餵狗；量測LIRC硬體timeout後MCU真重啟，reset reason與獨立scope/ICE/boot觀測相符。 |
| SDA低／slave內部鎖住 | open-drain bus-clear／STOP有界，無對推，失敗計數可信，解除故障後兩段I2C及下游恢復。 |
| SCL被外部持續拉低 | 有界失敗而非無限等待；不能聲稱9 clocks可解除外部硬拉低，釋放後才驗證恢復。 |
| IT6663不回應／下游reset | 分級恢復、重新初始化、HPD/SCDC協商及真正HDMI重新鎖定，記錄斷線／重連時間。 |
| MCU-only runtime/WDT reset | PS及x86 boot ID不變、無意外PS POR，真實MCU boot／WDT原因可證明。 |
| 更新期錯誤 | 先用mock；實體擦寫／掉電／故障hold測試只能於救援已實證、另行授權的備板環境做。 |
| 壓力／回歸 | 建議100次runtime reset，事前定義deadline；重連後原生RGB/NV12/NV16與ALSA／同一A/V pipeline長測，檢查內容、PCM、PTS、DMA freshness。 |

現有0x2c main-progress byte會wrap，reset-reason是boot時讀取後快取；它們**不是持久boot generation**。
若驗收要用generation，須先設計可靠計數ABI；目前應用受控fault、WDT reason與獨立boot觀測交叉證明。
現有legacy proxy仍有ISR內I2C1 transaction路徑，不能概稱「所有proxy已移出ISR」；此路徑的最壞期限、
starvation、與async F1/F2的相容性仍須專門測試。upstream I2C0 recovery、下游bus-clear與reset電氣行為均未實板驗收。

實際聽感／flash-beep lip-sync仍待人在測試機確認；MCU驗收不會自動關閉該A/V待辦。
