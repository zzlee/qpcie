# SC7F0 全量重建 / 打包 / 驗證（B1）— 2026-11-11

狀態：**進行中**（FPGA 第 2 輪 `26111103` 進行中）。本報告記錄 B1 實際做了什麼、
第 1 輪为何失敗、修正與測試、以及尚待完成的項目。

本階段安全界線（全程遵守）：**未部署、未燒錄、未替換任何板上單一檔案、未重啟卡、
未重啟服務、未載入/卸載驅動、未寫控制暫存器、未執行 `qpcie_upgrade --status`（它會
經 setpci 寫入）、未 `git add/commit/push`、未使用舊影像/舊產物冒充新全量建置。**

相关報告：A 報告（功能現況快照）[docs/sc7f0_bringup_progress_20261111.md](sc7f0_bringup_progress_20261111.md)；
本報告是它的交付/可重現性後續（B1）。B2（部署）在獨立 review 前鎖住。

---

## 1. 結論摘要

| 項目 | 狀態 | 證據 |
|---|---|---|
| 可重現全量 entry point | 完成 | `scripts/build_sc7f0_vcu_release.sh`（preflight/fpga/ps/package/all） |
| 版本身份真正套用到再綜合 | 完成（且由綜合產物反查） | `synth_1/zu4ev_pcie_card_top.tcl` + `runme.log` 綁定 |
| 第 1 輪 `26111102` | **失敗**（我寫的身份驗證 proc 有 Tcl 缺陷） | `build/vcu-release-26111102-r1/NOT_DEPLOYABLE` |
| 第 2 輪 `26111103` | 進行中（synth→place→route→strict gate） | `build/vcu-release-26111103-r1/logs/release.log` |
| PS 執行期元件入影像 | 機制+驗證器完成，實際影像待 PS 階段 | `scripts/package_sc7f0_rootfs.py`、`sc7f0-vcud` recipe/service |
| 正式四件套升級包 | 腳本+負向測試完成，實際包待 PS 完成 | `scripts/package_sc7f0_vcu_release.sh`、`scripts/check_sc7f0_release_package.py` |
| COMMIT 備份語義修正 | 完成（host tb 全過） | `test_app/qpcie_backup_retention.h` + tb |
| 本地測試閘 | 通過（182 tests，0 非預期失敗） | `build/vcu-release-26111103-r1/gates/unit-tests.json` |
| strict timing/CDC gate | **尚未判定**（route 後才知道） | PENDING |

一句話：今天 17:40 那個「能動」的狀態仍依賴包外檔案；B1 把「能重建成一樣的東
西」補起來，並在過程中抓到兩個會讓交付假成功的真實缺陷（見 §4、§6）。

---

## 2. 各輪次的凍結快照與一致性鏈（審查要求）

### 2.1 輪次 `26111102-r1`（失敗，保留作事證）

| 凍結點 | 時間（local） | 產物 | SHA256 |
|---|---|---|---|
| preflight 身份 | 18:14:03 | `identity.json` | `cc19bffb2a2ef5ad…` |
| 全樹逐檔清单（492 檔） | 18:14:03 | `SOURCE.sha256` | （含於 identity 記錄） |
| FPGA 輸入清单（172 檔） | 18:14:03 | `SOURCE_FPGA.sha256` | `21e49385ceb7fbaf…` |
| 來源快照 | 18:14:03 | `source-snapshot.tar.gz` | `3a0400fb951192aa…` |
| 建置腳本清单 | 18:14 後由 hw 階段產生 | `fpga/project-logs/SOURCE_RTL.sha256`（78 檔）、`SOURCE_BUILD.sha256`（12 檔） | — |

身份：`C_VERSION=0x26111102`、GIT 暫存器 `0xD2253D57`（來源 = **dirty-content
fingerprint**，不宣稱 clean HEAD）、`BUILD_TIMESTAMP=20261111`、HEAD `aea86126`、
worktree_dirty=true。

實際 binary 來源鏈（已驗證的部分）：
- 綜合前套用：`set_property verilog_define {GIT_COMMIT_HASH_DEF=32'hD2253D57
  BUILD_TIMESTAMP_DEF=32'h20261111 SC7F0_C2H_ONLY=1}`、
  `set_property generic C_VERSION=32'h26111102`（`synth_1/zu4ev_pcie_card_top.tcl` 第 87–88 行）。
- 綜合真的綁定：`synth_1/runme.log` → `Parameter C_VERSION bound to:
  32'b00100110000100010001000100000010`（=0x26111102）。
- **但沒有 bit、沒有 XSA**：place/route 從未執行，因此本輪不可部署、不可打包，
  `gates/` 內也沒有（也不准捏造）任何 gate 通過紀錄。

失敗真因（不是時序、不是資源、不是來源漂移造成）：

```
expected integer but got "i"      (reading increment)
invoked from within "incr -1 i"   (procedure "sc7f0_verify_identity" line 22)
(file "scripts/impl_sc7f0_dual_video.tcl" line 245)
```

`incr -1 i` 在 Tcl 是「把名為 `-1` 的變數增加 `i`」。這是我为 B1 新寫的**身份驗證
碼自身**的缺陷，位於綜合之後、佈局之前。教訓已轉成測試（§4）。

事後一致性（由工具判定，非我口頭聲明）：

```
MANIFEST_VERIFY SOURCE_FPGA.sha256                 files=172 MISMATCH scripts/impl_sc7f0_dual_video.tcl
MANIFEST_VERIFY fpga/project-logs/SOURCE_RTL.sha256 files= 78 OK
MANIFEST_VERIFY fpga/project-logs/SOURCE_BUILD.sha256 files= 12 MISMATCH scripts/impl_sc7f0_dual_video.tcl
verdict = SOURCE_DRIFT_BITSTREAM_FATAL
```

即：Tcl 修正之後，`26111102` 的凍結指紋**不再能自我再現**。因此依驗收條件走「新一
輪完整 build」，而不是续跑該專案、不是重寫 manifest、不是縮 scope。

### 2.2 輪次 `26111103-r1`（目前進行中）

| 項目 | 值 |
|---|---|
| 分配 | `26111103`（allocator 明確避免 `26111101`（文檔在用）與 `26111102`（既有 build 目錄）） |
| 凍結時間 | 18:47 local |
| `identity.json` | `e504cead4996659e…` |
| `SOURCE.sha256`（全樹逐檔） | `13bc2561c1580881…` |
| `SOURCE_FPGA.sha256`（FPGA 輸入） | `62e4f9cbbb65f6cc…` |
| `source-snapshot.tar.gz` | `c95d51d01efa21ea…` |
| 身份 | `C_VERSION=0x26111103`、GIT 暫存器 `0xB821E48E`（dirty-content-fingerprint）、DATE `20261111` |
| fpga scope | `93db3a21975b47d7…`（`SOURCE_IDENTITY_STABLE scope=fpga files=307`） |
| strict gate 策略 | `SC7F0_TIMING_GATE=strict`（entry point 強制，`record`/`off`/寬減一律拒絕） |
| VCU | `SC7F0_ENABLE_VCU=1` |

三段式凍結（誰對誰負責）：
1. **FPGA 凍結**（preflight 18:47）→ 對 bit/XSA 負責：`SOURCE_RTL.sha256`（rtl+constraints 的 `.v/.sv/.xdc`）、
   `SOURCE_BUILD.sha256`（build/impl/check 腳本）、`SOURCE_FPGA.sha256`（entry 的 FPGA 輸入清单）三者
   在 FPGA 階段結束時以 `sha256sum -c` 逐檔複核，且 `hardware.xsa` 內的 bit 必須與
   `fpga/zu4ev_pcie_card_top.bit` 逐位元組相同。
2. **PS 凍結**（PS 階段起始）→ 對新 image/runtime 負責：另存 `ps/identity-ps.json`，
   並以 `imported-xsa.sha256` 證明 PS 是用**本轮**的 `hardware.xsa` 匯入建置。
3. **release manifest** → 對兩者一起負責：`RELEASE.sha256`、`release.json`、
   `release-provenance.json`（身份、三種 scope 指紋、gate 結果、證據檔雜湊清單）。

漂移政策（回應「不可用改 scope/排除實際輸入來隱藏 dirty 漂移」）：
- `scripts/sc7f0_source_drift.py` 匯入（不是複製）`sc7f0_release_id.py` 的 scope 規則，
  逐檔比對 preflight 快照與目前樹，並將差異分類為 `BITSTREAM_INPUT_*` / `PS_INPUT_*` /
  `TOOLING_*` / `POLICY_EXCLUDED_FROM_IDENTITY_STILL_ON_DISK`；只要有任何 bitstream
  輸入變更，或任一份權威 manifest 複核不過，verdict 直接是
  `SOURCE_DRIFT_BITSTREAM_FATAL`（r1 就是被它判掉）。
- scope 排除清單只涵蓋 release/驗證**工具**與 PetaLinux 自行重寫的 `project-spec/configs/`
  （該目錄仍會被逐檔哈希進 PS build logs）；`rtl/`、`constraints/`、`scripts/*.tcl`、
  CSR 產生器、timing/VCU delta 檢查腳本一律**在** scope 與 manifest 內。本次未為了讓
  閘門變綠而動過這份清單。
- 被政策排除的 17 個 `configs/*` 檔案另立分類，避免把「政策排除」講成「檔案消失」。

---

## 3. 根因與修正（檔案級）

| 檔案 | 根因 | 修正 |
|---|---|---|
| `scripts/run_rebuild_26110301_vcu.sh` | 硬碼已刪除 worktree `/home/zzlee/vibecoding/sc7f0-dual-video`，且用 `SC7F0_TIMING_GATE=record` | 退役為指向新 entry point 的路標；不再是最終入口 |
| `scripts/run_c2h_ab_regression.sh`、`scripts/run_vcu_ooc.sh` | 同上硬碼絕對路徑 | 改由腳本位置推 repo root |
| `scripts/impl_sc7f0_dual_video.tcl` | 身份只在建專案時套过一次；後續重新綜合沿用舊身份（26111103/04/05 三份實體 bit 都回報 0x26110301 + 10/27 commit 即為此） | 身份在**重新啟動綜合前**套用（all-or-nothing 三個變數），並從 `synth_1` 產物反查；保留既有 profile define（`SC7F0_C2H_ONLY`） |
| `scripts/impl_sc7f0_dual_video.tcl` | `incr -1 i`（Tcl 語意錯誤）→ r1 於綜合後中止 | `incr i -1` |
| `scripts/impl_sc7f0_dual_video.tcl` | 身份反查用整檔 substring，無法分辨值在哪個 property，舊值殘留也能過 | `sc7f0_run_property`/`sc7f0_require_stamp`：讀取實際承載屬性（generic / verilog_define），值不符或放錯 property 即 `SC7F0_IDENTITY_MISMATCH`；改字串解析（Tcl braced regex 会在 bracket class 内第一個 `}` 截斷） |
| `scripts/build_sc7f0_matching_ps_vcu.sh` | 硬碼 PL-base 允許清單，擋掉後續 VCU 修訂 | 改為格式驗證並與本輪 XSA/身份綁定 |
| `petalinux/.../recipes-apps/sc7f0-vcud/*` | `sc7f0_vcud` 只在 BOOT 分區當游離檔，影像裡沒有 | 新 recipe（從 `test_app/sc7f0_vcud.cpp` 於影像內編譯）+ systemd unit + image bbappend + rootfsconfig；DESCRIPTION 敘述依實測影像更正 |
| `scripts/package_sc7f0_rootfs.py` | 原用 `mkimage -T flat_dt -p N -o …` 解析 FIT —— `mkimage` 的 `-p` 是 **patch**，會原地改寫輸入檔（曾把一份歷史 image.ub 截到 0 bytes，已依該發行目錄 manifest 還原並全目錄複核 OK） | 改純唯讀 Python FIT/FDT 解析（依 name+type 找 ramdisk，候選 base 必須實測可解析才採信）；`verify()` 任何例外轉為 FAIL 而非 traceback；**dangling enabled-unit symlink 原會被判 PASS，已修正** |
| `test_app/qpcie_upgrade_daemon.c`、`qpcie_backup_retention.h` | COMMIT 先 `rm -rf .backup_upgrade` 再寫「目前的檔」→ 同版重試或第二次 COMMIT 會把唯一的前一代換成當前影像；中途中斷會在還原前失去唯一恢复集 | 世代保留（txn- → gen-）、啟動時先恢复、未完成交易絕不刪除、世代絕不原地覆寫、空間不足**在複製前**拒絕 |
| `rtl/qpcie_csr_reg_space.v` | 產生的 CSR CDC wrapper 過期（`generate_sc7f0_csr_cdc.py --check` 失敗），缺 Packet DMA 狀態計數器跨 CDC | 重新產生（在 r1 凍結前，故 r1 manifest 仍自洽） |
| `scripts/tests/test_sc7f0_hdmi_dt.py` | 預設指向已刪除 IP 目錄 → 誤導性失敗 | 需 `SC7F0_TEST_XCI_DIR`，否則以可執行理由 skip；FPGA 階段用真實 IP 目錄並 `--require-run` |
| `scripts/sc7f0_release_tests.py` + `scripts/tests/RELEASE_TEST_BASELINE.json` | 測試依賴已刪除 IP/建置目錄與 MCU 產物 | 基線只容忍**既有** MCU 影像缺檔（附理由）；新增失敗/缺 gate 一律 blocker；`--require-run` 可強制關鍵測試必須真的執行 |

---

## 4. 測試矩陣與結果

本地閘（在 r3 preflight 內執行，作為 build 前置條件）：

```
$ python3 scripts/sc7f0_release_tests.py --out build/vcu-release-26111103-r1/gates/unit-tests.json
Ran 182 tests in 5.216s
UNIT_TESTS_GATE_PASS tolerated=10 failures=10 skipped=25 ran=154
```

r3 凍結後又新增了 19 個 case（`scripts/tests/` 不在 fpga/ps 身份 scope 內，也不在
`SOURCE_FPGA.sha256` 的 glob 中，所以不會弄壞已凍結的位元流輸入清單）：

```
$ python3 scripts/sc7f0_release_tests.py --out build/vcu-release-26111103-r1/unit-tests-postfix.json
Ran 201 tests in 5.764s
UNIT_TESTS_GATE_PASS tolerated=10 failures=10 skipped=25 ran=171
```

- `tolerated=10` 全部是既有 MCU 影像缺檔（`RELEASE_TEST_BASELINE.json` 有逐條理由）。
  新增的任何失敗或「關鍵測試被跳過」都會讓閘門失敗 —— r1 之後新增的 36 個測試全數
  真的執行且全過。
- 新增加入的兩組測試（本輪新增 36 個 case）：
  - `scripts/tests/test_sc7f0_impl_identity.py`（13）：以 `tclsh` 直接執行 build script
    裡的身份 proc。**正向**用 r1 的真實 `synth_1` 產物（必須 PASS）；**負向**含舊
    version、舊 GIT 暫存器（`2BCE1D81`，正是 11-03 的真實故障形態）、缺 generic、
    run log 未綁定 `C_VERSION`、stamp 只出現在註解、以及 `info complete` 括號平衡檢查。
  - `scripts/tests/test_sc7f0_fit_rootfs.py`（23）：bare FIT / legacy 包裝 / inline
    `data` / external `data-offset`（多個候選 base 必須實測解析成功才採信）/ gzip 與
    巢狀 uImage / 各切點截斷 / 壞 magic / tree 長度不一致 / ramdisk 缺失或多個 /
    cpio symlink 與 dangling 連結 / 非 ARM64 / 「reader 絕不寫入輸入檔」；並用官方
    `dumpimage` **在副本上**交叉對照，且斷言工具未修改輸入。
- Host C 測試（備份語義）：
  ```
  cc -O2 -Wall -Wextra -Itest_app test_app/qpcie_backup_retention_tb.c -o /tmp/qbr_tb && /tmp/qbr_tb
  TB_PASS: backup retention (3 generations kept) survives same-version retries, repeated
           COMMITs, an interrupted apply, an unreadable journal and a BOOT partition with no room
  cc -O2 -Wall -Wextra -Itest_app tb/qpcie_commit_integration_tb.c -o /tmp/qcit_tb && /tmp/qcit_tb
  TB_PASS: transactional COMMIT with generation-retaining backup verified ...
  ```
- ARM64 交叉編譯：`make -B -C test_app qpcie_upgrade_daemon` → 0 error（僅
  `-Wformat-truncation` 提示；`snprintf` 緩衝已放大到 1400）。
- PENDING：strict timing/CDC gate、XSA/bit 逐位元組相符、rootfs 內容證明、升級包負向
  測試（缺 runtime / 缺或錯 manifest / version-bit-XSA 不匹配 / 缺 gate / 假 gate）。

---

## 5. rootfs binary/service 證據

方法論：只看**實際影像**（`image.ub` 內 ramdisk 解包），不看 staging 目錄。驗證器
`scripts/package_sc7f0_rootfs.py verify` 檢查：binary 存在且為 ARM64 ELF、regular +
executable、unit 安裝於 `/lib/systemd/system`、`multi-user.target.wants` 的 symlink
確實指向影像內存在的 unit、`ExecStart` 不得是 `/run/media`、`/tmp`、`/mnt` 的游離檔。

對**出廠影像**（`build/sc7f0-ps-watchdog-20261027-r2-release/images/image.ub`，
sha256 `3f5d74ab461a6b854e80af59890f9374e4a1536c776b1f0c4f9d5d9922c9c72e`）實測：

```
cpio entries: 2544
usr/bin/qpcie_debugd          mode=0o100755 size=784232  ARM64=Yes uid=0
usr/bin/qpcie_hdmi_daemon     mode=0o100755 size=782320
usr/bin/qpcie_upgrade_daemon  mode=0o100755 size=862744
usr/bin/sc7f0_ps_watchdog     mode=0o100755 size=949680
usr/bin/omx_encoder|omx_decoder, usr/lib/libOMX.allegro.*.so, usr/lib/liballegro_*.so
lib/firmware/al5d.fw al5d_b.fw al5e.fw al5e_b.fw           # Allegro VCU firmware
enabled: qpcie-debugd / qpcie-hdmi-daemon / qpcie-upgrade-daemon / sc7f0-ps-watchdog
缺失: usr/bin/sc7f0_vcud、lib/systemd/system/sc7f0-vcud.service
```

因此真實缺口（也是今日必須靠包外檔案才能動的原因）：
1. `sc7f0_vcud` 與它的 unit 不在影像（曾是 BOOT 分區游離檔，`ExecStart` 指向
   `/run/media/...` 那種東西正是驗證器會拒絕的形態）；
2. 影像內的 `qpcie_debugd` 是 **0x800 mailbox 之前**的舊版；本輪由 recipe 從
   `test_app/` 現行源碼重建，故新影像自帶正確版本。

（更正：我曾在 recipe 敘述裡寫「OMX 函式庫完全不在 rootfs」，與實測不符，已用 edit
改正。VCU/OpenMAX 庫與韌體其实在出廠影像內就有。）

---

## 6. COMMIT 備份語義、首次舊 installer 升級相容性、回復可行性

### 6.1 旧行為为何危险
`do_commit` 之前會 `rm -rf .backup_upgrade`，然後把**卡上目前的檔**寫進去。後果：
- 同一 package 重試或第二次 COMMIT → `.backup_upgrade` 內容 = 當前影像 → 「備份」不再
  是任何舊一代；
- 中途斷電/失敗 → 唯一可恢复的位元組已在恢復之前被刪除。

### 6.2 新政策（`test_app/qpcie_backup_retention.h`）
- `.backup_upgrade` 變成**保留根目錄**；每次 COMMIT 一個 `txn-<epoch>-<n>`，完成後
  `rename` 成 `gen-<epoch>-<n>`（同檔系統 rename，不做複製後刪除）。
- 啟動/COMMIT 前先 `qbr_recover_all`：未完成交易優先恢复；journal 不可讀 → fail
  closed，保留位元組並拒絕再刷（實測訊息 `must not be reflashed`）。
- 舊版單一目錄佈局是**adopt**（把 payload 移進 `gen-0000000000-legacy`），不是刪除。
- 保留 `QBR_MAX_GENERATIONS=2` 個**已完成**世代；沒有 verdict 的目錄既不佔保留名額也
  永不刪除（否則半筆資料會擠掉最後一份好備份）。
- 空間：vfat 不保留任何空間。`qbr_room()` 在**複製前**要求 `free >= 需要的世代大小 +
  64 MiB`，不足即拒絕（不 stage、不刪檔、給 host 明確原因）；`qbr_prune_for_space()`
  只在促態完成後、且無進行中交易時，依序刪除最舊的**已完成**世代，至少保留 1 代。
- 尺寸估算：`BOOT.BIN` + `image.ub` + `boot.scr` ≈ 50 MB/代，2 代 ≈ 100 MB。卡上 BOOT
  分區實際可用空間本階段無法量測（不碰卡）→ 列入 B2 必做測量；不足時新daemon 會拒絕
  而非寫到一半。

tb 覆蓋：舊佈局 adopt、首次 COMMIT 保留前一代、同版重試不會把較舊一代變成當前影像、
中途中斷在下次啟動被恢复、journal 不可讀 fail closed、保留根unsafe 時 COMMIT 拒絕、
空間不足拒絕、`qbr_prune_oldest` 只刪已完成且留最新。

### 6.3 首次從舊 image/舊 installer 升級
- **PL mailbox / 狀態暫存器協定未變**：改的是 eMMC 上的備份佈局與 host 端工具來源，
  `REG_DMA_UPG_*` 狀態碼與 VERIFY→COMMIT 一次一用的語意未動 → 舊 host
  `qpcie_upgrade` 仍可驅動新 daemon（拒絕路徑沿用既有 `STATUS_UPG_ERR_*`）。
- 舊卡只有單一 `.backup_upgrade` 目錄 → 走 adopt 路徑（有 tb）。
- 舊 rootfs 沒有 `sc7f0_vcud`：升級後由新影像提供（recipe + unit enable），不再需要
  host 推檔；`qpcie_debugd` 同時被換成含 0x800 mailbox 的重建版。
- 升級包本身仍是標準四件套（`BOOT.BIN image.ub boot.scr manifest.sha256`，嚴格 ustar、
  無 PAX/GNU 擴充欄位）→ 舊 host 工具的解析不受影響。

### 6.4 回復（rollback）可行性
- 材料：`/run/media/BOOT-mmcblk0p1/.backup_upgrade/gen-*/{BOOT.BIN,image.ub,boot.scr}`
  （以及被 adopt 的 `gen-0000000000-legacy`）。
- 手動回復 = 把該代三個檔複製回 BOOT 分區根目錄（同一 vfat，先 umount 再 sync）；
  daemon **沒有**「回復第 N 代」指令，本輪也未新增（避免在卡上引入新寫路徑）。
- 自動路徑只剩啟動時的 journal 恢复（把 APPLYING 中的交易還原），加上 eMMC BOOT 失敗
  時的 SD installer（`BOOT_SD_INSTALLER.BIN` 流程）作為最後手段。
- 計畫（B2 之前不執行）：任何一次 COMMIT 前先由 host 記錄 BOOT 分區現況三檔 sha +
  另存一份副本，並記錄 `df`；COMMIT 後再做獨立 eMMC sha 複核與開機 ID 證明。

---

## 7. 精確指令（可重現）

```bash
# 前置： licence 由操作者提供，只在本 shell 內使用
export XILINXD_LICENSE_FILE=2101@192.168.200.112

# 全量（preflight → fpga → ps → package），一次性、目錄寫一次
scripts/build_sc7f0_vcu_release.sh --out build/vcu-release-26111103-r1 --stage all \
    --version 26111103 --known-version 26111101 --known-version 26111102

# 分段檢視／重跑（同一目錄；fpga/ps/package 需 preflight 已建立 identity.json）
scripts/build_sc7f0_vcu_release.sh --out build/vcu-release-26111103-r1 --stage fpga
scripts/build_sc7f0_vcu_release.sh --out build/vcu-release-26111103-r1 --stage ps
scripts/build_sc7f0_vcu_release.sh --out build/vcu-release-26111103-r1 --stage package

# 一致性 / 門派發（唯讀）
python3 scripts/sc7f0_source_drift.py --release build/vcu-release-26111103-r1 \
        --json build/vcu-release-26111103-r1/gates/source-drift-during-build.json
python3 scripts/sc7f0_release_tests.py --out /tmp/unit-tests-latest.json
python3 scripts/check_sc7f0_release_package.py --release build/vcu-release-26111103-r1 --self-test
```

---

## 8. PENDING（等 FPGA 結果）

- [ ] strict timing/CDC/bus-skew gate 實測結果（`gates/timing-gate-record.json`、
      `gates/timing-gate-recheck.json`）。已知風險：`capture_clk_300m` 曾在 11-11 以
      -0.116 ns / TNS -4.956 ns 失敗；本轮努力參數記錄在 provenance。
- [ ] `fpga/hardware.xsa` 與 bit 的 sha256 + XSA/bit 逐位元組相符
- [ ] PS 建置（用本轮 XSA）+ `ps/identity-ps.json` + `rootfs-runtime-content.json`
- [ ] `image.ub` 解包證明（`sc7f0_vcud`、unit enabled、`ExecStart=/usr/bin/sc7f0_vcud`、
      OMX/VCU 庫與韌體、重建後的 `qpcie_debugd`）
- [ ] 四件套 tar + `RELEASE.sha256` + `release.json` + `release-provenance.json`
- [ ] 負向包測試（缺 runtime / 缺或錯 manifest / version-bit-XSA 不匹配 / 缺 gate / 假 gate）
- [ ] `gates/bootbin-payload.json`（BOOT.BIN 確實含本轮 bit）
- [ ] B2 前提清單（含 `pl address map vs baseline`：本機無 baseline XSA → 老實記 not performed）

若 strict gate 失敗：停在 FPGA 階段並回報，**不進 package**，並提出具體時序路徑與下一
輪可實施的實體/約束手段（不以寬減 gate 解決）。

---

## 9. 第二輪 review 修正（18:20–19:00，全部離線，未碰卡）

### 9.1 `mkimage -p` 曾破壞歷史影像（已復原；改為純唯讀解析）

根因：舊 `scripts/package_sc7f0_rootfs.py` 用 `mkimage -T flat_dt -p 0 -o out image.ub`
取 rootfs。`mkimage -p` 的語義是 **patch**：它把 `image.ub` 當成輸出緩衝，歷史檔
`build/sc7f0-ps-watchdog-20261027-r2-release/images/image.ub` 因此被截為 0 bytes。

- 復原：由同 release 的 `upgrade-ps-watchdog-20261027-r2.tar` 取回，
  `sha256 = 3f5d74ab461a6b854e80af59890f9374e4a1536c776b1f0c4f9d5d9922c9c72e`
  與該 release `manifest.sha256` 逐字相符；`sha256sum -c RELEASE.sha256` 全部 OK。
  全樹掃描未發現其他 0 bytes 檔。
- 修正：改為純 Python 只讀 FIT/FDT 解析（不呼叫任何會寫檔的 upstream 工具），
  並用 `dumpimage` **在副本上**交叉對照 + 斷言輸入檔 SHA 不變。
- 教訓已寫進程式註解：**驗證工具絕對不得 mutate 被驗證的影像**。

### 9.2 release gate 的可證偽性（新增 16 個負向 case）

`scripts/tests/test_sc7f0_release_package.py` 以合成 release 目錄驱动真實 gate 邏輯，
并使用本 repo 真實歸檔的 report 集作 fixture（`build/qpcie_zu4ev_proj` 過閘、
`build/qpcie_zu4ev_hdmi_proj` 不過閘；缺 fixture 時 skip 且給理由，不假 pass）：

| # | 注入的缺陷 | 期望 | 結果 |
|---|---|---|---|
| 1 | 基線（全對） | `RELEASE_GATE_PASS` | OK |
| 2 | tar 缺 `image.ub` | 拒絕 | OK |
| 3 | payload 改 1 byte、manifest 不動 | 拒絕（manifest） | OK |
| 4 | tar 內缺 `manifest.sha256` | 拒絕 | OK |
| 5 | GNU/PAX header 非 strict ustar | 拒絕 | OK |
| 6 | bit 不是 XSA 內的那個 | 拒絕 | OK |
| 7 | PS image 宣告自另一 XSA | 拒絕 | OK |
| 8 | version-bit 與 release version 不符 | 拒絕 | OK |
| 9 | 缺 strict gate 紀錄 | 拒絕 | OK |
| 10 | **假 gate**：JSON 宣稱 pass，但同目錄真實 report 不過 | 拒絕並報 `FALSE GATE` | OK |
| 11 | 缺 BOOT.BIN payload 證明 | 拒絕 | OK |
| 12 | runtime binary 不在 image 內 | 拒絕 | OK |
| 13 | runtime binary 在 image 內 | 通過 | OK |
| 14 | `release.json` hash 不符 | 拒絕 | OK |
| 15 | provenance 指紋與 identity 不符 | 拒絕 | OK |
| 16 | tar 成員順序不對 | 拒絕 | OK |

### 9.3 移除「不可能通過」的 byte-exact 假驗證（獨立第二類 bug）

`scripts/build_sc7f0_matching_ps_vcu.sh` 原本的影像審計斷言：

```python
assert data == (Path('test_app')/binary).read_bytes(), binary + ' is stale in image.ub'
```

但這些 daemon 是由 recipe 的 `do_compile`（`${CC} ${CFLAGS}` + Yocto sysroot）編出來的，
與本機 `make` 重建的 `test_app/*` **不會**逐位元組相同（而且本機檔可能本身就是舊的，
比對它什麼也證明不了）。這個斷言只會在 PS 階段跑完之後才炸，浪費數十分鐘。

- 改為可證明的性質：in-image 檔必須是 64-bit ARM64 ELF、uid 0、regular、可執行、
  unit 已 enable 且 `ExecStart` 指向 in-image 路徑；**新行為由二進位內的字串證明**。
- `scripts/package_sc7f0_rootfs.py` 新增 `--expect-string PATH=LITERAL`（+3 個測試）。
  對歷史影像的實測（只讀，前後 SHA 相同）：
  ```
  $ python3 scripts/package_sc7f0_rootfs.py verify \
      --image-ub build/sc7f0-ps-watchdog-20261027-r2-release/images/image.ub \
      --expect-binary qpcie_upgrade_daemon=@present \
      --expect-string 'usr/bin/qpcie_upgrade_daemon=COMMIT: refused, no room for a backup generation'
  ROOTFS_RUNTIME_CONTENT_FAIL
  usr/bin/qpcie_upgrade_daemon does not contain b'COMMIT: refused, no room for a backup generation':
  the fix this release claims is not in the binary that will actually run
  ```
  這是**實測证据证明：目前板上的 upgrade daemon 沒有備份保留修正**（與第 6 節相容，
  但不再是推測）。新 image 必須讓同一條檢查通過。

### 9.4 gate 工具的輸入錯誤不再 traceback

`scripts/accept_sc7f0_vcu_hardware.py` 對錯誤輸入（如把目錄當 `--gate`）原本抛
`IsADirectoryError` traceback，在 PS 階段中間會被誤讀成「硬體被駁回」。現在先驗輸入、
統一輸出 `VCU_ACCEPTANCE_INPUT_ERROR: ...`，並用**獨立 exit code 2**（1 = 審閱後駁回，
2 = 輸入/事證問題），避免把資料缺漏算在硬體頭上。

### 9.5 打包階段now 內建來源漂移閘門

`scripts/package_sc7f0_vcu_release.sh` 在寫 provenance 前執行 `scripts/sc7f0_source_drift.py`：

- verdict `SOURCE_DRIFT_BITSTREAM_FATAL` → **拒絕打包**（非零 exit）。
- verdict `SOURCE_DRIFT_TOOLING_ONLY` → 允許，但把 verdict、逐檔漂移與 re-verify 結果
  **嵌入 `release-provenance.json` 的 `source_drift_after_freeze`**，让 release 自己
  說明「凍結後動過什麼」，而不是假稱整棵樹未變。

---

## 10. 輪次 `26111103` 的 strict gate 實測結果（**B1 停在 FPGA，不進 package**）

時間軸：18:48:13 綜合開始 → 19:39 route 完成 → 19:43 產出 routed report →
19:44:16 Vivado 在 `scripts/impl_sc7f0_dual_video.tcl:442` 中止：
`Dual-video timing/CDC gate failed; XSA withheld`。launcher 如實記錄
`STAGE all FAILED rc=1`、`build.exit=1`；**無 bitstream、無 hardware.xsa、無 PS image、無 tar**。

### 10.1 設計本身是乾淨的（問題不在 slack）

| 項目 | 實測值 | 來源 |
|---|---|---|
| Design State | `Physopt postRoute` | `fpga/project/timing_summary.rpt` |
| WNS / WHS / WPWS | **+0.053 / +0.010 / 0.000 ns** | 同上 |
| TNS（setup/hold） | 0（`values[1,2,5,6,9,10]==0`） | `gates/timing-gate-recheck-fixed-parser.json` |
| bus-skew min | +1.442 ns，無 `(VIOLATED)` | `fpga/project/bus-skew.rpt` |
| 路由完成度 | 179530/179530 fully routed，0 nets with routing errors | `impl_1/zu4ev_pcie_card_top_route_status.rpt` |

注：先前担心的 `capture_clk_300m` -0.116 ns 未再現（本輪收散成功）。

### 10.2 駁回清單（strict，未做任何寬減）

| 規則 | 數量 | 實測位置（具例） |
|---|---|---|
| **CDC-13** Critical（1-bit CDC path on a non-FD primitive） | **296** | `u_dualpath/reg_pkt_last_pts_reg[N]/C` → `u_dma_top/u_axil_reg_space/u_status/u_fifo/gnuram_async_fifo.xpm_fifo_base_inst/…/mem_reg_*/RAM{A..G}[_D1]/I`；clock pair `clk_pl_0 → pcie_user_clk`，CDC Type `No Common Primary Clock` |
| **CDC-12** Critical（multi-clock fan-in to synchronizer） | 10 | 全在 `u_dualpath` |
| **CDC-10** Critical（combinational logic before synchronizer） | 28 | `u_ps_capture` 10、`u_dualpath` 3、`u_hdmi_rx_ss` 3、`u_vid_phy_controller` 3、`u_dma_top` 2… |
| **TIMING-6 / TIMING-7** Critical Warning | 1 / 1 | `clk_pl_0` 與 `pcie_user_clk` 被同路徑約束但 **no common primary clock / no common node**（Vivado 原文：The design could fail in hardware） |
| check_timing HIGH（未約束 IO） | 7 in + 6 out | `fpga/project/check-timing.rpt:56,73` |
| TIMING-9 / TIMING-18 / ULMTCS-1 / CLKC-11,40,56 | 1 / 12 / 1 / 2,2,2 | `fpga/project/methodology.rpt` |
| unreviewed CDC warnings | 2660 | 主要是 CDC-15 4614（clock-enable controlled CDC）、CDC-26 416（LUTRAM 讀寫碰撞風險） |

**單一主根因**：`clk_pl_0 ↔ pcie_user_clk` 無宣告關係（無 common primary clock/node），而
`u_dma_top` 的 status async-FIFO **寫入資料由 `clk_pl_0` 域的 `reg_pkt_last_pts` 直接驱动**
（寫入資料不属于該 FIFO 寫入側的時鐘域）。TIMING-6/7 與 296 筆 CDC-13 都指向同一件事；
CDC-26（LUTRAM 讀寫碰撞 416 筆）是同批 XPM FIFO 推論成 LUTRAM 的副产物。

### 10.3 哪些是新增、哪些是既存（實測比對，非推測）

以 `check_sc7f0_timing.py` 同一套規則掃本 repo 所有留存 `cdc.rpt`：

| report 集 | critical CDC | 備註 |
|---|---|---|
| `build/qpcie_zu4ev_proj` | 無 | 目前唯一能過 strict 的 fixture（舊單視訊設計） |
| `build/sc7f0-26102204`、`sc7f0-audio-26102206-r5`、`sc7f0-audio-doorbell-26102702-r1` | CDC-10=24 | 已出貨世代也過不了 strict → `record` 模式存在的原因 |
| **`build/vcu-release-26111103-r1`** | CDC-10=28、**CDC-12=10**、**CDC-13=296** | CDC-12/13 是雙視訊/封包-DMA+VCU _merge_ 帶進來的 |

### 10.4 gate 工具本身的缺陷（已修，但**不是**為了让本輪過閘）

`check_sc7f0_timing.py` 原本只認 `Design State : Routed`；本輪 Vivado 2023.2 寫的是
`Physopt postRoute`，因此被誤判「not routed」。已改為**後路由狀態 allow-list**
（`Routed`、`Physopt postRoute`）；`Synthesized/Optimized/Placed/Physopt preRoute` 仍失敗，
**不認識的新字串也失敗**（fail closed），並在 JSON 裡回報 `design_state`。
新增 `scripts/tests/test_sc7f0_timing_state.py`（8 case：真實 routed fixture、r3 實際 report、
各前路由狀態、未知狀態、缺 header 抛 ValueError、以及「其他規則未被一起放寬」的回歸保護）。

修正前後對同一批 report 的實測差異（只少了一項誤判，其餘照樣駁回）。這份 A/B 對比
已存檔：`gates/checker-before-after.json`（sha256 `478e8ef8…cd72`），內容是由
`git show HEAD:scripts/check_sc7f0_timing.py` 重跑的「原始版」對照工作區版：

```
原始版 checker： pass_gate=False  errors=15（含 'timing report is not routed'，誤判）
現行版 checker： pass_gate=False  errors=14（design_state=Physopt postRoute）
removed_only = ['timing report is not routed']      added_only = []
```

即：**只移除 1 項工具誤判，未新增/未移除任何其他規則**；本輪仍以 14 項實質理由失败。
本輪自己的 `gates/timing-gate-record.json`（sha256 `118b7135…68030`）保持由**舊版**
checker 產生的原樣，新結果另存 `gates/timing-gate-recheck-fixed-parser.json`，兩者共存。
`scripts/check_sc7f0_timing.py` **確實被 r3 的凍結清單記錄**（`SOURCE_FPGA.sha256` 與
`fpga/project-logs/SOURCE_BUILD.sha256` 刻意包含會改變建置形態的腳本）。事後的工具修正
因此讓 r3 的凍結清單不再與樹相符 —— 如實記錄兩次快照：

| 快照 | 時間 | 結果 |
|---|---|---|
| `gates/source-drift-midbuild-1857.json`（`e22f835c…8dad7d`） | 18:57 | `SOURCE_FPGA.sha256` 172/172 OK、`SOURCE_RTL` 78/78 OK、verdict `SOURCE_DRIFT_TOOLING_ONLY`（當時這兩檔尚未改） |
| `gates/source-drift-final.json`（`b1d4cc3a…0eecc22`） | 20:05+ | `SOURCE_FPGA.sha256` 2 檔不符（`scripts/build_sc7f0_vcu_release.sh`、`scripts/check_sc7f0_timing.py`）、`SOURCE_BUILD.sha256` 1 檔不符、**`SOURCE_RTL.sha256` 78/78 仍 OK（未動任何 HDL）**、verdict **`SOURCE_DRIFT_BITSTREAM_FATAL`** |

含義（drift 工具自己寫進 JSON 的 `interpretation`）：這只表示 r3 **不可打包**；本輪
`artifacts_present` 全 false（無 XSA/bit/BOOT.BIN/image.ub），所以不存在「已產出位元流
失去可追溯性」的問題。正確處置是下一輪完整凍結時記錄這兩檔的現行版本，而不是回頭重算
r3 的指紋或宣稱它仍然完整。

### 10.5 本輪我**沒有**做的事

- 未把 `SC7F0_TIMING_GATE` 改成 `record`/任何其他值（入口仍硬性 `strict`，並拒絕寬減）。
- 未動 `set_clock_groups`/`set_false_path`/`set_max_delay` 等約束，未動 `rtl/`
  （`SOURCE_RTL.sha256` 78/78 仍 re-verify OK）。
- **但**本輪結束後改了 `scripts/build_sc7f0_vcu_release.sh`（失敗時自動寫 NOT_DEPLOYABLE）
  與 `scripts/check_sc7f0_timing.py`（Design State 修正），而這兩個檔在 r3 的
  `SOURCE_FPGA.sha256` 名單內 → 最終 drift verdict 為 `SOURCE_DRIFT_BITSTREAM_FATAL`，
  見 10.4 的兩個快照對照。r3 因此永遠不可打包（它本來也沒有產出任何東西）。
- 未跑 PS 階段、未打包、未部署、未烧錄、未碰卡。
- 新增工具：failed round 的目錄现在會自動寫 `NOT_DEPLOYABLE` + `gates/stage-failure.txt`
  （r3 的是事後手動補的，sha256 `973ca9a3…62669`）。

### 10.6 要走到可打包，需要的是（待Parent/操作者定案）

1. **RTL 正修 `u_dma_top` 時鐘域**：`u_axil_reg_space/u_status` 的 XPM async FIFO 寫入端
   必须用資料來源域（`clk_pl_0`）做寫入，或改用明確 handshake/寄存器同步；目標是 CDC-13
   296→ 0。這是唯一能真正消除 TIMING-6/7 警告的途徑。
2. 或者由獨立 review 對 `clk_pl_0 ↔ pcie_user_clk` 提出可接受的同步/約束論證（属政策決定，
   不是本代理可自行放寬範圍）；即便如此，CDC-10 的 28 筆與 13 個未約束 IO 仍需逐條理由。
3. 補齊 7 個輸入 / 6 個輸出埠的 IO 約束（或明確宣告為內部/未用）。
4. 任一選項都需**新一輪完整凍結 build**（因為 1/3 會改位元流輸入，使 r3 凍結清單失效）。

在以上之前，B1 的可交付物就是這份失敗分析與已完成的可重現/驗證基礎設施；
**B2（部署/升级）保持鎖住**。

---

## 11. 交接給獨立 review / 實施 A 的 coder（只用已有事證，未再做大型追查）

機器可讀版：`build/vcu-release-26111103-r1/gates/gate-failure-handover.json`
（sha256 `12060d90…819c`）。以下是人可讀摘要。

### 11.1 `u_status` FIFO 完整時鐘/信号來源（勿只改單一 port 的 clock）

模組：`rtl/qpcie_status_cdc.v`（46 行），實例 `u_status` 在
`rtl/qpcie_csr_reg_space.v:435`，`WIDTH=2063`，内部是 `xpm_fifo_async u_fifo`
（`FIFO_MEMORY_TYPE="distributed"`、`FIFO_WRITE_DEPTH=16`、`CDC_SYNC_STAGES=3`、
`READ_MODE="fwft"`、`USE_ADV_FEATURES="0000"`）：

| 信号 | 來源表达式 | 實際時鐘域 |
|---|---|---|
| `wr_clk` | `src_clk` → 實例 `.src_clk(pcie_clk)`；`u_dma_top` 頂端 `.clk(pcie_user_clk)` | **pcie_user_clk** |
| `din`（wr_data） | `src_status`，2063-bit 串接清單見 `rtl/qpcie_csr_reg_space.v:438` | 應为 pcie_user_clk；**實際混入 clk_pl_0**（見 11.2） |
| `wr_en` | `!fifo_reset && !wr_busy && !full` | pcie_user_clk（全部頂在 src 域） |
| `full` / `wr_rst_busy` | `.full(full)` / `.wr_rst_busy(wr_busy)` | pcie_user_clk |
| `rd_clk` | `dest_clk` → 實例 `.dest_clk(clk)` | AXI-Lite/PS 側 `clk` |
| `rd_en` | `dest_rst_n && dest_online && !rd_busy && !empty` | dest 域 |
| `empty` / `rd_rst_busy` | `.empty(empty)` / `.rd_rst_busy(rd_busy)` | dest 域 |
| `dout`→`dest_status`/`dest_valid` | 同一 `posedge dest_clk` always | dest 域 |
| `rst` | `fifo_reset = !src_peer_ready \|\| !src_rst_n`（組合邏輯；`src_peer_ready = ps_ready_pcie`，已由 control CDC 同步到 src 域，`u_controls` 共用同一份） | src 域 |

⚠ 实施注意（也是本轮先不动手的原因）：`u_status` 舆 `u_controls` **共用同一個
`src_peer_ready`**，而 `wr_en/full/wr_rst_busy/rst` 與 2063-bit `din` 必须同属一個寫入域。
把某個 port 單獨换 clock 会把危险移到别的欄位或移到 `wr_en`。

### 11.2 越界资料的來源（296 筆 CDC-13 的完整清單）

`clk_pl_0` → `pcie_user_clk`，CDC Type `No Common Primary Clock`，來源寄存器全在
`u_dualpath`（`sc7f0_dualpath`），由 `always @(posedge csr_clk)`
（`rtl/sc7f0_dualpath.v:81`）寫入，而 `u_dualpath` 的 `.csr_clk(pl_clk0)`
（`rtl/zu4ev_pcie_card_top.v:1067` 舆 `:1088`，`.csr_rst_n(sys_100m_rst_n)`）：

| 來源寄存器（clk_pl_0） | 位元数 | 出口 |
|---|---|---|
| `reg_pkt_last_pts_reg[63:0]` | 64 | `probe_pkt_last_pts_lo/hi`（`rtl/sc7f0_dualpath.v:117-118,140-141`） |
| `reg_pkt_bytes_reg[63:0]` | 64 | `probe_pkt_bytes_lo/hi` |
| `reg_pkt_submit_cnt_reg[31:0]` | 32 | `probe_pkt_submit_cnt` |
| `reg_pkt_done_cnt_reg[31:0]` | 32 | `probe_pkt_done_cnt` |
| `reg_pkt_err_cnt_reg[31:0]` | 32 | `probe_pkt_err_cnt` |
| `reg_pkt_msi_cnt_reg[31:0]` | 32 | `probe_pkt_msi_cnt` |
| `reg_pkt_last_len_reg[31:0]` | 32 | `probe_pkt_last_len` |
| `u_fsm_cdc/syncstages_ff_reg[0..7]` | 8 | `probe_pkt_fsm_state`（注意：`xpm_cdc_array_single` 已把 FSM 從 `mem_clk` 同步**到** `csr_clk=clk_pl_0`，見 `rtl/sc7f0_dualpath.v:71`） |

路徑：`u_dualpath.probe_pkt_*` → `dp_pkt_*` → `u_dma_top.in_pkt_*`
（`rtl/zu4ev_pcie_card_top.v:1116` → `:2093`）→ `rtl/custom_pcie_dma_top.v:38` 埠 →
`:1245` 進 `qpcie_csr_reg_space` → 打包進 `src_status`（`rtl/qpcie_csr_reg_space.v:438`）。
256 個資料位 + 8 個 FSM 位，因 LUTRAM 分片（`RAM{A..G}[_D1]`）而變成 296 筆 report 列。

為什麼這是真缺陷而不是報告雜音：`rtl/qpcie_status_cdc.v` 自己訂的契約是
「*Convert pulse telemetry to counters in the source domain before packing it into
src_status*」；`u_status` 的 source 域是 `pcie_user_clk`，而这 8 個 probe 是 `clk_pl_0`
寄存器，所以 FIFO 在 `wr_clk` 上可能擷取到轉變中的值——約束文字無法使其安全。
`CDC-26`（416 筆 LUTRAM 讀寫碰撞）是同批 FIFO 的副产物，會随此修正一起燮化。

可用機件（優先於自己寫）：同檔已用的 `qpcie_csr_cdc`（level+event，`u_controls`）；
`xpm_cdc_array_single` 僅用於真正穩定值。自由_running 計數器（submit/done/err/msi/bytes）
需 gray-code 或非二值計數方式；`last_len/last_pts` 是「最後一筆完成值」，需 value+valid
握手；FSM 状态已是 `mem_clk→clk_pl_0` 的第二級，再鏈到 `pcie_user_clk` 属設計決策。

### 11.3 其他必須逐條處理的清單

- **CDC-10（28，combinational logic before a synchronizer）**：`u_ps_capture` 10、
  `u_dualpath` 3、`u_hdmi_rx_ss` 3、`u_vid_phy_controller` 3、`u_dma_top` 2…具例：
  `u_100m_reset/U0/ACTIVE_LOW_PR_OUT_DFF[0].FDRE_PER_N/C → u_capture_reset/arststages_ff_reg[0]/PRE`；
  `u_hdmi_rx_ss/…/gen_fwft.empty_fwft_i_reg/C → u_hdmi_probe/u_pin_levels_cdc/syncstages_ff_reg[0][28]/D`。
  注：既存出貨世代也有 CDC-10=24（見 10.3），所以這批需要逐條判定而非预設可接受。
- **CDC-12（10，multi-clock fan-in to synchronizer）**：全在 `u_dualpath`；clock pair
  含 `clk_pl_0→capture_clk_300m`、`pcie_user_clk→capture_clk_300m`、
  `capture_clk_300m→clk_pl_0`、`pcie_user_clk→clk_pl_0`；具例
  `u_100m_reset/…/FDRE_PER_N/C → u_dualpath/u_packet_commands/u_read_reset/arststages_ff_reg[0]/PRE`。
- **未約束 IO（check_timing HIGH）**：輸入 7 個 `hdmi_rx_5v_det`、`hdmi_rx_ddc_scl`、
  `hdmi_rx_ddc_sda`、`hdmi_tx_ddc_scl`、`hdmi_tx_ddc_sda`、`hdmi_tx_hpd_in`、
  `hdmi_tx_refclk_rdy`；輸出 6 個 `hdmi_rx_ddc_scl`、`hdmi_rx_ddc_sda`、
  `hdmi_rx_hpd_out`、`hdmi_tx_tmds_clk_p`、`user_led_dma_active`、`user_led_pcie_link_up`。
  另有 1 個輸入埠 `sys_rst_n` 為 no-input-delay-but-false-path（MEDIUM，不計入 HIGH 駁回）。
  這些 quasi-static 的 DDC/HPD/LED 埠需要**具名理由**的約束（真實 IO delay 或明確
  `set_false_path`），約束修改属位元流輸入 → 需新一輪凍結。
- **本輪真實剩餘 gate 錯誤（14 項，逐字）**：`uncovered HIGH-severity endpoint`、
  `CDC-10 Critical=28`、`CDC-12 Critical=10`、`CDC-13 Critical=296`、
  `critical CDC detail (even if missing from summary)`、`unreviewed CDC warnings: 2660`、
  `TIMING-6 Critical Warning=1`、`TIMING-7 Critical Warning=1`、
  `TIMING-9 without complete reviewed CDC evidence`、`TIMING-18 Warning=12`、
  `ULMTCS-1 Warning=1`、`CLKC-11 Advisory=2`、`CLKC-40 Advisory=2`、`CLKC-56 Advisory=2`。

---

## B2-prep checkpoint（2026-11-11，收束點；非新輪次、非凍結、非批准）

範圍宣告：**未啟動任何 full build / 未部署 / 未燒錄 / 未寫卡 / 未 commit**（HEAD 仍
`aea8612`）。r3 `build/vcu-release-26111103-r1` 維持 `NOT_DEPLOYABLE` +
`SOURCE_DRIFT_BITSTREAM_FATAL`，本 checkpoint **不是**為 r3 重 stamp，只描述當前工作樹。

### 1–8 逐項實況

| # | 項目 | 狀態 | 實據 / 缺口 |
|---|---|---|---|
| 1 | 產生器根因修正（296 CDC-13） | **完成（含本地驗證）** | 定性改正：296 筆 CDC-13 是 **B1 包裝器產生器新引進的回歸**，非既有 merge 缺陷。`in_pkt_*` 10 埠為同域 `pl_clk0`（`sc7f0_dualpath.v` 由 `always @(posedge csr_clk)` 產生、板端 `csr_clk = pl_clk0`、`u_axil_reg_space .clk(pl_clk0)`），已移入 `LOCAL_INPUTS` 直連 `u_bank`；`rtl/qpcie_csr_reg_space.v:425` 為 `qpcie_status_cdc #(.WIDTH(1743))`（2063→1743），且該產生檔已與 HEAD 位元一致。產生器加方向/存在性 assert；`scripts/tests/test_sc7f0_csr_wrapper.py` 8 tests OK。离线 BAR0 語義已記錄（不得宣稱 64-bit 計數器兩次 32-bit 讀天然原子）。 |
| 2 | 結構性 reset CDC 修正 | **代碼已落地，驗證未跑** | 新增 `rtl/sc7f0_reset_cdc.v`（`sc7f0_reset_sync`：每來源獨立 `xpm_cdc_async_rst` 後合成，再同鐘多級過濾 runt；`sc7f0_event_reset`：單週期事件→保持性 reset 電位＋`pending`）。實例化共 **20 × reset_sync + 5 × event_reset**，分佈 `custom_pcie_dma_top / zu4ev_pcie_card_top / sc7f0_dp_fifo / sc7f0_dualpath / sc7f0_packet_cdc / sc7f0_tap_regs / video_axis_async_fifo / video_req_cdc / hdmi_rx_audio_bridge / hdmi_tx_video_bridge / hdmi_tx_audio_bridge`。`scripts/build_zu4ev.tcl:88` 為 `add_files [glob ./rtl/*.v]`，新模組會被自動納入（無需修 manifest）。**未跑 xsim**：`tb/sc7f0_reset_cdc_tb.sv` + `scripts/sim_sc7f0_reset_cdc.tcl` 已寫但從未執行（本 shell PATH 無 `xvlog/xelab`）；僅 `iverilog -g2012` 語法解析 exit 0 —— 解析 ≠ 功能證明，且仿真亦無法證明亞穩態不存在。 |
| 3 | `sc7f0_hdmi_probe` 診斷層位 | **代碼已落地，未經綜合驗證** | 7 條獨立 3FF `ASYNC_REG` 鏈：`rtl/sc7f0_hdmi_probe.v:312-318`（`rxss_tlast/tuser/tready/tvalid`、`phy_ch2/1/0_tvalid`），`u_pin_levels_cdc` 由 `.SRC_INPUT_REG(0)` 改 `1`（:441）；不再偽造 `src_clk`。r3 `cdc.rpt` 的 6 筆 CDC-10 該不該消失，需新一輪 `report_cdc` 才算證明。 |
| 4 | r3 routed DCP 唯讀證據 | **BLOCKED** | `build/evidence-b2prep-26111104/BLOCKED-dcp-probe.md`：stage1 `CLOCK_TYPE` 不存在、stage2 巢狀大括號 list 錯誤、**stage3 `ERROR: [Common 17-170] Unknown option '-object_filters'`** 後 Vivado 退出；盤上僅兩個 0 byte 檔案。pad→first-FF/`ASYNC_REG`、CDC-26 vendor FIFO `WCLK→O` disable arc、`clk_pl_0`↔`pcie_user_clk` max-delay 列舉、TX pad driver 檢查 **全部未執行**。依指示保留精確錯誤、不反覆改查詢重開 Vivado。 |
| 5 | 精準 IO 非同步約束＋時鐘關係 | **未做** | 工作樹 `constraints/sc7f0_capture_gray.xdc` 未改（僅兩條 capture-gray `set_max_delay -datapath_only 6.000`）；r3 `check-timing.rpt:53-79` 那 7 個 no-input-delay(HIGH) + 6 個 no-output-delay(HIGH) 原封不動；`exceptions-coverage.rpt` 無任何 DDC/HPD/refclk 條目。**RX DDC 首級同步器僅有來源層證據（RTL 3FF 鏈）， routed 層未證明 → 不得宣稱 DDC 約束已可收斂，亦不得拆分 RX DDC。** TX TMDS 須照實寫「pad 仍接 VPHY、TX 未驗證」，不得推定空載/未驅動。 |
| 6 | 兩層嚴格 gate | **未做** | `scripts/gates/` 目錄不存在 → Layer B 具名 review 清單**尚未建立**；`scripts/check_sc7f0_timing.py` 本階段未修改（仍為 B1 19:55 版），無 `report_drc`/`report_io`/`report_clock_interaction`/`exceptions -ignored|-scope_override`/`report_disable_timing` 解析器，無正/負 fixture。已完成的前置功課：由 r3 `cdc.rpt` 實際統計出 5744 detail / 334 Critical / 5038 Warning，並拆成 41 組 (rule, root, exception) 計數表 `build/evidence-b2prep-26111104/cdc-root-table.txt`（CDC-15 4614＝FIFO 3986 + `u_meter` 7×64 + CPLL 108+72；CDC-26 416＝PIX 201/AUD 152/DCS 43/VTD 20；CDC-6 8），以及 r3 routed DRC 全 123 筆皆 Warning（DPIP-2 74、DPOP-3 13、DPOP-4 30、PDCN-1569 3、REQP-1935 2、RTSTAT-10 1）——可直接作為逐 root 書寫依據，但**尚未寫成 gate 可消费的清單**。 |
| 7 | 套件/備份/恢復 review 缺口 | **未做** | `qpcie_debugd` 0x800 image 降級證明、必要測試未跑即 fail、FIT/rootfs 證據入包、身分/來源鏈、postroute resume 禁止、備份保留以新套件最大值估算＋generation 語義、舊安裝器相容之恢復 runbook：**皆未動**。這些檔案目前仍承載 B1 遺留 WIP（mtime 18:22–18:55），不屬本階段成果。MCU10  tolerated 仍不屬本輪，不得作為 MCU 安全證據。 |
| 8 | 來源完整性／凍結紀律 | **部分（僅指紋）** | 已產生 `build/evidence-b2prep-26111104/source-fingerprint-26111105.txt`（分支/HEAD、28 tracked 修改、21 untracked、`git diff`（排除 docs 以免自我指涉）摘要、逐檔 sha256）。**未凍結、未 stage、未 commit**；待 1–7 收斂後再以一次「stage all」凍結。 |

### 本地驗證：真的跑過 vs. 沒跑

跑過（checkpoint 當下重跑）：
- `python3 scripts/generate_sc7f0_csr_cdc.py --check` → rc 0
- `python3 -m unittest scripts.tests.test_sc7f0_csr_wrapper` → Ran 8 tests, OK
- `python3 -m unittest discover -s scripts/tests` → **Ran 216, failures=8, errors=2, skipped=25**；
  10 筆失敗**全部**集中在 `test_sc7f0_mcu_app_image.AppImageTests`（該檔 16:38、未被我修改、
  依賴 `scripts/check_sc7f0_mcu_app_image.py`）→ 屬 B1 遺留 MCU 域，依指示不計入本輪、
  亦不得解讀為 MCU 安全證據。25 skips 全為環境閘控（9 需 `SC7F0_TEST_XCI_DIR`、
  3 需 real capture image、13 需 real routed candidate）→ **等同未跑**，不得當作通過。
- `git diff --check` → rc 0（無空白錯誤）
- `iverilog -g2012 -i` 語法解析 `rtl/*.v` 與 reset TB → rc 0（僅解析）

未跑（如實列）：`scripts/sim_sc7f0_reset_cdc.tcl`（xsim）、任何 Vivado 綜合/佈局/路由、
任何 PS/PetaLinux build、`test_sc7f0_release_package`/`test_sc7f0_timing_state`/
`test_sc7f0_fit_rootfs`/`test_sc7f0_impl_identity`/`test_sc7f0_hdmi_dt` 的 real-candidate
分支、commit-integration/backup-retention C 測試、任何部署或燒錄測試。

### 活躍程序狀態

`dcp_stage3.tcl` 的 Vivado 已因上述錯誤自行退出（`INFO: [Common 17-206] Exiting Vivado`），
checkpoint 時 `pgrep -f dcp_stage3` 為空；未另啟第二份、未使用大範圍 pkill。

### 指紋（當前工作樹，非 r3 stamp）

```
build/evidence-b2prep-26111104/source-fingerprint-26111105.txt
sha256 = db68eaa4f2c6841016302e354948e658ab05939f5f8b10816428d32ab4a3467a
branch = feat/zu4ev-sc7f0-bringup   head = aea86126bda15af8d200c79aa62b853fc57f3b39
tracked-modified = 28   untracked = 21
git diff (exclude docs) sha256 = a223e323b328bdd13a7264160e97d49cc7af18167c986352fa20fdd548a31612
```

本 checkpoint 之後文件本身才會變動，故指紋刻意排除 `docs/`；`build/` 受 gitignore，
證據以路徑＋sha 引用的方式追溯。


## 12. reset/probe RTL 驗證輪次 `26111106`（離線模擬；未 build、未部署、未燒錄）

範圍：僅驗證並最小修正已寫入 WIP 的 reset/probe RTL（review 的 P0-2 / P1-4 / §2
「必跑 S1~S6」）。未動 constraints/gate/package，未做綜合/實作/PS build，未 SSH、
未部署、未燒錄、未裝驅動、未碰 MCU、未 `git add`/`commit`/`push`（HEAD 仍 `aea8612`）。

### 12.1 工具環境（先前「xvlog 不在 PATH」並非未安裝）

`xvlog/xelab/xsim/vivado` 一律由 `/opt/Xilinx/Vivado/2023.2/settings64.sh` 提供；
來源後 `command -v` 全部命中 `/opt/Xilinx/Vivado/2023.2/bin/`，
`XILINX_VIVADO=/opt/Xilinx/Vivado/2023.2`，`vivado v2023.2 (64-bit)`。
本輪用 **真實 XSim + 原廠 XPM 模型**（`XPM_LIBRARIES {XPM_CDC XPM_FIFO XPM_MEMORY}`，
xelab 實際編譯 `xpm.xpm_cdc_async_rst`／`xpm.xpm_fifo_async`／`xpm.xpm_fifo_rst` 等），
repo 內不存在任何本地 `xpm_*` stub（有 unit test 守住這點）。
`iverilog` 因不懂 XPM 只能做解析，故不作為驗證證據。

### 12.2 一鍵重跑指令與輸出

```bash
SC7F0_RESET_SIM_WAVE=1 ./scripts/run_sc7f0_reset_probe_validation.sh \
    build/reset-probe-validation-26111106
# 底層：vivado -mode batch -notrace -nojournal -source scripts/sim_sc7f0_reset_cdc.tcl
```

實測 `structure_tests_exit=0`、`simulation_exit=0`、`RESET_PROBE_VALIDATION_PASS`。
輸出目錄（gitignore 內）：`build/reset-probe-validation-26111106/`
→ `reset-sim-stdout.log`（兩個 TB 完整 transcript + 每項 check）、
`structure-tests.log`、`verdict.txt`、`environment.txt`、`xvlog.log`、`elaborate.log`、
`simulate.log`、`sc7f0_reset_cdc_tb_behav.wdb`、`sc7f0_hdmi_probe_async_levels_tb_behav.wdb`、
`parse-only/`、`failed-attempts/`（4 份中途失敗原始 log，保留不外覆寫）。

### 12.3 本輪發現並修復的 4 個實缺陷

| # | 位置 | 缺陷 | 修復 | 證據 |
|---|---|---|---|---|
| 1 | `rtl/sc7f0_dp_fifo.v:40,44` | `u_reset` 只同步 `wrst_n`、`u_read_reset` 只同步 `rrst_n`，導致 **讀側 reset 不沖洗 FIFO、舊資料在 peer restart 後重播**，且讀側 VALID 不會隨寫側 reset 立即關閉（HEAD 原本是 `!wrst_n\|\|!rrst_n` 兩個同步器都吃，語義在 WIP 重構時遺失） | 兩個同步器都改為 `SOURCES(W_SOURCES+R_SOURCES)`，`{rrst_n,wrst_n}`／`{wrst_n,rrst_n}` 各自獨立跨域後才做 AND（語義回到 HEAD，結構仍是每源一個 `xpm_cdc_async_rst`） | `RESET_CDC_CHECK_FAIL: S6 pre-reset word did not survive the flush`（修復前）→ 修復後 S6/S7 全 PASS，`bad_valid_edge=0` |
| 2 | `scripts/sim_sc7f0_reset_cdc.tcl`（舊版） | 判定用 `$pass eq "1'b1"`，但 xsim 的 `get_value` 對 1-bit 暫存器回報 `1`，**即使 TB 通過也永遠 GATE_FAIL**；且 `shutdown` 不是 xsim console 指令 → `invalid command name` | 改為末字元比對並印出 `gate_pass_raw=`，移除 `shutdown`；一個 tcl 內依序跑兩個 TB 並各自取 `gate_pass` | run1/run4 `GATE_FAIL`、run5 起 `RESET_CDC_SIM_TOP ... gate_pass_raw=1 gate_pass=1` |
| 3 | `tb/sc7f0_reset_cdc_tb.sv` 負控段 | 延遲模型 `a_d/b_d` 未給初值，`always @(a_q)` 對宣告初值不觸發 → `old_arst` 全程 X → **負控測到 0 個毛刺，所有正向 runt 檢查變成空斷言** | `reg a_d = 1'b0, b_d = 1'b1;` 並在 race 前先建立「A 斷言 / B 釋放」且長度 > RUNT_LIMIT 的乾淨視窗，加入 `old_runts==0` 前置檢查 | `RUNT on the pre-fix src_arst: released 3.200 ns` → `prefix_wiring_runts=1` 且 `fixed_structure_runts=0` |
| 4 | `rtl/sc7f0_hdmi_probe.v:420-426` | 註解與 review 都宣稱 7 條「3FF」鏈，但位元取的是 `[1]`＝**第二級**；未接線的 `[0]` 會被綜合移除 → 實際淨表只有 2 級同步（對 297 MHz 來源域是誇稱） | 7 位的輸出改為第三級 `[0]`，並改寫註解；慢速實體腳位（`det5v/hpd/scl/sda/tx_*`）維持 HEAD 的 `[1]` 兩級慣例不動 | 靜態 test 綁死位元映射；TB P6 直接比對第三級 == `reg_probe_pins[31:25]` |

另以靜態掃描發現 `rtl/sc7f0_display_pipeline.v:351` 殘留同一 P0-2 形態
`.src_arst (!mem_rst_n || !tx_rst_n)`（`build_zu4ev.tcl:88` 用 `glob ./rtl/*.v` 納入，
但**目前 repo 內無人實例化**，故 r3 的 `report_cdc` 沒有它的列）。已用同一
`sc7f0_reset_sync` 原語改為每源各自同步（`rtl/sc7f0_display_pipeline.v:354-359`）；
因未被實例化，**無行為級模擬證據**，僅 `xvlog` 分析通過（exit 0）。

### 12.4 TB instrumentation 修正（避免假陽性/假陰性）

* XPM 鏈在 time 0 以「釋放值」上電、同一時間步才被非同步清除 → 舊版把這個
  `X→1` 當成「釋放」，既計數又誤報「來源仍斷言時釋放」。改為只承認
  「先看過斷言」之後的釋放（`tb/sc7f0_reset_cdc_tb.sv:102-121`），實測
  `ignored_time_zero=1`。
* 新增 consumer bank（8 個以 `comb_rst_n` 作非同步 preset 的 dest 域 FF）以
  「**確實全部離開 reset 且持續接收新資料**」反制「過度濾波→從沒退出 reset」；
  釋放緣與 clock 緣同時間步的那一次在零延遲模擬中本不可判序（真實矽片靠
  recovery 時序收斂，只有 gate-level/SDF 可模擬），故只跳過釋放後第一個 negedge
  （`cons_grace`），之後仍殘留 0 才算半復位。實測 `cons_half_reset=0`、`cons_moving=816`、
  `releases=5`。
* S6 的 reset 脈衝依 XPM 契約（RST 至少 3 個 wr_clk 且 3 個 rd_clk）拉寬，
  「立即關閉 VALID」仍以 `#1` 檢查非同步路徑；新增 **S7**：讀側時鐘暫停期間做
  peer restart → 重啟後舊字不重播、新字可寫入。

### 12.5 新增的模擬與測試資產

* `tb/sc7f0_reset_cdc_tb.sv`（44 checks）：S0 斷言、S1a/b/c 兩種釋放順序＋同時釋放、
  S2 相近 assert/deassert + 負控、S3 單拍事件→最窄保持寬度、**S3b** 事件來源時鐘
  中途暫停/重啟（不丟、不重播、後續事件仍滿寬）、**S3c** 硬 reset 於 hold 中途到達
  （DMA 全域 flush 與硬 reset 序列不死鎖）、S4 dest 時鐘暫停/重啟、S5 單源 peer
  restart、S6 兩側沖洗不重播、**S7** 讀側停鐘 restart。實測 `checks=44 failures=0`。
* `tb/sc7f0_hdmi_probe_async_levels_tb.sv`（22 checks，362 行）：P0 probe reset 期間
  不外洩 level、P1 七位 one-hot 逐位對映、P2 `reg_probe_pins` 只可能在 pl_clk0 緣改變
  （來源由 148.5 MHz/297 MHz 兩個異相域驅動）、P3 快於 pl_clk0 翻轉時不出現 X 且能
  收斂、P4 管線延遲有界（實測 4~6 個 pl_clk0 週期，上限 12）且非第一緣、P5a 來源
  時鐘停止/重啟後恢復、P5b probe 自身 reset 循環後 DDC 計數仍動作、P6 層級式比對
  七條鏈的第三級 == 回報位元。實測 `checks=22 failures=0 bad_off_edge=0 bad_x=0`。
* `scripts/tests/test_sc7f0_reset_probe_structure.py`（13 tests，必跑、無環境閘控）：
  禁止任何 `.src_arst()` 出現 `|`/`&`、禁止 call-site 預先 `&&`/`||` 合成 reset 向量、
  `sc7f0_reset_sync` 的 `SOURCES` 與向量寬度必須相符且 `dest_rst_n` 不得是自身來源
  （依賴循環）、`sc7f0_dp_fifo` 兩側都必須含 `wrst_n`+`rrst_n`、全域 flush 事件只能
  進 `sc7f0_event_reset`、probe 七條 ASYNC_REG 鏈與位元映射與 `SRC_INPUT_REG(1)`/
  `src_clk==dest_clk`、**repo 內不得有本地 `xpm_*` stub**、gate 指令必須涵蓋兩個 TB
  且啟用真實 XPM、若存在已記錄的模擬 log 則必須為 PASS。
  已進入 `scripts/tests/`，因此 `python3 scripts/sc7f0_release_tests.py` 必跑它：
  實測 `Ran 229 tests`、`UNIT_TESTS_GATE_PASS tolerated=10 failures=10 skipped=25`
  （10 筆全為 baseline 已記錄的 MCU 域舊失敗；25 skips 為既有環境閘控，未新增 skip）。
* `scripts/run_sc7f0_reset_probe_validation.sh`：一鍵重跑（静态 test + XSim gate），
  自動記錄環境、log、wdb 與 exit code。

### 12.6 生成器與既有測試（未手改產生檔）

* `python3 scripts/generate_sc7f0_csr_cdc.py --check` → rc 0（產生檔與產生器一致，
  `rtl/qpcie_csr_reg_space.v:425` 為 `qpcie_status_cdc #(.WIDTH(1743))`，10 個
  `in_pkt_*` 為同域 LOCAL 直連，例 `:167`/`:562`）。
* `python3 -m unittest scripts.tests.test_sc7f0_csr_wrapper` → **8 tests OK**
  （含 `test_status_width_matches_the_domain_audit`）。

### 12.7 未跑 / 限制（不可由本輪結論推得）

* **未做**：綜合、實作、`report_cdc`/`report_drc`、任何 PS/PetaLinux build、
  package、部署、燒錄、驅動安裝、板上寫入、MCU 操作、`git add`/`commit`/`push`。
* 模擬**不能證明無 metastability**：Verilog 模擬對每次時鐘擷取一律給定值，無法呈現
  recovery/removal 違反或次週期解析。probe 的 7 位與 `sc7f0_reset_sync` 的異步斷言
  路徑屬**結構性宣稱**，要收斂仍需一次真實實作的 `report_cdc`（本 profile 目前
  `sc7f0_reset_sync` 21 例 + `sc7f0_event_reset` 1 例）與 ASYNC_REG 進淨表的證明。
* 負控的 1 ns / 3 ns 是 placement 延遲的替身，不是實測延遲；真實 reset 淨表的
  skew 需 route 後量測。
* `rtl/sc7f0_display_pipeline.v` 的修正無行為級證據（無人實例化）。
* `scripts/sim_sc7f0_reset_cdc.tcl` 與 `tb/sc7f0_reset_cdc_tb.sv` 目前**未被 git 追蹤**：
  `.gitignore:51` 的 `sim_*` 規則吃掉前者（既有慣例是其他 20 支 `sim_*.tcl` 都以
  `git add -f` 入库）。commit 時需一併 `git add -f scripts/sim_sc7f0_reset_cdc.tcl`
  與新 TB/runner，否則這道 gate 會隨工作樹消失（本輪依指示未執行任何 `git add`）。
* `simulate.log` 只留最後一個 TB 的 transcript（兩次 run 共用 run 目錄）；第一個 TB
  的完整輸出在 `reset-sim-stdout.log`。
* 因新增/修改 `rtl/*` 與 `scripts/*.tcl`，`SOURCE_FPGA.sha256` 指紋必然變動；本輪
  未凍結、未 `--stage preflight`，下一次必須在同一次 `--stage all` 內重建指紋。

`git diff --check` → rc 0。本節之後 `docs/` 之外變更檔案：
`rtl/sc7f0_dp_fifo.v`、`rtl/sc7f0_display_pipeline.v`、`rtl/sc7f0_hdmi_probe.v`；
新增（未追蹤）：`rtl/sc7f0_reset_cdc.v`（既有 WIP，未改）、
`tb/sc7f0_hdmi_probe_async_levels_tb.sv`、`tb/sc7f0_reset_cdc_tb.sv`（既有 WIP，本輪修改）、
`scripts/sim_sc7f0_reset_cdc.tcl`（本輪改寫）、
`scripts/run_sc7f0_reset_probe_validation.sh`、
`scripts/tests/test_sc7f0_reset_probe_structure.py`。

---

## 13. 兩層閘門（Layer A 正確性／Layer B 逐項審查）、命名異步約束、來源清單（本輪，全部離線）

本輪只做**閘門與約束**，不修已驗證的 reset/probe RTL，不跑完整 FPGA/PS build，不打包、不部署、不燒錄、不動 MCU、不 `git add`/`commit`/`push`。

### 13.1 分層

| 層 | 內容 | 可否被政策放寬 |
|---|---|---|
| **Layer A**（正確性，fail-closed） | WNS/WHS/WPWS 與 TNS、bus-skew、check_timing 覆蓋、**uncovered HIGH endpoint**、**critical CDC**（CDC-5/7/10/12/13、任何 Critical/Error 細節、報告把 critical 規則寫成 Warning、彙總/細節數量不符）、**未知 CDC severity 一律拒读**、DRC（缺 `drc.rpt` 即 fail、Error/Critical、彙總≠細節）、methodology 的 Critical 與 `TIMING-3`/`TIMING-24`、**未知的 postroute design state 不接受** | **不可**。政策檔只對 TIMING-6/7 這一對時鐘名解除重疊 |
| **Layer B**（逐項審查政策） | 每一條 vendor Warning/Advisory 都要有「確切 rule + 結構來源/目的 + 證據」的條目；每輪重新產生覆蓋清單；只有 vendor 措辭、空條目、重複分類、比對不上、本輪不存在、缺 `named-constraint-evidence.json` 或該檔綁定的 `cdc.rpt` SHA 不同 → **fail** | 由條目 `requires` 證據決定，不能只改 `status` |

### 13.2 命名約束（不得被廣設 clock group 抵銷）

保留既有 `6.000 ns` capture Gray（`constraints/sc7f0_capture_gray.xdc:8-11`，含同值 `set_bus_skew`）、`10.0 ns` probe meter（`constraints/zu4ev_pcie_pinout.xdc:108`）、vendor `15 ns` DPRAM `CLK→O`（`.gen/.../bd_2422_v_hdmi_rx_0_core.xdc`）與 XPM `8 ns`；r3 實測覆蓋為 `max_dpo=10→448/100%`、`max_dpo=15→416 endpoints（84.90% from / 57.94% to）`、`max_dpo=6→64+64/100%`、`max_dpo=8→5/100%`（`build/vcu-release-26111103-r1/fpga/project/exceptions-coverage.rpt:100,149,163,164,257`）。新增 `constraints/sc7f0_async_io.xdc`（79 行）**只**對已量測的第一級同步 FF 解除例外，**沒有** `set_clock_groups`、**沒有**憑空延遲；`hdmi_rx_ddc_scl/_sda` 與 `hdmi_tx_tmds_clk_p/_n` 刻意**不**寫，故仍留 HIGH 並照常 fail。

`clk_pl_0 ↔ pcie_user_clk`（TIMING-6/7）只有在「兩個方向都有 `report_clock_interaction` 紀錄 + 無 clock group + 命名約束與本輪覆蓋證據俱全 + Layer A 無 critical CDC／無 uncovered HIGH」時才改名為已審方法學；r3 因 `CDC-10/12/13` 與 uncovered HIGH 仍舊不可分級。

### 13.3 尚未收斂（保持紅燈，不自行闔上）

`scripts/gates/sc7f0_cdc_review.json` 的 `io_items`：**RX DDC**（`rx_ddc_scl`/`rx_ddc_sda`，`NEEDS_STRUCTURAL_REVIEW`）、`async_in_5v_det`(+PCIe 鏈)、`async_in_tx_refclk_rdy`、`async_out_hpd`；`tx_tmds_clock_pad` = `BLOCKED`。DRC 的 `RTSTAT-10` 亦 `NEEDS_STRUCTURAL_REVIEW`。RX DDC 的第一級 `DDC_INST/clk_scl_flt_reg[0]` 沒有 `ASYNC_REG`（`build/evidence-dcpio-26111106/query/s1-pad-first-stage.txt`），不得用過採樣比或 false path 洗白。

### 13.4 本輪檔案與實測

新增：`scripts/sc7f0_review_policy.py`(642)、`scripts/check_sc7f0_timing.py` 重寫(470)、`scripts/check_sc7f0_named_constraints.tcl`(398)、`scripts/gates/sc7f0_{cdc,drc,clock_pair}_review.json`(527/120/244)、`constraints/sc7f0_async_io.xdc`(79)、`scripts/tests/test_sc7f0_two_layer_gates.py`(1050)、`scripts/tests/fixtures/named_constraints_stub.tcl`(59)。修改：`scripts/build_zu4ev.tcl`（LATE 掛載 async IO XDC）、`scripts/impl_sc7f0_dual_video.tcl`（route 後補 `report_exceptions{-ignored,-scope_override,-coverage,-summary}`、`report_drc`、`report_io`、`report_clock_interaction`、`report_clock_networks`、`report_disable_timing -user_disabled`，並在 `cdc.rpt` 後產生覆蓋清單）、`scripts/build_sc7f0_vcu_release.sh`（報告齊備檢查、政策快照 `gates/policy/`＋`policy.sha256`、recheck 改用 `--policies="$OUT/gates/policy"`）、`scripts/check_sc7f0_release_package.py`（release 必須自帶政策快照且 hash 相符；分 Layer A／Layer B 的 FALSE GATE）、`scripts/sc7f0_release_id.py`（`REQUIRED_SOURCE_FILES`＋缺檔即 raise）、`.gitignore`（只加 `!scripts/sim_sc7f0_reset_cdc.tcl` 一條精準反向例外，未放寬 `sim_*`）、`scripts/tests/test_sc7f0_timing_state.py`、`tb/sc7f0_timing_gate_tb.py`。

實測（離線）：`python3 -m unittest scripts.tests.test_sc7f0_two_layer_gates` → **61 OK**；含 timing/CSR 的 9 支 → **142 OK（13 skip 需 Vivado）**；`tb/sc7f0_timing_gate_tb.py` → TB_PASS；`scripts/check_sc7f0_timing.py build/vcu-release-26111103-r1/fpga/project` → **FAIL**（Layer A：uncovered HIGH、`CDC-10 Critical=28`、`CDC-12 Critical=10`、`CDC-13 Critical=296`、critical 細節、缺 `drc.rpt`、`TIMING-6/7 Critical Warning=1`；Layer B 另計），凍結 r3 仍為 FAIL；`build/qpcie_zu4ev_proj` → FAIL（缺 `drc.rpt`）。`python3 -m unittest discover -s scripts/tests` → 292 ran，**僅 `test_sc7f0_mcu_app_image` 8 failed + 2 errors**，已在 `git archive HEAD` 的乾淨副本重現（本地 `test_mcu_nuc1262/nuc1262_bringup.elf` 為 10/24 舊產物），與本輪無關。`bash -n`、`py_compile`、`git diff --check` → rc 0。

**未做**：綜合／實作／`report_cdc`／`report_drc` 新報告、PS/PetaLinux build、package、部署、燒錄、驅動安裝、板卡寫入、MCU 操作、`git add`/`commit`/`push`。本節內容不可解讀為任何 TX／DDC 外部訊號「無負載」或已簽核。

## 14. 更正（隔日，離線、僅本地 sim＋靜態）：probe 鏈抽頭不是第三級，撤回 §12.3 第 4 項的證據

本節只改 `rtl/sc7f0_hdmi_probe.v` 的抽頭與註解、`tb/sc7f0_hdmi_probe_async_levels_tb.sv` 的判別式、
`scripts/tests/test_sc7f0_reset_probe_structure.py` 的規則是非同義反覆，加上兩個只跑 sim 的新工具腳本。
**未**動 constraints／`scripts/gates/`／policy／package／build 腳本，**未**動 MCU，**未** SSH／部署／燒錄，**未** `git add`/`commit`/`push`。§12.3 原文保留，不覆寫。

### 14.1 撤回：`reg_probe_pins[31:25]` 之前取的是**第一級** `[0]`，不是「第三級」

`chain <= {chain[1:0], src}` 把新樣本接在串接運算子的**低位**，所以 `[0]` 是**第一級**（最新樣本）、`[2]` 才是第三級（最舊樣本）。
本檔自己的慣例即是如此：`:412-415` 的 `if (scl_sync[2] && !scl_sync[1])` 以「[2] 較舊」判下降緣，兩級鏈則回報 `[1]`。
§12.3 第 4 項寫「7 位的輸出改為第三級 `[0]`」——**該敘述錯誤並在此撤回**：那次改動把抽頭留在第一級，`[1]/[2]` 無負載會被綜合移除，
`ASYNC_REG` 鏈在淨表裡塌成一顆，也無法與 XPM 的 `src_ff` 配對；註解宣稱的三級同步並不存在於淨表。
**已修**：`rtl/sc7f0_hdmi_probe.v:431-437` 七條鏈抽頭改為 `[2]`，註解改寫於 `:307-329`。慢速實體腳位（`det5v/hpd/scl/sda/tx_*`）維持 HEAD 的 `[1]` 兩級慣例，其他 reset 結構未動。

### 14.2 撤回：舊 `PROBE_LEVEL_SIM_GATE_PASS` 不構成「第三級」的證據（P6 是同義反覆）

舊 P6 為 `u_probe.<chain>_sync[0] === reg_probe_pins[bit]`——拿設計比自己，RTL 抽哪一級就成立哪一級，名子卻寫 "third stage"。
因此 `build/reset-probe-validation-26111106`（`PROBE_LEVEL_SIM_GATE_PASS`、checks=22 failures=0）**不得**解讀為抽頭正確。
本輪以證據說明，不是口頭否認：把改版前的 TB 對 `[0]` tap 的 mutant RTL 重跑 → `exit=0`、`checks=22 failures=0`（`build/probe-tap-mutation-26111201/old_tb_against_tap_first_stage.log`）。

同時不採 review 的建議「一拍短脈衝經 3FF 必被濾掉」：**三級同步器是延遲線，不是脈衝濾波器**，單拍脈衝會被逐級傳遞，只是延後三拍。P8b 因此斷言脈衝**會**抵達且只寬一拍。

### 14.3 本輪的判別式（都必須可失敗）

| 位置 | 內容 |
|---|---|
| `tb/...:242-300` | **獨立期望模型**（P7）：由文件契約重建 3FF 鏈＋`SRC_INPUT_REG(1)+DEST_SYNC_FF(3)` = 4 級，只喂 TB 自己的驅動線（`dri_levels`），絕不讀設計內部狀態；每個 `pl_clk0` 週期比對 `reg_probe_pins[31:25]`。鏈照 RTL 用非同步 reset 版敏感清單，`array_single` 無 reset 只會被「排空」 |
| `tb/...:501-568` | **確定延遲**（P8）：源在 `pl_clk0` 邊緣之間翻轉（含 1 ps 離緣對齊，避免激勵 race）；第一～第六個採樣緣絕不可回報，必須在第 7 緣出現（`P8a`，逐位元走 7 次）；單拍脈衝必須存活、寬一拍、落在第 7 緣（`P8b`） |
| `tb/...:570-611` | **反空斷言計數器**：`stage_discriminated[k]` 記錄「`[0]` 或 `[1]` 與 `[2]` 讀到不同值」的週期數，七條鏈都要 > 0 才算通過——否則「抽頭正確」可能只是管線靜止時三級同值的僥倖 |
| `scripts/tests/test_sc7f0_reset_probe_structure.py:131-200` | 靜態側不再寫死 `[0]`/`[2]` 字串，改由宣告 + 位移方向**推導**最舊級（`oldest_chain_stage`）；`:379` 的負向 test 在記憶體中產生 `[0]`/`[1]` 突變與「位移方向不可判」突變，要求規則**回報缺陷**；`:405` 禁止再把層級鏈與它所驅動的暫存器直接比對（同義反覆守門） |

### 14.4 本輪實測（Vivado 2023.2 真 XPM 模型，離線）

- `./scripts/run_sc7f0_reset_probe_validation.sh build/reset-probe-validation-26111201` → **RESET_PROBE_VALIDATION_PASS**；
  `structure_tests_exit=0`（15 tests OK）、`simulation_exit=0`、`RESET_CDC_SIM_GATE_PASS`、
  `PROBE_LEVEL_SUMMARY checks=34 failures=0 bad_off_edge=0 bad_x=0 model_checks=342 model_mismatches=0 chain_mismatches=0 early_arrivals=0`；
  完整 log：`build/reset-probe-validation-26111201/{reset-sim-stdout.log,verdict.txt,structure-tests.log,environment.txt}`。
- `./scripts/check_sc7f0_probe_tap_mutation.sh build/probe-tap-mutation-26111201 --old-tb build/probe-tap-evidence-26111201/pre-fix-snapshot/sc7f0_hdmi_probe_async_levels_tb_OLD.sv` → **PROBE_TAP_MUTATION_GATE_PASS**：
  control（正式 RTL，抽 `[2]`）PASS；`tap_first_stage`（`[0]`）**被拒** exit=1、failures=20、`model_mismatches=61`、`early_arrivals=14`；
  `tap_second_stage`（`[1]`）**被拒** exit=1、failures=11、`model_mismatches=42`、`early_arrivals=7`；
  舊 TB × `[0]` mutant → PASS（即 14.2 的空斷言）。突變只在 `build/` 下的副檔，正式 RTL 從未被來回改動。
- 其他：`test_sc7f0_csr_wrapper.py` 8 tests OK；`generate_sc7f0_csr_cdc.py --check` rc 0；`python3 -m unittest discover -s scripts/tests` → 294 ran，
  失敗仍僅 `test_sc7f0_mcu_app_image` 8 failed + 2 errors（§13.4 已在乾淨 HEAD 副本重現的既有問題）；`bash -n`、`git diff --check` → rc 0。

### 14.5 靜態掃描的實際範圍（不再寫「全 repo」保證）

`test_sc7f0_reset_probe_structure.py` 的 reset 形態掃描只看 `.src_arst/.wrst_n/.rrst_n/.src_rst_n` **四個 port 名**；
它**看不到** `xpm_fifo_*`/`xpm_cdc_*` 的 `.rst(<a || !b>)`，也看不到手寫的 `always @(posedge clk or posedge <閘輸出>)`。
所以它的 PASS 只意味著「`rtl/*.{v,sv}` 這四個 port 上沒有 pre-synchronizer 合成」，不是「全 repo 沒有組合邏輯驅動的非同步 preset」。
現存活例：`rtl/qpcie_csr_cdc.v:85,113`（`!ps_ready_pcie || !dest_rst_n`、`!src_rst_n || !src_online`，對 HEAD 無 diff；兩項同域，故今日為第二套手寫 reset 慣例而非 CDC 缺陷），屬 review P2-10 的**擴大掃描**範圍，本輪**未**擴大。

### 14.6 仍然沒有證明的事（不得由本節推得）

本輪只有行為級 sim 與來源層靜態檢查：`ASYNC_REG` 是否成對進入淨表、`report_cdc` 的 CDC-10 六列是否消失、`SRC_INPUT_REG(1)` 是否如宣稱，仍需**下一輪真實綜合／實作報告**。
模擬器把每一次時鐘擷取都解析成 0/1，**不證明亞穩態不存在**；本 TB 用了兩個獨立來源時鐘（148.5 MHz／297 MHz）＋ one-hot 走位、快速翻轉、停鐘／重啟與 probe 自身 reset 迴圈，但這只是結構與延遲層面的證據。

## 15. 套件/備份/閘門定稿輪（2026-11-12，純本機；未 full build、未部署、未燒錄）

正式交付物：[docs/sc7f0_release_deploy_acceptance_runbook.md](sc7f0_release_deploy_acceptance_runbook.md)
— B2 部署順序（完整包→上傳→VERIFY→一次 COMMIT→獨立 eMMC SHA→真 boot-ID 重啟→host driver 自建自裝
→GStreamer）與 5 分鐘併發驗收程序；該檔 §6 明列本輪未執行事項與**恢復能力 = 未證明（BLOCKED）**。

### 15.1 本輪完成（都有可重跑測試）

| # | 項目 | 檔案 | 驗證 |
|---|---|---|---|
| 1 | source inventory 補完＋角色清單分離 | `scripts/sc7f0_release_id.py`（`REQUIRED_SOURCE_FILES` 新增 `validation` 組、`FPGA_INPUT_GLOBS`/`VALIDATION_SOURCE_GLOBS`、segment-wise `matches_globs`、`source_inventory()`）、`.gitignore`（多一條 `!scripts/sim_sc7f0_probe_tap.tcl`） | `test_sc7f0_two_layer_gates.py::ValidationSourceInventoryTests`（7 項：刪掉任一 required 必 fail；required 檔必須存在且被 git 看見；角色清單不得互相污染） |
| 2 | 以真檔為準的驗證來源 | 真檔：`scripts/run_sc7f0_reset_probe_validation.sh`、`scripts/sim_sc7f0_reset_cdc.tcl`、`scripts/sim_sc7f0_probe_tap.tcl`、`scripts/check_sc7f0_probe_tap_mutation.sh`、`tb/sc7f0_reset_cdc_tb.sv`、`tb/sc7f0_hdmi_probe_async_levels_tb.sv`、`tb/sc7f0_hdmi_probe_tb.sv`。舊 handover 寫的 `scripts/run_sc7f0_reset_probe_sim.tcl`／`tb/tb_sc7f0_*.sv` **根本不存在**，故測試直接斷言路徑存在 | 同上 |
| 3 | 預覽段寫出三份清單並斷言覆蓋 | `scripts/build_sc7f0_vcu_release.sh`：`SOURCE.sha256` / `SOURCE_FPGA.sha256` / **新** `SOURCE_VALIDATION.sha256`；任何 required 入力若不在任一角色清單→拒絕 | `test_sc7f0_release_package.py::test_required_input_left_out_of_every_role_manifest_is_rejected` |
| 4 | PS runtime 入鏡像的位元組來源 | 新增 `scripts/resolve_recipe_install_output.py`（以 OE packagedata `FILES_INFO` 決定性解析；多候選不同摘要＝`AMBIGUOUS` 直接失敗；**無 `@present` 降級**）、`scripts/package_sc7f0_rootfs.py --expect-size`、`test_app/qpcie_debugd.c` ABI banner（`qpcie_debugd mailbox ABI h2c=0x800 c2h=0x1000`，帶 `#error` 防漂移）；`scripts/build_sc7f0_matching_ps_vcu.sh` 丟掉 `find … \| head -1`／`@present` | `test_sc7f0_ps_runtime_sources.py`（21 項）＋ `test_sc7f0_fit_rootfs.py`（新增 3 項 `--expect-size`，共 29 項） |
| 5 | 每段 required-test 實跑、gate 只讀正軌證據 | `scripts/sc7f0_release_tests.py`（記錄本輪三種 scope 指紋＋tolerated 清單）、`scripts/package_sc7f0_vcu_release.sh`（`unit-tests-at-package.json`、`SC7F0_CAPTURE_RELEASE/PS_BUILD`、kernel.config/System.map 入 `$IMG`）、`scripts/check_sc7f0_release_package.py`（三份 unit-test JSON 必須 PASS 且指紋對本輪、skip 即 fail、tolerated 只能屬已宣告的範圍外子系統、來源清單與 snapshot 互相 backing、runtime 無 `@present`、`deployable` 與 `package.ok`/`NOT_DEPLOYABLE` 一致、禁止宣稱硬體/部署驗收） | `test_sc7f0_release_package.py` 18 → **36 項**（新增 18 項負向） |
| 6 | 備份正確性小修 | `test_app/qpcie_backup_retention.h`（`qbr_commit_need_bytes` ＝ max(現行,新包)、`qbr_newest_generation`、`qbr_generation_count`、`qbr_prune` 註解與 fail-closed 修正）、`test_app/qpcie_upgrade_daemon.c`（空間用 max、保留用參照世代、寫入前先報可回退世代數） | `test_app/qpcie_backup_retention_tb.c` 新增場景 8–11 ＋ 新增 `scripts/tests/test_sc7f0_backup_retention.py`（8 項，含雨個 C TB 的編譯與執行） |
| 7 | release 入口封斜徑 | `build_sc7f0_vcu_release.sh`：`SC7F0_IMPL_RESUME` 非空直接拒絕；外部 `SC7F0_HARDWARE_ACCEPTANCE_DIR` 必須與本輪 version/XSA/bit/指紋相符才用；`accept_sc7f0_vcu_hardware.py` 的 `hardware.json` 新增 `source_fingerprint_sha256`/`git_head` | diff 可查（離線可執行部分由 15.2 覆蓋） |
| 8 | 修掉既有矛盾 | `scripts/check_sc7f0_capture_image.py` 原斷言 `sc7f0-vcud.service` **不得** enabled，與 PS 階段 Stage 4（必須 enabled）直接矛盾 — 打包段會駁掉每一輪**正確**的 PS 鏡像；現改為正向斷言（symlink 存在且為 symlink） | 本輪無真鏡像可跑該 audit（見 15.3） |

### 15.2 本輪實際跑過的離線驗證

```
python3 -m py_compile scripts/sc7f0_release_id.py scripts/sc7f0_release_tests.py \
    scripts/resolve_recipe_install_output.py scripts/package_sc7f0_rootfs.py \
    scripts/check_sc7f0_release_package.py scripts/check_sc7f0_capture_image.py \
    scripts/accept_sc7f0_vcu_hardware.py scripts/sc7f0_source_drift.py            # OK
bash -n scripts/build_sc7f0_vcu_release.sh scripts/package_sc7f0_vcu_release.sh \
        scripts/build_sc7f0_matching_ps_vcu.sh                                    # OK
cc -O2 -Wall -Wextra -Itest_app test_app/qpcie_backup_retention_tb.c … && 執行  # TB_PASS
cc -O2 -Wall -Wextra -Itest_app tb/qpcie_commit_integration_tb.c …    && 執行  # TB_PASS
python3 -m unittest discover -s scripts/tests -p test_sc7f0_two_layer_gates.py   # 87 OK
… test_sc7f0_release_package.py                                                   # 36 OK
… test_sc7f0_fit_rootfs.py                                                        # 29 OK
… test_sc7f0_ps_runtime_sources.py                                                # 21 OK
… test_sc7f0_backup_retention.py                                                  #  8 OK
… test_sc7f0_reset_probe_structure / _impl_identity / _timing_state / _csr_wrapper
  test_package_sc7f0_upgrade / _stop_token_driver / _capture_gray_constraints      # 全部 OK
git diff --check                                                                  # 乾淨
```

C TB 曾經出現的 4 次失敗，逐條 root cause（**沒有一項是靠放宽斷言關掉的**）：

1. `gens <= QBR_MAX_GENERATIONS+2`：斷言對象錯了 — 內容保留策略下「世代數」不再是那個不變量。
   改為**更強**的可恢复性斷言：`recoverable_has(BOOT-A)`／`recoverable_has(BOOT-C)`（回滚真正需要的映像必須在），
   另以「世代數 ≤ COMMIT 次數＋1」約束不會失控成長。
2. `count_prefixed(bakroot,"txn-") == 0`：**fixture 污染** — 第 6 场故意留下的 `txn-8888888888-0` 亂碼日誌
   依規定不可刪。改為同一次呼叫的前後**等值比較**（拒絕時不新增也不刪除），負向語意不變。
3. `removed == 1`（參照保留）：**我的 fixture 設計錯** — n=3、`QBR_MAX_GENERATIONS=2` 時只有 index 0 是候選，
   而 index 0 正好是「不同」的那代，production 回 0 **是正確行為**。改成 4 代（兩份重複＋一份不同）
   才真正走到「刪重複、留不同」；斷言維持 `removed == 1` 並额外斷言不同代仍在。
4. `qbr_promote(...) != 0`（不得覆寫既有世代）：**測試把提升後的名字算錯了**（`strrchr` 指到 `/`，需 `+1`），
   預先建的目錄名與實際目標不同，所以 promote 合法成功。修正名字後如預期拒絕，且兩份位元組都保留。

警告辨識：本輪唯一新增的警告（`qbr_newest_generation` 的 `int` vs `size_t` 比較）已修。剩下的全是
`-Wformat-truncation`（`snprintf` 最長 599 字元路徑／38399 字元二维緩衝寫進 300–501 字元目標）：
**無記憶体安全風險**（`snprintf` 只会截断），實際風險是**診斷文字尾端被剪**；生產路徑的名稱實際只有
約 100 字元（`EMMC_MOUNT_DIR` ＋ `.backup_upgrade` ＋ `txn-<10>-<n>`），所以那是編譯器無法證明的保守警告。
**未靜音任何警告**。

### 15.3 本輪未完成／仍封鎖（不是一個都可以當已完成讀）

1. **未 full build**：未跑任何 Vivado/PetaLinux 階段；CDC-10/12/13、13 個 HIGH IO、新增 XDC 的時序副作用**仍未證明**。
2. **未 SSH／未 R0／未部署／未燒錄／未装 driver／未動 MCU**；故**恢復能力 = 未證明（BLOCKED）**，
   需先在真機完成 runbook §2 並留下三份 sha256 ＋ MANIFEST。
3. **未跑 GStreamer 驗收**（§4 只是程序）；無 GUI session 就不能宣稱 fullscreen，也不得以 `fakesink` 或軟體編碼器冒充。
4. `check_sc7f0_capture_image.py` 的反向斷言修正**尚無真鏡像可驗**（需 PS build 產物），下一輪 `--stage ps/package` 才能確認。
5. MCU 基線 10 項仍是**既有紅**（本輪不碰 MCU）；release gate 現在會把它當成**範圍宣告**報出，而不是 MCU 安全證據。
6. `test_sc7f0_routed_profile_mutations`（pin 在 R6 `26102702` 凍結 SHA）**沒有復活成本輪門檻**；
   本 profile 的等價保護是始終執行的 `test_sc7f0_two_layer_gates` ＋ `test_sc7f0_release_package`。
7. 未 `git add/commit/push`；HEAD 仍 `aea8612`，工作樹大量 WIP 原樣保留。

### 15.4 下一輪完整 build 的確切命令候選（**本輪未執行**）

```bash
# 當日為 2026-11-12：全新 out/version（自動分配會跳開已用號），四段必須在同一次
# --stage all 內跑完，中途不得修改 SOURCE_FPGA.sha256 名單內的檔案
date +%y%m%d
python3 scripts/sc7f0_release_id.py --list-known | tail -8                # 先看已被占用的號
export XILINXD_LICENSE_FILE=<operator-supplied>
scripts/build_sc7f0_vcu_release.sh \
  --out build/vcu-release-$(date +%y%m%d)01-r1 --stage all \
  --known-version 26111101 --known-version 26111201
# 期望：gates/preflight.ok → gates/fpga.ok → gates/ps.ok → package.ok
#       ＋ gates/unit-tests{,-after-fpga,-at-package}.json 全 PASS 且指紋一致
# 失敗時：目錄內自動留 NOT_DEPLOYABLE ＋ gates/stage-failure.txt，不得手工刪除
# **本輪沒有解鎖任何燒錄授權**；部署/燒錄仍需逐段满足 runbook 的現場條件
```

---

## 16. 本輪之後：第一次真正執行 `--stage all`（2026-11-12，版本 26111202）

上面那段「下一輪候选」在 2026-11-12 00:00 真的跑下去了，結果與本文件無關（本文件的內容
仍是 2026-11-11/12 定稿輪的原樣，未被覆寫）：

- 完整報告：[sc7f0_full_build_26111202.md](sc7f0_full_build_26111202.md)
- 結果一句話：preflight **PASS**、FPGA **FAIL**（真時序失敗 + 新增 pad-closure 證據鉤子 abort）、
  PS/package **未執行**，`build/vcu-release-26111202-r1` = **NOT_DEPLOYABLE**，**沒有包**；
  同時完成 runbook §2 的 **R0 唯讀**部分，判定 **B2 BLOCKED**（同包 tar 已找到並驗算，
  但散檔 `sc7f0_vcud` 不在任何包內 ⇒ 完整恢復仍不成立）。

