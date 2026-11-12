# SC7F0 26111204 標準 PCIe 燒錄 + host driver + GStreamer 五分鐘驗收（2026-11-12）

執行者：本輪唯一地端部署/驗收代理（未 spawn 子代理）。
驗收基準：**USER_WNS_ONLY_ACCEPTANCE**（Vivado `WNS>=0` 即接受；其他警告如實記錄，
未跑 strict 全域 release gate，不另加 Critical0/strict policy 門檻）。
`release.json` 的 `deployable:false` 保持原樣未改，未偽造 strict metadata。

## 0. 結論總表

| 項目 | 結果 | 主要證據 |
|---|---|---|
| 包身分/SHA/成員/manifest | **PASS** | `logs/01`…`07`、本檔 §1 |
| 標準 `--package` → VERIFY `0x05` | **PASS** | `logs/08-package-verify.txt` |
| 恰一次 `--commit` → `0x04` | **PASS** | `logs/09-commit.txt` |
| 重啟前獨立 eMMC SHA 讀回（三檔全對） | **PASS** | `logs/09-commit.txt` |
| 標準 `--reboot`（PS warm reset + PCIe rescan） | **PASS** | `logs/10-reboot.txt` |
| 新 boot 實據：PL `0x26111204` / 新 PS boot_id / eMMC SHA / host boot_id 未變 | **PASS** | `logs/11`,`12` |
| 新 daemon ABI `0x800`（status `ready=1` + exec 成功 + banner + sha） | **PASS** | `logs/15-new-daemon-vcud-service.txt` |
| host driver 由本包 source 在測試機編譯 / 安裝 / reload | **PASS** | `logs/13`,`14` |
| 開機自動服務（4 支 qpcie/sc7f0 daemon active；vcud enabled 於 image 內） | **PASS（vcud 除外）** | `logs/15` |
| 卡端 `sc7f0-vcud.service` 能工作 | **PASS（僅在補完 ②b 節點格式＋順序後；冷啟自動成功仍未成立）** | `logs/55`,`56`,`64`、§13 |
| IT6663 已鎖但 FPGA RX 未鎖的恢復（一次既有 runtime reset） | **PASS（24 s 恢復，不需 cold reboot）** | `logs/22`–`26`、§12 |
| 卡端 media graph 4K60 pad 匹配（sink 先、source 後） | **PASS（REQBUFS EINVAL 解除）** | `logs/30`–`33`、§12.2 |
| video0 桌面全畫面（真 HDMI 流，5 分鐘真顯示） | **PASS（300 s，60.0 fps，drops 0）** | `logs/37`,`39`,`40`、§12.3 |
| video1 硬體 H264 → MP4，兩路重疊 ≥300s | **PASS（300.13 s，17998 幀，25 Mbps，卡端 ERR=0）** | `logs/59`–`63`、§13 |
| 完整 MP4 分析（ffprobe / ffmpeg -v error / PTS-DTS） | **PASS（解碼 rc=0 無解碼錯誤；來源 packet PTS/DTS 整數嚴格單調、重複 0 倒退 0；keyframe 600）** | `logs/60`,`62`,`63`,`66`、§13 |
| 測試機 host 整機重啟 / 桌面重啟 | **未做（禁止）** | — |
| I2C 寫入 | **已做 1 次（授權範圍）**：`i2ctransfer -y 0 w2@0x32 0x06 0x01`（MCU runtime restart，非 MCU 重燒） | `logs/24`,`25`,`26`、§12.1 |
| 卡端執行期設定（media-ctl / v4l2-ctl / systemctl start-stop） | **已做；無 unit drop-in、無 `/etc` 覆蓋、無換 binary** | `logs/46`,`55`,`64`、§13.4 |
| source 設定、RTL/XDC/production code 改動、git stage/commit | **未做**（本輪未改任何原始碼；`test_app/sc7f0_vcud.cpp` 與 HEAD 一致） | `git status --porcelain test_app/sc7f0_vcud.cpp` 空 |

## 1. 交付包（唯一來源）

- 路徑：`build/wns-fix-20261112T044035Z/release-26111204-r1/release/upgrade-26111204.tar`
- sha256 `708aa91821b1f18f89bec717e427e9502f486d8a8d4e7ef7fb3b5ed7703e93eb`，size 50,595,840
- 成員（ustar，0644，uid/gid 0）：`BOOT.BIN` 9,554,960 `59b7ea0e…934e`、
  `image.ub` 41,033,200 `b68e417e…9b`、`boot.scr` 3,474 `14c14ece…ad6`、
  `manifest.sha256` 225（內容三檔 digest 與上列一致）
- host-tools-src.tar.gz `7b995b52ed8be6db3fa0d6d1885c5f41b602bac5f57e2488f3b36a6ed66c9c7e`
- host-driver-src.tar.gz `2eb88d88da2605c079f90680faf9431f45cd65a23755bdf4f567cf274eb179afe`
- 三檔 SHA 在**本機**與**測試機**各自核對一致（`logs/07`）。
- 板上目標/開機參數：新 PS `cat /proc/cmdline` =
  `earlycon console=ttyPS0,115200 clk_ignore_unused root=/dev/ram0 rw`，
  **不含**已知錯誤的全域 `cma=1000M`（`logs/12`）；此項沿用既有
  `MEMORY_LAYOUT_PASS` / `SC7F0_CAPTURE_IMAGE_AUDIT_PASS` 證據，未重構。
- 未使用 `petalinux/qpcie-zu4ev/images/linux/BOOT.BIN`（舊 10/20 那份）或 26111101 包。

## 2. 前置狀態（燒錄前）

- 測試機 `sc7f0-test` / `192.168.190.247`，host boot_id
  `0da5af1d-5cd4-4d22-9a13-5908ad64c5dd`（燒錄前後相同）。
- PCI `03:00.0` = `12ab:e380`，LinkSta 8GT/s x4。
- 舊 PL：`0x26110301` / Git `0x2BCE1D81`；舊卡 boot_id
  `b8a77c32-483a-400b-8771-ae392ab3cbe4`；`/etc/sc7f0-recovery-release`
  = `sc7f0-ps-watchdog-20261027-r2`, `PL_BASE_VERSION=0x26110301`。
- 舊 eMMC 三檔 SHA（回滾用）：`BOOT.BIN f08402c122790e1914fa137d03c476c109700f349f607161c94c87147f689e76`、
  `image.ub 46da8a2ebe16395ceb7485c8604d66958a96b6c1ee85071ee5b5d3d8a2d773f9`、
  `boot.scr 14c14ececc4b35eb6ac10253f06a0f3dad10b7750d7283a7892676288df3bad6`。
- 無任何 capture/upgrade 程序在跑；`/dev/video0,1` 無人持有；`/` 可用 363G。
- 舊包 daemon 為 **H2C 0x400**，因此 preflight 的 PS 讀取一律用既有
  `/home/rd/sc7f0ctl_compat400`（`sudo` 下 status 4.3 ms、exec echo 18 ms 成功），
  未重演錯地址。`qpcie_upgrade --status` 屬更新流程正常副作用（含 setpci），不稱純讀。
- 備份（未刪除任何原檔）：`/home/rd/backup_predeploy_26111204_20261112-145824/`
  （`qpcie.ko`、`qpcie.ko.installed` sha `5afbe45d…`、`qpcie_upgrade c6947a40…`、
  `sc7f0ctl 0e3a824f…`、`sc7f0ctl_compat400 5d08fafd…` + `BACKUP.sha256`）。
  卡端 eMMC 舊檔另有升級 daemon 內建 backup+readback。

## 3. 標準燒錄序列（每步實際 stdout/rc/時間已存檔）

host 工作目錄 `/home/rd/deploy-26111204-20261112/`，工具由本包
`host-tools-src.tar.gz` 以 `test_app/Makefile` 標準參數編譯（未改碼）：
`gcc -O2 -Wall -I. -I../include -o sc7f0ctl_800 sc7f0ctl.c`、
`gcc -O2 -Wall -I. -o qpcie_upgrade_new qpcie_upgrade.c -lm -pthread`；
編出檔 sha 分別 `0e3a824f…`、`c6947a40…`，與測試機既有安裝版**逐位元組相同**。

| 時間(UTC) | 動作 | rc | 關鍵輸出 |
|---|---|---|---|
| 06:59:02→06:59:08 | `--package upgrade-26111204.tar` | 0 | Package SHA-256 `708aa918…`；`HELLO 0x06`；push 50,595,840 B @23.6 MB/s；canary PASS；`VERIFY reached 0x05`；`VERIFIED in 6.4s. eMMC is unchanged.` |
| 06:59:08 | `--status` | 0 | `Upgrade Status : 0x05 (VERIFIED (awaiting --commit))` |
| 06:59:15→06:59:22 | **恰一次** `--commit` | 0 | `COMMIT reached 0x04`；`SUCCESS: eMMC upgrade committed and board-verified!`；status → `0x04 (Previous Flash Succeeded)` |
| 06:59:2x | 獨立 eMMC SHA（compat400，重啟前） | 0 | `59b7ea0e…`／`b68e417e…`／`14c14ece…` 三檔全對 |
| 06:59:28→06:59:33 | 標準 `--reboot` | 0 | `Requesting PS warm reset + PCIe rescan (not board POR)`；host 端 device 重新出現，driver 自動 rebind（dmesg 107271） |

未重送 COMMIT、未裸 `cp` BOARD BOOT、未手動更新 daemon、未清 slot。

## 4. 新 boot 實據（獨立於 host）

- 新 800 client：`ABI=1 ready=1 card_epoch=0bf769dc`（06:59:47，一次成功；未多 client 輪試）。
- 一次有界 `exec` 讀回（`logs/12`）：
  - 新 PS **boot_id `02750a3d-0981-41ce-bdcc-ac0f82d38684`**（舊 `b8a77c32-…` ⇒ 實際換過 image 並重新開機）
  - eMMC 三檔 SHA 再次全對（`59b7ea0e…`／`b68e417e…`／`14c14ece…`）
  - `/etc/sc7f0-recovery-release` → `PL_BASE_VERSION=0x26111204`
- PL 版號：host sysfs `version` = `v38.17.18-variant4 (Git: 09C2C4F5, Date: 20261112, Caps: 0x1001011F)`；
  `--status` → `Hardware Version 0x26111204`、`Git Commit Hash 0x09C2C4F5`（= frozen dirty fingerprint）。
- **host boot_id 未變** `0da5af1d-5cd4-4d22-9a13-5908ad64c5dd`（host 未重啟）。
- 結束前複核（07:03:24，`logs/21-endstate.txt`）：`ready=1 card_epoch=0bf769dc`、
  PL 仍 `Git 09C2C4F5`、AER correctable/nonfatal/fatal 計數全 0。

## 5. daemon / 服務（新 image 內，非 BOOT 散檔、非 host push）

- `/usr/bin/qpcie_debugd` sha `c3a8ad14191cd7c09fa2c3c75475c17e698b8cbb020e8a2583344b7ccdcb1287`
  （= production-daemons 指紋），banner `qpcie_debugd mailbox ABI h2c=0x800 c2h=0x1000`；
  新 800 host client 實測 `status`/`exec` 皆成功 ⇒ 前後端 ABI 匹配。
- `systemctl is-active`：`qpcie-debugd` `qpcie-upgrade-daemon` `qpcie-hdmi-daemon`
  `sc7f0-ps-watchdog` = **active**；`sc7f0-vcud` = `activating`（見 §7）。
- `sc7f0-vcud.service`：`/lib/systemd/system/sc7f0-vcud.service`，
  `Loaded … enabled`，`ExecStart=/usr/bin/sc7f0_vcud --live`，
  卡端 `/usr/bin/sc7f0_vcud` sha `4f3999033e345319850ce63f6b1de173f54313ff0ff45cef102abcd0fe04c551`。

## 6. host driver（依使用者順序：燒完之後才做）

- 於測試機以其自身 `uname -r = 7.0.0-42-generic` + `/lib/modules/…/build` headers，
  解 `host-driver-src.tar.gz`（sha `2eb88d88…`）後 `make -C drv/driver`（tar 內原 Makefile，未改碼）→ `build_rc=0`。
- 產物 `/home/rd/deploy-26111204-20261112/drv/driver/qpcie.ko`
  sha `5411639e897c2877f2da4d6472f0b4150acf8b968da2ea892666c751597ae7c2`，
  `vermagic 7.0.0-42-generic SMP preempt mod_unload modversions`，
  `srcversion 2BA9C2B03340C193808943C`（與燒錄前已載入模組**同 srcversion**，代表原安裝版即同一份來源）。
- 安裝：`cp` 至 `/lib/modules/7.0.0-42-generic/extra/qpcie.ko` + `depmod -a`；
  確認 `refcount=0` 且 `fuser`/`lsof` 無人持有 → `rmmod qpcie`（**rc=0，未用 `-f`**）→
  `modprobe qpcie`（rc=0，07:00:11）；載入後 `initstate=live`、srcversion 相同、
  module parameters 維持 `sg_fetch_mode=2`、`force_sgl_fetch=N`。
- 重建 `/dev/video0`（NM12/RGB3/NM16，HDMI/TPG input，`Force HDMI RX`）與
  `/dev/video1`（`H264`/`HEVC` compressed，即卡端 VCU 硬體編碼路徑）。
- 建置警告如實記錄（非錯誤）：`compiler differs …`（同版本不同 prefix）、
  `pahole … You are using: 0`、`Skipping BTF generation … unavailability of vmlinux`。

## 7. 兩個阻塞點（各讀一次證據即停，未反覆 debug；**分開記錄，未宣稱同因**）

### B1 — Xilinx `v_hdmi_rx_ss` 未 lock ⇒ 兩路皆無資料（host 側可重現）

- host `hdmi_status` = `Status: No Locked Timing` / `Receiver: Xilinx v_hdmi_rx_ss`。
  **燒錄前 06:58:01（舊 PL 0x26110301）即為同一狀態**（`logs/06`），
  故此阻塞非本包/本次燒錄造成。
- host 端REQBUFS 可成功（1920x1080 的 buffer/SG desc 已成功建立），但
  `dmesg: qpcie-dma 0000:03:00.0: STREAMON refused: HDMI RX source not ready (5V=0x00000003, err=-67)`
  （`logs/19`、`logs/20`；`STREAMON refused` 共 2 行）。
  ⇒ `gst-launch v4l2src ! fakesink` 兩路都在 `Buffer pool activation failed` /
  `not-negotiated (-4)` 停止（`logs/16`）。
- 一次（且僅一次）依 AGENTS 規定用**已驗證 MCU proxy** 唯讀 IT6663 RXP0
  （`sc7f0_it6663_dump.py`，`data+status-v1`，下游 I2C 狀態逐筆檢查；無 bank 寫入、無 arbitrary MMIO）：
  `bank=0x00` 前後穩定、`r13=0xbf`（cable_5v=1、clock_stable=1）、
  `r14=0xff`（symbol_lock=1、hdmi_mode=1、bit7=1）、`r19=0xb0`（SCDT lock=1），
  兩次 `0x98..0xAA` 位元組完全一致 ⇒ `timing_valid=YES`，
  H active 3840 / total 4400，V active 2160 / total 2250（≈4K60；pixel clock 未量測，不推算 FPS）。
  證據：`build/deploy-26111204-20261112/logs/17-it6663-readonly.txt`、`18-it6663-readonly-human.txt`。
- **判讀更正（依父代理指示）**：`r14` bit7 是 **TMDS scrambling 指示**，
  **不可**等同「HDCP 已認證/加密」；本輪**不**主張 HDCP 為原因，也**不**要求使用者關閉 HDCP。
  依 AGENTS：IT6663 已 lock 且回報格式時先查下游 Vivado/PHY/PS 鏈；本表現在此記錄為
  「下游 v_hdmi_rx_ss 未 lock」，與本專案既有「TX/SCDC 永久 re-handshake 尚未修好」記載相符，
  但本輪未再做任何下游修復或追加診斷。

### B2 — 卡端 `sc7f0-vcud.service` 啟動迴圈（card 側，獨立記錄）

- `journalctl -u sc7f0-vcud`（讀一次）：
  `Hardware Packet DMA detected: Magic=0x44505631 ("1VPD") Version=0x00010000`、
  `vcu_encoder_config @ 0xA0000100 (magic=0x56435543)`、
  `vcu_host_ring @ 0xA0000200 (magic=0x56435552)`、
  `Initializing Live DMA-BUF Zero-Copy Pipeline…` →
  **`[VCUD ERROR] VIDIOC_REQBUFS failed: Invalid argument`** → `status=255/EXCEPTION`，
  `Restart=always` 每 5 s 重啟（restart counter ≥6）。
- daemon 開啟的是卡端 `/dev/video0`（`video-capture output 0`，VIPP），
  該節點 `VIDIOC_QUERY_DV_TIMINGS` = `Inappropriate ioctl for device`。
- 未宣稱 B2 與 B1 同因；未改 service、未手動推 binary、未做 I2C/MCU 重啟、未補配置。

> **後續更新（同日 07:12–08:00 UTC）**：本節是當時的一次性讀取記錄，保持原樣。
> 之後在授權範圍內確實做過：一次 MCU runtime reset（§12.1）、media graph 與節點格式的
> 執行期設定（§12.2 / §13.2）、以及 `systemctl stop/start`（§13.3）。
> B2 已解除且**未改 service／未推 binary**；B1 與 B2 仍屬**兩個獨立**問題，未同因。

### 其他一次觀察（不延伸）
- 一次 4K NV12M probe 曾出現 `qpcie-dma … dma alloc of size 4194304 failed`
  （boot 以來 dmesg 計數 **1**；host `MemAvailable 30.1G`、`CmaFree 62844 kB`）。
  之後 1920x1080 probe 的 buffer 可分配，失敗點變成 `STREAMON refused`，
  故本輪不把 DMA 配置失敗當主阻塞，僅記錄。

## 8. 五分鐘並行實測與 MP4 分析：**當時 NOT_RUN → 已於 §13 以實測補齊**

> 2026-11-12 07:46–07:52 UTC 已完成真正的雙路 5 分鐘並行實測與完整 MP4 分析，見 **§13**。
> 本節保留為「當時尚未能跑」的原始狀態記錄（就緒檢查結果仍有效），不得與 §13 混讀。

- 未執行：`video0 v4l2src → queue → waylandsink fullscreen=true`、
  `video1 v4l2src(H264) → queue → h264parse → mp4mux → filesink`，
  亦無 ≥300 s 重疊、無新 MP4，因此 `ffprobe` / `ffmpeg -v error` 全片解碼 /
  PTS 顯示序與 DTS 解碼序分開檢 / max gap / 尾端截斷檢 / fps-drop-packet_stats
  **全部 NOTRUN**。**未**以舊歷史 MP4 或 `x264` 軟編、`fakesink` 冒充。
- 已完成的就緒檢查（供 resume 直接用）：
  - `gst-inspect-1.0`：`v4l2src` YES、`waylandsink` YES、`h264parse` YES、`mp4mux` YES、
    `queue` YES、`filesink` YES（`v4l2h264enc` NO——不需要，H264 由卡端 VCU 產生）；
    `ffprobe`、`ffmpeg` 在 PATH。
  - 桌面 session：`loginctl` session **3 / uid 1000(rd) / seat0 / tty2 / active**，
    `gnome-shell` pid 3510，`XDG_SESSION_TYPE=wayland`、`XDG_RUNTIME_DIR=/run/user/1000`、
    `DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus`；`/dev/dri/card1`、`renderD128` 存在。
    未輸出憑證、未 `xhost +`、未 fake DISPLAY、未重啟 desktop。
  - 輸出目錄約定：host `~/sc7f0-validation/<timestamp>/`（尚未建立，因為沒有 MP4）。

## 9. 可恢復資訊 / 未做的事

- 原包仍在卡上（新包 `26111204` 已生效；舊包指紋見 §2，host 備份檔見 §2；
  host 原 `qpcie.ko` 備份 `5afbe45d…`）。本次**沒有**新增任何未記錄動作。
- 未做：MCU 燒錄/重啟、I2C 寫入、來源端設定、RTL/XDC/production code/config 改動、
  單獨覆蓋板上 PS/PL binary（含 RAM）、git add/commit/push、host 整機或桌面重啟、
  任何 `sudo reboot`（cold reboot 保留給使用者本人）。
- `git diff --check` 僅 6 行 trailing whitespace，全部在**先前已存在**的 PetaLinux
  產生檔（`configs/gen-machineconf.log.old:3817`、`configs/rootfsconfigs/Kconfig.user:22,25`），
  **不是本輪修改**；本輪只新增 `build/deploy-26111204-20261112/logs/*` 與本文件。

## 10. 下一步（最小阻塞點，2026-11-12 08:00Z 最終更新）

本輪三個阻塞已全部解除，且**不需改任何原始碼**：

1. RX 未鎖 → 一次既有 MCU runtime reset（§12.1，24 s）。
2. VCU `REQBUFS EINVAL` → graph pad 匹配（§12.2）。
3. VCU `Initial VIDIOC_QBUF: EINVAL` → **缺的是執行期初始化順序**：graph pad → VIPP 節點
   `--set-fmt-video=...NV12` → 再開 `sc7f0-vcud`（§13.3）；不是 daemon 原始碼/DT 問題。

**尚未完成（下一輪的固化工作）**：把①②②b 固化進開機流程（最小 recipe/service 或開機 script），
並重出完整 PS 包；在此之前，整包**冷啟後 `sc7f0-vcud` 仍會進入 QBUF EINVAL 重啟迴圈**，
本檔驗收的是「燒錄 + 執行期初始化 + 雙路取樣」，不是「冷啟自動 PASS」。
完整步驟已寫入 [sc7f0_build_package_flash.md](sc7f0_build_package_flash.md) 的「燒錄後必要步驟」①②②b③。

## 12. 局部恢復 + 五分鐘實測（同日 07:09–07:25 UTC 追加）

本节两项已升格為「燒錄後必要步驟」清單（見 `docs/sc7f0_build_package_flash.md`），
不再當作可選 recovery。**目前仍需手動執行，未固化入開機自動流程。**

### 12.1 IT6663 已鎖、Xilinx RX 未鎖 → 一次既有 runtime reset（已驗證）

- 基線（`logs/22`,`23`，07:09–07:12Z）：IT6663 bank0 / cable5V / clock / symbol / SCDT 皆鎖、
  幾何 3840×2160（4400×2250）穩定且兩次時序一致；但 host `hdmi_status` = `No Locked Timing`、
  host `--query-dv-timings` 全 0、卡端 `hdmi_info` = `Mode: DVI / No input stream detected`、
  `/dev/v4l-subdev2` = `Link has been severed`、`xilinx-vphy`=2 / `xilinx-hdmi-rx`=2（僅開機初始化）
  ⇒ 與 `docs/sc7f0_r7_signal_recovery_4k60_20261029.md` §1 逐項同型。
- 操作（使用者明確授權、恰一次；`logs/24`）：
  `sudo /home/rd/sc7f0ctl --timeout 5 exec 'i2ctransfer -y 0 w2@0x32 0x06 0x01'`
  → **rc=0、0.0158 s**（I2C bus0、從址 0x32=NUC1262 MCU、寄存器 0x06=0x01 = **MCU runtime restart**；
  不是 Xilinx RX/VPHY 局部 IP reset、不 flash、不改 IT 組態、不動 PL/eMMC）。
- 效果（3 s 輪詢，`logs/24`,`25`,`26`）：07:12:20 執行 → **07:12:44（24 s，第 9 次輪詢）**
  `Status: Signal Locked / 3840x2160p / Pixel clock: 594000000 Hz / mbus=0x100e`；
  卡端 `hdmi_info` = `3840x2160@60Hz RGB 8b 4PPC 594 MHz`；`/dev/v4l-subdev2 --query-dv-timings`
  = 3840×2160 total 4400×2250 progressive +vsync/+hsync **594 MHz / 60.00 fps**；
  `xilinx-vphy` 2→13、`xilinx-hdmi-rx` 2→2473；IT6663 複讀仍 4K60 鎖（`logs/25`）。
- 不是整卡 reset 的獨立證據：PS boot_id 始終 `02750a3d-0981-41ce-bdcc-ac0f82d38684`、
  host boot_id 始終 `0da5af1d-5cd4-4d22-9a13-5908ad64c5dd`、daemon `card_epoch` 始終 `0bf769dc`、
  AER correctable/nonfatal/fatal 全 0（`logs/26`,`41`,`42`）。**不需 cold reboot。**
- 禁止誤用：`r14` bit7 = **TMDS scrambling 指示，不得推為 HDCP 認證/加密**；本次未要求關 HDCP、未換來源。

### 12.2 卡端 media graph 4K60 匹配（已驗證推進一階）

- 原因（`logs/28`,`29`）：`b0060000.vpss-csc` = `/dev/v4l-subdev1`，開機 pad0 `RBG888_1X24/1280x720`、
  pad1 `VYYUYY8_1X24/1280x720`，而 hdmi-rx / frame-tap 皆 3840×2160 `field:none` ⇒ 尺寸不匹配。
  卡端 VIPP `get-fmt` 為退化值 `1920/0, YUYV, planes=0` → `REQBUFS → EINVAL`（即 `sc7f0_vcud`
  5 秒重啟迴圈的原因）；手動 `S_FMT NM12 3840x2160` 可成功但 `STREAMON → -EPIPE`。
  同時說明：**VCU 路徑不通不得全歸給 RX 未鎖**。
- 操作（先列舉不猜 code；`--list-subdev-mbus-codes pad=0` 回 `0x100e MEDIA_BUS_FMT_RBG888_1X24`；
  **分兩次**呼叫，sink 先、source 後；`logs/30`,`31`）：
  ```sh
  sudo /home/rd/sc7f0ctl exec 'media-ctl -V "\"b0060000.vpss-csc\":0 [RBG888_1X24/3840x2160]"'   # rc=0
  sudo /home/rd/sc7f0ctl exec 'media-ctl -V "\"b0060000.vpss-csc\":1 [VYYUYY8_1X24/3840x2160]"'   # rc=0
  ```
- 結果（`logs/32`,`33`）：`media-ctl -p` 両 pad 均 3840×2160 且 code 正確；
  vcud journal `V4L2 VIPP buffers allocated (8 buffers, DMA-BUF exported)` → REQBUFS 阻塞解除，
  一度 `ActiveState=active / ExecMainStatus=0`。
- 仍未解（`logs/34`,`35`）：隨後 `[VCUD ERROR] Initial VIDIOC_QBUF: Invalid argument`，
  `status=255/EXCEPTION`、`Restart=always` 迴圈（NRestarts 145→280）。
  已做一次「host 先開 `/dev/video1` 髮佈 VCU host ring」順序實驗，錯誤不變 ⇒ 非順序問題。
  属 image 內 `sc7f0_vcud` 代碼層缺陷，本次未授權改碼 ⇒ 如實回報，不擴修。

### 12.3 video0 桌面全畫面 5 分鐘（真測 PASS）

- 管線（無 fakesink、無軟編；queue 隔離、leaky=downstream 為直播顯示慣例設定）：
  `v4l2src device=/dev/video0 ! video/x-raw,format=NV12,width=3840,height=2160,framerate=60/1
   ! queue max-size-buffers=8 leaky=2 ! waylandsink fullscreen=true sync=false`
- 環境：rd uid 1000 / session 3 / tty2 / seat0 / `XDG_SESSION_TYPE=wayland`、
  `XDG_RUNTIME_DIR=/run/user/1000`、`WAYLAND_DISPLAY=wayland-0`（未 `xhost +`、未 fake DISPLAY、未重啟桌面）；
  顯示器 `card1-HDMI-A-1` 原生 `3840x2160`。
- 時間（monotonic）：start 07:18:27Z（warm-up 8 s 另列）→ 取樣窗口 07:19:05–07:23:35Z
  **10 × ≈30 s = 300.16 s 真重疊**，每窗 1800–1801 幀 ⇒ **59.97–60.01 fps**；
  總計 `ch0_frames` 於該串流生命期 18,489 幀（= 308 s × 60 ✓）；
  `ch0_drops=0`、`frame_drop_count=0 frames dropped`、`STREAMOFF: drained=1 video_errors=0`。
- 收檔：`SIGINT` → `Got EOS from element "pipeline0"`，`Execution ended after 0:05:08.169`，未 KILL。
- 真顯示的協定層證據（`logs/39`,`40`）：客戶端送出 `xdg_toplevel@17.set_fullscreen(nil)`，
  合成器回 `xdg_toplevel@17.configure(3840, 2160, array[4])`，視窗 20 s 内 `wl_surface.commit` 1200 次（≈60/s）。
  附記：gst-launch 會先報一次 `GStreamer-Wayland-CRITICAL gst_wl_window_ensure_fullscreen: assertion 'self' failed`
  （`fullscreen=true` 於視窗建立前就設定所致），隨後 `set_fullscreen` 仍送達且合成器回 3840×2160。
- 測試機產物：`/home/rd/sc7f0-validation/20261112T071827Z/`（`video0_fullscreen.log`、
  `fps-samples.txt`、`packet_stats.{before,after}`、`aer.{before,after}`、`wayland-debug-verify.log`）。
- **畫面流暢度由使用者肉眼判定，代理不代判。**

### 12.4 仍未完成（當時；已於 §13 解除）

- video1 硬體 H264 → `h264parse → mp4mux → filesink` 的 **五分鐘並行**：當時 NOT_RUN（卡在 §12.2 之後的 QBUF 錯誤）。
- 因此**無新 MP4** ⇒ `ffprobe` 時長/幀數、`PTS` 顯示序與 `DTS` 解码序分開檢、max gap/尾端截斷、
  `ffmpeg -v error` 全片解碼 error 0 等 **當時全部 NOTRUN**；**未**以舊 MP4、`x264` 軟編或 `fakesink` 冒充。

> **後續（同日 07:32–07:52 UTC）**：無需 cold reboot，也無需重燒/重裝 driver。
> 只要補上「VIPP 節點 `S_FMT` 再啟動 daemon」的順序（②b），兩路即真的有幀，
> 五分鐘並行與完整 MP4 分析已全部跑完 ⇒ 見 **§13**。
> 舊文本中「等使用者 cold reboot 後再續跑」的指示**作廢**：實測證明 RX 用既有 runtime reset 即可恢復，
> 而 VCU 用執行期初始化即可恢復；兩者都不需要斷電重啟。

## 11. Log 索引（本機 `build/deploy-26111204-20261112/logs/`，測試機同步留存於
`/home/rd/deploy-26111204-20261112/` 與 `/home/rd/backup_predeploy_26111204_20261112-145824/`）

`01-host-preflight.txt`、`02-card-preflight-compat400.txt`、`03-compat400-sudo.txt`、
`04-card-baseline-state.txt`、`05-backup-and-host-tooling.txt`、`06-video-caps-and-session.txt`、
`07-build-host-tools.txt`、`08-package-verify.txt`、`09-commit.txt`、`10-reboot.txt`、
`11-postboot-verify.txt`、`12-poll-new-daemon.txt`、`13-build-host-driver.txt`、
`14-install-reload-driver.txt`、`15-new-daemon-vcud-service.txt`、`16-bounded-capture-probe.txt`、
`17-it6663-readonly.txt`、`18-it6663-readonly-human.txt`、`19-negotiation-probe.txt`、
`20-host-dma-alloc-failure.txt`、`21-endstate.txt`、
`22-pre-reset-baseline.txt`、`23-it6663-before-reset.json`、`24-mcu-runtime-restart-once.txt`、
`25-it6663-after-reset.json`、`26-after-reset-card-vcud.txt`、`27-post-reset-capture-probe.txt`、
`28-card-vipp-graph-probe.txt`、`29-card-mediagraph-topology.txt`、`30-vpss-mbus-codes.txt`、
`31-graph-setup-pads.txt`、`32-graph-after-setup.txt`、`33-vcud-after-graph.txt`、
`34-vcud-journal-newerror.txt`、`35-video1-ordering-test.txt`、`36-prep-5min-wayland.txt`、
`37-video0-fullscreen-5min.txt`、`39-wayland-fullscreen-verify.txt`、`40-wayland-protocol-proof.txt`、
`43-post-run-state.txt`、`44-qbuf-einval-diagnosis.txt`、`46-graph-restore-hexcodes.txt`、
`47-vcud-with-correct-graph.txt`、`48-vipp-plane-count-probe.txt`、`49-vcud-state-and-graph-final.txt`、
`50-historic-mp4-anchor.txt`、`51`–`54`（vault 原始 toolcall 節錄）、`55-historic-init-replay.txt`、
`56-vcud-running-host-v1-probe.txt`、`57-v1-probe-ffprobe.txt`、`58-predual-state.txt`、
`59-dual-5min-run.txt`、`60-mp4-full-analysis.txt`、`61-dual-run-pipeline-logs.txt`、
`62-mp4-decode-check.txt`、`63-mp4-decode-classes-keyframes.txt`、`64-what-makes-it-work.txt`、
`65-final-handoff-state.txt`、`66-mp4-packet-pts-dts-stats.txt`（packet 整數 PTS/DTS 統計，
對應測試機 `…/20261112T074643Z-dual5min/packet_pts_dts_stats.json`）

## 13. QBUF 根因收斂 + 雙路 5 分鐘實測 PASS（同日 07:32–08:00 UTC 追加）

### 13.1 以 `/home/rd/vcu_live_capture.mp4` 為錨點的歷史成功鏈（vault 原始 tool 輸出，非摘要）

來源：已授權的單一 session `b6a76584-1e01-491d-a80c-059a6a56e893`（conversations DB steps）。
以下為**當時實際執行**的命令原文（只摘 VCU 相關欄位）：

| 面向 | 當時（2026-11-11，idx 23576/23602/23635/23649） | 本輪（2026-11-12） |
|---|---|---|
| 卡端 subdev | `v4l2-ctl -d /dev/v4l-subdev1 --set-subdev-fmt pad=0,width=3840,height=2160,code=0x100e,field=none`，pad1 `code=0x2100` | 同 code/尺寸/field（`media-ctl -V` 或 hex 形式） |
| 卡端節點 | `v4l2-ctl -d /dev/video0 --set-fmt-video=width=3840,height=2160,pixelformat=NV12`（idx 23602 回讀 `Number of planes : 2`，plane0 `Size Image 12441600`） | 同一形式；回讀 `NV12/3840x2160` |
| daemon 啟動 | `/run/media/BOOT-mmcblk0p1/sc7f0_vcud --daemon`（**BOOT 散檔 + 手動啟動**） | image 內 `/usr/bin/sc7f0_vcud --live`，由原 unit 啟動 |
| host 編碼管線 | `gst-launch-1.0 -e v4l2src device=/dev/video1 do-timestamp=true ! "video/x-h264,framerate=60/1" ! h264parse ! mp4mux ! filesink location=… buffer-mode=unbuffered`，30 s，`kill -2` EOS | 同管線，300 s，`kill -2` EOS |
| 產物 | `vcu_live_capture.mp4`：**本次 ffprobe 實測** `nb_frames=1841`、`duration=30.678833`、High@L5.2、`yuv420p`、`bit_rate=25,046,777` | `video1_h264_5min.mp4`：見 §13.4 |

**混合部署（使用者假設的部分證實）**：成功錄影實跑的是 BOOT 磁區散檔 `sc7f0_vcud`
（保留副本 81408 B，sha256 `d296e75d415a1fb15893504ec84f2a270f33b48eb81c0107c09dc46738162ada`，
卡端目前仍在 `/run/media/BOOT-mmcblk0p1/sc7f0_vcud`，本輪**從未執行**），而 26111101 包內
**不含 `sc7f0_vcud`/service**（既有文件記載）。該散檔的來源工作目錄
`/home/zzlee/vibecoding/sc7f0-dual-video/` 現已不存在 ⇒ **其來源 commit／原始碼身分：未證**。
⇒ 前版成功只證明「該 binary + 該執行期配置可跑」，**不證明整包冷啟可重現**。

### 13.2 `Initial VIDIOC_QBUF: Invalid argument` 的根因（實測收斂，非推測）

| 卡端執行期狀態 | `sc7f0_vcud` 結果 | 證據 |
|---|---|---|
| graph pad 仍 1280x720（開機預設） | `VIDIOC_REQBUFS failed: EINVAL`，5 s 重啟迴圈 | `logs/15`,`28`,`29` |
| graph pad 已 4K，但**未**對節點 `S_FMT` | `REQBUFS` 通過、`EXPBUF` 8 個成功、死在 `Initial VIDIOC_QBUF: EINVAL` | `logs/31`–`34`,`46`,`47` |
| graph pad 已 4K → **節點 `--set-fmt-video=` NV12** → 才啟動 | `ActiveState=active`、`ExecMainStatus=0`、`NRestarts=0`、無 QBUF 錯誤 | `logs/55`,`56`,`64` |

要點：
- `v4l2-ctl --get-fmt-video` 顯示 `Number of planes : 0` 是 **vipp 的回報怪癖**，不是阻塞點：
  同一狀態下卡端 `v4l2-ctl --stream-mmap --stream-count=1` 能捕到 12,441,600 B 完整 NV12 影格（`logs/55`）。
- `test_app/sc7f0_vcud.cpp` 的 V4L2 隊列契約在四個相關 commit（`3588f89`/`728e0f3`/`6c21b2a`/`ab96855`）
  **完全同型**：`VIDIOC_REQBUFS` 2 次、`VIDIOC_EXPBUF` 3 次、`Initial VIDIOC_QBUF` 1 次，而
  `VIDIOC_S_FMT`/`VIDIOC_G_FMT` **一律 0 次**（已逐 commit grep 驗證；目前 HEAD 與工作區同 sha256
  `24f6285acecc…`，本輪**未改一行程式**）。⇒ 節點格式一定得由**外部執行期**先設好；
  這是**初始化缺口**，不是 daemon 原始碼 bug。
- 選項形式差一個字元：`--set-fmt-video width=…`（空格）**靜默不生效**；必須
  `--set-fmt-video=width=…`。歷史 idx 23635 的腳本用的是空格形式並加 `|| true`，
  該次能成功是因為同一個 boot 內 idx 23602 已用 `=` 形式設過並留存。

### 13.3 本次成功到底靠什麼（逐項列出，含與原 image 之差）

| 項目 | 原 image（冷啟） | 本輪成功時 |
|---|---|---|
| daemon 檔 | `/usr/bin/sc7f0_vcud`，sha256 `4f39990325b1613538232496c88a60d91b5643476e824a7d4845682e82728650`（67672 B） | **同一檔、同一 SHA**（未換、未推檔） |
| 程序 argv | unit `ExecStart=/usr/bin/sc7f0_vcud --live` | `/proc/3404/cmdline` = `/usr/bin/sc7f0_vcud --live`；`/proc/3404/exe → /usr/bin/sc7f0_vcud` |
| CLI mode | `--live` | **沒換 mode**：原始碼預設即 `live_mode=true`，`--daemon` 只 fork/detach，兩者都進 `run_live_loop()` |
| unit | `/lib/systemd/system/sc7f0-vcud.service`，sha256 `a20dbacfc3ab720b21978138c1512b33a5327f7977f89e8dd8dff8a9b6a85a9a` | **同一檔**；`DropInPaths=` 空、無 `/etc/systemd/system/sc7f0-vcud.service`、無 drop-in 目錄 |
| 卡端執行期設定 | 無 | `media-ctl -V`／`v4l2-ctl --set-subdev-fmt`（pad0 `0x100e`、pad1 `0x2100`、3840x2160、`field=none`）+ `v4l2-ctl -d /dev/video0 --set-fmt-video=width=3840,height=2160,pixelformat=NV12` |
| service 操作 | 自動啟動（會迴圈失敗） | 只用 `systemctl stop/start/restart`（**未**改設定、**未** `daemon-reload`、**未** `mask`） |
| 其他 | — | **無 unit override、無手動散檔啟動、無單檔 binary 替換、無 git commit** |

> 備註：`pgrep -a sc7f0_vcud` 在 busybox 下只顯示 `/usr/bin/sc7f0_vcud`（argv 被截斷），
> 曾造成「好像沒帶 `--live`」的誤讀；以 `systemctl show -p ExecStart` 與 `/proc/PID/cmdline` 為準。

### 13.4 雙路 5 分鐘實測：**PASS**（真測，非模擬）

- 起迄：`2026-11-12T07:46:43Z → 07:51:44Z`；兩條管線皆 `Execution ended after 0:05:00.298`，
  以 `SIGINT` 優雅 EOS，**未使用 KILL、未截斷檔**。
- `/dev/video0` raw NV12 4K60 → `waylandsink fullscreen=true sync=false`：使用者目視桌面正常
  （流暢度由使用者判定，代理不代判）。
- `/dev/video1` 硬體 H.264 → `h264parse ! mp4mux ! filesink`：
  `/home/rd/sc7f0-validation/20261112T074643Z-dual5min/video1_h264_5min.mp4`
  - `size=937,883,624`、sha256 `3b933b36dc77b4a549b091cb5b23d52d8e8fd7831483b771e61e087aaaea1f96`
  - `nb_frames=17998`、`duration=300.133333`、`r_frame_rate=60/1`、`avg_frame_rate=134985/2251`（≈59.97 fps）
  - 3840×2160 High **Level 5.2**、`yuv420p`、bt709（range tv）、`field_order=progressive`、`refs=1`、
    `has_b_frames=0`、`nal_length_size=4`、`bit_rate=24,995,631`（format 24,999,119 bps）
  - **三層分開判讀（勿混）**：
    1) **影像解碼無損壞**：`ffmpeg -v error -i … -f null -` **rc=0**（21.2 s），
       輸出**無**任何 decode / corrupted / missing-reference 錯誤行。
    2) **來源時間戳狀態（直接對本檔 packet 整數值統計，`logs/66`）**：
       `time_base=1/6000`、17,998 個 packet，**PTS 與 DTS 皆嚴格單調**：
       遞增 17,997 / 17,997，**duplicate = 0、backwards = 0、non-increasing = 0**；
       `pts==dts`（`has_b_frames=0`，本就無重排理由）；`pts` 範圍 0 → 1,800,700 tick
       （首末跨度 300.1167 s）、packet `duration` 總和 1,800,800 tick = 300.1333 s、keyframe 600。
       影格間隔有**速率抖動**：標稱 100 tick，13,049 步恰為 100，其餘 4,948 步偏離，
       範圍 **3–532 tick（0.5 ms – 88.7 ms）**；這是間隔抖动，**不是**時戳順序錯亂。
    3) **null 輸出告警**：該 55 行（52 + 3 行 `Last message repeated`）
       `non monotonically increasing dts to muxer` 是 **ffmpeg null muxer 自身輸出端的
       timebase 量化告警**；因為來源 packet 整數 PTS/DTS 已證實嚴格單調，
       **不得**宜稱「來源 52 個 PTS 重複」或歸因為來源時戳缺陷。
       同理，`rc=0` 只代表解碼/語法，**不得**說成「全零錯誤輸出」（上面 55 行告警客觀存在）。
  - keyframe：**600** 個，間隔 0.499833 s（GOP=30，與卡端 `Periodic IDR frequency = 30` 一致）
- 卡端計數（**累計語意，非本輪增量**）：`Sent 18118 / 60.0 FPS / 25.78 Mbps`、
  `SUB=18118 DONE=18118 MSI=18118 ERR=0`；host dmesg `host_head <- ps_tail=18118`、`video_errors=0`。
  這些是 daemon 自啟動起的**累計**值（本 daemon 啟動後先跑過一次 120 幀 probe）。
- 穩定性：AER `cor/nonfatal/fatal` 前後**完全不變**（皆 0）；host boot-ID
  `0da5af1d-…c5dd`、PS boot-ID `02750a3d-…8684`、`card_epoch=0bf769dc` 全程未變 ⇒ 未重啟、未 reset。
- **入檔率／丟幀率：本輪不可計算（已撤銷先前記載）**。正式 5 分鐘開始前**未先取 `Sent` 基線**，
  只有跨測試的累計值（結束 18118；已知含先前 120 幀 probe）。因此：
  - 17,998 幀（MP4 實測）與 18,118（累計）**恰好差 120**，只能視為累計值的一致性旁證，
    **不得**據此宣稱 99.34% 入檔率或「丟 120 幀」；
  - `LIVE STAT` 的 `drops 7711 → 7769` 跳跨停流瞬間且為累計計數，**不得**當作正式 300 s 的 loss；
  - 也**不**宣稱零 drop。正式量法：於開始前先讀一次 `Sent`/`ps_tail` 基線再取 delta（本輪未做）。

### 13.5 殘留風險（如實記錄）

1. **冷啟自動化未成立**：①②②b 仍靠人工；開機後 `vpss-csc` 預設 1280x720 + 節點格式未設，
   `sc7f0-vcud` 會進入 QBUF EINVAL 迴圈（本輪實測多次）。固化需最小 recipe/service 或開機 script
   ＋重出完整 PS 包（**禁止單檔 binary 替換**）。
2. **影格間隔抖動**（非時戳錯亂）：packet 整數 PTS/DTS 嚴格單調（重複 0、倒退 0），
   但步距偏離標稱 100 tick 的有 4,948 步，範圍 3–532 tick（0.5–88.7 ms）。
   若下游要求嚴格定頻/strict-CBR，需另案處理卡端 pacer/時間戳；與先前的
   `null muxer` 告警**無關**（告警屬輸出端，不是來源缺陷）。
3. `packet_stats` 在此 host 的 debugfs 路徑不可讀（前/後檔 0 B），本次以 daemon 計數器
   ＋host dmesg ＋AER 佐證。
4. 本輪**未**重燒、**未**重裝 driver、**未**重啟 host/卡；歷史 MP4 **未**代替本次結果
   （本次新檔 §13.4 獨立可核）。

### 13.6 本節更正記錄（2026-11-12，僅分析/文書，未重錄、未改 source）

初稿有兩處**不能由當時證據直接推論**的主張，已依 packet 層實測更正：

| 項目 | 初稿（錯） | 更正後（實測依據） |
|---|---|---|
| `null muxer` 告警 | 「52 行告警 ⇒ 52 個來源 PTS 重複（0.29%）」 | 對本檔 17,998 個 packet 的**整數** pts/dts（`time_base=1/6000`）統計：
  **duplicate 0、backwards 0、non-increasing 0**，PTS/DTS 皆嚴格單調 ⇒ 告警是 **ffmpeg null muxer
  輸出端 timebase 量化告警**，不得歸因來源時戳缺陷（`logs/66`） |
| 入檔率 | 「17,998 / 18,118 = 99.34%，丟 120 幀（ring 停放）」 | `Sent`/`ps_tail` 為**daemon 啟動後累計**，且本輪正式開始前**未取基線**；
  120 恰為前置 probe 量 ⇒ **撤回入檔率與丟幀推估**，改記「跨測試累計計數，不能算本輪丢幀率」；
  亦不宣稱零 drop |

保留不變（已由實證支援）：一次 MCU runtime reset 24 s 恢復 RX、boot-ID 未變、
graph pad `RBG888_1X24`(0x100e)/`VYYUYY8_1X24`(0x2100) + `field:none`、
**節點 `--set-fmt-video=` 必在 graph 之後、啟動 daemon 之前**、
前版成功為 BOOT 散檔混合部署、以及**真的 300 s 雙路實測 PASS**。
本節未重錄、未 remux、未改 MP4、未改 source。
