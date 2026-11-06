# AGENTS.md - SC7F0 項目架構與操作手冊

> **SC7F0 任務說明**: 請先閱讀 [系統架構](docs/sc7f0_system_architecture.md) 及 [目前建置/打包/燒錄程序](docs/sc7f0_build_package_flash.md)。 
> SC7F0 是 ZynqMP **PS Linux + PL**，eMMC 啟動，並帶有一個獨立的 NUC1262 MCU。
> SSH 連線至 x86 主機；使用 `sc7f0ctl exec` 執行卡端 PS 指令。
> A50T SPI/Gen2/7-series 的說明 **不是** SC7F0 部署流程。
> 正常的抓取 DMA 寫入主機 RAM，而不是 PS DDR。MCU 燒錄與 PS/PL 固件包是分開處理。
> 永遠不要將舊的 XSA 或套件視為新的建置。

## 💳 硬體與核心規格

- **目標 FPGA**: AMD/Xilinx Artix-7 A50T (`xc7a50t-csg325-2` / `xc7a50t-fgg484-2`)
- **PCI 裝置識別**: 供應商 ID `0x12AB`, 裝置 ID `0xE380`
- **PCIe 介面**: 7-Series 整合 PCIe Block (`pcie_7x_0`)，Gen2 x4，128-bit AXI-Stream
- **板載 SPI Flash**: Macronix 128Mb SPI Flash (`MX25L12872F` / `mx25l12872f-spi-x1_x2_x4`)

## SC7F0 N1 HDMI2 V11: 獨立 eMMC 啟動 vs. PCIe 重置

**主要硬體來源:** `/home/zzlee/llm-wiki/raw/SC7F0_N1_HDMI2_V11/SC7F0 N1 HDMI2 V11.pdf`, YUAN Hightech 規格書，標題 `SC7F0 N1 HDMI2 V11`，版本 1，日期 2024-01-23 (PDF 創建於 2024-02-26)。請使用 **V11**，而不是 V10/V20 版本，用於此板卡。直接與規格書第 10、11 和 36 頁核對；A11→K11 和 R8/R7 的分配與 `constraints/zu4ev_pcie_pinout.xdc` 符合。維基總結只是指引，不是規格書的替代品。元件安裝和特定板卡上的實際電壓仍需要檢查/測量。

## 🛠️ FPGA 模組建置與 SPI Flash 燃錄流程

### 1. 建置 FPGA 模組 (Vivado 批次模式)
編譯原始 RTL 模組 (`a50t_pcie_card_top.v`, `pcie_7x_axi_bridge.v`, `cq_rx_decoder.v` 等) 成為位元流:

```bash
./scripts/build_a50t.sh
```
- 輸出位元流: `./build/qpcie_a50t_proj/qpcie_a50t_card.runs/impl_1/a50t_pcie_card_top.bit`

### 2. 标準自動化 SPI Flash 燒錄 (推薦)
永遠使用自動化腳本 **`./scripts/flash_a50t.sh`** 來燒錄 SPI Flash 記憶體:

```bash
./scripts/flash_a50t.sh
```

**`flash_a50t.sh` 自動執行:**
1. 呼叫 Vivado 批次 TCL 腳本 [`scripts/program_flash_a50t.tcl`](file:///home/zzlee/qpcie/scripts/program_flash_a50t.tcl)。
2. 將編譯好的 `.bit` 位元流轉換為 SPI 二進位格式 (`./build/a50t_pcie_card_top_spix1.bin`)。
3. 連線至 JTAG 硬體伺服器 / 探測器。
4. 使用 100% 校驗和燒錄 Macronix `MX25L12872F` SPI Flash。

## 🤖 AI 子代理角色說明

為了有效管理 SC7F0 項目，以下各個子代理會負責收集特定資訊並撰寫到本文件中:

### 1. 架構分析代理 (Architecture Agent)
- 收集 FPGA 系統架構與元件資訊
- 分析 PL/PS 模組間的互動邏輯
- 整理 PCIe 設定與通訊協定
- 撰寫設計規格與技術文件

### 2. 建置流程代理 (Build Agent)
- 收集所有建置腳本資訊與使用方式
- 分析建置流程中的各個階段與依賴關係
- 整理 Vivado 與 PetaLinux 的建置配置
- 編寫建置環境設定與工具使用說明

### 3. 任務分發代理 (Deployment Agent)
- 收集部署流程與腳本說明
- 分析自動化部署腳本的執行邏輯
- 整理與測試機互動的資訊
- 驗證部署流程中的確認與安全機制

### 4. 測試驗證代理 (Testing Agent)
- 收集測試指令與流程
- 整理驗證報告與結果分析
- 提供測試環境配置資訊
- 編寫測試案例與效能評估

## 🔧 建置專案步驟

根據 `scripts/sc7f0_build.sh` 腳本，完整建置流程如下:

### 第一步：回歸測試與模組驗證
```bash
# 執行 RTL、Python、AXI、CDC 和 4K60 回歸測試
./scripts/test_sc7f0_nv_formats.sh

# 執行 Python unittests
python3 -m unittest discover -s scripts/tests

# 執行模組驗證測試 (PS AXI 協定、CDC、音訊)
for test in sim_zu4ev_ps_axi_protocol test_sc7f0_cdc test_sc7f0_audio; do
    vivado -mode batch -source "scripts/$test.tcl"
done

# 執行實體驗證測試 (RGB, NV12, NV16 4K60)
for format in RGB NV12 NV16; do
    export SC7F0_TEST_NV12=1  # 或相應格式
    vivado -mode batch -source scripts/test_sc7f0_live_video.tcl
done
```

### 第二步：FPGA 建置與驗證
```bash
# 使用指定 TCL 腳本建立 FPGA 設計
vivado -mode batch -source scripts/build_sc7f0_hdmi_08.tcl

# 驗證建置結果 (需達成以下條件)
# - 建置流程正常完成
# - 時序分析通過 (HDMI08_BUILD_PASS)
# - Bus skew 分析無異常
# - DRC 無違反
```

### 第三步：PS 建置與元件打包
```bash
# 與 FPGA 位元流一起建置 PS Linux 鏡像
make -C petalinux/qpcie-zu4ev hw-desc linux XSA_DIR="$OUT/fpga/hardware.xsa"

# 編譯所有必要的 daemon 服務
make -B -C test_app qpcie_upgrade_daemon qpcie_debugd qpcie_hdmi_daemon

# 建立 BOOT.BIN、boot.scr 等文件
SC7F0_IMPL_DIR="$OUT/fpga" SC7F0_IMG_DIR="$OUT/images" bash scripts/package_zu4ev_bootbin.sh
```

## 🔥 燒錄專案步驟

根據 `scripts/sc7f0_flash.sh` 腳本，完整燒錄流程如下:

### 第一步：準備與驗證
```bash
# 檢查建置結果與完整性 (verify SHA256)
sha256sum -c RELEASE.sha256

# 驗證 PS 服務運行狀態 (需要 sc7f0ctl 狀態)
sudo /home/rd/sc7f0ctl status
```

### 第二步：執行驗證階段
```bash 
# 在 x86 上進行 VERIFY 操作
./qpcie_upgrade --package "upgrade-$VERSION.tar"

# 驗證檔案 SHA 檔案完整性
grep -E '  (upgrade-[0-9]+\.tar|host-driver-src\.tar\.gz|host-tools-src\.tar\.gz)$' RELEASE.sha256 | sha256sum -c -

# 備份現有 eMMC 鏡像
sudo /home/rd/sc7f0ctl exec "b=/run/media/BOOT-mmcblk0p1; test -s \$b/BOOT.BIN; d=\$b/.backup_cli_$STAMP; mkdir \$d; for n in BOOT.BIN image.ub boot.scr; do cp \$b/\$n \$d/\$n; done"
```

### 第三步：執行提交與重啟階段
```bash
# 安裝新的驅動程式並進行提交
sudo -n insmod driver/qpcie.ko

# 使用提交命令更新 eMMC
./qpcie_upgrade --commit

# 檢查 eMMC 鏡像驗證 (SHA256)
sudo /home/rd/sc7f0ctl exec 'sha256sum /run/media/BOOT-mmcblk0p1/BOOT.BIN /run/media/BOOT-mmcblk0p1/image.ub /run/media/BOOT-mmcblk0p1/boot.scr'

# 進行卡端重啟
./qpcie_upgrade --reboot

# 確認 PS 回復與版本驗證
sudo /home/rd/sc7f0ctl status
```

## 📊 測試機相關資訊

SC7F0 測試環境包含：
- **主機**: Linux x86 主機，安裝有 sc7f0ctl 工具
- **連線方法**: SSH 連接至 `rd@sc7f0-test.local`
- **驅動程式配置**: 為特定測試機的 Kernel 版本編譯與安裝
- **驗證工具**: 針對不同的格式 (NV12, NV16) 的實體測試

### 推薦測試命令:
```bash
# 驗證視訊功能
/home/rd/sc7f0-nv-formats/capture_verify /dev/video0 NV12 hdmi 1800
/home/rd/sc7f0-nv-formats/capture_verify /dev/video0 NV16 hdmi 1800

# 驗證音訊功能 (ALSA)
arecord -l

# 查看 HDMI 狀態
cat /sys/bus/pci/devices/0000:03:00.0/hdmi_status

# 檢查驅動狀態
lsmod | grep qpcie
dmesg | tail -n 50
```

## 🔍 驗證與流程說明

### 版本控制規則
- 使用 `C_VERSION` 參數進行版本管理 (格式: `0xYYMMDDpp`)
- 確保每次修改後都更新 `C_VERSION`
- 維持 `C_PLATFORM` = `"PCIE"` 與 `C_BOARD_VERSION`

### 安全機制
- 2 階段流程：VERIFY → COMMIT，避免錯誤更新導致系統異常
- 每次升級前會自動備份 eMMC 到 `/backup_cli_` 目錄
- 系統狀態可透過 `sc7f0ctl exec` 查詢

### 註意事項
1. **部署風險**: 由於使用兩階段機制，即使錯誤也可以恢復
2. **前置需求**: 需要正確的 Vivado/PetaLinux 環境及 `sc7f0ctl` 工具
3. **回滾功能**: 在升級失敗時可使用備份鏡像快速恢復

## 📋 建置結果

完整建置包包含以下元件：
- FPGA 設計 bitstream (`zu4ev_pcie_card_top.bit`)
- PetaLinux boot 鏡像 (`BOOT.BIN`, `image.ub`, `boot.scr`)
- Linux kernel driver 源碼與工具
- 升級驗證腳本與報告檔案

## 🧪 子代理測試與錯誤處理

為了確保 SC7F0 流程的穩定性，以下各個子代理將對每個步驟進行測試並在失敗時停止報告錯誤原因:

### 建置流程測試代理 (Build Process Agent)
- 測試 `build_a50t.sh` 腳本
- 驗證 Vivado 環境是否正確設置  
- 測試 FPGA 模組建置過程
- 檢查所有測試案例是否通過
- 若任何步驟失敗，立即停止並回報具體錯誤原因

### 打包流程測試代理 (Package Process Agent)
- 執行 `sc7f0_package.sh` 腳本
- 驗證產生的 tarball 文件完整性
- 檢查 SHA256 校驗碼正確性
- 確保所有必需組件都存在於打包中

### 燒錄流程測試代理 (Flash Process Agent)
- 測試 `sc7f0_flash.sh` 腳本的執行能力 
- 驗證 SSH 連線到測試主機的可行性
- 執行驗證與提交階段的完整流程
- 偵測所有可能的錯誤並提供明確的故障原因

每個代理都將以串行方式執行，若任一步驟失敗，則立即停止整個流程，並提供詳細的錯誤報告。這樣的設計確保了 SC7F0 系統的可靠性與穩定性。

此文件是 SC7F0 專案的完整操作手冊，包含所有建置、測試、部署流程的詳細說明。