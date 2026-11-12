# SC7F0 完整新包嘗試 26111204 — 結果：**無合格包**（route WNS < 0，依使用者 WNS>=0 裁決停止）

日期 2026-11-12（UTC 03:01Z 起）。角色：build worker。範圍：只在 `/home/zzlee/qpcie`，
未 SSH、未燒錄、未裝 driver、未動 MCU、未 git add/commit/push、未改任何 source/RTL/XDC/
scripts/recipes/policy。既有 WIP 原樣保留，未 reset、未 stage。

## 1. Source 身分（整輪凍結，結束時複核未漂移）

| 項目 | 值 |
|---|---|
| git HEAD | `aea86126bda15af8d200c79aa62b853fc57f3b39`（branch `feat/zu4ev-sc7f0-bringup`）|
| worktree | dirty（既有 WIP，非本輪產生）|
| 分配版號 | `26111204`（`26111202`/`26111203` 為既有 diagnostic 輪，未重用）|
| GIT 登記暫存器 | `09C2C4F5`，來源 `dirty-content-fingerprint` |
| BUILD_DATE 暫存器 | `20261112` |
| source fingerprint (all scope) | `09c2c4f5f94a6508ab59de6569d8af6d113f14298280dbd30c6d7bcf3ad87618` |
| 快照 | `build/vcu-release-26111204-r1/source-snapshot.tar.gz`（sha256 前綴 `d00cb038…`，529 檔，含 untracked）|
| FPGA 輸入清單 | `SOURCE_FPGA.sha256` 183 檔 |
| 身分檔 | `build/vcu-release-26111204-r1/identity.json`、`VERSION`、`SOURCE*.sha256` |

## 2. 實際命令與每 stage exit

| Stage | 命令（既有入口，未改碼） | exit |
|---|---|---|
| preflight | `bash scripts/build_sc7f0_vcu_release.sh --stage preflight --out build/vcu-release-26111204-r1 --version 26111204 --known-version 26111101` | **0**（`gates/preflight.ok`、`gates/unit-tests.json` ran=333 tolerated=10）|
| FPGA（IP→synth→place→route→bit） | `SC7F0_ENABLE_VCU=1 SC7F0_TIMING_GATE=record` + 凍結身分 + `bash scripts/build_sc7f0_dual_video_hw.sh build/vcu-release-26111204-r1/fpga/project` | **1**（`fpga/project-logs/build.exit=1`）|
| PS / package | **未執行**（`ps/`、`release/` 空；無 `gates/ps.ok`、無 `gates/fpga.ok`、無 tar） | — |

環境：`XILINXD_LICENSE_FILE=2101@192.168.200.112`、`/opt/Xilinx/Vivado/2023.2`、
directives `PLACE=Explore PHYS_OPT=AggressiveExplore ROUTE=Explore POST_ROUTE_PHYS_OPT=AggressiveExplore`
（皆為 `build_sc7f0_vcu_release.sh` 原有預設值，未新增參數）。
`SC7F0_IMPL_RESUME` 未設定（全新 synth→route）。

## 3. 最終 route timing（本輪證據，非舊輪）

`build/vcu-release-26111204-r1/fpga/project/timing_summary.rpt`（routed design）：

```
WNS -2.472 ns   TNS -11.946 ns   6 failing setup endpoints / 369041
WHS  0.004 ns   THS  0.000 ns   0 failing hold endpoints
WPWS 0.000 ns   TPWS 0.000 ns
```

各 clock 群（同一份報告，僅列既有數字）：

| Clock /  crossing | WNS (ns) | failing/total endpoints |
|---|---|---|
| 全部 intra-clock（含 `capture_clk_300m`） | 皆 >= 0（`capture_clk_300m` = 0.000，122671/0 失敗） | 0 |
| `clkout2 → clk_pl_0` | **−2.472**（TNS −7.406） | 3 |
| `phy_rxoutclk → clk_pl_0` | **−1.702**（TNS −4.540） | 3 |

最壞路徑（報告原文）：`u_hdmi_probe/rxss_tuser_src_reg/C`（clkout2）→
`u_hdmi_probe/rxss_tuser_sync_reg[0]/D`（clk_pl_0），requirement 0.002 ns、
0 logic levels、clock path skew −1.995 ns ⇒ 失敗由探測 tap 的**來源域餵入時鐘偏斜**主導，
不是 logic depth。對照上一輪 `26111202`：WNS −2.760／TNS −39.759／405 failing endpoints ⇒
capture 300 MHz 群已改善收斂（本輪 0 失敗），違例集中到 probe tap 的兩個 async crossing。

## 4. 為何沒有 XSA／沒有包

route/bitstream 完成（`impl_1/zu4ev_pcie_card_top.bit`，7,797,815 B，sha256 前綴 `cc570b7c…`），
但 `scripts/impl_sc7f0_dual_video.tcl:451` 的具名例外覆蓋檢查
（`scripts/check_sc7f0_named_constraints.tcl`）在報告 stage 內以 Tcl 錯誤中止：

```
SC7F0_NAMED_EVIDENCE_PROBLEMS 20
item query aborted: can't set "a(values)": variable isn't array
```

因此 `hardware.xsa` 從未寫出（`fpga/project/hardware.xsa` 不存在），
`timing-gate-record.json` 也未產生（中止點在 gate 區塊之前）。
兩件事都是**事實陳述，非放行**：本輪即使有 XSA 也不可出貨，因為 **WNS < 0**。

接受依據：`USER_WNS_ONLY_ACCEPTANCE`（使用者裁決「WNS>=0 即通過」）。CDC/DRC/warning 照實
保留在既有報告檔中，本輪未新增 Critical=0／全 warning 結案／獨立 review 門檻，也未把
`USER_WNS_ONLY_ACCEPTANCE` 冒充原 strict checker PASS（strict gate 本輪根本未評估值）。
`fpga.ok`／`ps.ok`／gate JSON 一律未偽造。

## 5. 復用候選檢查（結論：無可用候選）

| Artefact | 记录的 WNS | 可否復用 |
|---|---|---|
| `build/vcu-release-26111103-r1/fpga/project/`（2026-11-11，C_VERSION 0x26111103，register 0xB821E48E） | gates/timing-gate-record.json 記 WNS **+0.053** | **否**：無 `hardware.xsa`（find 全 build 樹 2026-11 至今 0 個 `hardware.xsa`），且 source fingerprint `b821e48e…` ≠ 本輪 `09c2c4f5…`（缺 11-12 的 reader/probe 修正）|
| `build/vcu-release-26111202-r1`、本輪 `26111204` raw bit | WNS −2.760／−2.472 | 否（WNS<0，且無對應 XSA）|

不把舊 WNS 套到新 bit、不重用不匹配 XSA；因此「完整新包」的前置（timing-clean bit +
matching XSA）目前不存在。

## 6. 本輪同時完成的文件修正（docs 不在凍結 manifest 內，已核實）

`docs/` 在 `SOURCE.files`／`SOURCE_FPGA.sha256`／`SOURCE_VALIDATION.sha256` 中 0 筆命中，
編輯後 `sc7f0_release_id.py --scope fpga --check-fingerprint` 仍 `SOURCE_IDENTITY_STABLE`，
`git diff --check` clean，`git status` 與凍結前唯一差異是 ` M docs/sc7f0_build_package_flash.md`。

- `docs/sc7f0_build_package_flash.md:75` 新增小節「H2C mailbox 位址與前後端匹配（燒錄前必查）」
  （+32 行）：`dc202ee`(2026-10-15)=0x400/3072 → `3588f89`(2026-11-09)=0x800/2048（與
  BAR0+0x2200 VCU host ring 尾端重疊；commit 註解的 slot 號未經源碼核對，故不引用）；
  舊包 26111101 daemon 0x400 ↔ 僅 `sc7f0ctl_compat400`；新完整包 daemon 0x800 ↔ 預設
  `sc7f0ctl`；C2H 兩邊皆 0x1000；`ABI=1`/`ready=1`、C_VERSION 版號欄（本板停滯 0x26110301）
  與 PL GIT 登記欄（0x2BCE1D81）皆不能協商 payload layout；匹配須按 image 內實際 H2C 存取
  指令／呼叫參數＋ELF SHA/BuildID＋來源指紋判定；echo 為會寫 mailbox 的正常交易，非純讀。
- `docs/sc7f0_previous_stage_acceptance_20261112.md:210` 新增 §8 更正（歷史輸出原樣保留）：
  預設 0x800 客戶端逾時 ≠ PCIe／debugd 已死（compat400 實測 echo rc=0/9 ms 逐 byte 相同、
  `exec uname`、`exec boot_id b8a77c32-483a-400b-8771-ae392ab3cbe4`，證據
  `build/current-mailbox-diagnosis-20261112T024025Z/run-025213Z/`）；該結論僅限本案例；
  §4.2 `No Locked Timing` 與 §4.3 `sc7f0_vcud`／service 缺席仍為獨立未解項。
- `docs/zu4ev_gen3x4_debug_mailbox.md` **不存在**（照實回報，未外搜）。

## 7. 留給下一輪的最小問題（一個）

**probe tap 的 async crossing 餵入路徑在本輪 route 仍違例 −2.472 ns
（`u_hdmi_probe/rxss_tuser_src_reg`(clkout2) → `rxss_tuser_sync_reg[0]`(clk_pl_0)，
requirement 0.002 ns、skew −1.995 ns），需先讓該路徑被具名 async 例外正確涵蓋或使其被
正常計時後重新 route；在此之前没有任何 WNS>=0 的 bit＋matching XSA，整包流程無法開始。**
（次生障礙，僅記錄不修：`scripts/check_sc7f0_named_constraints.tcl` 在本輪 Vivado 2023.2 以
`can't set "a(values)": variable isn't array` 中止，使具名例外覆蓋無判定。）

## 8. 未執行事項（明確）

未部署、未燒錄、未 `qpcie_upgrade --commit/--reboot`、未裝 driver、未動 MCU、未重啟主機、
未 git stage/commit/push、未改 RTL/XDC/scripts/recipes/policy、未新建 build framework。
本輪不產生任何可燒物件；標準燒錄命令（`./scripts/sc7f0_flash.sh --build <release> --host
rd@sc7f0-test.local`）在存在合格包之前**不可執行**，本輪亦未執行。
