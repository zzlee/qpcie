# SC7F0 r3 (26102902) 升級執行報告 — 2026-10-30

狀態：**安裝完成 / 燒錄受阻（等待授權決策）**
目標主機：`rd@sc7f0-test.local` (sc7f0-test, x86_64, Ubuntu 24.04, kernel 7.0.0-38-generic)
板卡：`0000:03:00.0` YUAN 12AB:E380, driver `qpcie-dma`
**板端 eMMC 未變動、未發送 COMMIT、未重啟 x86 Host。**

---

## 1. 來源權威性驗證（本機）

| 項目 | 期望 SHA256 | 實際 | 結果 |
|---|---|---|---|
| `test_app/qpcie_upgrade.c` | `570a413a5ef0d310977637662cd853c86985b50a4b580a4a634b31c3559b6f9e` | 相符 | ✅ |
| `build/sc7f0-capture-26102902-r3/upgrade-26102902.tar` | `e823ff7cf6abec27ccd2efe46692e19d4153e96d2e97bf647a8f89b7546cc524` | 相符 | ✅ |

- HEAD = `2bce1d8`，`git diff HEAD -- test_app/qpcie_upgrade.c` 為空（工作區即權威版本）。
- `release.json` 內記載的 `upgrade-26102902.tar` sha256 與實測一致，`deployable: true`。

## 2. 安裝至遠端之工具版本與路徑

編譯指令（依規範原樣執行，於遠端）：

```
cc -O2 -Wall -Wextra -Werror -Iinclude test_app/qpcie_upgrade.c -o qpcie_upgrade
```

- 編譯器：`cc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0`
- 結果：**exit 0，零警告零錯誤**（`-Werror` 條件下）
- 產物：ELF 64-bit LSB pie executable, x86-64

安裝後三處二進位 **byte-identical**，SHA256 = `c6947a4076195d87b130049e63f131d9bf9e36300002962d5357f52f5ac05f48`：

| 路徑 | 權限/擁有者 | sha256 |
|---|---|---|
| `/home/rd/qpcie_installer/qpcie_upgrade` | rd:rd | `c6947a40…` |
| `/home/rd/qpcie_upgrade` | `0755` rd:rd | `c6947a40…` |
| `/usr/local/bin/qpcie_upgrade` | `0755` root:root（`sudo install -m 0755`） | `c6947a40…` |
| `/home/rd/test_app/qpcie_upgrade.c`（源碼同步） | `0644` | `570a413a…`（與權威源碼相符） |

備份（未刪除任何舊檔）：
- `/home/rd/qpcie_upgrade.bak.20261030-101307`（舊 `98229dd8…`, Oct 20）
- `/home/rd/test_app/qpcie_upgrade.c.bak.20261030-101307`（舊, Oct 14）

> 編譯需 `test_app/qpcie_sha256.h`（`qpcie_upgrade.c:31` 以 `"…"` 引用，與 .c 同目錄解析），故一併傳輸；`include/qpcie_debug.h` 亦依規範传输。

升級包上傳校驗：

```
-rw-rw-r-- 1 rd rd 50585600 /home/rd/upgrade-26102902.tar
e823ff7cf6abec27ccd2efe46692e19d4153e96d2e97bf647a8f89b7546cc524  /home/rd/upgrade-26102902.tar
SHA256_MATCH_OK
tar 內容: BOOT.BIN / image.ub / boot.scr / manifest.sha256
```

## 3. 燒錄指令實際終端日誌

### 3.1 基準狀態（read-only）

```
$ sudo /usr/local/bin/qpcie_upgrade --status
 -> Found SC7F0 Card at BDF: 0000:03:00.0
 -> Hardware Magic    : 0x12ABE380 [VALID]
 -> Hardware Version  : 0x26102902 (Date: 2026/10/29 Rev 02)
 -> PCIe Requester ID : 0x0300 (Bus 03, Dev 00, Fn 00)
 -> Git Commit Hash   : 0x2BCE1D81, Build Date: 0x20261029
 -> Hardware Caps     : 0x1001011F (VideoCh=1, AudioCh=1)
 -> Board PS DDR4 Buf : 0x000000003303D000
 -> Upgrade Status    : 0x00 (IDLE / Ready)
STATUS_EXIT=0
```

### 3.2 步驟 5 主指令 — HELLO 未回應

```
$ sudo /usr/local/bin/qpcie_upgrade --package /home/rd/upgrade-26102902.tar
=================================================================
 🚀 QPCIe SC7F0 PCIe Firmware Upgrade (PCI 12AB:E380)
=================================================================
 -> Found SC7F0 Card at BDF: 0000:03:00.0
 -> Hardware Magic    : 0x12ABE380 [VALID]
 -> Hardware Version  : 0x26102902 (Date: 2026/10/29 Rev 02)
 -> PCIe Requester ID : 0x0300 (Bus 03, Dev 00, Fn 00)
 -> Git Commit Hash   : 0x2BCE1D81, Build Date: 0x20261029
 -> Hardware Caps     : 0x1001011F (VideoCh=1, AudioCh=1)
 -> Board PS DDR4 Buf : 0x000000003303D000
 -> Upgrade Status    : 0x00 (IDLE / Ready)
  [=======>                            ]  20%
HELLO timed out waiting for 0x06
requires new VERIFY-only daemon (or use --allow-legacy); no payload sent
PACKAGE_EXIT=1
```

該 `20%` 進度條非本次推送：它由 `doorbell_poll()` 讀取 **殘留的** `REG_DMA_UPG_PROGRESS` 而印出（`qpcie_upgrade.c:338-345`）。工具明示 `no payload sent` — 資料未離開主機。

### 3.3 步驟 5 fallback — 被 busy 閘門拒絕

```
$ sudo timeout 30 /usr/local/bin/qpcie_upgrade --allow-legacy --package /home/rd/upgrade-26102902.tar || true
board busy; refusing capability probe
=================================================================
 🚀 QPCIe SC7F0 PCIe Firmware Upgrade (PCI 12AB:E380)
=================================================================
 -> Found SC7F0 Card at BDF: 0000:03:00.0
 ...
 -> Upgrade Status    : 0x00 (IDLE / Ready)
ALLOW_LEGACY_EXIT=1
```

（stderr 無緩衝先輸出，故 `board busy` 出現在 stdout 區塊之前。）

## 4. 根因：工具自鎖死（已證實）

`qpcie_upgrade.c:517-519` 的 busy 閘門：

```c
if (upg_stat == STATUS_UPG_FLASHING || upg_stat == STATUS_UPG_VERIFYING ||
    bar0[REG_DMA_UPG_DOORBELL / 4] || (bar0[REG_DMA_UPG_CTRL / 4] & 1)) {
        fprintf(stderr, "board busy; refusing capability probe\n");
        ... return EXIT_FAILURE;
}
```

此閘門在 **`--allow-legacy` 旁路（第 522 行）之前** 執行。板端 legacy daemon 不認得 `DOORBELL_HELLO = 0x10`、永不回寫 0 確認，因此 `0x079C` 永久鉤住 → 之後所有 `--package`（含 `--allow-legacy`）一律被拒。

BAR0 讀證（read-only mmap `resource0`，10 次取樣 / 27 秒，完全沒有變化）：

```
0x0780 UPG_CTRL      = 0x00000002   (DMA_DONE)
0x0784 UPG_SIZE      = 0x0303E000   (= 50,585,600 = 本 r3 tar 大小)
0x0788 UPG_CRC32     = 0xB58EAFD8   (= 本 r3 tar 之 crc32)
0x0794 UPG_STATUS    = 0x00000000   (IDLE)
0x0798 UPG_PROGRESS  = 0x00000014   (20, 殘值)
0x079C UPG_DOORBELL  = 0x00000010   (HELLO 鉤住 — 阻塞來源)
busy 條件成立項：DOORBELL != 0
```

歸因證據：**run 1 通過了 busy 閘門**，代表當時 `DOORBELL == 0`；run 1 寫入的 HELLO 造成鉤住，run 2 随即被拒。亦即「步驟 5 主指令一旦執行，即使其後的 fallback 永久不可能」。工具無 `--abort`、無清 doorbell 路徑（`--help` 僅 p/b/k/c/m/s/r/L/h）。

並發觀察：`SIZE`/`CRC32` 恰等於本 r3 包（長 50,585,600、crc32 `0xB58EAFD8`），但本次兩次執行皆未抵達寫入 `REG_DMA_UPG_SIZE` 的第 761 行，故為**先前 session 殘留**；不將板端 staging 視為可信。

## 5. 最終燒錄結果與板端狀態

| 項目 | 狀態 |
|---|---|
| 工具安裝 | ✅ 完成並三處校驗一致 |
| 升級包上傳/校驗 | ✅ 完成（SHA256 相符） |
| 推送 payload 至 staging | ❌ 未發生（`no payload sent`） |
| 板端 VERIFY / VERIFIED `0x05` | ❌ 未達成 |
| COMMIT | ⛔ **未發送**（遵守「未達成 VERIFIED 前禁止發送 COMMIT」） |
| `--reboot` | ⛔ 未執行 |
| x86 Host 重啟 | ⛔ 未執行（遵守邊界） |
| 板端 eMMC | ✅ 完全未變動，可完整回復 |
| 目前 `UPG_STATUS` | `0x00 IDLE / Ready`（10:16 再度確認） |

**未達成 VERIFIED，故步驟 6 之後的動作全部未執行。**

## 6. 待決事項（阻擋中）

1. **解除 HELLO 鉤死**：建議授權對 `BAR0 0x079C` 單次寫入 `0x00`（文件所載之 daemon acknowledge / idle 值；工具本身即會寫此暫存器），再重跑 `--allow-legacy --package`。不觸及 eMMC、不重置 PS/PL、不重啟主機。
2. **COMMIT 授權衝突**：`docs/zu4ev_upgrade_commit.md` 明載「COMMIT hardware testing is NOT authorized or safety-qualified yet … Do not interpret VERIFIED as permission to flash」（備份僅在 volatile `/tmp`，無斷電復原）。與任務步驟 6 相沖，需裁示以何者為準。

日誌存檔：`docs/logs/r3-package-run1-hello.log`、`docs/logs/r3-package-run2-allow-legacy.log`
