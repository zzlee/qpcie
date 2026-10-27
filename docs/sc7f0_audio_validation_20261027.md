# 2026-10-27 HDMI PCM / ALSA 實測（尚非完整有聲 A/V 驗收）

> **後續更新**：26102702已完成eMMC部署與真正PS reboot，正在預設buffers下驗證。
> 本文以下保留frozen06與8-buffer workaround的歷史；最新狀態見
> [26102702部署驗證](sc7f0_audio_26102702_validation.md)，不要把本文舊的「未燒錄／runtime only」當成目前狀態。

## 結論與版本邊界

**正式 ALSA DEV1 實際48kHz stereo S32_LE擷取與單一桌面A/V的10分鐘嚴格資料/時間線測試已通過。條件是runtime新軟體＋8-buffer workaround；預設buffer配置仍有停滯，永久RTL修正尚在建置、沒有部署。實際可聽與lip-sync仍未確認。**

- PL 沿用凍結的 `0x26102206`；MCU 仍 v1.1.15，沒有燒錄 MCU。
- PS watchdog R2、kernel/PMU/FSBL 不變。只在運行中的 rootfs 替換 HDMI daemon，
  及暫時 insmod 新 host driver；**沒有寫 eMMC boot files、沒有 PS/x86 重啟**。
- 因此這是 **runtime software override**，不是新的可持久部署 release；
  PS/host 重啟後不能假定本輪 daemon/module 修正仍在。
- HEAD 保持 `5ae137a`，index 空，audio/recovery WIP 沒有 commit/push。

## 來源與真正修正

先前重現約384k frame/s、零 payload，正式 DEV1 正確拒絕。使用者隨後說明來源先前靜音，
並已開啟聲音；之後實際 frame-counter 變為約47999–48000/s，雙聲道非零。
這是觀測到的狀態改變，**不是已證明靜音會造成所有384k異常的通用根因**。

官方 PS `hdmi_info` 此時報告 **8ch L-PCM**、ACR N5824/CTS約563077、594MHz pixel clock。
舊 PS parser/host guard 只接受2ch，導致合法輸入仍被拒絕。

修正：
- `test_app/qpcie_hdmi_audio.h` 接受2/4/6/8ch 48k LPCM，CSR 保留 **實際 source channel count**。
- `driver/qpcie_alsa.c` 接受上述來源，以現有 PL 的 TID0/1 抽取 **Front L/R**。
  ALSA 仍只有2ch S32_LE，PCM name=`HDMI LPCM Front L/R`。
- **不是8ch downmix**，沒有丟棄7/8 samples來偽造取樣率，也沒有取消 ACR、
  measured-rate、IEC60958 non-audio、freshness/format guards。
- parser native test 及 PCM simulation 補上多聲道來源/TID2–7應被忽略的案例。

## 已實際通過

證據目錄：`build/validation/sc7f0-audio-20261027.rpRCkq/`
（pointer `build/.sc7f0-audio-oct27-latest`）。

| 測試 | 實際結果 |
|---|---|
| 正式 DEV1 10秒 | 480000 frames；L/R非零；每個S32 sample低8bit為0 |
| 正式 DEV1 120秒 | 5760000 frames / 46080000 bytes；L/R非零各5677851/5678116 |
| 同時真實 NV12 擷取 | 6000幀 / 100.006秒 / 59.996fps，74.6496GB DMA進host RAM |
| 啟動順序 | audio先/video後、video先/audio後皆通過 native capture |
| ALSA 20次重開 | 每次48000 frames，L/R非零、低8bit正確，無arecord錯誤 |
| exact libasound capability API | 接受S32_LE/2ch/48000；拒絕S16/S24、8ch output、44100/96000/384000 |
| audio-only desktop playback | SystemClock/skew下120.216秒正常EOS、WAV5760000frames、無warnings；Pulse=USB Audio S/PDIF Output，可聽性未確認 |
| 軟體 regression | 66 Python tests、strict native parser test；PCM/DMA/raw-trace RTL simulations通過 |

`arecord -r` 可能自動選 nearest rate，不能拿這個行為當拒絕非法rate的證據。
本輪用現有 `libasound.so.2` 的 exact `snd_pcm_hw_params_test_*` API；
測試機缺 ALSA dev headers，沒有為此安裝套件。

長錄後 RX errors=0，source fmt=`0x0008bb80`，TID mask=`0xff`；
PL measured rate48087–48088（原有guard47900–48100內），實際counter差分約47999/s。
DEV2 diagnostic 預設關閉，最終 module parameter=`N`。

## 初始失敗：預設 buffer 配置的單一 GStreamer A/V

不能把 audio-only 或 native concurrent capture 算成整體 desktop A/V 成功。

- 原設定 `GstAudioSrcClock` / Pulse `slave-method=resample` 出現音訊丟樣與整體停滯；
  部分失敗程式 EOS 也卡住，已記錄後只終止對應的測試程序，未 reset 主機/卡片。
- 改用共用 `GstSystemClock`、非 driver timestamps、Pulse `skew` 後，audio
  能連續送到真實 sink，無bus warnings、alignment errors=0、初始DISCONT=1。
- **Video 仍在4–6 buffers後不再前進**。PTS與clock相符，不是靠caps/PLAYING宣告成功。
  某次卡住時 head58/tail80、frames6、running1，並有 STREAMOFF drain timeout；
  後續正常native擷取可乾淨 `drained=1`。
- GStreamer log有動態 buffer resurrection/CREATE_BUFS，這是調查線索，**不是已定根因**。
- queue變小/leaky、降低Pulse latency均未解決。
- 無audio的video-only sync=true可正常300幀EOS；原生200ms hold/requeue有/無audio均可恢復；
  含額外page-padded UV CREATE_BUFS的原生60幀也通過。故不能籠統歸因於
  「descriptor耗盡」「UV padding」「Audio必然搶走所有PCIe bandwidth」。
- `scripts/sc7f0_av_preview.py` 現在要求持續video/audio實測吞吐、已知DMA drop counter、
  無warnings及正常EOS，並明列 audible/lip-sync=false。
  regression包含「只播前一小段就卡住」不能通過長測的案例。最終實機負例正確exit1。

使用者明確回覆 **目前無法在測試機旁確認**；不能宣稱聽到正常聲音。
先前 NV16 TPG format-switch timeout 也仍未解，不能與本次GStreamer現象合併定因。

## 後續定位：雙 ring doorbell 競態與軟體 workaround

- 已核對 frozen06 SOURCE：thin fetch RTL SHA
  `187a81d00882cac743ad6056d6c246bafbddb3d26c065a9c165017bcebf0577a`。
- 舊RTL在尚未`frame_active`、另一plane doorbell尚未抵達時就能預取單一ring。
  新liveness test實際重現：heads1/1、tails1/1，但launches=0/retired=0，提交的frame永遠未啟動。
  不只是測試斷言「不喜歡預取」，而是有可重現的dispatch遺失。
- 候選修正僅允許`frame_active`時fetch。NV12/NV16、Y-first/UV-first、small/4K geometry，
  每組3次empty/refill，8種組合通過。4K geometry使用1MiB SG segments。
- 加上既有byte-exact tests，共20個快速RTL案例通過；另跑3格式完整4K raster regression。
  raster regression測data-plane，doorbell測試另測thin bookkeeping，不能說兩者已整合成實板驗收。
- `driver/qpcie_v4l2.c`新增**load-time診斷參數** `sc7f0_nv_min_buffers`，default2不改歷史行為，
  clamp2..8。實機暫載`=8`，保持frozen PL06不變，降低ring耗盡機率。
- 20秒單一A/V實測：1185個實際rendered frames、59.754fps、947200audio frames，
  video/DMA drops0、無bus warnings、alignment errors0、初始DISCONT1、正常EOS。
- 第一輪10分鐘A/V：35975source/35965rendered frames、59.975render fps、GUI drops10、DMA drops0、
  正常EOS且無bus warnings。但WAV598.549秒對PTS599.563秒，相差1.013333秒（48640samples）。
  **舊harness的pass=true不是嚴格連續性通過**；原JSON保留，另存retrospective分析標示失敗。
- capture端`alsasrc slave-method`預設skew可能默默調整讀取時間線，不一定設定DISCONT或bus warning。
  第一輪不代表已證明ALSA本身掉sample；它不能通過「原PCM與呈現時間線一致」的嚴格驗證。
  120秒audio-only測試也未逐buffer記錄PTS，不能反過來拿來證明不存在這個問題。
  改為`slave-method=none`保留擷取samples，Pulse sink仍skew跟隨共用SystemClock。60秒控制試驗：
  2889216samples、source3611/render3607frames、無missing PTS/jumps/gaps/overlaps；總PTS/sample時長誤差<2ns。
- harness新增逐buffer及總時長對帳，超過兩個sample誤差即失敗。第二輪嚴格長測完成：
  600.337秒、36006source/36002rendered frames、59.989render fps，GUI drops4、DMA drops0；
  audio28804096frames，PTS/sample duration600.085333秒、總誤差-1ns；
  missing PTS/jumps/gaps/overlaps全0，初始DISCONT1、無bus errors/warnings、正常EOS。
  WAV逐塊低8bit檢查通過，601個檢查blocks有599個非零（節目可有靜音片段）。
- 嚴格結果為`av-buffer8-none-600s.json`、`av-buffer8-none-600s-wav-analysis.json`；
  `acceptance-scoped.json`明列workaround/pass scope與未驗證項目，第一輪的舊pass不被嚴格驗收採用。
  這仍是buffer-pressure **workaround**，不是新的FPGA已修好，也不保證任意長停頓仍能恢復。
- RTL候選完整build已啟動：`build/sc7f0-audio-doorbell-26102702-r1`，PID276579。
  只在開發機編譯，不連/燒錄測試機；SOURCE已凍結，不要在build進行中改covered sources。
  手動完整RGB/NV12/NV16 raster regression均已通過；完整builder仍會重新跑所有gate。
  離線package watcher PID280817等待build.exit=0與build.ok後才打包，任何失敗即停止；不會自動flash。
  候選仍包含default-off raw-trace WIP，必須完整簽核，不能只由兩行thin修正就宣稱可部署。
- 原生midstream CREATE_BUFS測試也通過，不能將GStreamer動態配置本身當成已證明根因。

## 實驗性 trace 與安全邊界

- 一開始新增 default-off DEV2：PL06上只是未資格化converter資料，nominal384k
  **不表示來源384k，更不能直接拿來播放**。正式DEV1 guards不受影響。
- working tree 有 raw IEC trace RTL/ABI/decoder/tests；只做過simulation。
  `build/sc7f0-audio-trace-26102701-r1` 已刻意停止，無 `build.ok`、無可部署release、
  沒燒錄。該次舊 EXIT trap 留下build.exit=0，**不能當成功**；STOP_REASON與缺失的
  success gate才是判斷依據。builder已補INT/TERM非零exit traps供後續使用。
- 不採用被拒絕的combined I2C，也沒有任意PS MMIO診斷。
- 所有失敗與成功logs、原始PCM、來源patch、driver/daemon binary及SHA皆保留。

## 最終現場／回滾

- host boot ID `812110b6-6e3f-4f78-9d9e-6ba1ddb6cb59`。
- PS boot ID `1cea52f1-4d7f-4d69-bc19-50c619410d73`；四個services active，guardian health=healthy。
- HDMI RGB8 3840×2160p / 594MHz locked；PCI COMMAND0406，WirePlumber active。
- 目前buffer8診斷module srcversion `1FF4500647203414839B599`、參數`sc7f0_nv_min_buffers=8`，SHA
  `f4cd3c54644d9f27e1a748797a0918c7647b2b8b08dd59771b0f80ba17f6d257`；
  binary/source archive均已保存。沒有把此參數或module安裝成開機預設。
- runtime daemon SHA `b773daeb87cf83984b55f0d4bf8ffd57bf03a82509ccdad484d6ed77da3a0e59`。
- 第一版front-pair module（後續已被buffer8診斷module取代）srcversion `F22CC5E3115F8761D65F198`，SHA
  `52f9fed9c0da85d859aefbca24567cc1b858f4e2c957be796e65768f990618b5`。
- remote artifacts `/home/rd/sc7f0-audio-20261027.o6DKrTmw`；
  `module-before.ko` SHA `6d8584b1d4d2e41402c4e0e0552a7e1607035e5075330714b4afb65860aa1847`。
- PS runtime old daemon backup:
  `/tmp/sc7f0-audio-frontpair-20261027/qpcie_hdmi_daemon-before`。
- eMMC三檔SHA仍完全相同於已部署watchdog R2，見 `final-live-state.log`；
  本輪沒有重包/COMMIT，也沒有建立自動A/B fallback。

下一步：候選RTL完整建置、時序/DRC/PS套件驗證仍在背景進行；成功後才有離線候選套件。
部署後必須用預設buffers重驗，不能把目前的workaround當成永久修正。
可聽與flash/beep lip-sync仍需人機確認，持久套件/重啟驗證也尚未完成。
