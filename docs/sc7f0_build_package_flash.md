# SC7F0：編譯、打包、燒錄三支 script

在開發機 `/home/zzlee/qpcie` 執行，不是在卡端 PS 或 x86 測試機執行。
本文驗收紀錄以 `0x26102204` 視訊基線為準，不代表卡端目前版本或即時狀態。

## 三行重跑

```sh
cd /home/zzlee/qpcie
./scripts/sc7f0_build.sh --version 26102205 --out build/sc7f0-retest-26102205
./scripts/sc7f0_package.sh --build build/sc7f0-retest-26102205
./scripts/sc7f0_flash.sh --build build/sc7f0-retest-26102205 --host rd@sc7f0-test.local
```

第三支會要求輸入 `YES`，才會寫 eMMC 及重啟**卡端 PS**；不重啟 x86。
指定新的版本號以遵守 RTL 版本規則；目前已驗收的是 `0x26102204`。
輸出目錄必須不存在，不能覆蓋既有驗證映像／rollback。編譯需要較長時間，
包含 3 種格式的完整 4K60 模擬、Vivado implementation 和 PetaLinux 建置。

本輪 FPGA/PS 編譯步驟均已實際完成。`sc7f0_build.sh` 是這些步驟的封裝，已做
shell syntax／dry-run 檢查，沒有為測試封裝再重做一次完整 FPGA build；
**`sc7f0_package.sh` 與 `sc7f0_flash.sh` 已完整實跑於本輪 `0x26102204`**。

## 1. `scripts/sc7f0_build.sh`

- RTL byte-exact、Python、archive、PS AXI、CDC、RGB/NV12/NV16 4K60 回歸。
- Vivado synthesis／route／bitstream；setup/hold、DRC、bus skew gate。
- 凍結相符的 `.bit`／XSA／reports，核對 XSA 內 bitstream。
- 將匹配 XSA 匯入 PetaLinux，建置 PS；保留 debug、HDMI、upgrade 三個 daemon。
- 保存 FSBL/PMU/ATF/U-Boot/DTB/image.ub/boot.scr 及 matched host driver/tool sources。
- `build.ok` 只會在成功時產生；輸出 `logs/build.log`、`SOURCE.sha256`、
  `COMPILED.sha256`。失敗時查看 `build.exit` 及 `logs/`。
- 不連測試機、不燒錄、不重啟。一次只允許一個 build/package 操作。

依賴本機既有的 Vivado/Vitis 2023.2、授權、`petalinux:latest` Docker 建置環境、
C/Cross compiler、iverilog、Python3、make。預設 Vivado 設定：
`/opt/Xilinx/Vivado/2023.2/settings64.sh`；可透過 `VIVADO_SETTINGS` 覆寫。
PS FIT 是實驗室版本，保留 PCIe root debug exec；不要視為未授權環境的 production image。

## 2. `scripts/sc7f0_package.sh`

- 只接受成功 build，檢查來源及已編譯 artifact SHA。
- 用同一份 bitstream、FSBL、DTB 等產生 BOOT.BIN。
- 產生嚴格 ustar：**只有 BOOT.BIN、image.ub、boot.scr、manifest.sha256**。
  不是把整個 build 目錄打進 tar，也不能省略 boot.scr。
- 使用與 PS daemon 相同的 C extractor／SHA verifier 做離線驗證。
- 產物：`upgrade-<version>.tar`、`release.json`、`RELEASE.sha256`、`package.ok`。
- 無硬體操作；不覆蓋已封存的 package。

## 3. `scripts/sc7f0_flash.sh`

測試機需要 SSH、免密 `sudo -n`、gcc/make/kernel headers，及既有
`/home/rd/sc7f0/bin/sc7f0ctl`。本版是針對目前 x86 測試機／aarch64 SC7F0 PetaLinux，
eMMC boot mount 為 `/run/media/BOOT-mmcblk0p1`。其他部署配置應先確認，不能猜測。

1. 核對 release SHA，將包與 matched source 傳到測試機。
2. **透過 sc7f0ctl exec** 檢查真正 PS 的架構及三個 daemon。
3. 在 x86 上針對該機 kernel 編譯 matched driver；拒絕正在使用 `/dev/video0` 的情況。
4. PCIe push／PS VERIFY；不接受 E1，不會忽略錯誤強行 COMMIT。
5. 備份 PS eMMC 三個 boot files 與 host module；載入及安裝 matched driver。
6. COMMIT；經 PS mailbox 獨立讀回三個檔案的 SHA。
7. 請求卡端 warm system reset／PCIe rescan（依賴活著的 PS upgrade daemon，**不是外部 POR**），等待 PS 回復，確認 active version 與三個 daemon；新流程還需比對 PS kernel boot_id。
8. 比對 x86 boot ID 未變。保留 remote logs／backups 的目錄路徑。

只有 VERIFY、不寫 eMMC、不換驅動、不重啟：

```sh
./scripts/sc7f0_flash.sh --build build/sc7f0-26102204 --verify-only
```

省略確認提示（確定要燒錄才使用）：`--yes`。
三支都支援 `--help`／`--dry-run`；dry-run 不接觸硬體。
`logs/flash.log` 保存燒錄紀錄。燒錄成功不等於視訊成功，下面仍需驗收。

## H2C mailbox 位址與前後端匹配（燒錄前必查）

`include/qpcie_debug.h` 的 `DB_H2C_DATA` 改過一次位址，新舊兩端不能混用：
`dc202ee`（2026-10-15）建為 **0x400**（`DB_PAYLOAD` 3072），
**`3588f89`（2026-11-09）改為 0x800／2048** — 理由是 0x400 與 BAR0+0x2200 的
VCU host ring（block 相對 0x200..0x43F）**尾端重疊**，命令文字會寫進 ring 區
（該 commit 註解寫「ring slot 7..15」，但依 64-byte header + 16×32-byte slot 的
算術只能得到 0x400..0x43F 這段尾端，slot 號未自源碼核對，不引用）。
`DB_C2H_DATA` 兩個版本都是 **0x1000**。

| 對象 | 卡端 daemon H2C | 配對 host 客戶端 | C2H | 備註 |
|---|---|---|---|---|
| 舊包 `upgrade-26111101.tar`（現階段在燒的那顆） | **0x400**（image.ub 內 debugd 的實際 H2C 存取指令／呼叫參數） | 只有 `sc7f0ctl_compat400` | 0x1000 | 僅供該舊包診斷；預設 `sc7f0ctl`(0x800) 與它不同窗 |
| 新完整包（本輪起的目標） | **0x800**（由當前源碼編譯的 debugd） | `sc7f0ctl`（預設 0x800） | 0x1000 | 標準組合；不要為遷就舊包把源碼退回 0x400 |

- `ABI=1`、`ready=1`、PL 版號欄（C_VERSION，本板停滯在 `0x26110301`）與 PL GIT
  登記欄（`0x2BCE1D81`）在新舊兩邊都相同，**不能**拿來協商 payload layout。
- `status` 正常而 `echo`/`exec` 逾時：**本案例**已由 image 內 binary 與 compat400
  實測確定是兩端 H2C 視窗不同窗；其他同症狀的情況先照下條逐項核對，不得直接判
  PCIe transport 或 daemon 已死。
- 匹配與否要按**實際 image 內的二進位**判定（解包後的實際 H2C 存取指令／呼叫參數、
  ELF SHA/BuildID）加上它對應的來源指紋，host 端則查實際要執行的那支工具自己的
  objdump（daemon 是 `read`，不只是比某個寫入立即數）。只比檔名（`qpcie_debugd` 與 `qpcie_debugd_0x800` 並存過）或照當前 header
  推定都不算證據；對任意 `0x400`/`0x800` 常數的 grep 也不是實測。
- 標準指令是 `test_app/sc7f0ctl`（新 ABI 0x800）；`sc7f0ctl_compat400` 是**舊包例外**，
  只在已證明卡端 daemon 讀 0x400 時使用。兩者都**不是唯讀工具**：`echo` 會依協定寫
  H2C 並更新 HOST_EPOCH/HOST_BEAT，屬正常交易，不可當成「純讀取樣」，也不得在 ABI
  不明時盲試客戶端。
- 舊包 + compat400 的實測旁證：
  `build/current-mailbox-diagnosis-20261112T024025Z/run-025213Z/`、
  `docs/sc7f0_current_mailbox_diagnosis_20261112.md` §8–§9。

## 測試機檔案放置與整理（2026-11-12 起強制）

測試機 `rd@sc7f0-test.local` 上所有 SC7F0 工具、腳本、原始碼、升級包、錄影、log 與暫存檔
**一律在 `/home/rd/sc7f0/` 下**；`/home/rd` 根目錄不得再新增任何檔案（既有非 SC7F0
專案／私人檔案不屬本規範，不變動）。細分用途與保留清單見測試機
`/home/rd/sc7f0/README.md`，搬移與刪除的逐筆記錄見
`/home/rd/sc7f0/docs/cleanup-20261112-moves.tsv` 與 `cleanup-20261112-deletions.tsv`。

現行入口使用的固定路徑（本檔指令例子已照此更新）：

| 用途 | 現行路徑 | 已停用舊路徑 |
|---|---|---|
| MCU/PS proxy（matching 0x800） | `/home/rd/sc7f0/bin/sc7f0ctl` | `/home/rd/sc7f0ctl` |
| 舊 0x400 daemon proxy | `/home/rd/sc7f0/bin/legacy/sc7f0ctl_compat400` | 不得當預設 |
| 升級 staging | `/home/rd/sc7f0/tmp/upgrade.XXXXXXXX` | `/home/rd/sc7f0-upgrade.XXXXXXXX` |
| 共用工裝鎖／互斥 | `/home/rd/sc7f0/tmp/.upgrade.lock`、`.upgrade.mutex` | `$HOME/.sc7f0-upgrade.lock`／`.mutex` |
| MCU runtime restart 紀錄 | `/home/rd/sc7f0/logs/mcu-restart-history` | `$HOME/.sc7f0-mcu-restart-history` |
| host 端腳本／build dir | `/home/rd/sc7f0/scripts`、`/home/rd/sc7f0/src/{driver,test_app,include}` | `/home/rd/*.py|.sh`、`/home/rd/{driver,test_app,include}` |
| 當行升級包 | `/home/rd/sc7f0/packages/26111204-r3/` | `/home/rd/upgrade-*.tar`（已入 `archive/review/packages/`） |

整理原則：只有「同 SHA 重複副本」、「可由 tar 重新解壓的解壓目錄」、「派生快取（pyc）」、
「被新路徑取代的 0-byte 舊鎖」可直接刪；其餘用途／保留不明的 SC7F0 檔案一律移
`/home/rd/sc7f0/archive/review/` 待判，不猜用途刪。歷史實測章節中的舊路徑保留當時事實，
新舊對照以 move-manifest 為準，不回頭改寫成新路徑冒充當時狀態。

## 實機抓幀／畫面確認

測試機上已有本輪驗證工具，可逐一測試（不要同時開多個 capture）：

```sh
/home/rd/sc7f0-nv-formats/capture_verify /dev/video0 NV12 hdmi 1800
/home/rd/sc7f0-nv-formats/capture_verify /dev/video0 NV16 hdmi 1800
python3 /home/rd/sc7f0-nv-formats/sc7f0_hdmi_preview.py --format NV12 --sink wayland --native-size --fullscreen
```

> 2026-11-12 整理實測：測試機上已無 `/home/rd/sc7f0-nv-formats/`（本次整理前就不在
> `/home/rd` 頂層）。上述命令只作歷史例子；若重建這個工具，一律放
> `/home/rd/sc7f0/bin/` 下，不得回到 `/home/rd` 根目錄。

`capture_verify` 的來源是 `test_app/v4l2_capture_verify.c`，可用
`make -C test_app v4l2_capture_verify` 建置。它實際 STREAMON/DQBUF，逐 plane
檢查 bytesused／sequence／error flags，可再加 dump 檔名保存完整一幀。
目前只將 3840×2160 作為這個小工具的驗收尺寸。

**reset 術語修正**：工具過去顯示「POR」不精確；目前 Linux/PSCI/PMU 路徑是 card warm **system** reset（不是 PMU 的 PS_ONLY subtype），不保證拉低板上 MCU／IT6663 reset 線。詳見 [PS watchdog 與 reset 範圍](sc7f0_ps_watchdog_20261024.md)。

## 燒錄後必要步驟（HDMI/擷取功能驗收清單，2026-11-12 於 0x26111204 實機驗證）

> 適用：新 800 mailbox ABI 組合（`sc7f0ctl` 0x800 + image 內 `qpcie_debugd` 0x800）。
> 這是**燒錄/重啟後的功能初始化與驗收清單**，不是可選除錯手段；但也**不是**無條件每次都做的動作。
> 目前 ② 與 ③ 仍需**手動**執行，尚未固化成開機 script/service；本文件不宣稱整包已全自動。

> **與 `scripts/upgrade.sh` 的界線（2026-11-12 修正）**：本清單是**影像功能**驗收，**不是**燒錄成功條件。
> 燒錄時**不要求**接 HDMI 來源，因此 `scripts/upgrade.sh` 不再等待或判定 RX lock、`3840x2160p` 時序、
> 包內 `SC7F0_CAPTURE_INIT`、`sc7f0-vcud` 是否 `active`、VIPP capture probe 或 `ch0_frames` 計數；
> 它只在結尾**讀一次**擷取狀態當參考（不輪詢、不判成敗），綠燈語意為「本套件已寫入 eMMC、獨立讀回、
> 並作為新映像啟動，且 MCU runtime reset 已恰一次執行」，**不得**宣稱 4K60／擷取／編碼驗收通過。
> 上表「已 lock 就跳過 reset」只適用於**人工**除錯路徑；`upgrade.sh` 內的 reset 是**無條件恰一次**，
> 不以訊號或 unit 狀態跳過。①②②b③ 屬後續 host driver／GStreamer 階段，接上來源後另驗。

### ① 必查兩層鎖；只在「上游已鎖、下游未鎖」時做一次 runtime reset

先讀兩邊（皆唯讀）：

```sh
sudo /home/rd/sc7f0/bin/sc7f0ctl status                                              # daemon 有回應
sudo -n cat /sys/bus/pci/devices/0000:03:00.0/hdmi_status                    # 下游 Xilinx v_hdmi_rx_ss
# 上游：既有的唯讀 IT6663 取樣（已驗證 proxy，回 bank/r13/r14/r19 + 兩次 0x98..0xAA 時序）
python3 sc7f0_it6663_dump.py --json
```

判定（**不要以 `r14` bit7 的 scrambling 推 HDCP**：那是 TMDS scrambling 指示，不等於 HDCP 已認證／加密，
據此要求關 HDCP 或換來源是錯的；也不得把 transport 失敗當成「無訊號」）：

| IT6663 | Xilinx RX | 處置 |
|---|---|---|
| 未 lock／無 cable 5V | 未 lock | 查來源/線材端，**不要**動板上 reset |
| **已 lock（clock/symbol/SCDT + 穩定幾何）** | **No Locked Timing** | 執行下方**一次** runtime reset，然後輪詢 30 s |
| 已 lock | Signal Locked | 跳②，**不要**多餘 restart |

```sh
# 只在上一列成立時執行，一次；不 i2cdetect、不試其他暫存器、不重試
sudo /home/rd/sc7f0/bin/sc7f0ctl exec 'i2ctransfer -y 0 w2@0x32 0x06 0x01'
# 輪詢直到真的出現 Signal Locked（實測 ≤30 s；2026-11-12 為 24 s）
watch -n3 'sudo -n cat /sys/bus/pci/devices/0000:03:00.0/hdmi_status'
```

這是 **NUC1262 MCU 的 runtime restart**（I2C bus 0、從址 `0x32`、暫存器 `0x06`=0x01），
**不是**重燒 MCU、**不是** Xilinx RX SS/VPHY 的局部 IP reset、也**不是** cold reboot；
它不動 PL bitstream、不動 eMMC、不動 PS/host。
2026-11-12 實測（`build/deploy-26111204-20261112/logs/24,25,26`）：rc=0 / 0.016 s →
24 s 後 `Signal Locked / 3840x2160p / 594000000 Hz`，卡端 `hdmi_info` 3840x2160@60Hz、
`/dev/v4l-subdev2 --query-dv-timings` 3840×2160 total 4400×2250 60.00 fps，
`xilinx-hdmi-rx` 中斷 2→2473（真的重跑交握），而 **PS boot-ID、host boot-ID、`card_epoch` 全未變**
⇒ 證明不是整卡/PS reset，**不需要 cold reboot**。
三支 script 不會暗中執行這一步；失敗就不要重試，先回報。

### ② 必查 media graph 各 pad 的尺寸／code／field 是否匹配當前輸入，**並接著顯式設定 VIPP 節點格式，順序固定**

開機後 `vpss-csc` 兩 pad 是 **1280x720 預設**，且卡端 VIPP `video-capture output 0` 是退化格式
（實測 `1920/0, YUYV, planes=0`）。上游換成 4K60 後若不匹配：
VIPP `REQBUFS` 回 **EINVAL**（`sc7f0_vcud` 會卡在 5 秒重啟迴圈）、
手動 `S_FMT 3840x2160` 可成功但 `STREAMON` 回 **‑EPIPE**（link validate 尺寸不符）。
**每次開機後、或輸入格式改變後都要重設**；若 `media-ctl -p` 已顯示各 pad 一致，就不用重寫。

```sh
sudo /home/rd/sc7f0/bin/sc7f0ctl exec 'media-ctl -p'          # 先讀：看各 pad fmt 與 /dev/v4l-subdevN 對應
# 4K60 範例（b0060000.vpss-csc = /dev/v4l-subdev1）：sink 先、source 最後，**分兩次**呼叫；
# 一次 media-ctl -V 同時設兩 pad 會讓兩 pad 都變 RBG888 且 Field Any → 又 -EPIPE
sudo /home/rd/sc7f0/bin/sc7f0ctl exec 'media-ctl -V "\"b0060000.vpss-csc\":0 [RBG888_1X24/3840x2160]"'
sudo /home/rd/sc7f0/bin/sc7f0ctl exec 'media-ctl -V "\"b0060000.vpss-csc\":1 [VYYUYY8_1X24/3840x2160]"'
sudo /home/rd/sc7f0/bin/sc7f0ctl exec 'media-ctl -p'          # 覆核：兩 pad 3840x2160、code 正確、field none
```

若 `media-ctl -V` 的符號名稱被拒（`VIDIOC_SUBDEV_S_FMT: Invalid argument`），改用同一個 code 的十六進位形式，
並顯式帶 `field=none`（2026-11-12 實測可用，`logs/46,55`）：

```sh
sudo /home/rd/sc7f0/bin/sc7f0ctl exec 'v4l2-ctl -d /dev/v4l-subdev1 --set-subdev-fmt pad=0,width=3840,height=2160,code=0x100e,field=none'  # RBG888_1X24
sudo /home/rd/sc7f0/bin/sc7f0ctl exec 'v4l2-ctl -d /dev/v4l-subdev1 --set-subdev-fmt pad=1,width=3840,height=2160,code=0x2100,field=none'  # VYYUYY8_1X24
```

### ②b **必做**：graph 設完之後，再顯式設 VIPP 擷取節點格式，最後才啟動 `sc7f0-vcud`

順序是**硬性要求**：`subdev pad0 → pad1 → /dev/video0 節點 S_FMT → 啟動 daemon`。
反序（先設節點或先起 daemon）會讓 `sc7f0_vcud` 死在 `Initial VIDIOC_QBUF: Invalid argument`。

```sh
# 注意選項形式必須是 --set-fmt-video=...（帶「=」）。寫成 --set-fmt-video width=... 會靜默不生效，
# 若再套 `|| true` 就完全看不出來（2026-11-12 與 2026-11-11 兩輪都踩過）。
sudo /home/rd/sc7f0/bin/sc7f0ctl exec 'v4l2-ctl -d /dev/video0 --set-fmt-video=width=3840,height=2160,pixelformat=NV12'
sudo /home/rd/sc7f0/bin/sc7f0ctl exec 'v4l2-ctl -d /dev/video0 --get-fmt-video | head -4'   # 覆核 3840x2160 'NV12'
sudo /home/rd/sc7f0/bin/sc7f0ctl exec 'v4l2-ctl -d /dev/video0 --stream-mmap --stream-count=1 --stream-to=/tmp/h.bin'  # 應產出 12441600 B
sudo /home/rd/sc7f0/bin/sc7f0ctl exec 'systemctl restart sc7f0-vcud; sleep 8; systemctl show sc7f0-vcud -p ActiveState -p ExecMainStatus -p NRestarts'
```

2026-11-12 實測（`logs/55,56,64`）：照此順序後 service `ActiveState=active`、`ExecMainStatus=0`、
`NRestarts=0`，`Initial VIDIOC_QBUF` 錯誤消失，卡端計數器 `SUB=120 DONE=120 MSI=120 ERR=0`。
執行這步**只需要** `systemctl stop/start/restart` 與 `v4l2-ctl` 執行期設定：**沒有** unit drop-in、
**沒有** `/etc` 覆蓋、**沒有**換 binary（`/usr/bin/sc7f0_vcud` sha256 `4f399903…` 與包內產物一致，
BOOT 散檔 `d296e75d…` 從未執行）。

2026-11-12 實測（`logs/30,31,32,33`）：設定後卡端 `sc7f0_vcud` 的 **REQBUFS EINVAL 消失**，
journal 出現 `V4L2 VIPP buffers allocated (8 buffers, DMA-BUF exported)` 並一路跑到
`OpenMAX VCU Hard IP Encoder Executing (Level 5.2 Auto, DMA-BUF Zero-Copy)`。

> **注意（已收斂的誤判）**：只有 graph 正確、但**沒有**跑 ②b 的節點 `S_FMT` 時，daemon 仍會死在
> `Initial VIDIOC_QBUF: Invalid argument`。這**不是** daemon 原始碼錯誤、也**不是** RX 未鎖：
> `G_FMT` 顯示 `Number of planes : 0` 是 vipp 的回報怪癖（同一狀態下卡端 `--stream-mmap` 仍能捕到
> 12,441,600 B 的完整 NV12 影格），真正的必要條件是 ②b 的「graph → 節點格式 → 啟動」順序。
> 詳情與證據見 `docs/sc7f0_26111204_flash_gstreamer_acceptance_20261112.md`。

### ③ 兩路都要「實際有幀」才算燒錄後功能驗收通過

```sh
# 原始路徑（host 端）
sudo -n v4l2-ctl -d /dev/video0 -V -v pixelformat=NM12,width=3840,height=2160 >/dev/null
sudo -n v4l2-ctl -d /dev/video0 -V --stream-mmap --stream-count=60 --stream-to=/tmp/v0.nv12
ls -l /tmp/v0.nv12      # 應為 60×3840×2160×1.5 = 746,496,000 bytes
sudo -n cat /sys/bus/pci/devices/0000:03:00.0/ch0_drops      # 應為 0
# 編碼路徑：卡端服務 active 且 host /dev/video1 真收到非零 H264
timeout 30 sudo -n /home/rd/sc7f0/bin/sc7f0ctl exec 'systemctl is-active sc7f0-vcud'
sudo -n gst-launch-1.0 -e v4l2src device=/dev/video1 num-buffers=30 ! video/x-h264 ! h264parse ! fakesink
```

`sc7f0-vcud` 仍非 `active`、或 `/dev/video1` 讀不到 H264 幀（例如 `No valid frames found before end of
stream`、host `VCU Host Ring full … parking publisher`）時，**只能宣告「燒錄/啟動成功、視訊功能未通過」**，
不得因 eMMC SHA 與 PL 版號正確就宣稱功能驗收完成。

2026-11-12 完成 ①＋②＋②b 後的**雙路 5 分鐘實測**（`logs/59,60,61,62,63`；
測試機 `/home/rd/sc7f0-validation/20261112T074643Z-dual5min/`（該目錄已整組搬至
`/home/rd/sc7f0/captures/sc7f0-validation/20261112T074643Z-dual5min/`，內容 SHA256 相同；
此處保留當時舊路徑為事實記錄，對照見 move-manifest）：

- `/dev/video0` raw NV12 4K60 → `waylandsink fullscreen=true`：`0:05:00.298`，SIGINT 正常 EOS，
  `ch0_drops=0`，使用者目視桌面顯示正常。
- `/dev/video1` 硬體 H.264 → `h264parse ! mp4mux ! filesink`：`video1_h264_5min.mp4`
  937,883,624 B，`nb_frames=17998`、`duration=300.133333 s`（約 59.97 fps）、
  3840×2160 High@L5.2 `yuv420p` bt709 progressive、24,995,631 bps、`refs=1`、無 B 幀、
  keyframe 600 個（每 0.4998 s，GOP=30）。**影像解碼無損壞**：`ffmpeg -v error` 完整 decode
  `rc=0` 且無 decode/corrupted/missing-reference 錯誤（註：這**不等於「全零輸出」**，見下）。
  輸出中另有 52 行（+3 行 `Last message repeated`）
  `non monotonically increasing dts to muxer` 告警，**屬 null muxer 自身的輸出 timebase 量化告警**。
  對本檔 packet 整數時間戳直接統計（`time_base=1/6000`，17998 個 packet，
  `logs/66-mp4-packet-pts-dts-stats.txt`）：**PTS 與 DTS 皆嚴格單調**（17997/17997 遞增、
  **重複 0、倒退 0**，`has_b_frames=0` 故 PTS=DTS）
  ⇒ **不得**把該告警歸因為來源時戳重複/缺陷。影格間隔標稱 100 tick（60 fps）但有抖動：
  13049 步為 100 tick，其餘 4948 步偏離，範圍 **3–532 tick（0.5 ms–88.7 ms）**，屬速率抖動而非時戳順序錯亂。
- 卡端 `Sent 18118 / 60.0 FPS / 25.78 Mbps`、`SUB=DONE=MSI=18118 ERR=0`；host dmesg
  `host_head <- ps_tail=18118`、`video_errors=0`；AER cor/nonfatal/fatal 三項前後不變；
  host/PS boot-ID 與 `card_epoch=0bf769dc` 全程未變。
- 卡端 `Sent` 與 host `ps_tail` 是**daemon 自啟動起的累計計數**（本輪結束讀到 18118），
  而本 daemon 啟動後曾先跑過一次 120 幀 probe，**正式 5 分鐘開始前未先取 `Sent` 基線**
  ⇒ **不能**用 17,998 / 18,118 算「入檔率」或推估丟帧原因（兩者恰好差 120 只是累計值一致性，
  不是本輪丟幀量測）。同理 `drops 7711 → 7769` 跨停流瞬間且為累計語意，**不得**當作正式 300 s 的 loss。

> **仍屬手動、未固化**：①②②b 目前都要人工執行。整包**冷啟後 `sc7f0-vcud` 不會自行成功**
> （開機後 `vpss-csc` 兩 pad 為 1280x720、節點格式未設 → `Initial VIDIOC_QBUF: EINVAL` 重啟迴圈）。
> 本輪驗收的是「燒錄 + 執行期初始化 + 雙路取樣」，**不是**「冷啟即自動通過」；
> 後續仍需最小 recipe/service 或開機 script 修正並重出完整 PS 包，才算整包自動化。

## 本輪可直接使用的產物

- `build/sc7f0-26102204/`：凍結的已驗證映像、matched driver source、SHA、logs。
- Active FPGA：`0x26102204`；NV12/NV16 各 1800 幀約 59.98 FPS，DMA drops/overflow 0。
- 真實 PNG 及 Wayland rendered-frame 證據：`build/validation/sc7f0-nv-formats/`。
- 詳細修正／驗收：`docs/sc7f0_nv_formats_20261022.md`。
- HDMI07、HDMI08 rev01 rollback 均保留。
- 使用者後續要求原生4K NV12全螢幕：已在測試機啟動 transient user service
  `sc7f0-nv12-4k-preview`。管線不含 videoconvert/videoscale，sink收到NV12 3840×2160。
  螢幕目前也是3840×2160@60、scale1.0；實際rendered約60FPS，DMA drops/overflow0。
  燒錄或另開capture前先在測試機停止：
  `systemctl --user stop sc7f0-nv12-4k-preview`。
