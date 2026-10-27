# SC7F0 實際系統邊界：開發機、x86 Host、卡上 PS Linux、PL、MCU

## 必須先分清楚的四個執行環境

| 環境 | 角色與路徑 |
|---|---|
| 開發機 | `/home/zzlee/qpcie` 原始碼；Vivado/Vitis 2023.2、Docker `petalinux:latest` 建置環境；不是裝卡的測試機 |
| x86 測試機／PCIe Host | `rd@sc7f0-test.local`、kernel `7.0.0-38-generic`；PCIe BDF `0000:03:00.0`；`qpcie.ko`、V4L2、ALSA、GStreamer、Wayland desktop |
| SC7F0 卡上 PS | ZynqMP A53、aarch64、PetaLinux kernel `6.1.30-xilinx-v2023.2`；自己的rootfs、platform drivers與systemd daemons |
| 卡上 PL 與獨立 MCU | PL是 `xczu4ev-fbvb900-2-e` 可程式邏輯；MCU是獨立 NUC1262（不是IT6663），運行裸機韌體、經I2C控制IT6663 |

SSH只登入x86。**不能**在x86直接查找PS的 `/sys/bus/platform/devices/b0010000.hdmi-rx`；
也不能假設測試機有開發機的 `/home/zzlee/qpcie`。

## 控制面：PS Linux不可省略

```text
開發機 --SSH--> x86 test host
                  sc7f0ctl
                     │ host qpcie_debug.c / misc device
                     ▼ PCIe BAR0 debug mailbox (0x2000..0x3fff)
              PL shared AXI-Lite crossbar / BRAM
                     ▲ PS M_AXI_HPM0_FPD, physical 0xA0002000..
                  PS qpcie_debugd --> card Linux shell command

PS Linux official HDMI RX/VPHY platform drivers
  ├─ control PL VPHY @ 0xb0000000 and HDMI RX @ 0xb0010000
  ├─ handle PS GIC IRQ, RX callbacks, EDID and recovered stream configuration
  └─ expose PS V4L2 subdevice + hdmi_info sysfs
       ↓ PS qpcie_hdmi_daemon
     shared PL CSR @ PS 0xa0000000 / host BAR0 offsets
       ↓ host driver coherent telemetry reads (SEQ / flags / heartbeat)
     host V4L2 format/source checks and ALSA HDMI format checks
```

- **PS drivers**：official Xilinx HDMI 2.0 RX/Video PHY modules；
  `petalinux/.../recipes-modules/qpcie-v4l2-bridge/files/qpcie_v4l2_bridge.c`
  提供V4L2/media master以綁定RX，不需要PS video framebuffer writer。
- **PS HDMI daemon**：`test_app/qpcie_hdmi_daemon.c`，透過官方video subdevice量測timing/color，
  寫入 `0x0604..0x067c` 的versioned telemetry；音訊初版另外解析官方 `hdmi_info` 的
  LPCM/channels/ACR。不把MCU快取當RX driver的量測。
- **PS debug daemon**：`test_app/qpcie_debugd.c`，實驗室root command transport；不是SSH server，
  不是PCIe網路，也不是不依賴Linux的救援console。
- **PS upgrade daemon**：`test_app/qpcie_upgrade_daemon.c`，接收升級協定、驗證bundle、寫eMMC。
- **MCU firmware**：`test_mcu_nuc1262/`；PS I2C0 → MCU I2C0 slave → MCU I2C1 master → IT6663。
  PS/VPHY設定不是全部由MCU負責，MCU也不直接代替PS讀PL的PCIe CSR。

典型查詢（第一個command在x86執行，第二個才在PS執行）：

```sh
ssh rd@sc7f0-test.local 'uname -m; cat /sys/bus/pci/devices/0000:03:00.0/hdmi_status'
ssh rd@sc7f0-test.local 'sudo -n /home/rd/sc7f0ctl exec "uname -m; systemctl is-active qpcie-debugd qpcie-hdmi-daemon qpcie-upgrade-daemon; cat /sys/bus/platform/devices/b0010000.hdmi-rx/hdmi_info"'
```

PS `0xa0000000` 是HPM0已映射的shared CSR base；不是host physical BAR address。
`0xb0000000` 已作VPHY aperture，不能照舊daemon注解把它當CSR base任意探測。

## 資料面：直接進Host RAM，不是PS DDR擷取

```text
HDMI input → IT6663 routing / TMDS → PL VPHY + v_hdmi_rx_ss
    ├─ Video AXIS → pack/CDC → capture150MHz → RGB / NV12 / NV16 engines
    │              → PCIe125MHz packet queue → RQ MWr → host VB2/SGL buffers
    │              → host V4L2 /dev/video0 → GStreamer → desktop Wayland
    └─ Audio AXIS @ PCIe125MHz → TID/preamble/PCM adapter → audio DMA ring
                   → RQ MWr → host ALSA buffer → GStreamer → desktop audio sink
```

PL PCIe endpoint使用PG213 **Gen3 x4**，不是PS PCIe控制器，也不是「PCIe4 IP名稱=Gen4」。
HDMI4-PPC native active raster可能148.5MHz，因此video capture使用150MHz，不能因PCIe
平均頻寬足夠就把所有video搬回125MHz。

PS DDR可供**升級包staging**使用，與正常視訊／音訊擷取目的地完全不同。
PS出現media/subdevice節點不表示host應從PSDDR搬影像。

## 建置／打包／燒錄：PS+PL成套，MCU另一路

唯一現行入口：[sc7f0_build_package_flash.md](sc7f0_build_package_flash.md)。
在**開發機**執行：

```sh
./scripts/sc7f0_build.sh --version <NEW_YYMMDDpp> --out build/<FRESH_DIRECTORY>
./scripts/sc7f0_package.sh --build build/<FRESH_DIRECTORY>
./scripts/sc7f0_flash.sh --build build/<FRESH_DIRECTORY> --host rd@sc7f0-test.local
```

1. Build：unit/PS AXI/CDC/audio/4K60 regressions → Vivado synthesis/route/bitstream →
   timing/DRC/skew signoff → **新XSA含同一份bitstream**。
2. 匯入該XSA：`petalinux-config --get-hw-description=... --silentconfig`，透過既有
   make/Docker runner **實際執行petalinux-build**，重建匹配PS hardware description。
3. 編譯aarch64 daemons、產出含必要services的rootfs/FIT；host driver則在x86 kernel headers建置，
   **不把host qpcie.ko誤當PS platform driver塞進PS kernel**。
4. BOOT.BIN：FSBL + PMUFW + PL bitstream + ATF BL31 + DTB + U-Boot。
   BL31是EL3 secure monitor，不是泛稱的Trusted OS。
5. Bundle嚴格只有 `BOOT.BIN`、`image.ub`、`boot.scr`、`manifest.sha256`。
   主機driver/tool sources是另外傳到x86的release artifacts，不混進四成員tar。
6. Flash：Host `qpcie_upgrade` ↔ shared CSR ↔ PS upgrade daemon；PCIe H2C staging至PSDDR，
   VERIFY → 備份 → COMMIT寫eMMC → SHA讀回 → **card warm system reset/PCIe rescan**。
   此 reset 依賴活著的 PS daemon／Linux，不是外部 POR；獨立 MCU／IT6663 不保證隨之 reset。
   詳見 [PS watchdog 與 reset 範圍](sc7f0_ps_watchdog_20261024.md)。
   不重啟x86，但卡的PCIe裝置及擷取會中斷，必須先停使用者capture。

**MCU不是這個tar自動更新的內容。** MCU另用 `scripts/sc7f0_mcu_flash.py`，由x86的
`sc7f0ctl exec`在PS送I2C0 `0x2a`升級協定；runtime狀態在`0x32`，proxy在`0x33`。
MCU先用 `make -C test_mcu_nuc1262` 建置、檢查APROM大小限制與CRC/SHA、備份原版本，
再依明確授權燒錄並讀回版本；本次音訊工作不更新已驗證v1.1.15。
詳見 [sc7f0_hpd_fix_v1.1.15_20261021.md](sc7f0_hpd_fix_v1.1.15_20261021.md)。

## 證據與版本界線（音訊接手時）

- `0x26102204` 是已驗證RGB/NV12M/NV16M視訊基線；**不是新PCM音訊的成功證據**。
- 檔案存在或日期舊的XSA/BOOT.BIN，不能證明剛修改的RTL已被編譯。
- AMD PG236 AUDIO_OUT preamble=1/2/3；本專案TPG raw preamble=B/9/C。
  原audio DMA只接受B/9/C，會忽略真正HDMI。TID也必須保留以過濾並配對channel0/1。
- ALSA `S32_LE`標籤不代表DMA payload是PCM；raw AES3節點不能直接拿來播放。
- 新audio build需有新output directory、source/artifact SHA、sim/route/XSA/PS logs，再做實機驗證。
- PLAYING、ALSA open、InfoFrame顯示LPCM、或僅有靜音buffer，均不能當成「實際聲音已播放」。
