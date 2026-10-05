# SC7F0 PCIe H2C DMA Firmware Fast-Push & Atomic eMMC Update Plan

## 1. 概述與設計目標 (Executive Summary & Goals)

### 1.1 背景與核心痛點
在 Zynq UltraScale+ ZU4EV (SC7F0 N1 HDMI2 V11) 介面卡開發過程中，若每次更新韌體（`BOOT.BIN`、`image.ub`、`boot.scr`）都需要：
1. 主機關機 ➔ 開啟機箱
2. 撥動 SW1 撥碼開關至 SD 模式 (`1110`) ➔ 插入 MicroSD 卡
3. 開機自動燒錄 eMMC ➔ 關機
4. 撥動 SW1 回 eMMC 模式 (`0110`) ➔ 拔出 SD 卡 ➔ 重新開機

此流程在頻繁迭代時極度耗時且容易磨損實體開關。傳統的 PCIe MMIO（32KB 分頁讀寫）傳輸 40MB 韌體需耗時 15~30 秒，且協議較繁瑣。

### 1.2 設計目標
* **極速傳輸**：利用既有的 PCIe Gen3 x4 實體頻寬（~3.2 GB/s），透過 **H2C (Host-to-Card) DMA**，將包含所有韌體的壓縮包（`upgrade.tar.gz`，約 40MB）在 **15 毫秒 (0.015 秒)** 內推送到板端 Linux 記憶體。
* **零變磚風險（Zero Brick Risk）**：在板端 RAM 內先校驗 `tar.gz` 完整性與各檔案 SHA256 哈希值，**只有 100% 正確才替換 eMMC 分區**。
* **零硬體干預（Zero Touch）**：SW1 開關永久固定在 **eMMC 模式 (`0110`)**，所有更新由主機終端單一指令觸發，板卡自動熱重啟生效。

---

## 2. 系統架構與資料流路徑 (Architecture & Data Flow)

```
┌────────────────────────────────────────────────────────────────────────┐
│ 1. Host PC 主機端                                                      │
│    • 打包檔案: tar -czf upgrade.tar.gz BOOT.BIN image.ub boot.scr     │
│    • 執行指令: sudo ./qpcie_upgrade upgrade.tar.gz                     │
│    • PCIe 驅動: 發起 H2C (Host-to-Card) DMA 傳輸                      │
└──────────────────────────────────┬─────────────────────────────────────┘
                                   │ PCIe Gen3 x4 匯流排 (DMA 速率 ~3.2 GB/s, 耗時 15ms)
                                   ▼
┌────────────────────────────────────────────────────────────────────────┐
│ 2. SC7F0 板卡硬體 (PL 端)                                              │
│    • PCIe IP Core (pcie4_uscale_plus_0, Gen3 x4)                       │
│    • SG-DMA Engine (H2C Channel) 接收資料流                            │
│    • 透過 ZynqMP S_AXI_HP0_FPD 介面直接寫入 PS DDR4 保留區段 (CMA)     │
│    • 傳輸完成後向 PS 端發送 Mailbox/Doorbell 中斷                      │
└──────────────────────────────────┬─────────────────────────────────────┘
                                   │ 觸發中斷 / Doorbell 通知
                                   ▼
┌────────────────────────────────────────────────────────────────────────┐
│ 3. SC7F0 板端 Linux (PS 端 ARM Cortex-A53)                             │
│    • 背景服務 (qpcie-upgrade-daemon.service) 監聽到更新請求           │
│    • 自 DDR4 緩衝區取出 upgrade.tar.gz (位於 /tmp/ 記憶體檔案系統)    │
│    • 步驟 A: tar -tzf 驗證封包完整性 + sha256sum 校驗                   │
│    • 步驟 B: 掛載 /dev/mmcblk0p1 (eMMC BOOT 分區)                      │
│    • 步驟 C: 一次性原子替換 BOOT.BIN, image.ub, boot.scr               │
│    • 步驟 D: 同步寫入 /dev/mmcblk0boot0 硬體備份分區                   │
│    • 步驟 E: 回傳 SUCCESS 暫存器給 Host ➔ 觸發 systemctl reboot       │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 3. CSR 暫存器與 Doorbell 握手協議 (Register & Protocol Spec)

在 `axil_reg_space.v`（BAR0 偏移 `0x0780 ~ 0x07B0`）保留專屬的 DMA Upgrade CSR 區段：

| 偏移位址 (Offset) | 暫存器名稱 | 讀/寫 | 說明 |
| :---: | :--- | :---: | :--- |
| `0x0780` | `REG_DMA_UPG_CTRL` | RW | Bit 0: `START_TRANSFER` (Host 觸發開始)<br>Bit 1: `DMA_COMPLETE` (硬體拉起)<br>Bit 2: `ABORT` (中途終止) |
| `0x0784` | `REG_DMA_UPG_SIZE` | RW | `upgrade.tar.gz` 總位元組長度（Bytes） |
| `0x0788` | `REG_DMA_UPG_CRC32`| RW | Host 端計算之 `upgrade.tar.gz` 總體驗證 CRC32 |
| `0x078C` | `REG_DMA_UPG_PS_ADDR`| RO | 板端 PS DDR4 接收緩衝區實體位址（由板端 Linux 啟動時填入） |
| `0x0790` | `REG_DMA_UPG_STATUS` | RO | 板端回報狀態：<br>`0x0`: IDLE (待機)<br>`0x1`: RECEIVING (DMA 傳輸中)<br>`0x2`: VERIFYING (解包與校驗中)<br>`0x3`: FLASHING (寫入 eMMC 中)<br>`0x4`: SUCCESS (更新完畢，準備重啟)<br>`0xE1`: ERR_CRC (CRC32/TAR 損壞)<br>`0xE2`: ERR_FLASH (eMMC 寫入失敗) |
| `0x0794` | `REG_DMA_UPG_PROGRESS` | RO | 0~100 (百分比進度指示) |

---

## 4. 板端 Linux 自動更新守護進程 (`qpcie-upgrade-daemon`)

### 4.1 服務生命週期
* 安裝於 PetaLinux `/usr/bin/qpcie_upgrade_daemon`，由 `qpcie-upgrade-daemon.service` 開機自動拉起。
* 開機時向 CMA（Contiguous Memory Allocator）或保留記憶體區段申請 64MB 緩衝區，並將實體位址寫入 `REG_DMA_UPG_PS_ADDR`。
* 進入低功耗休眠，等待 Doorbell 中斷或輪詢 `REG_DMA_UPG_CTRL[0]`。

### 4.2 驗證與寫入流程
```bash
#!/bin/sh
set -e

TMP_DIR="/tmp/upgrade_staging"
rm -rf "$TMP_DIR" && mkdir -p "$TMP_DIR"

# 1. 自 DDR4 記憶體取出 tar 檔案
cp /dev/qpcie_dma_buf /tmp/upgrade.tar.gz

# 2. 測試 tar.gz 完整性
if ! tar -tzf /tmp/upgrade.tar.gz > /dev/null 2>&1; then
    echo "ERROR: Corrupted tar archive"
    exit 1
fi

# 3. 解壓縮至臨時目錄
tar -xzf /tmp/upgrade.tar.gz -C "$TMP_DIR"

# 4. SHA256 校驗 (若封包內有 sha256sums.txt)
if [ -f "$TMP_DIR/sha256sums.txt" ]; then
    (cd "$TMP_DIR" && sha256sum -c sha256sums.txt)
fi

# 5. 原子替換 eMMC BOOT 分區
EMMC_BOOT_MNT="/mnt/emmc_boot"
mkdir -p "$EMMC_BOOT_MNT"
mount /dev/mmcblk0p1 "$EMMC_BOOT_MNT"

[ -f "$TMP_DIR/BOOT.BIN" ] && cp -v "$TMP_DIR/BOOT.BIN" "$EMMC_BOOT_MNT/BOOT.BIN"
[ -f "$TMP_DIR/image.ub" ] && cp -v "$TMP_DIR/image.ub" "$EMMC_BOOT_MNT/image.ub"
[ -f "$TMP_DIR/boot.scr" ] && cp -v "$TMP_DIR/boot.scr" "$EMMC_BOOT_MNT/boot.scr"
sync
umount "$EMMC_BOOT_MNT"

# 6. 同步寫入硬體備份分區 (mmcblk0boot0)
if [ -b "/dev/mmcblk0boot0" ] && [ -f "$TMP_DIR/BOOT.BIN" ]; then
    echo 0 > /sys/block/mmcblk0boot0/force_ro 2>/dev/null || true
    dd if="$TMP_DIR/BOOT.BIN" of=/dev/mmcblk0boot0 bs=64k conv=fsync status=none
    echo 1 > /sys/block/mmcblk0boot0/force_ro 2>/dev/null || true
fi

# 7. 回報 Host 成功並重開機
sync
sleep 1
systemctl reboot
```

---

## 5. Host 主機端更新工具 (`test_app/qpcie_upgrade`)

Host 端提供單一可執行工具 `qpcie_upgrade`，支援兩種模式：
1. **目錄或檔案模式**：
   ```bash
   # 自動打包並更新
   sudo ./qpcie_upgrade --boot BOOT.BIN --kernel image.ub --script boot.scr
   ```
2. **單一 Package 模式**：
   ```bash
   sudo ./qpcie_upgrade upgrade.tar.gz
   ```

* **執行過程**：
  1. 連接 `/dev/qpcie_ctrl`。
  2. 讀取板端狀態，確認為 `IDLE`。
  3. 配置 H2C DMA，發起單次高速傳輸（耗時 ~15ms）。
  4. 寫入 `TRIGGER`，等待板端回傳 `SUCCESS`（約 1.5 秒完成 eMMC 寫入）。
  5. 提示使用者：「升級成功，SC7F0 正在重啟中！」。

---

## 6. 實施階段與查核清單 (Roadmap Checklist)

- [ ] **階段 1：硬體基礎確認 (當前階段)**
  - [ ] 實機完成目前 eMMC 冷開機驗證（確認 Host `lspci -d 12ab:e380` Gen3 x4 枚舉成功）。
  - [ ] 驗證基本 PCIe BAR0/BAR1 讀寫與 V4L2 測試。
- [ ] **階段 2：PL-to-PS DMA 接口連接**
  - [ ] 在 Vivado / RTL 中將 PCIe H2C DMA 資料流引至 PS 的 `S_AXI_HP0_FPD`。
  - [ ] 在 `axil_reg_space.v` 中加入 `0x0780 ~ 0x0794` Upgrade CSR 暫存器。
- [ ] **階段 3：板端 Linux 守護服務實作**
  - [ ] 撰寫 `qpcie_upgrade_daemon` 與 systemd 服務。
  - [ ] 整合進 `petalinux/qpcie-zu4ev` 根檔案系統。
- [ ] **階段 4：Host 端 CLI 工具實作與驗證**
  - [ ] 開發 `test_app/qpcie_upgrade.c`。
  - [ ] 實機執行 40MB `upgrade.tar.gz` 傳輸與自動重啟升級驗證。
