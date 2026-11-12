# SC7F0 分支進度報告 — 2026-11-11（A 階段：狀態釐清與文件落地）

> 本文件只做「目前到底到哪一步」的白話總結與證據索引。它不是驗收證書，也不代表產品完成。
> B 階段（完整建置入包＋正規包燒錄）已由使用者授權，但**本次尚未執行**，詳見第 9 節。

## 0. 採樣時點與分支身分

| 項目 | 實測值 |
|---|---|
| 查核時間 | 2026-11-11 17:40:34 – 17:46 +0800（地端量測起始時間戳） |
| 分支 | `feat/zu4ev-sc7f0-bringup`（`git branch --show-current`） |
| HEAD | `aea86126bda15af8d200c79aa62b853fc57f3b39`（縮寫 `aea8612`）｜Merge branch `feat/sc7f0-dual-video-vivado`，2026-11-11 16:39:04 +0800 |
| 工作區 | 採樣當下 `git status --porcelain` 空輸出＝乾淨；與 `origin/feat/zu4ev-sc7f0-bringup` 無 ahead/behind |
| worktree | 僅 `qpcie`、`qpcie-m2-720`；`/home/zzlee/vibecoding/sc7f0-dual-video` **已於 11-11 16:48 刪除** |
| 本機 `build/` | 最新 artifacts 停在 2026-11-06；無 `dual-video-26110301-vcu-r1`、無 `sc7f0-capture-26102804-r1` |

**重要**：本報告所有「HEAD / 乾淨工作區」敘述只對上表這一刻成立。此後任何工作若產生新 commit 或髒工作區，**不得沿用 `aea8612` 作為身分**，必須重新採樣並另立時點。

## 1. 白話結論（先講人話）

- **HDMI 原始 4K60 擷取（HDMI → PL → 主機 RAM）已經打通**，今日現場短測 600 幀零掉包。
- **HDMI → PL → VCU H.264 編碼 → 主機（video1 Packet DMA）已經打通**，今日現場短測 300 幀、封包計數完全吻合、解碼零錯誤。
- 但**這還不是「可重現的完整交付驗收」**：目前可用狀態依賴套件外／開機後才存在的檔案，正式時序與 CDC gate 沒有可重驗的簽核，獨立重啟重現、1–3 小時雙路燒機、音訊／人工聽音與唇同步、三路 C2H、應用層整合都還沒做。
- 一句話：**功能路徑通了，交付與可重現性還沒通。**

## 2. 里程碑與 commit（僅列已有證據者）

| commit（完整 SHA 前 7 碼） | 日期 | 內容 | 佐證 |
|---|---|---|---|
| `54c418c21edec5b5c8b83414f83dc418d24dc8dd` | 11-06 | VCU 硬編＋Packet C2H DMA＋host V4L2 controls | commit message |
| `ab968555132f36492eed8f34006b38c47ae1c74d` | 11-09 | zero-copy DMA-BUF OpenMAX 編碼器＋Packet DMA 串流 | commit message |
| `8cc4451642eb3b0a3e5988b85c0b72316c08f0ff` | 11-09 | VCU DPC1 完結 watchdog off-by-one 修正 | commit message |
| `6c21b2a56d5983bb2f10482a58a0ba1d8e1ae4fc` | 11-09 | HDMI RX 時間戳經 VCU 送至 host（時鐘校正） | commit message |
| `728e0f31a5d9e4896b4de0f544971726d1241ef9` | 11-09 | 卡端硬體 pacer（V4L2 controls，零停頓 60Hz） | commit message |
| `3588f8972c1f136e3220127abdd46edb8ca118ae` | 11-09 | 多 slot DDR staging 打結修正、AUD 分隔符、progressive SPS | commit message |
| `731c599a23a673e33ee61d37d430d3dd05e5d8b7` | 11-11 16:36 | C2H 仲裁 pop 互鎖＋mailbox 0x800 位址重疊修正 | commit message；對應 vault pi session `01a1c8a3` |
| `aea86126bda15af8d200c79aa62b853fc57f3b39` | 11-11 16:39 | 合併 `feat/sc7f0-dual-video-vivado` 至本分支（現 HEAD） | `git log` |
| `2bce1d8176e644fa44eef520a94ca6fa31f51b3a` | **10-27** | HDMI LPCM A/V ＋ PS watchdog 恢復（＝板上實讀 `GIT 0x2BCE1D81` 版本的真實來源） | `git log`；見第 3 節版本缺口 |

## 3. 版本身分：三種身分必須分列，不可混為一談

| 身分 | 值 | 由來／取得方式 |
|---|---|---|
| **升級套件號** | `26111101` | 測試機 `/home/rd/upgrade-26111101.tar` 檔名與 manifest。**字串 `26111101` 不存在於 HEAD 任何檔案**（全樹 grep 無命中） |
| **硬體暫存器版本** | `0x26110301`（`Hardware Version 0x26110301`，Date 2026/11/03 Rev 01）、Git `0x2BCE1D81` | host `qpcie_upgrade --status`＋`version`（v38.17.3-variant1, Date 20261103, Caps 0x1001011F）實讀 |
| **repo RTL 預設** | `32'h2610_2901` | [`rtl/zu4ev_pcie_card_top.v:20`](../rtl/zu4ev_pcie_card_top.v) `parameter C_VERSION = 32'h2610_2901` |

**版本戳記工具鏈缺口（本次查出的根因，非猜測）**：[`scripts/impl_sc7f0_dual_video.tcl`](../scripts/impl_sc7f0_dual_video.tcl) 內**完全沒有** `set_property generic {C_VERSION=…}`，也沒有 `GIT_COMMIT_HASH_DEF`／`BUILD_TIMESTAMP_DEF`（舊流程 `build_sc7f0_hdmi_08.tcl`、`build_zu4ev.tcl` 才有）。因此 11-03 建案所產生的 version/date/GIT 三個數字，被 11-09、11-10、11-11 三次建置**原封不動沿用**；實讀 `0x2BCE1D81` 其實指向 **10-27** 的 commit `2bce1d81…`，且同一數值也出現在 `docs/sc7f0_r3_upgrade_report_20261030.md`、`docs/sc7f0_r7_signal_recovery_4k60_20261029.md`。
→ 結論：**版本暫存器無法區分 11-03／11-10／11-11 三次建置**，目前可信的身分只有「BOOT.BIN／eMMC 內容 SHA ＋ `card_epoch`」。**不應為了湊齊數字而單獨重燒一次。**

**SHA 比對的正確說法（不可誇大）**：

- 卡端 eMMC 讀回三成員 SHA — BOOT.BIN `f08402c1…`／image.ub `46da8a2e…`／boot.scr `14c14ece…`（皆為**縮寫**，原報告僅記錄前 8 碼）——與 `/home/rd/upgrade-26111101.tar` 的 manifest **數值相符**。這是「雜湊值相符」，**不是逐位元組內容比對**。
- 整包 `/home/rd/upgrade-26111101.tar` sha256 `0efab7acd945839d…d6dd3236`（**縮寫**，頭尾各一段）與 vault 紀錄相符；同機另外兩包 `879897…`、`8b0f0f…` 三包互不相同。
- 三包中 **BOOT.BIN 各不相同（`a115bd05`／`60a44567`／`f08402c1`，縮寫），但 image.ub 與 boot.scr 三包完全相同** → 11-03→11-11 只換了 PL／BOOT.BIN，PS kernel/rootfs 鏡像從未變過。
- `sc7f0ctl status` 回傳 `ABI=1 ready=1 card_epoch=eb404516`，與 11-11 燒錄後 vault 記錄相同。此事實**支持**「11-11 燒錄後未觀察到新的卡端 epoch」，但**不足以宣稱卡必定從未重啟**（epoch 的產生與覆蓋範圍未獨立驗證）。

## 4. 本次即時量測（17:40–17:46，地端親測，非重讀舊檔）

**平台與驅動身分**

- host：`Linux sc7f0-test 7.0.0-42-generic`，up 8:34；`sc7f0-test.local` → `192.168.190.247`（SSH 嚴格金鑰驗證，未跳過）
- PCI：`03:00.0 [12ab:e380]`，driver `qpcie-dma`，LnkSta 8GT/s x4；HDMI **Signal Locked / 3840x2160p / 594 MHz**（fmt `0x00800200`）
- 驅動 srcversion 已收斂：loaded `2BA9C2B03340C193808943C` ＝ `/home/rd/qpcie.ko` ＝ `/lib/modules/7.0.0-42-generic/extra/qpcie.ko`（md5 `cbb6a311…` 縮寫）。僅 `/home/rd/driver/qpcie.ko`（`98BC0543…` 縮寫，11-10 殘留舊檔）不同 → 11-10 記載的「loaded 與磁碟不一致」已不存在
- PS：`qpcie-zu4ev 6.1.30-xilinx-v2023.2`、`boot_id 3b788648-35e2-42de-bc7c-4d59f7a272e0`、rootfs 為 **RAM initramfs**、三 daemon active、`is-system-running = running`
- `vcu_encoder_config`：magic `0x56435543`、Config Sequence 43／PS Ack 43、AVC CBR 25 Mbps、GOP 60、CABAC
- `Upgrade Status 0x00 IDLE`（無待 COMMIT 狀態）

**4.1 video0 原始擷取（HDMI → PL → host RAM）**

`gst-launch-1.0 -q v4l2src device=/dev/video0 num-buffers=600 ! NV12,3840x2160,60/1 ! fakesink`
→ `GST_RC=0`、**600 buffers / 10.044 s ≈ 59.74 fps**、`ch0_drops=0`、`frame_drop_count=0`、`drained=1 video_errors=0`；新增 dmesg 僅 22 行且無 error/warn/overflow，AER 0/0/0，epoch 未變。

**4.2 video1 VCU 編碼路徑（PS → VCU → HOST）**

`gst-launch-1.0 v4l2src device=/dev/video1 num-buffers=300 ! filesink`
→ `GST_RC=0`、**300 buffers / 5.176 s ≈ 57.9 fps**、15,485,744 bytes、h264 3840x2160；
`packet_stats` submit/done/msi 由 `2901 → 3201`（**+300，與 buffer 數完全吻合**）、`err_cnt=0`；
dmesg `VCU done[1..7] comp[0]=0x44504331 actual_len=…`（DPC1 正常完結、非零長度）；`ffmpeg -v error` **0 錯誤行**；AER 0；epoch 未變；測試暫存檔 `/tmp/pi_probe_vcu_71874.h264` 已刪除。

> **限制（務必這樣讀）**：4.1 與 4.2 都是**秒級短測**。600 幀 59.74 fps、300 幀 57.9 fps 只能證明「短時間沒有掉包／沒有錯誤」，**不可宣稱穩態 60 fps**，也不可宣稱長時間不會累積停頓或擁塞。穩態主張屬於第 8 節的燒機項目。

**4.3 主動放棄的一項測試**：合成 Packet DMA 單測**未執行**。理由：`sc7f0_vcud --daemon`（PID 3852，約 54% 核心）常駐且持有同一封包引擎／環，現成包裝腳本 `/home/rd/run_pkt_test.sh` 內含 `killall -9`（host＋卡端），而暫停 daemon 属禁止動作；11-10 同類測試曾造成測試機 soft hang 20 分鐘以上需斷電。依「需暫停服務即停止該測試」的原則迴避。

**4.4 測試副作用如實紀錄（不得說成純被動讀取）**：本次曾執行 `qpcie_upgrade --status`。該工具在 `main()` 定位裝置後**無條件**執行 `setpci -s <bdf> COMMAND=0x06`（置 Bus Master ＋ Memory Space），見 [`test_app/qpcie_upgrade.c:464-469`](../test_app/qpcie_upgrade.c)。對已在動作的 DMA 裝置無實質危害，但**它不是完全被動讀取**，日後不應把 `--status` 列為被動探測工具。
本次**未**執行 VERIFY／COMMIT／reboot，**未**部署、**未**重啟卡／PS／MCU、**未**更新或替換板上任何檔案。唯一寫入是測試自身暫存輸出 `/tmp/pi_probe_vcu_71874.h264`（已刪除）。

## 5. 歷史重驗（與第 4 節分開，不可當成今日串流）

| 物件（時間戳） | 內容 | 重驗結果 |
|---|---|---|
| `/tmp/pure_stress_500.log`（11-11 16:21） | 合成封包 DMA 純測 | **500/500**、257.09 MiB、empty=0、gaps=0、CRC fail=0、30.007 s、8.57 MB/s@17pps → **非空集合 PASS**，支持 vault 宣稱 |
| `/tmp/video1_concurrent.log`（11-11 16:22） | 4K60 原始擷取**併發**下的封包 DMA | **500/500**、258.52 MiB、empty/gaps/CRC = 0/0/0 |
| `vcu_live_capture.mp4`（11-11 16:30，96,065,265 B） | VCU H.264 產物重解碼 | ffprobe：h264 3840x2160、**1841 幀 / 30.679 s / 25.05 Mbps**；`ffmpeg -v error` **0 錯誤行**、`nb_read_frames=1841` → 檔案層級完整可解 |
| `vcu_5min_test.mp4`（11-10 12:43） | 舊 VCU 產物 | **891 行解碼錯誤**，但 `ffmpeg_rc=0` → **必須數 error 行，不能只看 rc**；同時支持「11-11 相對 11-10 是實質改進」 |

## 6. AGENTS.md／repo 文件 與 vault 的衝突（依使用者裁決處理）

使用者裁決：**vault 的 11-11 實測代表較新進度，且本次現場量測支持它；較舊的 repo 文件敘述降為歷史基線。**據此：

1. **狀態衝突由現場證據判決**：[`docs/sc7f0_continuous_todo.md:8`](sc7f0_continuous_todo.md)（清單第 4 項）「No VCU hardware or executable daemon exists yet」與 `:11`「The deployed card remains `26102702` … No card flash」、[`docs/sc7f0_dual_video_worklog.md`](sc7f0_dual_video_worklog.md):9「VCU hardware/executable daemon remain unimplemented」、[`docs/sc7f0_build_package_flash.md`](sc7f0_build_package_flash.md):3／:105「Active FPGA：`0x26102204`」——皆與即時量測直接矛盾（vcud 正在執行、eMMC SHA 對應 26111101、VCU 4K60 現測通過）。這些句子**是歷史基線，不是目前狀態**；屬文件問題，不需要改代碼。
2. **流程入口分列，不二選一**：
   - *文件標準流程*：`scripts/sc7f0_build.sh` → `scripts/sc7f0_package.sh` → `scripts/sc7f0_flash.sh`（三支皆在 repo，10 月世代）。
   - *11-11 實際流程*：`scripts/run_rebuild_26110301_vcu.sh`（`SC7F0_ENABLE_VCU=1`、`SC7F0_TIMING_GATE=record`）＋ `scripts/package_zu4ev_bootbin.sh` ＋ 直接 `qpcie_upgrade --package/--commit/--reboot`，未走上述三支。
3. **A50T 章節為 legacy**：`AGENTS.md` 的 Artix-7 A50T／`pcie_7x_0`／SPI Flash `MX25L12872F`／`scripts/flash_a50t.sh` 屬另一張卡的 legacy 段落，**不是 SC7F0 部署流程**；`AGENTS.md:27` 引用的 `build/sc7f0-capture-26102804-r1/deployment/it6663-readonly.*` 本機已不存在。
4. **PS 時鐘偏差**：卡端時鐘比 host **慢約 3 天 2 小時 18 分** → 卡端任何檔案 mtime **不可**用來辨版本或判新舊，必須用 SHA／manifest／manifest 時間與 host 側時間戳。

## 7. 交付阻塞（尚未解，B 階段目標）

1. **目前可用狀態依賴「套件外＋易失」元件**（重啟可重現性**尚未實測**，以下為證據＋推論，**不得寫成已證實重啟失敗**）：
   - `/usr/bin/qpcie_debugd` sha `e200063c…`（縮寫）＝ 測試機 `qpcie_debugd_0x800`；而 rootfs 是 **RAM initramfs**、image.ub 三包相同 → 該 0x800 版 debugd **疑似開機後由 host 放入 RAM**。
   - `/tmp/sc7f0_pkt_dma_test`（sha `0ff0af47`，縮寫）同屬每開機推送的暫存工具。
   - `sc7f0_vcud` 是 BOOT 分區上的**散檔**（`/run/media/BOOT-mmcblk0p1/sc7f0_vcud`，81,408 B），**不在四成員 tar 內**。
   → 推論：單純重開機**可能**無法重現今日可用狀態；B 階段必須查證並把這些 runtime 正式入包。
2. **回滾路徑是假的**：`/run/media/BOOT-mmcblk0p1/.backup_upgrade/{BOOT.BIN,image.ub,boot.scr}` SHA **與現行完全相同**，且無 `.backup_cli_*` → 卡上**沒有前一代鏡像可回滾**；AGENTS「回滾功能可用」在此世代不成立（主機端仍留 26110301／26111001 兩包，回滾需重燒）。
3. **正式 timing／CDC 證據遺失**：原 worktree 與 `build/dual-video-26110301-vcu-r1` 報表**本機不存在**（比對基準 `build/` 最新 11-06）→ 11-11 的 WNS `0.000 ns`（零 setup 餘裕、WHS +0.009）、exact-path／CDC `pass_gate: false` 只是**歷史紀錄，本次未重驗**，也**無法**在本次重驗；對照 10-28 世代的嚴格收斂標準（`docs/sc7f0_full_profile_r6_review.md` WNS +0.671）差距明顯。
4. **建置入口已斷路**：[`scripts/run_rebuild_26110301_vcu.sh:4`](../scripts/run_rebuild_26110301_vcu.sh) 寫死 `ROOT="/home/zzlee/vibecoding/sc7f0-dual-video"`（已刪）→ 該入口現況無法重跑；同腳本 `SC7F0_TIMING_GATE="record"`（非致命），而 [`scripts/build_sc7f0_dual_video_hw.sh:17`](../scripts/build_sc7f0_dual_video_hw.sh) 預設 `strict` → gate 已被放寬是**寫在腳本裡的事實**。
5. **版本注入缺口**：見第 3 節，`impl_sc7f0_dual_video.tcl` 未接 `C_VERSION`／`GIT_COMMIT_HASH_DEF`／`BUILD_TIMESTAMP_DEF`；髒工作區指紋亦無來源。
6. **文件中推薦的驗證工具不存在**：`/home/rd/sc7f0-nv-formats/capture_verify` 與該目錄在測試機查無 → 文件標準驗證入口失效（本次改用既有 `gst-launch-1.0`／`ffprobe`／`ffmpeg`，未安裝任何東西）。
7. **`scripts/build_sc7f0_matching_ps_vcu.sh` 只接受 `0x26102902`／`0x26110301` 兩個 VCU 基底**（`:33-35`），與「套件號 26111101」無對應關係；版本命名規則需在 B 階段一次性收斂。

## 8. 明確未完成（不得宣稱產品／交付完成）

- 獨立**重啟重現**驗證（卡端断电／重啟後，不靠 host 推送即可自行恢復可用狀態）。
- 正式**時序（WNS/TNS）與 CDC** 簽核（本次未重驗，歷史 `pass_gate: false` 不算通過）。
- **1–3 小時雙串流燒機**（video0 4K60 ＋ video1 VCU 併發穩態、錯誤／drain／擁塞）。
- **音訊**：ALSA 節點存在（card0 `SC7F0 HDMI Audio`／`SC7F0 HDMI PCM capture`）但**未做音訊測試**；HDMI LPCM 進 MP4、人工聽音與唇同步未做。
- **三路 C2H 最終候選**驗收（raw video ＋ encoded packet ＋ Front L/R audio 併發）。
- **應用層整合**（qcap-dev／demos／zstreamer 適配）。

## 9. B 階段：已獲使用者授權，**尚未執行**

使用者已同意 A＋B（先出本報告，再做完整收斂）。本文件撰寫當下 **B 一點都沒有開始**。B 的範圍（經授權、待父代理另派）：

1. 一次**完整建置**（FPGA＋PS＋所有 runtime），不用個別替換板上檔案的方式过关。
2. **所有 runtime 正式入包**：含 0x800 版 `qpcie_debugd`、`sc7f0_vcud`（以及需要時的重現所需工具），使重啟後可自立恢復。
3. **版本來源正名＋dirty 指紋**：把 `C_VERSION`／`GIT_COMMIT_HASH_DEF`／`BUILD_TIMESTAMP_DEF` 正式接進 dual-video 流程，讓暫存器能區分各次建置。
4. **前代備份與真正可用的回復路徑**（修正 COMMIT 前備份語意，使 `.backup_upgrade` 保存前一代）。
5. **嚴格 gate**（`SC7F0_TIMING_GATE=strict` 與 exact-path／CDC 閘門）**＋正規包燒錄**（VERIFY → 一次 COMMIT → 獨立 eMMC SHA → 真實重啟/boot-ID 證據）。
6. **禁止為過關而放寬 gate**；**禁止個別替換板上檔案**。

## 10. 來源與證據索引

**兩份原始報告（絕對路徑）**

- 衝突研究：`/home/zzlee/.pi/agent/sessions/--home-zzlee-docker-sc7f0-hdmi-alphablending--/subagent-artifacts/375aca7d-d855-4e9d-a3a3-8465c59df4c0_delegate_output.md`
- 現場量測：`/home/zzlee/.pi/agent/sessions/--home-zzlee-docker-sc7f0-hdmi-alphablending--/subagent-artifacts/ffbfa5ad-4870-4c5f-8960-e61a2c7f5a25_delegate_output.md`

**agent-vault**

- session `agy_zzlee-X299-UD4-Pro-dc0a_b6a76584-1e01-491d-a80c-059a6a56e893`（「Agent Work Progress Handover」，2026-11-11，26,510 則）
- brain 目錄 `~/.gemini/antigravity-cli/brain/b6a76584-1e01-491d-a80c-059a6a56e893/SC7F0-Packet-DMA-Protocol-Fix-and-Verification-Report.md`（11-11 16:22；訊息 #26153 tar SHA、#26158 COMMIT 前 log）
- 相關 pi session：`01a1c8d2`（11-11 14:02 Vivado／gate `pass_gate:false`）、`01a1c8a3`（11-11 14:10 修復）、`01a1c9c1`（11-11 16:40 合併）

**本 repo 檔案**

- `rtl/zu4ev_pcie_card_top.v:20`（`C_VERSION = 32'h2610_2901`）
- `scripts/impl_sc7f0_dual_video.tcl`（無 version／git／timestamp generic 注入）
- `scripts/run_rebuild_26110301_vcu.sh:4,9,10`（已刪 ROOT 路徑、`SC7F0_ENABLE_VCU=1`、`TIMING_GATE=record`）
- `scripts/build_sc7f0_dual_video_hw.sh:17`（預設 `strict`）
- `scripts/build_sc7f0_matching_ps_vcu.sh:33-35`（僅接受 26102902／26110301）
- `test_app/qpcie_upgrade.c:464-469`（`--status` 亦執行 `setpci COMMAND=0x06`）
- 歷史基線文件：`docs/sc7f0_continuous_todo.md`、`docs/sc7f0_dual_video_worklog.md`、`docs/sc7f0_build_package_flash.md`、`docs/sc7f0_full_profile_r6_review.md`、`docs/sc7f0_pkt_dma_stage_restore_261110_report.md`（自註「`PASS … over 0 packets` 為空集合 PASS」，不可跨日與 11-11 結論併讀）、`docs/sc7f0_r3_upgrade_report_20261030.md`、`docs/sc7f0_r7_signal_recovery_4k60_20261029.md`

**SHA 清單（完整性聲明）**

- 完整 SHA：HEAD `aea86126bda15af8d200c79aa62b853fc57f3b39`；R6 XSA `3a39c1faf5d2e14c1fb5d68aa171030fc65bbba58511f64b406e0e9d880b3075`、R6 embedded bit `f70a2cb61c42ff3175c2191203a8cdae5c636b1f627377a4202d6a384ee06d3e`（後兩者屬 10-28 世代歷史紀錄）
- **縮寫（原報告只記錄片段，未在此補全，亦未編造）**：tar `0efab7acd945839d…d6dd3236`；eMMC `f08402c1…`／`46da8a2e…`／`14c14ece…`；三包 `879897…`／`8b0f0f…`／`0efab7…`；BOOT.BIN `a115bd05`／`60a44567`／`f08402c1`；debugd `e200063c…`；`sc7f0_pkt_dma_test` `0ff0af47`；`qpcie.ko` md5 `cbb6a311…`；11-11 bitstream `b741ae81…`
- 身分雜湊以外的身分標記：`card_epoch=eb404516`、PS `boot_id 3b788648-35e2-42de-bc7c-4d59f7a272e0`、driver srcversion `2BA9C2B03340C193808943C`

---

## 追加（2026-11-11 18:50，僅連結，不改寫上方 17:40 快照）

本报告（A）的交付/可重現性後續由 B1 追蹤：**
[docs/sc7f0_full_package_rebuild_20261111.md](sc7f0_full_package_rebuild_20261111.md)**。

B1 目前狀態（要點，詳細證據與完整 SHA 在該檔）：

- 新建可重現全量入口 `scripts/build_sc7f0_vcu_release.sh`（preflight/fpga/ps/package/all，強制
  `SC7F0_ENABLE_VCU=1`、`SC7F0_TIMING_GATE=strict`，拒 `record`/寬減）；舊入口
  `scripts/run_rebuild_26110301_vcu.sh` 已退役為路標（它硬碼已删 worktree 且用 `record`）。
- 身份（`C_VERSION`/`GIT_COMMIT_HASH_DEF`/`BUILD_TIMESTAMP_DEF`）改為在**重新啟動綜合前**套用，
  並從 `synth_1` 實際產物反查（已對真實 run script/runme.log 驗證綁定值）。
- 第一輪 `26111102` **失敗**（身份驗證 proc 自身的 Tcl 缺陷 `incr -1 i`，綜合完成後才中止 →
  無 bit/XSA/PS image）。事後 drift 工具如實判定 `SOURCE_DRIFT_BITSTREAM_FATAL`，因此**不续跑、
  不改 scope、不假指紋**，改走新一輪完整 build；事證在
  `build/vcu-release-26111102-r1/NOT_DEPLOYABLE`。
- 第二輪 `26111103` 進行中（`build/vcu-release-26111103-r1`）：preflight 已過（198 tests、
  0 非預期失敗）、fpga scope 指紋 `93db3a21…` SOURCE_IDENTITY_STABLE。
- 上列「今日能動仍靠包外檔」的兩項缺口已進 packaging：`sc7f0_vcud` recipe+systemd unit 入影像；
  `qpcie_debugd` 由現源碼重建（影像內舊版是 0x800 mailbox **之前**的）。另更正一項事實：
  出廠影像其實已有 `libOMX.allegro.*`/`liballegro_*`/`al5d·al5e` 韌體，所以缺口不是「OMX 庫完
  全不在 rootfs」。驗證方法一律為**實解 `image.ub`**（純唯讀 FIT/cpio 解析），不看 staging 目錄。
- COMMIT 備份語義已修（世代保留、同版重試不得抹掉前一代、未完成交易絕不删、空間不足在複製前
  拒絕）；host testbench 全過。本階段**未部署/未烧錄/未改板上檔/未重啟/未 commit**；B2 仍需獨立
  review 後才可進行。

### 追加最終狀態（2026-11-11 20:30，B1 階段結束交還）

- 輪次 `26111103` **停在 strict gate**：综合/佈局/路由全部完成且設計本身健康
  （WNS +0.053 ns、WHS +0.010 ns、WPWS 0.000 ns、bus-skew +1.442 ns、
  179530/179530 全路由、0 路由錯誤），但 strict 閘門以 **14 項 CDC/約束理由**駁回並保留 XSA：
  主根因是 `u_dualpath` 的 8 個 `dp_pkt_*` probe（clk_pl_0 域）直接餵進
  `u_dma_top/u_axil_reg_space/u_status`（`xpm_fifo_async`，寫入側 `pcie_user_clk`）的 `din`，
  共 296 筆 CDC-13，外加 TIMING-6/7（`clk_pl_0` 舆 `pcie_user_clk` 無 common primary clock/node）、
  CDC-12×10、CDC-10×28、CDC-26×416 舆 13 個未約束 IO。
- 因此**沒有** bitstream / hardware.xsa / image.ub / upgrade tar，也沒有進 PS 階段舆打包；
  未放宽 gate、未動 `rtl/`（`SOURCE_RTL.sha256` 78/78 仍 re-verify OK）或約束。
  **如實記錄**：本輪結束後改了 `scripts/build_sc7f0_vcu_release.sh` 舆
  `scripts/check_sc7f0_timing.py`（両者均在 r3 的 `SOURCE_FPGA.sha256` 名單內），故最終
  `gates/source-drift-final.json` 判為 `SOURCE_DRIFT_BITSTREAM_FATAL` —— 意義只是 r3
  永不可打包（它本來也沒有產出任何artifact），而非已有位元流失去追溯。
  事證：`build/vcu-release-26111103-r1/NOT_DEPLOYABLE`、`gates/timing-gate-record.json`、
  `gates/checker-before-after.json`、`gates/gate-failure-handover.json`。
- 下一動作（由父代理另派）：先獨立唯讀 review `u_status` 各埠時鐘域，再派 coder 實施 A 方案
  正確 CDC 修正 + 13 個 IO 約束，然後**新一輪完整凍結 build**。B2 持續封鎖。

### 進度連結（2026-11-11 B2-prep checkpoint）

- A 方案第一步已落地：`in_pkt_*` 定性為同域 `pl_clk0` 並改為直連 `u_bank`，
  `qpcie_status_cdc` WIDTH **2063→1743**；296 筆 CDC-13 的根因就此修正為
  **B1 包裝器產生器回歸**（詳見 B 報告同名 checkpoint 表格第 1 項）。
- Reset 結構改寫（新增 `rtl/sc7f0_reset_cdc.v`，20×`sc7f0_reset_sync` +
  5×`sc7f0_event_reset`）與 probe 7 條 3FF 鏈已寫入工作樹，但 **xsim 與任何
  Vivado 階段均未跑**，因此 CDC-10/12/13 是否消失仍是未知數。
- 唯讀 DCP 深挖證據 **BLOCKED**（`build/evidence-b2prep-26111104/BLOCKED-dcp-probe.md`）：
  因此 **RX DDC 首級同步器只有 RTL 結構證據、routed 層未證明**，13 個 HIGH 非同步
  IO 約束與兩層 gate / 套件備份項 **未動**。
- **B2 仍封鎖**：未 full build、未部署、未燒錄、未 commit（HEAD 仍 `aea8612`）。
  逐項狀態與指紋見 [B 報告末尾 checkpoint](sc7f0_full_package_rebuild_20261111.md)。

### 進度連結（2026-11-12 套件/備份/閘門定稿，纯本機）

- 最新一輪：[B 報告 §15](sc7f0_full_package_rebuild_20261111.md) — source inventory
  舆角色清單（bitstream 入力 vs. validation 證據）、PS runtime 位元組來源（舍
  `@present` 舆 `find … | head -1`）、打包段 required-test 與 release gate 只讀本輪
  正軌證據、備份空間/保留小修、release 入口封斜徑。
- 正式交付物（程序，非驗收紀錄）：
  [SC7F0 release deploy / acceptance runbook](sc7f0_release_deploy_acceptance_runbook.md)
  — B2 順序、R0 恢復基線、GStreamer 5 分鐘併發驗收舆恢復程序。
- 状態未變：**未 full build、未 SSH、未部署、未燒錄、未装 driver、未動 MCU**；
  **恢復能力 = 未證明（BLOCKED）**，需先在真機完成 runbook §2。

### 進度連結（2026-11-12 fresh 完整建置輪 26111202）

- 本輪報告：[sc7f0_full_build_26111202.md](sc7f0_full_build_26111202.md)
  — preflight PASS / **FPGA FAIL**（`capture_clk_300m` 同域 -0.225 ns、399 端點；
  `clkout2`/`phy_rxoutclk`→`clk_pl_0` 未具名審查的非同步路徑持有 WNS -2.760）/
  CDC-12舆 CDC-13 已歸 0、CDC-10 28→13（剩 6 條無人審查）/ PS・package 依規則未啟動，
  `build/vcu-release-26111202-r1` = **NOT_DEPLOYABLE**、**沒有包**。
- **R0 已首次在真機唯讀執行**（`build/r0-baseline-20261111T155509Z/`）：現行 eMMC 三檔與
  `/home/rd/upgrade-26111101.tar` 逐位元組相符（tar sha256 `0efab7ac…`），但 BOOT 散檔
  `sc7f0_vcud`（sha256 `d296e75d…`，正由 `/proc/3852/exe` 執行）不在任何包內 ⇒
  **B2（燒錄解鎖）仍 BLOCKED**；本輪仍**未**部署/燒錄/重啟/装 driver/動 MCU/git commit。

### 進度連結（2026-11-12 局部：`u_reader` 300 MHz 同域臨界圓錐重寫，纯仿真）

- 對象（26111202 §4.1/§5.1 真失敗，非本輪新創）：`capture_clk_300m` 同域
  **WNS -0.225 / TNS -26.973 / 399 端點**，代表路徑 `u_dualpath/u_reader/remaining_reg[10] →
  tx_last_be_reg[2]`（3.547 ns = logic 1.251 + route 2.296、12 級、2×CARRY8）。
  真實 module 為 **`rtl/sc7f0_ps_packet_reader.v`**（`rtl/sc7f0_dualpath.v:184` 實例化 `u_reader`，
  `clk=mem_clk`）。凍結報告路徑走 `chunk_bytes[6/8]_*` → `arlen[7]_i_3` → `tx_first_be[3]_i_6/
  _i_2` → `tx_last_be[2]_i_1`，即「三段串聯 32-bit 鉗位 min + 同週期全部衍生欄位」同一圓錐。
- 改法（**不改**時鐘頻率/約束/政策/閘門；狀態序列、封包協定、4 KiB 規則、ready-valid 回壓不動；
  **零新增狀態、零新增延遲**）：
  1. `rtl/sc7f0_ps_packet_reader.v:54-97` — `next_chunk` 由串聯 32-bit 比較鏈改為三段**平行** 9-bit
     飽和鉗位 + 平衡 min（結果恆 ≤ 256 ⇒ room 先鉗 256 無損，min 具結合/交換律 ⇒ 逐位元相同）；
     beat 數用同一定理在 16-byte 域算 `ceil(min)/16-1`，`tx_dw_len` 用免進位式
     `(cb+3)>>2 == cb[8:2] + |cb[1:0]`。
  2. `:116-122` PREP 只留 `chunk_bytes/arlen/araddr/read_index/tx_payload` 清零；
     `:123-142` 把 `tx_addr/tx_dw_len/tx_first_be/tx_last_be/read_beats` **推一拍**到 AR 註冊 ——
     這些欄位最早在 SEND 才被消費（`tx_valid=state==SEND`，READ 至少佔 1 週期），運算式**原字照搬**，
     只把運元由組合 `next_chunk` 換成已註冊的 `chunk_bytes/arlen`（值相同 ⇒ 等價可證）。
  3. `:34/:105/:140/:161` 新增 1-bit `last_chunk`（在 remaining/chunk_bytes 仍未變動時捕獲），
     取代 WAIT→state 的 32-bit `remaining==chunk_bytes` 比較（同值，早一週期計算）。
- 新增 **`tb/sc7f0_ps_packet_reader_tb.sv`**（922 行；**先寫 TB、先跑未改版作基準**）：300 MHz 即時鐘、
  AXI-R slave VIP（隨機 AR/R 空隙、rresp／短 burst／長 burst 注入）、封包匯收 VIP（隨機 + 1200 週期
  `tx_ready` 停、`done_ready` 滿）、逐 byte payload 比對（只比 byte-enable 涵蓋欄，規則同
  `rtl/rq_tx_encoder.v`）、4 KiB 不跨界雙端檢查、`first_be/last_be` 全集合、completion record 64 byte
  逐 byte、每 job 恰一份報告、`valid && !ready` 期間資料凍結、reject/error/reset-abort 後可再收。
  案例：拒收 10（非空指令、零封包、error=1）、len=0+EOS、**1..64 全长度**、16-byte 位移 1..20、
  beat/chunk/4K 邊界 24 種、4K 雙端臨界 6 種、注入錯誤 3、隨機 backpressure 90、長停 2、
  reset-abort 後重收、**4K60 真 frame（NV12 Y=8,294,400 / UV=4,147,200）**、最大合法 0x800000。
  固定 seed `0x13579BDF`（log 內 `TB_SEED`），每 job 有 cycle watchdog 與可定位 progress 行。
- A/B 實測（`iverilog 12.0`，log 在 `/tmp/rdr-ab/`）：
  改前/改後**整份 log 逐行相同**（full：diff=0 行）—jobs=238、data_pkts=89,548、records=228、
  **逐 byte 比對 payload = 22,777,094 byte**、ar=89,552、beats=1,423,721、穩定性檢查 7,432、
  `chunk_min=1 chunk_max=256`、`first_be_seen=808a last_be_seen=808b`（可達集合 {0,1,3,7,f} 全覆蓋）、
  兩邊 `READER_TB_PASS`／`vvp_exit=0`。參考對照 `tb/sc7f0_dualpath_tb.sv`（Vivado 2023.2 xsim）
  改前改後皆 `DUALPATH_SIM_GATE_PASS`、`tlps=334 enabled_bytes=79481`（同值）。
- 局部 OOC（單模組、3.333 ns、**非 route 收斂證據**）：改前最差 `remaining_reg[14]→arlen_reg[6]`
  **13 級 / -0.523 ns**；改後最差 `source_reg[5]→chunk_bytes_reg[0]` **6 級 / +1.235 ns**。
  （`place_design` 在此空壳 OOC 兩邊都 103 errors 放置失敗，故只有 postsynth 估計值可比。）
- **明確未做**：未跑全板 build/route、未部署/燒錄/重啟、未動 PS・driver・MCU・constraints・閘門、
  未 `git add/commit/push`（`git diff --check` 乾淨）。本節**不得**解讀為時序已收斂：300 MHz 是否
  修好只能由下一輪全新 freeze route 實測；且 26111202 凍結的 `timing_summary.rpt` 對 399 個失敗端點
  **只列舉 1 條**（同域另有 `u_ps_capture` HLS 核心），本改動只涵蓋已被證實的代表圓錐。

---

## 尾記連結（2026-11-12）

- 本 A 報告之後的「上一階段成果實測验收」（復用 `upgrade-26111101.tar` → 標準 VERIFY/COMMIT/reboot → host driver 編譯安裝 → 桌面/H264 5 分鐘測試結果與受阻原因）：
  [sc7f0_previous_stage_acceptance_20261112.md](sc7f0_previous_stage_acceptance_20261112.md)
