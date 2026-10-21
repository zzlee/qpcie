# SC7F0 HDMI06 建置、部署與測試執行紀錄

## 狀態與授權

- 日期：2026-10-19。
- 使用者要求：Vivado 成功後，確認測試機連線、燒錄 SC7F0、安裝 driver、
  執行測試，並記錄所有步驟。
- 授權包含 PCIe eMMC COMMIT、必要的**板卡**重啟與配對 driver 安裝；不重啟 host。
- **目前未燒錄、未重啟板卡、未安裝或重載 driver。**
- 當前背景工作是 synthesis-only，不等於 implementation/timing/bitstream 成功。
  任何失敗或不明結果均停止部署，不重送可能已執行的 COMMIT。
- 詳細設計與前階段測試：`sc7f0_hdmi_rx_takeover_20261019.md`。

## 1. Vivado（執行中，尚未驗收）

實際啟動命令（專案根目錄）：

```bash
source /opt/Xilinx/Vivado/2023.2/settings64.sh
SC7F0_PROFILE=full SC7F0_PROJECT_DIR=/tmp/opencode/sc7f0-hdmi06-build \
  SC7F0_BUILD_STAGE=synth \
  vivado -mode batch -notrace -source scripts/build_zu4ev.tcl \
    -log /tmp/opencode/sc7f0-hdmi06-synth.log \
    -journal /tmp/opencode/sc7f0-hdmi06-synth.jou
```

目標 `C_VERSION=0x26101906`，不覆寫已驗證的 HDMI05/debug04 project。
Synthesis 回報後還必須完成 implementation、routed timing/CDC/DRC 審查、
bitstream 與配對 XSA，不能僅憑程序 exit 0 或 `.bit` 存在決定燒錄。

## 2. 測試機唯讀連線檢查（PASS）

本節在等待 Vivado 期間先行執行，不改動板卡或 driver。

連線方式：

```bash
ssh -o BatchMode=yes -o ConnectTimeout=10 rd@sc7f0-test.local
```

第一組實際執行的遠端命令：

```bash
set -e
hostname
uname -r
id
sudo -n true
lspci -nn -d 12ab:e380
lspci -s 0000:03:00.0 -vv
command -v sc7f0ctl || test -x /home/rd/sc7f0ctl
command -v qpcie_upgrade || test -x /home/rd/qpcie_upgrade
ls -l /dev/qpcie-debug-* /dev/video* /home/rd/qpcie_upgrade /home/rd/sc7f0ctl
```

第二組實際執行的遠端命令：

```bash
set -e
sudo -n /home/rd/qpcie_upgrade --status
sudo -n /home/rd/sc7f0ctl status
sudo -n lspci -s 0000:03:00.0 -vv
modinfo -n qpcie
test -d "/lib/modules/$(uname -r)/build"
readlink -f "/lib/modules/$(uname -r)/build"
ls -l /sys/bus/pci/devices/0000:03:00.0/driver
```

結果：

| 項目 | 觀察值 |
| --- | --- |
| hostname／帳號 | `sc7f0-test`／`rd` UID 1000 |
| Host kernel | `7.0.0-38-generic` |
| 非互動 SSH／sudo | 成功 |
| PCIe BDF／ID | `0000:03:00.0`／`12ab:e380` |
| PCIe link | `8GT/s x4`（Gen3 x4） |
| Hardware magic／version | `0x12ABE380`／`0x26101905` |
| Upgrade state／PS buffer | `0x00 IDLE`／`0x30000000` |
| Debug channel | ABI 1、READY=1 |
| 目前 driver | `qpcie-dma`，`/lib/modules/7.0.0-38-generic/extra/qpcie.ko` |
| Host headers | `/usr/src/linux-headers-7.0.0-38-generic` 存在 |
| Device nodes | debug misc node 及 `/dev/video0..6` 存在 |
| AER 基準 | UESta／CESta 列出的錯誤旗標均為 `-`；LaneErrStat=0 |

完整輸出留在專案本地建置目錄（不納入 source commit）：

- `build/validation/sc7f0-hdmi06/preflight.log`
- `build/validation/sc7f0-hdmi06/baseline.log`

## 3. 標準 PetaLinux 建置環境（已確認，尚未執行新映像建置）

必須使用專案 Make + Docker 流程，而非宿主機直跑 PetaLinux/BitBake：

- 根目錄 `Makefile` → `petalinux/qpcie-zu4ev/Makefile`
  → `petalinux/mkfiles/qpcie-zu4ev.mk`
  → `petalinux/mkfiles/petalinux-dispatch.mk`
  → `petalinux/petalinux-run.sh`。
- 已執行 `docker image inspect petalinux`，映像存在：
  `sha256:0d903a2491d9cb5e715fe596b89d069ca706ea1f6f389d71d2d4653ba44e4eba`，
  `linux/amd64`。
- 先前宿主機缺套件／直接 BitBake 失敗不能當成此標準建置流程已失敗。

待新 XSA 可用後才執行 hardware-description import；使用**絕對路徑**，明確指定
與該 XSA 配對的 bitstream/FSBL/DT，避免預設 debug 路徑混進 HDMI image。
HDMI06 專用 DT opt-in 為 `SC7F0_HDMI_RX_ENABLE:pn-device-tree = "1"`，
未配對的 debug／HDMI05 image 保持 0。

## 4. 待執行的部署關卡（不是已完成紀錄）

1. 完成 Vivado synthesis、implementation、timing/CDC/DRC gate，保存 reports、
   source snapshot、C_VERSION、bitstream/XSA 的 SHA-256。
2. 以 Make + Docker 匯入配對 XSA 並建置 PetaLinux；重包 `BOOT.BIN`，確認
   upgrade/debug daemon、HDMI modules、DT、服務設定與該硬體 revision 相容。
   未完成的 telemetry ABI／capture control 不列為通過。
3. 備份測試機原 driver、工具及可回復 firmware，記錄 checksums；確認無其他
   capture/upgrade 工作。於測試機對目前 kernel 編譯新 driver，不先破壞舊版本。
4. 將經審查的 eMMC production bundle（不是 SD installer 根目錄）送至 host。
   先 `qpcie_upgrade --package`，必須得到 VERIFIED 且內容/hash 符合候選版本。
5. 明確 `qpcie_upgrade --commit`，等待 SUCCESS；僅在確認成功後執行
   `qpcie_upgrade --reboot`，不重啟 host。若逾時或狀態不明，先查證而非重送 COMMIT。
6. 安裝／綁定配對 driver，驗證重新列舉、magic/version、Gen3 x4、daemon liveness
   與 module path/version。保存安裝前後的 driver／PCIe／kernel logs。
7. 測試順序：debug command → PS RX/PHY probe/IRQ → cable/EDID/timings →
   TPG 回歸 → 真實 HDMI capture → STREAMON/OFF 重複啟停、拔插與解析度變更。
   TPG 成功不可代替 HDMI 驗收；只有 cable detect 不算 TMDS/video lock。
8. 記錄每項命令、退出碼、預期值／實測值、影像樣本與新 AER/overflow/drop 情況。
   未實作／無法測試者標為 BLOCKED 或 NOT RUN，不寫成 PASS。

## 5. HDMI06 rev A：critical warning 修正與 telemetry ABI

Synthesis 首輪 0 errors、2 critical warnings，兩者都指向
`rtl/zu4ev_pcie_card_top.v` 的 `ps_hpm1_arid` 重複宣告（同一訊號在
`ps_hpm1_awid, ...` 批次宣告後又單獨宣告一次）。此重複宣告會被 Vivado
忽略，但 critical warning 不得帶進部署，因此先移除重複行。

同時完成「不得偽造遙測」的實作：

- RTL `rtl/axil_reg_space.v`：新增 `0x0668..0x067C` 版本化遙測 ABI。
  `0x0668 ABI_VERSION` 為唯讀常數 `0x00010000`；`0x066C SEQ`、
  `0x0670 FLAGS`、`0x0674 HEARTBEAT`、`0x0678 MBUS_CODE`、`0x067C
  PIXELCLK_HI` 由 PS 發佈者寫入。重設值改為 0，不再預載
  1920x1080/148.5 MHz 這類假 timing。
- 卡端 daemon `test_app/qpcie_hdmi_daemon.c`：以官方 subdevice 的
  `VIDIOC_SUBDEV_QUERY_DV_TIMINGS` 與 `VIDIOC_SUBDEV_G_FMT` 取得真實
  timing／colorimetry／media-bus code；以 odd→payload→even 的 SEQ
  包夾發佈，每秒推進 HEARTBEAT；無訊號時清空 payload 並清 flags。
  不再寫 `0x0600`。未實作的 IPC 命令回 `-EOPNOTSUPP`（不假裝成功）。
- Host driver `driver/qpcie_v4l2.c`：新增 seq 一致快照讀取與 heartbeat
  老化判斷；`QUERY_DV_TIMINGS` 移除所有 1080p/CEA 預設值，ABI 不符、
  timing invalid 或發佈者停更時回 `-ENODATA`，無 5V 回 `-ENOLINK`。
  `STREAMON` 在 auto/force-HDMI 模式下若無鎖定 timing 直接拒絕。
- `qpcie_stop_streaming()` 重排為：停 source → 停 descriptor fetch →
  等 in-flight 寫入 retire →（必要時）abort reset → 全域 quiesce +
  `synchronize_irq()` → 重設 ring → **最後**才歸還 buffers。舊順序在
  DMA 仍可能寫入時就把 buffer 還給使用者，是真實的資料毀損風險。
- `test_app/qpcie_hdmi_ctl.c`：以相同 seq 協定顯示 ABI/flags/mbus，
  無效時明確顯示 UNKNOWN，不再印假數值。
- `scripts/install_debug_rootfs.sh` + `qpcie-hdmi-daemon.service`：
  以 `ENABLE_HDMI_DAEMON=1` 明確 opt-in，避免 debug／HDMI05 image
  啟動後因 ABI 不符而不斷重啟。

驗證：

- `test_app/tests/hdmi_telemetry_test.c` 改寫為 ABI 回歸測試（有效快照、
  無效快照清空、odd SEQ 復原），以 host gcc 編譯執行 **PASS**
  （`HDMI telemetry tests passed`）。
- Host driver 以 `/lib/modules/7.0.0-38-generic/build` 編譯 **PASS**
  （僅 compiler/pahole 版本警告）。
- Daemon 以 Vitis 2023.2 AArch64 toolchain 靜態編譯 **PASS**
  （`qpcie_hdmi_daemon`，ARM aarch64，static）。
- 首輪 synthesis 專案已刪除，改用含上述修正的 source 重新啟動 full
  profile synthesis+implementation；新專案
  `/tmp/opencode/sc7f0-hdmi06-impl`、候選 XSA
  `/tmp/opencode/sc7f0-hdmi06.xsa`。
- `scripts/build_zu4ev.tcl` 的 timing/CDC/DRC gate 改為 **兩種 profile
  都 fail-closed**：full profile 若 gate 失敗，不得匯出 XSA。

## 6. HDMI06 建置與 Timing 驗證完成（2026-10-20）

經接手排除 License Server 網路逾時障礙，採用方案 A 於既有專案 `build/qpcie_zu4ev_hdmi_proj`
復用已獲得 Purchased 授權之 HDMI RX/TX/PHY IP 網表，更新 `zu4ev_ps_bd`（`pl_ps_irq0[2:0]` 擴展）
與頂層 RTL，成功完成全模組合成、實作與 Bitstream 生成。

### 產物與檢驗指標
- **目標版本**：`C_VERSION = 0x26101906`
- **Bitstream**：`build/qpcie_zu4ev_hdmi_proj/qpcie_zu4ev_card.runs/impl_1/zu4ev_pcie_card_top.bit`
  - 大小：7,798,023 bytes (7.5 MB)
  - SHA-256：`3ab319b02af04ea829a34b7b568fbe9341e450f6c3f7da38cb9201bee3a766dc`
- **硬體描述檔 (XSA)**：`hw_platform/sc7f0-hdmi06.xsa`
  - 大小：3.8 MB
  - SHA-256：`c2a6954718f0a69215b5c7b1a769c7ef7ff4d0097b005b594ee3a3c3399b0cf5`
- **Timing Summary (All Constraints MET)**：
  - Setup: WNS = **+0.847 ns**, TNS = **0.000 ns** (0 failing endpoints)
  - Hold: WHS = **+0.011 ns**, THS = **0.000 ns** (0 failing endpoints)
  - Pulse Width: WPWS = **0.000 ns**, TPWS = **0.000 ns** (0 failing endpoints)
- **ILA Probes**：`build/qpcie_zu4ev_hdmi_proj/qpcie_zu4ev_card.runs/impl_1/zu4ev_pcie_card_top.ltx`

## 7. PetaLinux 映像建置與打包完成（2026-10-20）

- **Device Tree**：啟用 `SC7F0_HDMI_RX_ENABLE:pn-device-tree = "1"`，包含 `sc7f0_vphy` (SPI 90)、`sc7f0_hdmirx` (SPI 91)、`qpcie_v4l2_bridge`。單元測試 `scripts/tests/test_sc7f0_hdmi_dt.py` 驗證 PASS。
- **PetaLinux Build**：4418/4418 任務成功，編譯生成 `Image`、`system.dtb`、`rootfs.cpio.gz`、`xilinx-hdmi-rx.ko`、`xilinx-vphy.ko`、`qpcie_v4l2_bridge.ko`。
- **BOOT.BIN 打包**：使用 `scripts/package_zu4ev_bootbin.sh` 將單一 monolithic bitstream (`0x26101906`)、`zynqmp_fsbl.elf`、`pmufw.elf`、`bl31.elf`、`system.dtb`、`u-boot.elf` 打包為 `images/linux/BOOT.BIN` (SHA256: `eb3c90f5736609ab602cb63f8ad6c6c258ebe5e106d07b44ce9188a227106dba`)。
- **image.ub 打包**：使用 `scripts/inject_upgrade_daemon_to_image_ub.sh`（`ENABLE_DEBUG_EXEC=1 INCLUDE_DEBUG_DAEMON=1 ENABLE_HDMI_DAEMON=1`），注入 AArch64 靜態編譯的 `qpcie_upgrade_daemon`、`qpcie_hdmi_daemon`、`qpcie_debugd`，打包為 `images/linux/image.ub` (SHA256: `cea7a5166dc863888957174c0aeea7885b9d9242feda7ac839f6d02af2a86f69`)。
- **升級包**：打包 `build/upgrade_hdmi06.tar.gz` (41 MB, SHA256: `016dc32fbb9e3d5c3f9449927c48b1777c02f8eb348393f517daa0f628586c21`)。

## 8. 測試機 PCIe DMA 部署、重啟與驗收測試（2026-10-20 PASS）

1. **環境備份**：備份現有 `/lib/modules/7.0.0-38-generic/extra/qpcie.ko` 及工具至 `/home/rd/backup_20261020_hdmi05/`。
2. **PCIe DMA 升級與 eMMC 寫入**：
   - 階段一：`qpcie_upgrade --package upgrade_hdmi06.tar.gz`，通過 40.75 MB DMA 寫入 (23.4 MB/s) 與 DDR 邊界 canary 檢查，板端回報 `0x05 VERIFIED`。
   - 階段二：`qpcie_upgrade --commit`，寫入 eMMC `/dev/mmcblk0p1` 並完成校驗，回報 `0x04 SUCCESS`。
3. **板卡溫重啟 (Zero-Host-Reboot)**：
   - 執行 `qpcie_upgrade --reboot`，觸發 PMU POR 重啟卡端並重新列舉 PCIe 匯流排，Host 主機完全不重開。
   - PCIe 成功重新建立於 `0000:03:00.0`，版本為 `0x26101906`，PCIe Link 為 Gen3 x4 (8GT/s x4)。
   - AER 錯誤暫存器（UESta/CESta）均為 0。
4. **卡端系統開機與驅動載入確認**：
   - 透過 PCIe debug 信箱 (`sc7f0ctl exec`) 讀取卡端 dmesg：
     - `xilinx-vphy b0000000.phy: probe successful` (Version 02.02)
     - `xilinx-hdmi-rx b0010000.hdmi-rx: Using Xilinx built-in EDID. Successfully loaded edid.`
     - `qpcie-v4l2-bridge: HDMI RX subdevice 'b0010000.hdmi-rx' bound to QPCIe V4L2 bridge`
     - `qpcie-v4l2-bridge: QPCIe V4L2 Bridge ready: /dev/v4l-subdev* and /dev/media* registered!`
     - `xilinx-hdmi-rx b0010000.hdmi-rx: probe successful`
   - 卡端服務 `qpcie-hdmi-daemon.service` 處於 active (running) 狀態。
   - 映射 PL CSR 遙測 ABI v1.0 (`0x0668..0x067C`)：
     - `ABI_VERSION = 0x00010000`
     - `TELEMETRY_SEQ` 為偶數 (快照完整)
     - `HEARTBEAT` 嚴格以 1 Hz 規律累計遞增。
5. **Host 端驅動編譯與取幀驗證**：
   - 於 `rd@sc7f0-test.local` 編譯最新 `qpcie.ko` (含 Telemetry ABI v1.0 與安全串流關閉邏輯) 並載入。
   - **TPG 取幀測試** (`--source 1`, 1920x1080@60)：
     - 成功擷取 120/120 幀，實測 59.827 FPS，0 資料錯誤，0 PCIe backpressure stall。
     - 4K (3840x2160) DMA 測試：60/60 幀傳輸完成，輸送量達 706.63 MiB/s。
   - **真實 HDMI 狀態與 No-Mock 檢查** (`--source 2`)：
     - 前端 IT6663 / MCU 正常運作 (`sc7f0_mcu_flash.py --status` 讀出 5V=True, HPD=True)。
     - 外部目前無活躍視訊時脈輸入時，卡端 Xilinx RX SS 誠實回報未鎖定，Host 端 `QUERY_DV_TIMINGS` 回傳 `ENODATA`，`STREAMON` 拒絕取幀（No Mock 承諾兌現）。


