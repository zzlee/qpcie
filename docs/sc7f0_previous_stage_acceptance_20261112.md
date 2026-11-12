# SC7F0 上一階段成果實測验收（2026-11-12）

- 執行時間：2026-11-12 09:31 → 09:50 CST（本機 `zzlee-X299-UD4-Pro`，唯一 worker，未 spawn 子代理）
- 倉庫：`~/qpcie`，branch `feat/zu4ev-sc7f0-bringup`，HEAD `aea86126`；**本次未改任何源碼／RTL／XDC／Make／recipe／腳本，未 `git add/commit/push`**
- 本地證據目錄：`build/previous-stage-acceptance-20261112/`（新建，不覆蓋任何既有 round 證據）
- 測試機證據目錄：`/home/rd/sc7f0-validation/20261112T014146Z/`
- 任務性質：**只驗證上一階段成果是否合規**（復用已驗包 → 標準燒錄 → host driver 編譯安裝 → 桌面顯示 + video1 H264→MP4 5 分鐘）。遇到無法通過的地方照實記錄，不自行改碼修。

---

## 0. 一句話結論

**標準燒錄與 host driver 兩段：PASS（有獨立證據）；5 分鐘桌面顯示 + MP4 錄影：NOT RUN（被兩個現場硬性故障擋住，非本次改動造成）**。
兩個故障是：(1) 卡端 PS debug mailbox 的 **命令通道**在本次官方 `--reboot` 之後失效（`status` 讀得到、`exec/echo/loopback` 一律逾時，重載 driver 與再做一次正常重啟都救不回來）；(2) PL HDMI RX **無鎖定時序**（`hdmi_status` = No Locked Timing、`QUERY_DV_TIMINGS` 無資料、STREAMON 40 秒 0 幀）。
因此本輪**不能**宣稱上一階段的桌面/H264 應用路徑合規；同時發現一個真实的 packaged 缺口：**VCU 編碼 daemon `sc7f0_vcud` 不在任何包內**（BOOT 分割區散檔），卡端一旦重開，H264 編碼路徑不會自立恢復。

---

## 1. 驗證對象與來源（復用既有包，**不是**新編譯）

| 項目 | 實測值 |
|---|---|
| 套件 | `/home/rd/upgrade-26111101.tar`（50,575,360 bytes，4 成員 ustar：`BOOT.BIN` `image.ub` `boot.scr` `manifest.sha256`）|
| 整包 sha256 | `0efab7acd945839d251587b1f0401091e703d5f97bd88087e3a4a4dbd6dd3236`（測試機與本機唯讀備份 `build/r0-baseline-20261111T155509Z/host-tars/` **逐位元組一致**）|
| BOOT.BIN | `f08402c122790e1914fa137d03c476c109700f349f607161c94c87147f689e76` |
| image.ub | `46da8a2ebe16395ceb7485c8604d66958a96b6c1ee85071ee5b5d3d8a2d773f9` |
| boot.scr | `14c14ececc4b35eb6ac10253f06a0f3dad10b7750d7283a7892676288df3bad6` |
| tar 內 `manifest.sha256` | 與上面三檔 SHA 完全相符（本機解包 `build/previous-stage-acceptance-20261112/pkgchk/` 驗算）|

- **明確立場**：本輪是「**復用既有已驗包**」，不是新編譯。未啟動任何本次 WIP 分支的 build，未新建置 bitstream/BOOT.BIN。
- 本機不存在任何可對應 `f08402c1` 的建置產物（全樹 `BOOT.BIN` 雜湊比對，只有本包解包檔與 R0 備份兩份，皆為同一個包的複製），也找不到 SHA 為 `b741ae81…` 的 `.bit`（全樹 `.bit` 比對 0 命中）→ 產生這個包的原始 build worktree 確實已不存在。

### 1.1 版本號不一致（照實分列，不為對數字重編）

| 來源 | 讀到/紀錄的值 |
|---|---|
| 套件檔號／檔名 | `26111101`（字串 `26111101` 不存在於 HEAD 任何檔案）|
| PL 實際登記（`qpcie_upgrade --status` 即時讀取）| `Hardware Version 0x26110301`、`Git Commit Hash 0x2BCE1D81`、`Build Date 0x20261103` |
| driver sysfs | `v38.17.3-variant1 (Git: 2BCE1D81, Date: 20261103, Caps: 0x1001011F)` |
| 卡端 `/etc/sc7f0-recovery-release` | `PL_BASE_VERSION=0x26110301` |
| 11/11 vault 報告 | 韌體 `0x26110301`、Git `0x2BCE1D81`、bitstream `b741ae81…` |
| HEAD commit | `aea86126`（2026-11-11 16:39）；`0x2BCE1D81` = commit `2bce1d8`（2026-10-27），即該 bitstream 落後 HEAD 11 個 commit |

→ 三者的 **PL 身分一致**（`26110301`/`2BCE1D81`），只有「包裝檔版本號 26111101」與 PL 登記號不同。這是既有命名問題，本輪未為對齊數字重編。

### 1.2 Vivado 時序（WNS）證據與缺口

- 用戶驗收標準：**僅 WNS ≥ 0 即算通過**；本次不加 CDC/DRC/Critical-0 門檻（如實記錄、不另加 policy）。
- 上一階段對應 bitstream 的時序宣稱只出現在 11/11 vault 報告文字（`WNS = 0.000`）。**原始 build worktree 已刪除**，本機沒有 SHA 為 `b741ae81…` 的 `.bit`，也沒有可綁定的 `timing_summary.rpt`。
  ⇒ 老實講：**「報表 ↔ 實物」綁不到**。本輪以既有報告 + 卡端即時 PL 登記（`2BCE1D81`）作為身分依據，WNS 數值本身無法在本地重算複核（記錄為證據缺口，不謊稱已複核）。
- 本地**其他**輪次的時序（**只列事實，不用來替代上面那顆 bit 的 WNS**）：
  - `build/vcu-release-26111103-r1/…/zu4ev_pcie_card_top_timing_summary_routed.rpt`：`WNS = +0.053 ns`、`WHS = +0.010 ns`、`All user specified timing constraints are met`；但該輪 `build.exit=1`（後續閘門失敗），`images/`、`release/` 皆空 ⇒ **沒有包**，也不是上一階段已驗收對象。
  - `build/vcu-release-26111202-r1/…/…_timing_summary_routed.rpt`：`WNS = -2.760 ns`（407 failing endpoints，`Timing constraints are not met`）→ **WNS < 0，依規定禁止燒錄**，本輪**未**使用、**未**燒錄。

---

## 2. 標準燒錄（正式流程，全部照 `scripts/sc7f0_flash.sh` 的既有官方序列）

工具身分：`/usr/local/bin/qpcie_upgrade`（root，2026-10-30 build；`--help`/source 已讀確認語意：`--package` 只 push+verify 不寫 eMMC，`--commit` 才寫，`--reboot` 是 PS warm reset + host PCIe remove/rescan，**不是** POR，不重啟 x86）。
本輪**沒有**使用本次新增的完整包腳本（其 metadata/CDC 加碼門檻不套在舊包上），也**沒有**替換任何板上單檔／debugd。

| 步驟 | 結果（實測輸出） |
|---|---|
| 連線 | `ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=8 rd@sc7f0-test.local`；主機 `sc7f0-test`、kernel `7.0.0-42-generic`、host boot_id `0da5af1d-5cd4-4d22-9a13-5908ad64c5dd` |
| 卡端身分 | PCI `0000:03:00.0` `[12ab:e380]` YUAN；`Kernel driver in use: qpcie-dma` |
| 是否有他人使用 | `fuser -v /dev/video0 /dev/video1` 空、無 `gst-launch`/`capture_verify` 程序、模組 refcount 0 ⇒ 卡閒置，非搶佔 |
| 磁碟空間 | 測試機 `/` 可用 363G；卡端 BOOT 分割區 `1463192` KB 可用（7% 使用）|
| 卡端服務（燒錄前）| `qpcie-debugd` / `qpcie-hdmi-daemon` / `qpcie-upgrade-daemon` / `sc7f0-ps-watchdog` 全 `active` |
| 遠端鎖 | `flock -n ~/.sc7f0-upgrade.lock` 取得成功（無併發 upgrade）|
| **VERIFY** | `--package /home/rd/upgrade-26111101.tar` → push 50,575,360 bytes @23.8 MB/s → staging DDR canaries PASS → **`VERIFY reached 0x05`（VERIFIED in 7.0s，eMMC unchanged）**，RC=0 |
| 官方備份 | `sc7f0ctl exec` → `/run/media/BOOT-mmcblk0p1/.backup_cli_20261112T013839Z/{BOOT.BIN,image.ub,boot.scr}` 三檔 SHA 與當時線上檔一致；**未刪改任何既有備份**（`.backup_upgrade` 原樣保留）|
| **COMMIT（僅一次）** | 09:38:49 開始 → **`COMMIT reached 0x04` / `SUCCESS: eMMC upgrade committed and board-verified!`**，09:38:56 結束，RC=0。**結果明確，無模糊狀態，未重送** |
| 獨立 eMMC 回讀（reboot 前，走 PS mailbox）| 三檔 SHA = `f08402c1…` / `46da8a2e…` / `14c14ece…` **與包內 manifest 完全相同**；BOOT 分割區散檔 `sc7f0_vcud`（81,408 B，mtime Nov 8 17:06）**未受影響** |
| **卡端 warm reboot** | 09:39:06 `--reboot` → 約 19 秒後 `sc7f0ctl status` = `ready=1`；**`card_epoch` 由 `eb404516` → `c22ee47a`（新啟動世代，獨立開機證明）** |
| host 未重開 | host boot_id 前後皆 `0da5af1d-5cd4-4d22-9a13-5908ad64c5dd`（未變）|
| AER / 錯誤 | `dmesg | grep -ci AER` = 0；`aer_dev_fatal/nonfatal` 各欄 0；driver re-probe 正常（`Node 0 → /dev/video0`、`Node 1 → /dev/video1`、ALSA Card #0 註冊成功）|
| 燒錄後 PL 版本 | `Hardware Version 0x26110301 / Git 0x2BCE1D81 / Caps 0x1001011F`、`Upgrade Status 0x00 (IDLE / Ready)` |

補充：因 eMMC 三檔在燒錄前就已與本包逐位元組相同（11/11 已燒同一包，`card_epoch=eb404516` 自 11/11 起未變），本輪 COMMIT 寫入的是**同一組已驗位元組**（非新映像）。`BOOT.BIN/image.ub/boot.scr` 的 mtime 由 `Nov 8 16:11` 變成 `Nov 9 07:23`（卡端 RTC 未同步），證明 eMMC 確實被重寫過一次。

---

## 3. host driver 編譯／安裝／載入身分（燒錄後進行）

- 來源：原 HEAD `aea86126` 的標準 driver bundle，依既有打包定義產生（`git ls-files -z driver include | tar --null -T -`，與 `scripts/package_sc7f0_vcu_release.sh:121` 相同），**未改一行代碼**。
  - bundle tar sha256：`f6a474c7fd801059bebaba7377d060a45fcb73f90095c00cb7e0b3f1e29aa6e1`（記錄於 `build/previous-stage-acceptance-20261112/host-driver-src-HEAD.tar.sha256`）
  - 11 個原始檔逐一 SHA 見 `build/previous-stage-acceptance-20261112/driver-HEAD-sources.sha256`
  - `git diff --stat HEAD -- driver/ include/` 為空 ⇒ 工作區 driver 未被本次 WIP 動過，HEAD 源碼即上一階段源碼
- 編譯環境：測試機自身 `/lib/modules/7.0.0-42-generic/build`（`uname -r` 相符），gcc 13.3.0；`make -C driver -j4` → **BUILD_RC=0**
  - 僅兩條無害 warning：`compiler differs`（同版本不同前綴名）、`pahole version differs`（BTF 跳過，非錯誤）
- **身分對照（關鍵）**：新編 `qpcie.ko` `srcversion = 2BA9C2B03340C193808943C`，與燒錄前測試機**已載入**模組的 `/sys/module/qpcie/srcversion` **完全相同**
  ⇒ 證明上一階段實測時跑的就是 HEAD 這份 driver 源碼（不是另外來源）。
  - 新 ko sha256 `5afbe45d3e65563cc18446c8fc480fc0053998184cd0339239d70c17df782dff`；燒錄前安裝檔 sha256 `8553adf5df7de234da1e94738d39002f2aa252bd21b3a8cf0b1efd090447ce23`（差在建置路徑/時間戳，srcversion 相同）
- 安裝過程（照 `sc7f0_flash.sh` 既有做法，先留檔再換）：
  1. `fuser -v /dev/video0 /dev/video1` → 空（無持有者）；`lsmod` refcount 0
  2. 留檔：`module-before.ko`（root，4,551,640 B）、`home-module-before.ko` 存於 `/home/rd/sc7f0-validation/20261112T014146Z/`
  3. `modprobe videobuf2-v4l2; modprobe videobuf2-dma-sg` → `rmmod qpcie`（**未用 -f 強制**）RC=0 → `insmod 新 ko` RC=0 → `/dev/video0`、`/dev/video1` 重新出現
  4. `install -D -m 0644 qpcie.ko /lib/modules/7.0.0-42-generic/extra/qpcie.ko` + `depmod -a` OK；`modinfo -n qpcie` 指向該檔；同步 `/home/rd/qpcie.ko`
  5. **未重啟測試機、未動桌面 session**（session 3、uid 1000、tty2、`Type=wayland`、`Active=yes` 全程保持）
- V4L2 能力實測（`v4l2-ctl --list-formats-ext`）：
  - `/dev/video0`（Multiplanar）：`NM12`、`NM16`、`RGB3`，1920x1080 / 3840x2160 / 4096x2160 @60.000 fps
  - `/dev/video1`（Capture）：`H264`、`HEVC`，同上尺寸/60fps
  - `v4l2-ctl --list-devices` 正常；ALSA `SC7F0 HDMI Audio` Card #0 存在

---

## 4. 桌面顯示 + video1 H264→MP4 5 分鐘：**NOT RUN（受阻）**

計畫本輪要跑的兩條 pipeline（取自上一階段既有報告 `SC7F0-Raw-Display-and-H264-MP4-Verification-Report.md`，未自創做法）：

```
# 路 1：真桌面全畫面（測試機 rd uid1000 active GNOME Wayland session 3/tty2）
gst-launch-1.0 v4l2src device=/dev/video0 ! queue ! waylandsink fullscreen=true sync=false
# 路 2：VCU 硬體 H264 直存（禁 x264 軟編）
gst-launch-1.0 -e v4l2src device=/dev/video1 ! video/x-h264,framerate=60/1 \
  ! h264parse ! mp4mux ! queue ! filesink location=<...>/vcu_5min.mp4
```

**實際受阻原因（兩項都與本次操作無關，且都無法靠改碼在本輪修）**：

### 4.1 卡端 PS 除錯 mailbox 的「命令通道」失效

- 症狀：`sc7f0ctl status` 正常（`ABI=1 ready=1 card_epoch=e890de41 card_beat` 持續遞增 ⇒ 卡端 `qpcie_debugd` 活著、mailbox 讀方向正常），但
  - `sc7f0ctl exec '…'` → **完全無輸出**（含 `uname -r`）
  - `sc7f0ctl echo PING123` / `loopback 64` → `Debug transport lost/timed out; command outcome may be unknown. NOT retried.`，RC=125
  - 由 `test_app/sc7f0ctl.c` 碼路判斷（兩種觀察到的形狀都指向 **H2C 命令路徑卡住**）：
    - `exec`：完全無輸出、也無錯誤訊息 ⇒ 對應 `transact()` 開頭的 `if (db_rd(DB_H2C_SEQ)!=db_rd(DB_H2C_ACK)) return 125;`，即 H2C slot 處於「已送未 ack」的卡死狀態，指令根本沒被卡端收走；
    - `echo` / `loopback`：出現 `Debug transport lost/timed out`（只在 `transact()` 等待回覆的迴圈結束時印出）⇒ `attach()` 階段成功（`DB_ACK_EPOCH` 有 ack、heartbeat 正常），但送令之後收不到 C2H 或 `ACK_EPOCH` 被清掉。
    - 卡端 `test_app/qpcie_debugd.c` 在「framing corrupt」、「in-flight 指令無法被取代」或 session 逾時時，會 `blocked=session; db_wr(DB_ACK_EPOCH,0)` 而後不再處理該 session 的指令 —— 與上述兩種症狀吻合（此為**症状對應碼路的判讀**，未做 MMIO 探測）。
- 已嘗試且**無效**的合法復原：重載 host driver（rmmod/insmod，未強制）、再做一次官方 `qpcie_upgrade --reboot`（第二次重啟後 `card_epoch=e890de41`）→ 仍然一樣
- 影響：
  1. **AGENTS.md 規定的 IT6663 唯讀判讀無法執行**——本專案唯一checked管道 `scripts/sc7f0_it6663_dump.py` 就是走 `sudo -n sc7f0ctl exec 'i2ctransfer -y 0 …'`（腳本自述：transport failure 不是「無信號」證據）。因此本輪**不得**也**未能**把「無影像」歸因於來源端；也無 UART、無 MCU 串列埠、卡端無已知 IP 可繞過去（測試機只有 `enp1s0` 一张網卡，`/dev/ttyACM*`/`ttyUSB*` 不存在）。
  2. **套件外 VCU daemon 無法啟動**（見 4.3）。
  3. 文件記載的 warm reboot 後 IT6663 既定復原步驟（`sc7f0ctl exec 'i2ctransfer -y 0 w2@0x32 0x06 0x01'`，MCU runtime restart，非重燒 MCU）同樣無法執行；本輪依指示**未動 MCU**。
- 可能方向（僅供後續調查，本輪未驗證、未改碼）：該 bitstream 的 PL git 登記為 `2BCE1D81`（2026-10-27），而 HEAD 的 `731c599` 註明「`DB_H2C_DATA` 已隔離到 0x800（與 BAR0+0x2200 的 VCU ring 讓開）」——已部署映像仍是 pre-0x800 佈局，測試機上同時存在 `qpcie_debugd` 與 `qpcie_debugd_0x800` 兩套卡端執行檔。此為**假設**，本輪未做 MMIO 探測（AGENTS.md 禁止任意 MMIO）。

### 4.2 PL HDMI RX 沒有鎖定時序（無影像資料可捕）

實測（燒錄後、兩次重啟後皆相同）：
- `hdmi_status`：`Status: No Locked Timing / Receiver: Xilinx v_hdmi_rx_ss`（telemetry 是新鲜的，代表卡端 publisher 活著，只是 RX 沒有 valid timing）
- `v4l2-ctl -d /dev/video0 --query-dv-timings / --get-dv-timings`：`failed: No data available`，Active 0x0、Pixelclock 0 Hz
- 有界捕幀實測：`v4l2-ctl -d /dev/video0 --set-fmt-video=width=3840,height=2160,pixelformat=NM12 --stream-mmap --stream-count=3`（外層 40 s timeout）→ **RC=124，未產出任何檔案，`ch0_frames=0`**、`ch0_status=0x00000300 (running=0, overflow=0)`、`frame_drop_count=0`
- driver 事件：`[V4L2 HDMI RX] Source change detected! status: 0x00000001 -> 0x00000003, res: 0x00000000 -> 0x00000000`

沒有訊號源時序 ⇒ `video0` 全畫面顯示與 `video1`（VCU 輸入同樣取自 HDMI RX）都無法進行。**本輪未用 TPG/fakesink 冒充顯示或錄影。**

### 4.3 真實 packaged 缺口：VCU daemon 不在映像裡（重開後不會自立恢復）

- 卡端 `sc7f0_vcud` 是 BOOT 分割區**散檔**：`/run/media/BOOT-mmcblk0p1/sc7f0_vcud`（81,408 B，sha256 `d296e75d…`，mtime Nov 8 17:06），執行方式為手動 `sc7f0_vcud --daemon`
- 映像內 `usr/bin/sc7f0_vcud` **不存在**、`sc7f0-vcud.service` **不存在**；`/etc/systemd/system/multi-user.target.wants/` 只有 `qpcie-debugd / qpcie-hdmi-daemon / qpcie-upgrade-daemon / sc7f0-ps-watchdog / tcf-agent / busybox-*`
- 本輪卡端重開之後（COMMIT 只寫三檔，散檔本體還在但）`sc7f0_vcud` **沒有被任何服務帶起來**，而唯一能手動啟動它的 PS 通道（4.1）已失效
- 结论：**`upgrade-26111101.tar` 不是自立完整的 H264 應用映像**；上一階段的 H264 路徑實測依賴「套件外散檔 + 手動啟動」。本輪依指示**未上傳/複製任何新 binary 到板子上修好它**。

### 4.4 因此本輪**沒有**產生新 MP4

- 沒有 5 分鐘重錄檔可交（`/home/rd/sc7f0-validation/20261112T014146Z/` 內只有 driver 源碼與 `module-before.ko` 備份）。
- **未**以 11/11 的歷史檔 `/home/rd/vcu_live_capture.mp4`（30.68 s）或卡端 `stream_60.h264` 冒充新錄結果。
- 流暢度由使用者人眼判斷；本輪無桌面流可看，故**不宣稱**任何流暢度結論。

---

## 5. 卡端／測試機**實際**變更清單（如實回報，不再宣稱「未部署」）

本輪**確實**動過硬體與測試機（皆在使用者明確授權範圍內：標準包燒錄、卡端正常重啟、host driver 編譯安裝/安全 reload）：

1. **卡端 eMMC 被寫入一次**（`COMMIT` 0x04 成功）。內容 = `upgrade-26111101.tar` 三檔（與寫入前逐位元組相同）。
2. **卡端被正常 warm reboot 兩次**（09:39:06、09:44:05）：啟動世代 `eb404516` → `c22ee47a` → `e890de41`；**卡端 `boot_id` 未能在本輪讀取**（exec 通道失效），獨立開機證明改用 `card_epoch` 變更 + driver re-probe 日誌 + BOOT 檔 mtime 變更。
3. **卡端 BOOT 分割區新增一個官方備份目錄** `.backup_cli_20261112T013839Z/`（三檔）。既有 `.backup_upgrade/`、散檔 `sc7f0_vcud`、`stream_60.h264` 未刪未改。
4. **卡端 `sc7f0_vcud` 目前**未執行**（重開後無 service 帶起）**；`qpcie_debugd`/`qpcie_hdmi_daemon`/`qpcie_upgrade_daemon` 由 systemd 帶起且 mailbox heartbeat 正常，但**exec 命令通道目前失效**（本輪結束時的現場狀態）。
5. **測試機 host driver 已被重新編譯並安裝**：`/lib/modules/7.0.0-42-generic/extra/qpcie.ko` = sha256 `5afbe45d…`（srcversion 不變 `2BA9C2B0…`，即同一份源碼），`/home/rd/qpcie.ko` 同步更新，`depmod -a` 已跑；舊檔備份在 `/home/rd/sc7f0-validation/20261112T014146Z/module-before.ko`（`8553adf5…`）。模組曾 `rmmod`/`insmod` 一次（未 `-f`），未重啟測試機、未動桌面。
6. 測試機新增目錄：`/home/rd/sc7f0-validation/20261112T014146Z/`（driver 源碼 + ko 備份）；`/tmp/accept-verify-*.log`。
7. **本機**新增 `build/previous-stage-acceptance-20261112/`（解包驗算、driver 源碼與 SHA、最終狀態留檔）；新增本報告。**未**新增/修改任何源碼、腳本、recipe、XDC、政策檔；未動 MCU；未碰 A50T SPI/私有 JTAG。

---

## 6. 驗收表

| 項目 | 判定 | 證據 |
|---|---|---|
| 選定上一階段已驗版本與可燒 image | **PASS**（復用既有包，身分清楚）| §1，整包/三檔 SHA、卡端即時 PL 登記 |
| Vivado 僅 WNS ≥ 0（報表↔實物對應）| **PARTIAL／Not Verifiable** | 上一階段 bit 的 WNS=0.000 只存在報告文字，原 worktree 已刪、本機無對應 `.bit`/rpt；本地可驗的 26111103 WNS=+0.053、26111202 WNS=-2.760（禁燒、未用）|
| 套件完整性／manifest／target／容量／非搶佔 | **PASS** | §2 前段 |
| 標準燒錄 VERIFY | **PASS** | `VERIFY reached 0x05`，7.0s |
| 標準燒錄 COMMIT（一次）| **PASS** | `COMMIT reached 0x04` SUCCESS，無模糊狀態 |
| 獨立 eMMC SHA 回讀 | **PASS** | 三檔 = 包內 manifest |
| 卡端正常 warm reboot + 獨立開機證明 | **PASS（以 `card_epoch` 變更為證）**；`boot_id` 無法讀取（exec 失效）| `eb404516→c22ee47a`（→`e890de41`）|
| host boot_id 不變 | **PASS** | `0da5af1d…` 前後相同 |
| host driver 編譯（測試機自身 headers）| **PASS** | BUILD_RC=0，vermagic `7.0.0-42-generic` |
| driver 安裝 + 安全 reload + 載入身分 | **PASS** | srcversion `2BA9C2B0…` 相符；refcount 0 時 rmmod；未 `-f` |
| V4L2 caps（video0 raw / video1 H264）| **PASS** | §3 |
| HDMI lock / 4K60 實況 | **FAIL** | `No Locked Timing`、`QUERY_DV_TIMINGS` 無資料、STREAMON 40 s 0 幀 |
| IT6663 唯讀判讀（AGENTS.md 步驟）| **BLOCKED** | 唯一 checked 管道依賴已失效的 `sc7f0ctl exec` |
| 桌面 video0 全畫面 5 min | **NOT RUN** | 無影像時序 +（重開後）無 H264 daemon |
| video1 VCU H264 → MP4 5 min + ffprobe/ffmpeg 完整解碼 | **NOT RUN** | 同上；且 daemon 不在包內、啟動通道失效 |
| MP4 完整性（ffprobe/ffmpeg）| **NOT RUN**（無新檔；不以歷史檔冒充）| §4.4 |
| 不改源碼／不 spawn／不動 MCU／不 commit | **PASS** | `git diff --check`、`git status` 僅新增文件；本報告 |

---

## 7. 留給下一輪的最小問題清單（本輪未自行修復）

1. `sc7f0ctl exec` 命令通道在本次官方 warm reboot 後失效（`attach` OK、`transact` 必死）。這是**目前唯一**的卡端 PS 通道，失去它就失去 IT6663 判讀、daemon 啟動、卡端 boot_id/服務查核。請先恢復这条通道（或提供第二條被认可的 PS 通道），否則任何「重開後」的應用層驗收都無法進行。
2. HDMI RX 無鎖定時序：需在 PS 通道可用後，依 AGENTS.md 順序先做 IT6663 唯讀判讀（bank/0x13/0x14/0x19 + 0x98..0xAA 兩次timing），再決定是否涉及來源端；本輪**未**把責任推給來源。
3. 打包缺口（真缺陷）：把 `sc7f0_vcud`（及其 unit，`ExecStart` 指向 `/usr/bin/sc7f0_vcud`）正式入影像；否則每次重開 H264 路徑都要套件外手動補救。
4. 版本命名：`26111101`（包）↔ `0x26110301/0x2BCE1D81`（PL 登記）不一致，且 `PL_BASE_VERSION` 標籤滯留；請一次收斂（本輪未為對數字重編）。
5. 證據可追溯性：上一階段那颗 bit 的 Vivado 報表與實物綁定已遺失（原 worktree 刪除）。後續任何要交付的映像，請把 `timing_summary.rpt`、`.bit` SHA、BOOT.BIN SHA、包 SHA 同輪留檔。

---

## 8. 2026-11-12 晚間更正（只縮小 §4.1／§7-1 的歸因；以上歷史輸出照原樣保留）

- **預設 `sc7f0ctl`（H2C 0x800）失敗 ≠ PCIe transport 死，也 ≠ `qpcie_debugd` 死。**
  同一現場改用已配對的既有客戶端實測（證據檔
  `build/current-mailbox-diagnosis-20261112T024025Z/run-025213Z/`，判讀見
  `docs/sc7f0_current_mailbox_diagnosis_20261112.md` §8–§9）：
  - `sc7f0ctl_compat400 --timeout 10 echo SC7F0_ABI400_TEST` → **rc=0、9 ms**、
    17 bytes 與輸入逐 byte 相同（`step3-single-echo.txt`）；
  - 同客戶端 `exec uname -r` → `6.1.30-xilinx-v2023.2`（`step5-exec-uname.txt`）；
    `exec cat /proc/sys/kernel/random/boot_id` →
    **`b8a77c32-483a-400b-8771-ae392ab3cbe4`**（`step6-exec-bootid.txt`）。
  因此 §4.1「唯一 PS 通道失效」的真正原因是已燒 26111101 包內 debugd 讀 H2C
  **0x400**（pre-`3588f89`）而測試機預設 client 寫 **0x800**（post-`3588f89`），
  兩者永不同窗；**不需要 cold reboot**，也無需恢復「第二條 PS 通道」。
  本次 echo 是會寫 mailbox 的正常交易（H2C SEQ 4→5、HOST_EPOCH/BEAT 更新），
  不是純讀取樣；§7 第 1 項由「通道損壞」改為「兩端 ABI 常數未先匹配」。
  適用範圍：本節結論只限本案例（已以 image 內 binary 的實際 H2C 存取指令／
  呼叫參數與 compat400 動態實測雙重確證）；其他 `echo`/`exec` 逾時仍須先核對兩端
  實際 binary 與工具，既不得直接判 daemon／transport 已死，也不得反向斷定 ABI
  必為原因。
- **仍獨立未解（不因上項結案）**：
  - §4.2 PL HDMI RX 仍為 `Status: No Locked Timing`（配對客戶端可用後 host
    `hdmi_status` 同一值，見 `step7-hdmi-status.txt`）；IT6663 唯讀判讀現在才有
    可行的 PS 通道，但 checked 腳本 `scripts/sc7f0_it6663_dump.py` 走預設 0x800
    客戶端，燒舊包期間仍需先解決配對。本輪仍未把責任推給來源端。
  - §4.3 `sc7f0_vcud` 與 `sc7f0-vcud.service` 不在映像內，重開後 H264 編碼路徑
    不會自立恢復；這是打包缺口，與 mailbox ABI 無關。
- 本文不改變 §2 的事實：該輪確實重燒了**同一個舊包**，那不是整包修正。

---

### 相關檔案

- 本次最終狀態留檔：`build/previous-stage-acceptance-20261112/final-state-host.txt`
- driver 源碼身分：`build/previous-stage-acceptance-20261112/driver-HEAD-sources.sha256`、`host-driver-src-HEAD.tar.sha256`
- 包解包驗算：`build/previous-stage-acceptance-20261112/pkgchk/`
- R0 唯讀基線（上一階段在跑狀態的原始證據）：`build/r0-baseline-20261111T155509Z/live-read-only.txt`
- 上一階段實測報告（外部 vault）：`SC7F0-Packet-DMA-Protocol-Fix-and-Verification-Report.md`、`SC7F0-Raw-Display-and-H264-MP4-Verification-Report.md`
