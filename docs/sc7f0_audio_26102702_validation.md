# SC7F0 26102702：部署與預設 buffers 音訊／A/V 驗證

> 此報告承接 [2026-10-27 音訊診斷](sc7f0_audio_validation_20261027.md)。
> 已完成部署、真正PS reboot、預設buffers的10分鐘嚴格A/V長測與後續格式回歸。
> 資料/時間線驗證通過；TPG停止仍有兩次可恢復的primary-drain fallback，詳見下文。
> 實際可聽與flash/beep lip-sync仍未確認，不是完整產品音訊驗收。

## 映像與簽核

- Candidate/release：`build/sc7f0-audio-doorbell-26102702-r1/`，PL **0x26102702**。
- 66 Python tests、20快速RTL案例、native parser/archive、PS AXI/CSR/CDC/audio simulations、RGB/NV12/NV16完整4K raster均通過；PetaLinux4418 tasks全部成功。
- Routed WNS **+0.076ns**、WHS **+0.010ns**。Setup margin較小，只代表目前工具signoff通過。
- DRC **111 warnings**，規則/數目與frozen06一致，沒有Error/Critical-severity DRC。
- CDC **24條Critical-class**，內容逐列與frozen06完全相同，屬既有reset同步/diagnostic pin-level advisories，沒有新增；**不是零Critical CDC**。
- 新bit、XSA內嵌bit及BOOT輸入bit一致。Raw-trace WIP仍default-off，DEV2未啟用，不列本輪驗收。
- 實際FIT抽出的kernel與已接受watchdog R2完全相同；PMU/FSBL/ATF/DTB也byte-identical。
- 實際FIT的四個AArch64服務、main-loop notify、唯一WDT owner、kernel nowayout/reset-on-timeout DT均通過補充audit。沒有拿僅僅patch存在當作PMU功能證據。

## 部署：有寫eMMC，但沒有重啟x86／更新MCU

使用既有工具 VERIFY → 明確備份 → COMMIT → 獨立eMMC SHA讀回 → card warm **system** reset。
這不是外部POR，不會保證MCU/IT6663跟著reset；沒有自動bootable A/B fallback。

- Remote：`/home/rd/sc7f0-upgrade.vDY9R4mh`。
- R2+PL06 eMMC備份：`/run/media/BOOT-mmcblk0p1/.backup_cli_20261027T054754Z`。
- 另外保留frozen R2套件與原buffer8 runtime module（先前evidence內）。
- Host boot ID一直為 `812110b6-6e3f-4f78-9d9e-6ba1ddb6cb59`。
- PS kernel boot ID：`1cea52f1-4d7f-4d69-bc19-50c619410d73` → **`78e5c8eb-cdd7-4611-b78e-624b43075ece`**。
  這是獨立重啟證據，不是只看PCIe enumeration/READY。
- 開機marker為watchdog R2、`PL_BASE_VERSION=0x26102702`；四services active、guardian healthy；WDT active/timeout60/nowayout1。
- Host matched module已安裝到`/lib/modules/7.0.0-38-generic/extra/qpcie.ko`，讀回參數 **sc7f0_nv_min_buffers=2**、diagnostics=N。
  此次不再使用8-buffer workaround。沒有做x86 reboot來測autoload。
- 新PS image已在真正PS reboot後執行；官方metadata8ch LPCM及正式DEV1 capture成功，沒有再靠runtime替換daemon。

新eMMC檔案SHA：

| 檔案 | SHA256 |
|---|---|
| BOOT.BIN | `36f0fcba11cafcec64ee806550f46bddb206123c0ec99399e88efc0926e8a13e` |
| image.ub | `bd25b2529190b5fae0b48951b4989c36338a461cdb32239cd4c5a9bdcb359e8a` |
| boot.scr | `14c14ececc4b35eb6ac10253f06a0f3dad10b7750d7283a7892676288df3bad6` |

Warm reboot後HDMI一度未鎖。只執行一次既有MCU runtime restart，**未flash MCU**。
初始45秒等待未過，後續觀測約PS uptime100秒恢復4K60；沒有盲目重送reset。
PS仍相同新boot ID；RGB8 3840×2160p/594MHz、8ch LPCM，link quality三路excellent。
這個reconnect latency不應被宣稱為已修好的即時自動恢復。

## 技術修正／未改的保護

- PS parser與host guard接受2/4/6/8ch 48k LPCM，保留真實來源channel count。
  ALSA輸出仍 **Front L/R stereo S32_LE**，不是surround downmix。
- ACR、measured-rate、non-audio、freshness、格式保護全部保留；沒有丟7/8 samples偽造48k。
- Thin descriptor engine改成只在`frame_active`下fetch。舊frozen06 source可單測重現：
  staggered Y/UV doorbells被提早吃完，heads=tail卻launches=0；新版對兩種寫入順序與3次empty/refill、小尺寸/4K geometry都通過。
- GStreamer capture端`slave-method=none`，不再讓預設skew默默改變捕獲資料時間線；
  Pulse sink仍skew跟隨共用SystemClock。逐buffer及總PTS/sample時長均驗證。
- 不把所有歷史NV16 timeout歸成同一根因；新版9次有界格式測試已另測通過，但TPG teardown仍有fallback，未宣稱完全根治所有停止時序。

## 已完成的新版實機測試

- Exact libasound capability guards再次通過；正式DEV1 3秒真實PCM擷取成功。
- Default module minimum=2；GStreamer log確認**初始request4 MMAP buffers**，並出現動態buffer reallocation仍能持續。
- 30秒單一真實4K NV12+ALSA+Wayland/Pulse：**1804 rendered frames**、video/DMA drops0、1446400 audio frames；
  EOS正常、無bus errors/warnings、初始DISCONT1、missing PTS/jumps/gaps/overlaps0、總時長誤差-1ns。
- 新版嚴格長測 **600.690秒**：36023 source/36016 rendered frames、59.976 render fps；GUI drops7、DMA drops0。
  audio28771328frames，PTS/sample時長599.402666666秒，總誤差0ns；missing PTS/jumps/gaps/overlaps0、初始DISCONT1、無bus errors/warnings、正常EOS。
  `av-default-600s.json`／`.log`／`.wav`完整保存；WAV全檔低8bit檢查通過，600個檢查blocks皆有非零資料。
- 程式總耗時包括startup/EOS，不等於PCM樣本時長，也不是量測實際lip-sync。
  額外只在evidence複本加探針的30秒診斷測得steady capture約47999.57frames/s；
  結尾audio/video各等待約0.102/0.098秒，PTS仍連續。沒有因此改寫frozen release來源。
- **20次ALSA重開**：每次48000frames、低8bit0，L/R總非零959818/959830，沒有quiet window。
- 真實RGB與audio併行：RGB600幀/10.005秒/**59.973fps**、1.492GB/s；15秒audio720000frames，L/R非零719862/719887、低8bit正確。
- 9次格式測試：HDMI RGB/NV12/NV16 → TPG RGB/NV12/NV16 → HDMI RGB/NV12/NV16，各120幀全部成功；
  HDMI約59.58–59.94fps，TPG實測58.232/56.889/58.732fps，**不把TPG說成全都60fps**。
- **剩餘teardown問題**：TPG NV12/NV16各一次初始drain逾時，driver pulse video sub-reset後皆回到drained=1、video_errors=0。
  沒有unrecovered drain失敗、poll timeout或PS reset，但這兩次不是乾淨的primary drain，仍需獨立修正/重驗。
- 最後恢復真實HDMI NV12，300幀/5.018秒/59.789fps，保存native3840×2160 raw/PNG並目視確認為來源森林/溪流/濺水影像，非TPG或空白。
  PNG離線由NV12轉RGB以便檢視，實際live pipeline沒有videoconvert/videoscale。
- `post-long-regression.exit=0`；最終無capture clients、WirePlumber active、PCI COMMAND0006（重新enumeration後BusMaster已開）、參數2、DEV2=N。
  未觸發錯誤隔離trap，沒有任何額外COMMIT或PS/x86 reset。

## 證據與未驗收範圍

- 本輪evidence：`build/validation/sc7f0-audio-20261027.rpRCkq/deployment-26102702/`。
- Pointer：`build/.sc7f0-audio-deploy-latest`。
- 包含predeployment signoff、實際FIT audit-view、preflight、完整deploy及去progress摘要、獨立boot ID/guardian證據與default-buffer30秒報告。
- 舊frozen06+8buffer的10分鐘成功只算歷史workaround；第一輪有1.013秒PTS差的舊pass則已另行標記不接受，原JSON未改。
- 最終PS boot ID仍78e5c8eb-cdd7-4611-b78e-624b43075ece，四services active、guardian healthy；eMMC三檔再次讀回完全符合release。
- Installed host module SHA為`d72ae1a814fd5973e220afee80c99812e39685144ab4688c64c6e3a4dc8b03cc`，與本次host build完全相同；x86未reboot。
- `hardware-acceptance-scoped.json`分開記錄capture/transport通過、兩次TPG drain fallback，以及audible/lip-sync未確認；不改寫frozen release manifest。
- 尚未確認：實際可聽、source channel allocation以外的surround downmix、flash/beep lip-sync、所有來源/拔插/任意hang恢復。
- MCU仍使用既有v1.1.15；無MCU firmware flash、無x86重啟。HEAD5ae137a、audio/recovery未commit/push。
