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
`/home/rd/sc7f0ctl`。本版是針對目前 x86 測試機／aarch64 SC7F0 PetaLinux，
eMMC boot mount 為 `/run/media/BOOT-mmcblk0p1`。其他部署配置應先確認，不能猜測。

1. 核對 release SHA，將包與 matched source 傳到測試機。
2. **透過 sc7f0ctl exec** 檢查真正 PS 的架構及三個 daemon。
3. 在 x86 上針對該機 kernel 編譯 matched driver；拒絕正在使用 `/dev/video0` 的情況。
4. PCIe push／PS VERIFY；不接受 E1，不會忽略錯誤強行 COMMIT。
5. 備份 PS eMMC 三個 boot files 與 host module；載入及安裝 matched driver。
6. COMMIT；經 PS mailbox 獨立讀回三個檔案的 SHA。
7. 只對卡端 POR／PCIe rescan，等待 PS 回復，確認 active version 與三個 daemon。
8. 比對 x86 boot ID 未變。保留 remote logs／backups 的目錄路徑。

只有 VERIFY、不寫 eMMC、不換驅動、不重啟：

```sh
./scripts/sc7f0_flash.sh --build build/sc7f0-26102204 --verify-only
```

省略確認提示（確定要燒錄才使用）：`--yes`。
三支都支援 `--help`／`--dry-run`；dry-run 不接觸硬體。
`logs/flash.log` 保存燒錄紀錄。燒錄成功不等於視訊成功，下面仍需驗收。

## 實機抓幀／畫面確認

測試機上已有本輪驗證工具，可逐一測試（不要同時開多個 capture）：

```sh
/home/rd/sc7f0-nv-formats/capture_verify /dev/video0 NV12 hdmi 1800
/home/rd/sc7f0-nv-formats/capture_verify /dev/video0 NV16 hdmi 1800
python3 /home/rd/sc7f0-nv-formats/sc7f0_hdmi_preview.py --format NV12 --sink wayland --native-size --fullscreen
```

`capture_verify` 的來源是 `test_app/v4l2_capture_verify.c`，可用
`make -C test_app v4l2_capture_verify` 建置。它實際 STREAMON/DQBUF，逐 plane
檢查 bytesused／sequence／error flags，可再加 dump 檔名保存完整一幀。
目前只將 3840×2160 作為這個小工具的驗收尺寸。

**已知獨立限制**：PS-only warm reboot 後 IT6663 下游可能未恢復。
若 `hdmi_status` 仍未鎖定，先停 capture，在 x86 測試機執行一次：

```sh
sudo /home/rd/sc7f0ctl exec 'i2ctransfer -y 0 w2@0x32 0x06 0x01'
```

等待 `/sys/bus/pci/devices/0000:03:00.0/hdmi_status` 真正顯示 Signal Locked 才抓幀。
這是 MCU runtime restart，不是重燒 MCU；三支 script 不會暗中執行這一步。

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
