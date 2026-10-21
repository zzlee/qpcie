# SC7F0 HDMI RX 接手狀態與後續 ABI 設計（2026-10-19）

> 最新續作狀態見 §6；§1–5 保留第一階段核對與設計記錄。
> 建置／部署／實機命令與結果逐步記錄於
> [sc7f0_hdmi06_validation_log.md](sc7f0_hdmi06_validation_log.md)。
> 標準 PetaLinux 流程為根目錄 Make + Docker；先前宿主機建置錯誤不是此流程的驗證結果。

來源：agy conversation `38fbf4ef-6007-4086-985b-49b61b326336`。
本文件以目前原始碼核對交接摘要；不是實機驗收報告。
專案為 `/home/zzlee/qpcie`，不是空的 `vibecoding/sc7f0-bringup`。
既有未提交 RTL、driver、XSA 修改均保留，本輪沒有修改 RTL 或燒錄板卡。

## 1. 已確認的必要修正

### 官方 driver 必須配合 IP 世代

目前 XCI 為 `xilinx.com:ip:v_hdmi_rx_ss:3.2`、4 PPC、8 bpc，
PHY 為 Video PHY 2.2。應使用 Xilinx 官方 **HDMI 2.0 out-of-tree modules**：

- Recipe：`components/yocto/layers/meta-xilinx/meta-xilinx-core/recipes-kernel/hdmi/kernel-module-hdmi_2023.2.bb`
- upstream：`https://github.com/Xilinx/hdmi-modules`
- branch：`xlnx_rel_v2023.2`
- SRCREV：`82209b0021a7b5d7ef71a859eed4bafeb541ed08`
- RX：`xilinx-hdmi-rx.ko`，原始碼 `hdmi/xilinx-hdmirx.c`
- PHY：`xilinx-vphy.ko`，原始碼 `hdmi/phy-vphy.c`
- RX driver match：`xlnx,v-hdmi-rx-ss-3.1`（3.2 的 fallback binding 須與 DTG 核對）
- PHY match：`xlnx,vid-phy-controller-2.2`

內建 `CONFIG_VIDEO_XILINX_HDMI21RXSS` 的 `xilinx-hdmirxss.c` 是另一個
HDMI 2.1 IP driver；不能把目前 IP 的 compatible 改成
`xlnx,v-hdmi-rxss1-1.1` 來強迫綁定。`xhdmiphy.c` 亦不是此 VPHY 的對應 driver。

### IRQ 與 HPD 尚未整合

`rtl/zu4ev_pcie_card_top.v` 中 VPHY 和 RX SS 的 `.irq()` 均懸空，
PS `pl_ps_irq0` 目前只接 `ps_irq_pulse_w`。需保留原有通知來源，擴充 PS IRQ
向量或加入 interrupt controller 後，再依實際接線配置 GIC SPI。
不可直接照抄範例 DTS 中的 SPI 90/92。

PHY 的 `vid_phy_axi4lite_aclk` 與 `drpclk` 都已接 `pl_clk0`。
DRU 參考時鐘不是 DRP clock，應按實際 Si5341／GTH 連線建模。
RX `hdmi_rx_hpd_out` 目前綁 HIGH，未使用 `hdmi_rx_hpd_from_ss`；
官方 EDID 更新時的 HPD toggle 因此不會傳到外部，需與 IT6663／MCU 路徑一起驗證。

### 不能沿用交接摘要的錯誤 register 定義

以 `driver/qpcie_driver.h`、`driver/qpcie_v4l2.c` 和 RTL 解碼為準：

- `0x0118` 是 channel 0 **overlay**，不是 source select。
- Source policy 在 channel CTRL `[21:20]`，目前 menu 為 Auto / Force TPG / Force HDMI。
- Channel CTRL enable 是 bit 0；format 欄位在 `[5:4]`，不是 `[3:2]`。
- `0x0600` readback 來自硬體輸入，沒有寫入解碼。
  目前只產生 bit 0 cable detect、bit 1 HPD；bit 2/3 沒有真實 lock 資料來源。
- `axil_reg_space.v` 中 timing reset defaults 仍有 1920x1080／148.5 MHz。
  這些不代表偵測到訊號，下一次 RTL revision 必須清零。
- Daemon 的映射基底在接手時已是 `0xA0000000`，只有錯誤訊息仍印舊位址。

## 2. 本輪已實作（第一階段）

- `rootfs_config` 選用現有官方 `kernel-module-hdmi` recipe，不複製 vendor driver。
- Bridge 在存在 DT 節點時不再額外建立第二個 virtual platform device。
  DT disabled 也會阻止 legacy fallback。
- DT bridge 強制要求明確 `hdmirx` phandle，不悄悄改綁另一個 receiver。
- 修正 async notifier 配置失敗時的 cleanup、空 media devnode 的卸載處理，
  以及 subdevice unbind/rebind 時 media registration 的生命週期。
- 因 RX/PHY nodes 與 IRQ 尚未到位，DT bridge 暫時 disabled。
  完成接線後須同時加入 `hdmirx = <&實際_RX_label>` 及 `status = "okay"`。
- Daemon 不再向唯讀 `0x0600` 寫虛構 lock／5V 狀態。
- 移除官方 HDMI 2.0 RX 不支援的 `VIDIOC_SUBDEV_S_DV_TIMINGS` 呼叫。
  QUERY 是偵測結果，不是用 S_DV_TIMINGS 鎖定 receiver。
- 啟動／正常退出／訊號遺失會清除 timing telemetry。
- 未實作的 IPC 命令回傳 `(uint32_t)-EOPNOTSUPP`，不再假回成功。

尚未完成：DT RX/PHY nodes、IRQ RTL、完整 capture control、color telemetry、
原子 snapshot、host 整合與實機 HDMI 擷取。

## 3. Capture 與 stream 控制的責任分界

資料路徑為 HDMI RX → PL capture/CDC → PCIe DMA → host 記憶體。
因此卡端需要 V4L2 master/bridge 管理官方 subdevice；不應為了讓 probe 成功
而虛構一個寫入 PS DDR 的 vb2 capture device。
目前 bridge 只提供 subdev/media 註冊，**不是已完成的 capture controller**。
後續若需要 media topology，須增加對應實體 DMA sink entity/link。

官方 HDMI 2.0 `xhdmi_s_stream()` 是 no-op，RX 持續偵測 cable／timings。
Host 的 V4L2 STREAMON/OFF 才是 DMA buffer ownership 與 capture gate 的入口。
應優先沿用既有 host `qpcie_start_streaming()` / `qpcie_stop_streaming()`，
不要讓使用者用 raw BAR write 與 kernel driver 同時控制 DMA。

建議狀態機（待實作）：

1. `IDLE`：RX 維持訊號偵測，DMA/gate 關閉，無 host buffer 被硬體持有。
2. `ARMING`：確認 telemetry 新鮮、format/geometry 支援，設定 ring，等待完整 SOF。
3. `RUNNING`：在幀邊界開 gate；回報實際 running，不把 request 當成 ack。
4. `STOPPING`：停止接收新幀、停止 descriptor fetch，等待在途 DMA 寫入結束。
5. `IDLE`：確認 idle 後才能將 buffers 交還 vb2；逾時需確實 quiesce/reset DMA。

目前 stop callback 在停止硬體前就 return buffers，需優先審查修正，以免 buffer
重用後仍被 DMA 寫入。Force HDMI 在未鎖定時應回報錯誤，不自動宣稱 TPG 是 HDMI。
解析度改變時停止舊 geometry 的 DMA、發 SOURCE_CHANGE，等待 host 重新配置 buffers。

## 4. 遙測／控制 ABI 草案（尚未寫入 RTL）

保留既有 `0x0600..0x0664`，新增欄位前須確認全專案無衝突。
建議保留如下欄位，而非覆寫實體 cable/HPD status：

| 建議 offset | 欄位 | 寫入者／用途 |
| --- | --- | --- |
| `0x0668` | ABI_VERSION | RTL／避免舊 app 錯解新資料 |
| `0x066C` | TELEMETRY_SEQ | PS／奇數更新中、偶數完成 |
| `0x0670` | TELEMETRY_FLAGS | PS／timing valid、color valid、interlaced、query error |
| `0x0674` | HEARTBEAT | PS／更新計數，host 以本機時間偵測停更 |
| `0x0678` | MBUS_CODE | PS／保留 V4L2 media-bus code，不和 host NV12 format 混淆 |
| `0x067C` | PIXELCLOCK_HI | PS／搭配既有 low 32-bit |

Host 必須在 seq 前後一致且為偶數時接受 snapshot，並驗證 flags 與 heartbeat。
先啟用該 ABI 的 MMIO ordering/barriers，再把多欄位讀寫視為 atomic publication。
色彩資訊來自官方 `VIDIOC_SUBDEV_G_FMT`／實際 InfoFrame，未知不可偽裝成 RGB。
現有 audio format 欄位的 16-bit sample rate 無法表示 96/192 kHz，也須版本化。

Stream on/off 使用既有 channel CTRL，由 driver 控制；若新增 PS command，
必須另外設計 request-id / ack-id / result / timeout，並序列化多個 host callers。
不可用目前單一 doorbell 的「收到即成功」流程當成已完成命令。

## 5. 驗證結果與下一步

已完成軟體建置：

- Bridge 對現有 ARM64 Linux `6.1.30-xilinx-v2023.2` build artifacts 編譯成功。
- 上述官方 SRCREV 的 `xilinx-hdmi-rx.ko`、`xilinx-vphy.ko` 等模組編譯成功。
  Vendor source 有既有 VLA/deprecation warnings，未修改 vendor code。
- Daemon 使用 Vitis 2023.2 AArch64 GCC，以 `-Wall -Wextra -Werror -static` 編譯成功。
- `test_app/tests/hdmi_telemetry_test.c` 的 ASan/UBSan 測試通過，檢查 4K timing
  發布、失鎖清除及不改寫硬體 status／TX／IPC 欄位。

完整 `petalinux-build -c qpcie-v4l2-bridge` 在 prerequisite 檢查被擋：
缺少 `xterm`、`texinfo`、`gcc-multilib`、ncurses development libraries。
未自行安裝系統套件，未完成 rootfs/package/image build。
獨立模組建置只驗證編譯，不代表板卡 driver 已成功 probe。

接續順序：

1. 補足 build 環境；產生對應目前 XCI 的 HDMI 2.0 DT，核對 PPC、refclk、PLL。
2. 接 VPHY/RX IRQ 至 PS，檢查 HPD/DDC；依 AGENTS.md bump C_VERSION 並重建 XSA。
3. 完成 DT clock/IRQ/PHY lanes、enable bridge，驗證 probe、事件、真實 timings。
4. 實作版本化遙測 ABI、daemon 色彩/新鮮度、host snapshot reader。
5. 完成 capture gate／STOP DMA 安全順序，再驗 STREAMON/OFF、拔插、改解析度。
6. 經使用者硬體驗證流程測試真實 HDMI，而非只驗 TPG。

## 6. 續作：HDMI06 IRQ／Device Tree（2026-10-19）

### 已實作

- `C_VERSION` 升至 `0x26101906`（top default 與 full build generic）。
- Full profile 的 `pl_ps_irq0` 擴為 `[2:0]`：bit 0 保留原通知，bit 1 接 VPHY，
  bit 2 接 RX SS；debug profile 仍是原本 1-bit IRQ。
- PS IP 的 `PSU__NUM_F2P0__INTR__INPUTS` 為唯讀，由 external port 寬度傳播，
  不可直接 set_property。兩種 profile 均已用 Vivado validate 並檢查傳播結果。
- IRQ mapping 依 ZynqMP BSP `XPS_FPGA0_INT_ID = 121U`：
  bit 1 為 GIC ID 122 / DT SPI 90；bit 2 為 GIC ID 123 / DT SPI 91，皆 level-high。
- 新增 `sc7f0-hdmi-rx.dtsi`，配置官方 HDMI 2.0 bindings、PHY lanes、實體位址、
  4 PPC／8 bpc、GTHE4／4-byte transceiver、NI-DRU、PLL/refclk selectors。
- `system-user.dtsi` 在明確 opt-in 時才引入該 fragment，bridge 透過 phandle enable。
  Recipe 的 `SC7F0_HDMI_RX_ENABLE` 預設 0；debug／HDMI05 不啟用 HDMI probe。
  只有匯入配對 HDMI06 XSA 並一起重建 bitstream/image 時，才在 PetaLinux
  `petalinuxbsp.conf` 設定 `SC7F0_HDMI_RX_ENABLE:pn-device-tree = "1"`。
- 刪除 common.dtsi 在 `0xB0000000` 的舊 `zzlab_env` placeholder，避免與 PHY alias。
- HPD 改由 RX SS 驅動，不再綁 HIGH；允許官方 driver 的 EDID 更新 HPD pulse
  傳至 IT6663。實際 IT6663／MCU 的啟動相依與外部 HPD 行為尚待硬體驗證。

### Clock 模型限制

PS AXI／DRP 使用 `zynqmp_clk 71`（實際 pl_clk0）；DRU 以 FSBL 已設定的
Si5341 OUT4 156.25 MHz 建模，不用 DRP clock 冒充。
Recovered RX video clock 由 VPHY 管理、尚無 CCF rate provider，故使用明確
rate=0 的 unmanaged handle。已核對此版官方 RX driver 只 prepare/enable 該 handle，
不讀取／設定其 rate；不能將此零值當成實測像素時鐘或未來 rate-sensitive driver 的支援。

### 驗證及建置

- HDMI BD：`HDMI_BD_PASS`；debug BD：`DEBUG_BD_PASS`。
  仍有原有 PS isolation 與 HP0 ARUSER/AWUSER width warnings，非 HDMI IRQ critical warning。
- `python3 scripts/check_sc7f0_hdmi_dt.py`：`HDMI_DT_PASS`。
  使用實際 DTG PS sources + 當前全部 user includes 編譯，不是 synthetic fixture。
  同時檢查 RX/PHY XCI 參數、IRQ、phandle、clock names、PHY order 及位址 alias。
  Base DTS 仍有既有 clock/simple-bus/unit-address/interrupt-provider warnings。
- 新增正向、default/debug 不探測 HDMI、PPC／PLL 不匹配拒絕測試：
  `python3 -m unittest discover -s scripts/tests -p test_sc7f0_hdmi_dt.py -v`。
  4 個測試全部通過。
- 已啟動獨立 synthesis，不覆寫 HDMI05/debug04 project：

  ```bash
  source /opt/Xilinx/Vivado/2023.2/settings64.sh
  SC7F0_PROFILE=full SC7F0_BUILD_STAGE=synth \
    SC7F0_PROJECT_DIR=/tmp/opencode/sc7f0-hdmi06-build \
    vivado -mode batch -notrace -source scripts/build_zu4ev.tcl \
      -log /tmp/opencode/sc7f0-hdmi06-synth.log \
      -journal /tmp/opencode/sc7f0-hdmi06-synth.jou
  ```

  Synthesis 結果尚待回報；尚未完成 routed timing／bitstream／新 XSA import／BOOT.BIN。
  修改後的 DTS **不得單獨裝到 HDMI05 或 debug-only 硬體**。
  在新 bitstream＋對應 XSA／DT 一起建置驗證前，不是可部署 release。

另以隨附 Yocto buildtools_extended 與明確的 PetaLinux `PROOT` 等變數執行
`bitbake qpcie-v4l2-bridge kernel-module-hdmi`：4402 recipes 解析完成，進入實際 tasks，
但 bridge 的 `oe_runmake` 在 spawn `pwd`／recursive make 時回報 `Invalid argument`。
尚未產出完整 package/image；相同 module source 的獨立 ARM64 Kbuild 已於 §5 驗證。
不以關閉 build safety checks 或修改無關 vendor recipes 的方式宣稱問題已解決。

下一階段仍為遙測 ABI（seq／valid／heartbeat／color）、host reader、capture gate、
安全 STOP DMA 與 STREAMON/OFF；§4 的新 register 仍只是草案、未寫入 RTL。

## 7. 續作：遙測 ABI 與 capture gate 已實作（2026-10-20）

§4 的草案已落到 RTL／卡端／host 三層，ABI 版本 `0x00010000`：

| Offset | 欄位 | 實作 |
| --- | --- | --- |
| `0x0668` | ABI_VERSION | RTL 唯讀常數 `0x00010000` |
| `0x066C` | TELEMETRY_SEQ | 卡端 daemon：odd 表示更新中、even 表示完成 |
| `0x0670` | TELEMETRY_FLAGS | bit0 timing valid、bit1 color valid、bit2 interlaced、bit3 query error |
| `0x0674` | HEARTBEAT | 卡端 daemon 每次發佈遞增，正常至少 1 Hz |
| `0x0678` | MBUS_CODE | 官方 subdevice `VIDIOC_SUBDEV_G_FMT` 的 media-bus code |
| `0x067C` | PIXELCLK_HI | 與 `0x060C` 合併為 64-bit pixel clock |

- `0x0660` 重新定義為 `[7:0] colorspace`、`[11:8] quantization`、
  `[15:12] ycbcr_enc`、`[19:16] xfer_func`、`[23:20] bit depth`、
  `[27:24] encoding`（RGB／444／422／420）。
- RX timing／color payload 的重設值改為 0；沒有 flags 的資料不得被解讀為有效。
- Host `QUERY_DV_TIMINGS` 只接受 seq 前後一致、flags timing-valid 且 heartbeat
  未停更的快照，否則 `-ENODATA`；不再回退 1920x1080/148.5 MHz。
- `STREAMON` 在 auto/force-HDMI 模式下先驗證真實 lock，失敗即拒絕，避免對
  不存在的訊號回報成功。
- `STOP_STREAMING` 改為先 quiesce（停 source、停 fetch、等 retire、必要時
  abort reset、全域 soft reset、`synchronize_irq()`）再歸還 buffers。

驗證：telemetry 單元測試 PASS、host driver Kbuild PASS、AArch64 靜態 daemon
編譯 PASS。`scripts/build_zu4ev.tcl` 現在對 full profile 也執行 fail-closed
timing/CDC/DRC gate；full build 與 routed report 尚待完成。
