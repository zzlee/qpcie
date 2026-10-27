# SC7F0 V11：warm reboot／I2C 卡死的復原設計審查

日期：2026-10-23。**本次只讀原始碼、原理圖與文件；沒有新增硬體探測、改韌體、燒錄或重啟。**
視訊基線 commit `5ae137a` 不變；此審查和 audio WIP 分開。

## 1. 先釐清這次已知與未知

- 已確認：x86 warm reboot 後主機恢復、PCIe可枚舉，但卡端 PS 的 epoch／heartbeat 未變；
  `READY=1` 和 `SignalLocked` 是舊資料，不能證明 PS 活著。
- 先有多訊息 I2C transaction timeout／後續EAGAIN；復原時我又誤讀未經確認的
  `0xff020000`，PS command 隨後不返回、heartbeat停止。Linux adapter0 實際對應
  PS I2C1 `ff030000.i2c`。不能用 `/dev/i2c-N` 的 N 推測控制器實體位址。
- 沒有邏輯分析儀波形，不能把第一個 timeout 完全歸因於 MCU、Cadence HOLD 或 IT6663。
  也沒有獨立確認 MCU／IT6663 目前是否死機。**PS不回應後，無法透過它診斷下游是否健康。**
- cold power cycle 是否恢復這次故障，仍未實測。關機也未必等於所有電源消失：須考慮
  外接供電、USB／HDMI／AUX回灌，量測實際rail。

所以需要分別處理：(A) I2C protocol/controller/slave 卡住；(B) PS kernel／MMIO 無回應；
(C) MCU本身無回應；(D) IT6663下游重接／重新初始化。單純重啟daemon不能包辦。

## 2. V11 原理圖實際 reset 拓樸

唯一板圖來源：
`/home/zzlee/llm-wiki/raw/SC7F0_N1_HDMI2_V11/SC7F0 N1 HDMI2 V11.pdf`
SHA256 `c4e8a709bb17b51d5797c2aa90f8f1c6b63b7cd84f0cce67c9649741b03d6306`。
以下是**原理圖連線**；DNP／NC是否符合手上實板，仍需BOM及導通／示波量測確認。

### 第36、11頁：PCIe PERST沒有向上游reset PS

```
PCIe A11 PERST# = RSTn_PCIe ──┐
                             AND SU10 → X0_RSTn_PCIe → PL K11 → PCIe core reset
PS POR net X0_PS_PORb ────────┘
```

方向是「PS POR也會reset endpoint」，不是「host PERST會reset PS」。反向不存在。
而且不同主機的warm reboot是否實際重拉slot PERST，必須量測，不能由Linux reboot推定。

### 第10、13頁：已有POR→MCU→IT6663 reset連動

```
SRT1 (TLV840MADL29DBVR) → X0_PS_PORb → PS N19 / PS_POR_B
                                      └─ SR17 33Ω → RSTn_PWR0 → MCU U5 pin32 RESETn
RSTn_PWR0 ────────────────────┐
                              AND SU4 → RSTn_GPIO_MCU0 → IT6663 reset (第14頁)
MCU PA.10 / RSTn_MCU0 ────────┘
```

因此不能說V11完全沒有整板reset鏈；真正的外部POR會連帶重置MCU與IT6663。
缺的是一條不依賴已死PS、可由host/recovery controller發起這個動作的路徑。
另須注意：SR17是電阻而非單向buffer，`RSTn_PWR0`和PS POR電氣上仍相連。外加GPIO直接
拉MCU RESETn也可能反向拉低PS POR；新板若要獨立MCU reset，應使用分離的reset combiner／
buffer，而不是只在目前共用net上多接一顆下拉管。MCU內部WDT／NVIC reset則是另一種機制。

### 第10、13頁：容易混淆的兩條SRST net與DNP

- RST1的RESET output是 `X0_SRSTb`，接PS P20 `PS_SRST_B`，也接PL K12（第11頁）。
- MCU PB.6/pin1的net是 `X0_PS_SRSTb`，不是同名的PS pin直連。
- 兩者相關的控制路徑是 `PB.6 → X0_PS_SRSTb → R62 → RST1.MR`；**R62標為NC**。
  若實板未裝，不能靠改MCU GPIO就讓它reset PS。
- BT1接RST1.MR，是system-reset按鍵路徑，不應直接稱作POR按鍵。
- `X0_SRSTb` 與 `X0_PS_PORb` 間另有 **R116 NC**，不能假設兩網已接通，也不建議盲目補短。
- SRT1的MR沒有看到可由host／PL／MCU控制的已接線入口。

TI資料確認該DL型號RESET為open-drain、active-low，MR為active-low。但仍須確認實裝型號、
VCCO、pull-up、脈寬、上電時序及其他驅動者，才能評估PL K12以open-drain方式作緊急SRST，
或裝R62後由MCU拉MR。**不得把既有input直接改成push-pull output。**

PS_SRST_B不等於PS_POR_B；SRST有BootROM／系統設定條件，不能保證復原所有深層hang。
若改成POR還會讓endpoint／PL狀態失效，發起reset的邏輯不得在reset中失去時脈而無法釋放reset。

## 3. 現有程式的具體缺口

### MCU

- `test_mcu_nuc1262/main.c`：HardFault／exit無限迴圈；未見啟用獨立硬體WDT。
  `board.c`只有把PB.6設為input，main沒有用它處理PS reset邊沿。
- `i2c0_slave.c:handle_rx_complete()` 在I2C0 ISR內同步執行整個下游I2C1 transaction。
  上游response、clock stretching和下游故障耦合。
- `i2c1_bus.c`已有單transaction串行化、state驗證與有限cycle timeout（v1.1.14修正），
  不能誤稱完全沒有保護；但timeout後只做STOP，**沒有GPIO bus-clear／controller reset／
  下游硬reset的升級路徑**，也不是一個整體operation deadline。
- I2C0 ISR雖有TOIF分支，init未見啟用timeout；需核對NUC硬體timeout設定，不能當作已有保護。
- 單次I2C1鎖不能讓「切bank→多次read→restore bank」成為原子operation；background poll
  仍可能在中間讀錯bank。必須由MCU提供banked-read command並在同一worker job中完成。
- `it6663_poll_status()`主要看上游source及既有configured旗標。PS／下游sink重啟但上游不變時，
  可能沒有重新跑TX/SCDC/HPD協商；這與之前需要手動MCU runtime restart相符，但仍需事件測試。

### PS Linux、FSBL與daemon

- 實際PetaLinux6.1 Cadence driver在`drivers/i2c/busses/i2c-cadence.c`：bus busy timeout後，
  只有`adap.bus_recovery_info`存在才呼叫`i2c_recover_bus()`。現有pcw.dtsi的i2c1節點只見
  `status="okay"`，未見專用pinctrl/GPIO recovery設定；需核對final DT與runtime，不能僅因
  driver有rinfo欄位就認為bus-clear已經可用。
- 同一driver只有特定broken-HOLD quirk會預先拒絕receive後再接message。不能未驗證就
  斷言所有Cadence版本都不支援；SC7F0 client應先限制為已驗證的transaction型態。
- **FSBL也要改**：已列入bbappend的Si5341 patch內，`si5341_write()`有兩段
  `while (XIicPs_BusIsBusy(...)) { /* NOP */ }`，沒有deadline。PS與MCU upstream／
  clock-generator共用相關I2C連線，bus卡住時可能在Linux之前就卡死；只改daemon太晚。
- `test_app/qpcie_upgrade_daemon.c:trigger_pmu_por()`實際呼叫SysRq／Linux reboot／PSCI；
  名字不是物理PS_POR_B會被拉低的證據，且一定依賴PS還能執行程式。
- 現有`pl_magic_ok()`的alarm／SIGBUS／siglongjmp不是硬體AXI transaction timeout。
  若CPU停在無回應的MMIO讀取，signal／kill／readl_poll_timeout都不能保證救回。
- watchdog節點在generatedpcw.dtsi已有okay；但不能因此宣稱已啟動、有人餵狗、PMU reset action
  已設定或真能救hard-hang。需核對kernel、finalDTB、PMUFW、/dev/watchdog owner與實際reset域。

## 4. 建議先做的軟體修正（不改板）

1. **停止任意MMIO探測**：正式維運改成typed診斷API；由driver根據DT resource取得base、
   經runtime-PM／clock framework存取，未知／disabled資源直接拒絕。lab root shell另行授權，
   不把`timeout devmem`當安全隔離。
2. **PS單一MCU transport owner**：serial queue + transaction白名單 + bounded retries；
   分清NACK、timeout、bus busy、bad request。所有i2c-dev直接存取與debug shell都不得繞過
   ownership去切bank。正式kernel client或受限daemon皆可，但須限制旁路權限。
3. **MCU proxy v2非同步**：ISR只收command／seq／CRC並回BUSY／status，main worker執行下游I2C，
   host poll GET_RESULT；不在ISR跑IT6663 init／delay／整段bank-read。舊w+r協議需版本協商，
   不可靜默改成不相容格式。整個banked-read job必須有restore／錯誤回報。
4. **每層有獨立deadline**：I2C0 transaction、I2C1 transaction、banked-read job、整個recovery
   都有總期限；用獨立free-running timer，不依賴被ISR阻擋的SysTick ISR。
5. **bus recovery**：釋放controller／pinmux→open-drain GPIO檢查SCL/SDA→在SCL可拉高時最多9個
   clock、確認SDA釋放並正確STOP→恢復pinmux/controller。SCL仍被拉低或SDA持續不放時升級reset。
   不可push-pull硬拉高，不可在未完成write狀態盲目補clock而寫入垃圾。
6. **WDT**：MCU從獨立時脈啟用hardware reset，只由main正常推進時餵狗，不由ISR固定餵。
   PS硬體SWDT／PMU error/reset路徑實測；systemd WatchdogSec只監督process，不能取代hardware WDT。
7. **HELLO(epoch)+重新初始化**：PS boot、host新session、下游HPD變動各有明確事件；重新建立
   TX/SCDC/HPD狀態，不只看上游source仍locked。不要在每次健康poll重設所有HDMI設定。
8. **FSBL bounded recovery**：上電／重啟初始化clock generator前檢查bus、有限重試、必要時
   走已確認的reset路徑；所有BusIsBusy等待有總deadline。不能一直等到Linux daemon來救。
9. **重啟驗收**：記錄PS kernel `boot_id`、MCU boot generation、heartbeat與reset reason。
   daemon的隨機epoch改變只能證明daemon換了一個實例，不單獨證明PS重啟。應按要求的reset級別
   檢查相應boot ID／generation改變、heartbeat前進、服務與HDMI重新協商完成，不能只看PCIe
   重新枚舉或READY=1。

### 先處理MCU升級容量

目前產物`nuc1262_bringup.bin`為8088bytes，updater限制8192bytes，只有104bytes餘裕。
MCU linker FLASH是128KiB，限制來自**目前升級協議與SRAM staging**，不是晶片flash只有8KiB。
新增worker、WDT與recovery前，必須先審核staging區／stack／BSS隔離與rollback／bootloader安全，
不能直接加大一個常數或宣稱新韌體必然能透過現行8KiB協議燒入。

## 5. 分層復原與硬體修改建議

```
合法transaction失敗
  → bounded STOP／controller reinit
  → I2C bus-clear
  → reset MCU I2C0／I2C1 peripheral
  → MCU WDT或獨立MCU reset
  → IT6663 RESETn + 完整re-init／HPD協商
  → PS watchdog／受控system reset
  → 外部POR／必要的受控rail power-cycle
```

這是依故障所在層選擇／升級的選單，不是每次error都依序重置全卡。bad request應直接拒絕，
不能觸發reset；有eMMC COMMIT、IRQ／DMA活動時先quiesce，嚴重故障才使用失聯復原policy。

### 現有板可先評估

- 核對R62裝件／導通，確認PB.6→MR接法及reset波形，再考慮MCU open-drain SRST request。
  可救PS而MCU仍活著的情況；救不了MCU自身hard-hang，且不等於POR。
- 核對PL K12的`X0_SRSTb`、TLV840型號／pull-up，評估獨立BAR recovery peripheral輸出
  open-drain pulse的可能性。此功能不能經PS mailbox或用PS提供的可停止clock。
  這仍只是SRST級，必須實測故障覆蓋率；不是宣稱現有bitstream已具備。
- 不建議盲目裝R116把SRST/POR短接。POR會同時重置MCU及endpoint，容易讓發起pulse的邏輯
  自己失去clock／configuration，造成reset脈寬不足、無法釋放或循環。先做sequencing設計。

### 下一版建議：獨立reset supervisor／小CPLD

常供電、獨立時脈、不跟PS/PCIe功能domain一起reset的management controller：

| 輸入／輸出 | 用途 |
|---|---|
| host PERST# input | 偵測fundamental reset；可配置「只reset endpoint」或「受控全卡重啟」policy |
| PS_ALIVE與MCU_ALIVE，最好獨立GPIO | 不依賴已卡住I2C判斷對方生命跡象 |
| host可達的獨立recovery request | PS死時仍能請求復原；可用獨立PCIe management BAR與適當OOB介面 |
| PS POR supervisor的MR／open-drain reset request | 真正不依賴Linux的reset；PGOOD、PS_REF_CLK、pulse/release時序合規 |
| 獨立、隔離後的MCU_RESETn | MCU死時仍可reset；與現有共用POR net作適當buffer/combiner隔離，不能仍走MCU自己的I2C command |
| IT6663_RESETn與必要的bus isolator reset | 下游slaves拉死bus時隔離故障；保留既有SU4 reset意義 |
| clock generator reset／power enables（分domain） | 按需使用，不能把reset sequencer本身的clock一起關掉 |
| 必要rail load switches／PGOOD | 真正power-cycle時完整供電與防回灌，不只切IT6663的1.0V core |
| sticky reset reason／generation／result | host可知道執行了哪一級、是否完成，避免假成功與reset storm |

獨立SMBus／USB管理可作OOB，但主機slot SMBus是否可用、地址分配及隔離要實測；不能把它
直接併到目前PS-master／MCU-slave bus並假設多主控一定安全。

## 6. 不能把PERST直接一線並到所有reset

- PERST與POR reset域不一樣；standalone eMMC boot不應被host缺席永久壓住。
- reset controller不能依賴會被自己reset的PS、MCU或clock；否則形成復原閉環。
- 全卡從eMMC啟動可能慢於BIOS／PCIe枚舉時間。需量測實際PERST／REFCLK／link-ready，
  選擇pre-reboot quiesce、fast/tandem endpoint或host後續rescan等策略，不能保證焊一條線就好。
- 新host session不可重播舊的DMA RUN與host RAM地址：PERST／link-down後清除capture permission，
  新generation／ring設定完成才允許重新bus-master DMA。PS CSR還保有舊level不代表可安全重啟。
- flash transaction／eMMC internal cache／clock穩定性也必須納入reset policy；兩階段更新不代表
  任意時刻斷電都沒有風險。

## 7. 建議實施優先序及驗收

P0：typed diagnostics／禁止未驗證MMIO、reboot epoch驗收、已知transaction白名單。
P1：FSBL bounded waits、PS bus recovery與硬體WDT；MCU容量／更新安全先審核，再做proxy worker、
    bus-clear、WDT、HELLO epoch與下游重連。
P2：實板量測R62／K12／reset和供電，評估小改版SRST通道。
P3：獨立管理reset／POR與必要power-domain控制，才能涵蓋PS與MCU都不回應的故障。

驗收矩陣：正常cold boot、host warm reboot、PS-only reboot、MCU-only reset、下游HPD重新協商、
transaction中斷、SDA stuck、SCL stuck、MCU ISR故障、daemon crash、controlled PS stall、
update期間reset禁止／例外、反覆100次重啟、重啟後4K RGB/NV12/NV16與audio回歸。

先用unit/mock／bus-model／可控fault injector；**不得再靠讀disabled MMIO注入PS hang**。
用scope／logic analyzer確認每次assert/release、GPIO open-drain、clock與rail時序。
驗收須包含相應reset級別的新PS kernel boot_id／MCU boot generation、heartbeat前進、
I2C兩段均恢復、無stale DMA／buffer重播及實際A/V內容。

## 8. 參考

- SC7F0 V11 PDF第10／11／13／14／36頁；渲染圖暫存`build/validation/sc7f0-reset-design-review/`。
- TI TLV840 datasheet：https://www.ti.com/lit/ds/symlink/tlv840.pdf
  （DL open-drain；MR input與delay，不把外部拉低RESET output誤當MR觸發延時。）
- AMD UG1085／PG201：Zynq UltraScale+ MPSoC reset domains，必須區分PS_SRST_B、PS_POR_B與software reset。
- Linux I2C fault injection／bus recovery：https://www.kernel.org/doc/html/v5.9/i2c/gpio-fault-injection.html
