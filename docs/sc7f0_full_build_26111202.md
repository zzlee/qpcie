# SC7F0 完整建置輪 26111202（fresh `--stage all`）— FPGA gate 真失敗，無包

- 執行時間：2026-11-12 00:00:29 → 01:05:45 CST（本機 `zzlee-X299-UD4-Pro`，唯一 worker，無子代理）
- 仓库：`~/qpcie`，branch `feat/zu4ev-sc7f0-bringup`，HEAD `aea86126`，WIP 全部保留、未 `git add/commit/push`
- Release 目錄：`/home/zzlee/qpcie/build/vcu-release-26111202-r1`（**NOT_DEPLOYABLE**）
- 本輪**未**部署、**未**燒錄、**未**重啟、**未**裝 host driver、**未**動 MCU、**未**改板上任何檔案

## 0. 結論

| 階段 | 結果 | 證據 |
|---|---|---|
| preflight | **PASS** | `gates/preflight.ok`、`gates/unit-tests.json`（`UNIT_TESTS_GATE_PASS`，required 12 套全 `ran`） |
| FPGA | **FAIL（真閘門失敗）** | `build.exit=1`、`NOT_DEPLOYABLE`、`gates/stage-failure.txt`；`gates/fpga.ok` 不存在 |
| PS | **NOT RUN**（依規則不接） | `gates/ps.ok` 不存在、`ps/identity-ps.json` 不存在 |
| package | **NOT RUN** | `release/`、`package.ok`、`upgrade-26111202.tar` 皆不存在 |

**沒有可交付的包。** 唯一位元流產物是 Vivado 內部 raw `impl_1/zu4ev_pcie_card_top.bit`
（`7c8212c51db191d406e0af26547a2898a210cda7094af70ddf82b720d39e898a`），它**沒有**對應
`hardware.xsa`（流程在 XSA 匯出之前就中止），且該 bit 屬 NOT_DEPLOYABLE 目錄，**嚴禁上卡**。

## 1. 事前檢查（實跑，非宣稱）

| 項目 | 命令 | 結果 |
|---|---|---|
| 無本專案活躍建置 | `ps -eo … \| grep -Ei 'vivado\|petalinux\|build_sc7f0\|make '` | 無相符程序；`build/.sc7f0-build.lock` 未持鎖；不干預其他程序 |
| 磁碟 | `df -h /` | 469G 總、啟動時 44G 可用（91%）；本輪結束後仍足夠 |
| CPU/RAM | `nproc; free -g` | 20 cores / 54 GB |
| Vivado | `source /opt/Xilinx/Vivado/2023.2/settings64.sh` | 存在且可用（2023.2） |
| License | 本機已組態值（repo 內既有設定），僅做 TCP 探測 `bash –c 'exec 3<>/dev/tcp/<host>/<port>'` | `LICENSE_PORT_REACHABLE`；**未**把端點值印出報告 |
| PetaLinux/cross | `docker run –rm petalinux:latest`（鏡像存在）、`/opt/Xilinx/petalinux/2023.2` 存在、`aarch64-linux-gnu-gcc`、`mkimage`（PetaLinux buildtools）、`dtc`、`fakeroot`、`docker volume ls`（`sc7f0-ps-vcu-sstate`/`-downloads`） | 全數就緒 |
| CLI 真實語法 | `scripts/build_sc7f0_vcu_release.sh --help` | `--out` / `--stage all\|preflight\|fpga\|ps\|package` / `--version` / `--known-version`（可重複）/ `--fpga-project` / `--ps-build-logs` |
| 已佔用版本 | `python3 scripts/sc7f0_release_id.py --list-known` | 261111 當日 01…06 全被佔用；26111201 被 `probe-tap-evidence-26111201` 佔用 |

### 1.1 freeze 前的必跑/語法檢查（都在身份凍結之前）

```
python3 scripts/generate_sc7f0_csr_cdc.py --check                # rc=0
python3 -m py_compile <15 個 checker/release 工具>                # PY_OK
bash -n <10 個 build/package/injection 腳本>                      # BASH_N_OK
python3 - <<PY (load_policy)                                       # POLICY_OK cdc items=11 / drc items=6 / clock_pair items=1
tclsh info complete <4 個 Tcl>                                     # TCL_PARSE_OK
python3 -m unittest discover -s scripts/tests                     # 370 tests：10 失敗全在 test_sc7f0_mcu_app_image
12 個 required preflight 套件逐套                                   # 全部 OK
```
`test_sc7f0_mcu_app_image` 的 10 項失敗為**既有紅**（MCU 影像稽核，本輪範圍外、未觸碰、
不在 REQUIRED_TESTS 內，release gate 只把它記為範圍宣告）。
本輪**未**修改任何腳本/checker/policy/RTL —— freeze 前也沒有做會影響來源的試驗。

## 2. 版本分配（照實際日期，不猜 01）

`allocate_version()` 在 `2026-11-12T00:00:29+0800` 給出：

```
{'version': '26111202', 'date': '20261112',
 'collisions_avoided': {'26111201': 'artifact directory probe-tap-evidence-26111201'},
 'known_version_count': 43}
```

啟動命令（實際執行、detach、以 `build.exit` 為結束標記）：

```bash
source /opt/Xilinx/Vivado/2023.2/settings64.sh
export XILINXD_LICENSE_FILE=<本機已組態端點>          # 未印出
nohup setsid scripts/build_sc7f0_vcu_release.sh \
  --out build/vcu-release-26111202-r1 --stage all \
  --known-version 26110301 --known-version 26111001 --known-version 26111101 \
  > build/vcu-release-26111202-r1.nohup 2>&1 &        # PID 4037987
```
`--known-version` 傳入的是**實測**主機上既存三包（`ssh rd@sc7f0-test.local ls /home/rd/upgrade-*.tar`）
的版本號，不是從舊報告猜的。

## 3. Preflight 實測（全 PASS）

```
IDENTITY 26111202 20261112 register CC309BD4 (dirty-content-fingerprint) head aea86126 dirty True
FPGA_INPUT_MANIFEST 182 files -> SOURCE_FPGA.sha256
VALIDATION_INPUT_MANIFEST 13 files -> SOURCE_VALIDATION.sha256
REQUIRED_INPUTS_COVERED 526 snapshot files, 193 role-tagged
UNIT_TESTS_GATE_PASS tolerated=10 failures=10 skipped=25 ran=301   # 10 = test_sc7f0_mcu_app_image（既有紅）
SOURCE_IDENTITY_STABLE scope=fpga files=320 37a51cbc…
```

身份與來源快照（`build/vcu-release-26111202-r1/`）：

| 檔案 | SHA256 |
|---|---|
| `identity.json` | `f1585d972ce8d6e43348b2ef12734b555bc4cdc38d4b4d95588e8c339937d1d0` |
| `SOURCE.sha256`（526 檔，含 untracked 真來源） | `4b3b5ec0f6e646edd662985b57306bc3c8e047d4eec3f63290c99518a68dc7cd` |
| `SOURCE_FPGA.sha256`（182） | `25b2f3239572574f25a227c7667e3efeb50f2152b2aef619603be208a18ffa0c` |
| `SOURCE_VALIDATION.sha256`（13） | `9cf3b8d9b2bc94b73be07906260328c56428fd5a5ca304310d668036acfae4d3` |
| `source-snapshot.tar.gz`（5.8 MB） | `f95fedd45ff246a0cd7e4b0da800ee8220c6e392f4958669af12edf36334212c` |
| `gates/unit-tests.json` | `f15ad2ea9de8333042c69d7b32c000184a075730af4747ea22b442fcf4599cf6` |
| `logs/release.log` | `2e0ad7f4786e51ef1af381abc00…`（完整見檔內 sha256sum 輸出） |
| `NOT_DEPLOYABLE` | `57cb259095ce4b47b1348f349539f5c71e8ff985eeaa9fe14f59f03e819ac10f` |
| `build.exit` | 內容 `1` |

全部身份欄位：`c_version=0x26111202`、GIT 暫存器 `0xCC309BD4`（來源標記
`dirty-content-fingerprint`，如實承認工作樹是髒的）、`BUILD_DATE=20261112`、
`source_fingerprint_sha256=cc309bd402f00f2ce60978b35432f9731559d9f721d1bdc8311cce62a7ddcf60`。

## 4. FPGA 階段：完整 fresh synth → place → route → reports → 中止點

時間軸（本機 CST）：

| 時刻 | 事件 |
|---|---|
| 00:00:29 | 身份分配、快照、required tests |
| 00:01–00:02:11 | IP 產生（`IP_GENERATION_COMPLETE`） |
| 00:15:49 | 頂層 `synth_design completed successfully`（elapsed 3:16；OOC IP 先跑） |
| ~00:16–00:30 | `opt_design` 1:01 → `place_design` **9:32**（Explore）→ `phys_opt_design` 2:53（AggressiveExplore） |
| 00:30–00:43 | `route_design` **12:58**（Explore，`SC7F0_TIMING_TUNED` 全部生效） |
| 00:43–00:48 | `post_route_phys_opt` 4:26（AggressiveExplore）；`routed.dcp` 00:48:12 |
| 00:48–00:56 | 19 份閘門報表全部寫出（含 r3 缺的 `clock-interaction/exceptions-ignored/exceptions-scope-override/io`） |
| 00:56–01:05:45 | `check_sc7f0_named_constraints.tcl` 逐項量測 → **abort**（見 §5.3） |

身份綁定（實測 log，非宣稱）：

```
SC7F0_IDENTITY_APPLY C_VERSION=32'h26111202 GIT_COMMIT_HASH_DEF=32'hCC309BD4 BUILD_TIMESTAMP_DEF=32'h20261112
SC7F0_IDENTITY_VERIFIED C_VERSION=0x26111202 bound in synthesis run log and run script
SC7F0_IDENTITY_RECORDED head=aea86126… dirty=1 version=0x26111202 git=0xCC309BD4 date=20261112 source=dirty-content-fingerprint
SC7F0_GRAY_ENDPOINTS_PASS u_tap/u_source_time: 64 direct bits, effective max-delay 6.000 ns   (opt 前)
SC7F0_GRAY_ROUTED_BEGIN … SC7F0_GRAY_ENDPOINTS_PASS ×2                                        (route 後 128 端點重審通過)
```

### 4.1 實測時序（本輪最終、routed + post-route phys_opt）

`fpga/project/timing_summary.rpt`（`fe6ea6de…`）：

```
WNS -2.760 ns   TNS -39.759 ns   TNS failing endpoints 405 / 369063
WHS +0.011 ns   THS 0.000 ns     THS failing endpoints 0 / 367299
WPWS 0.000      TPWS 0.000       "Timing constraints are not met."
```

逐群（同檔 Clock/Inter-clock 表）：

| 路徑群 | WNS | TNS | 失敗端點 / 總端點 | 性質 |
|---|---|---|---|---|
| `capture_clk_300m`（同域 intra） | **-0.225** | -26.973 | **399** / 122,494 | **真同域 300 MHz 路徑失敗** |
| `clkout2 → clk_pl_0` | **-2.760** | -8.246 | 3 / 188 | 非同步跨時鐘被拿去當 setup 審（未具名審查） |
| `phy_rxoutclk → clk_pl_0` | **-1.631** | -4.540 | 3 / 284 | 同上 |

最差三條路徑（原文欄位摘錄）：

1. **-2.760 ns**（本輪 WNS）
   - Source `u_hdmi_rx_ss/inst/v_vid_in_axi4s/inst/COUPLER_INST/generate_async_fifo.FIFO_INST/XPM_FIFO_ASYNC_INST/gnuram_async_fifo.xpm_fifo_base_inst/gen_fwft.empty_fwft_i_reg_replica/C`（`clkout2`，週期 6.734 ns）
   - Dest `u_hdmi_probe/rxss_tvalid_sync_reg[0]/D`（`clk_pl_0`，10 ns）
   - `Requirement: 0.002 ns`、Data Path Delay 0.642 ns、Logic Levels 2、Clock Path Skew **-1.891 ns**
2. **-1.631 ns**
   - Source `u_vid_phy_controller/inst/xpm_array_single_DRU_CTRL_in_sync_inst/syncstages_ff_reg[2][1]/C`（`phy_rxoutclk`）
   - Dest `u_hdmi_probe/phy_ch1_tvalid_sync_reg[0]/D`（`clk_pl_0`）
   - `Requirement: 0.002 ns`、route 佔 92.3 %
3. **-0.225 ns（同域真失敗的代表）**
   - `u_dualpath/u_reader/remaining_reg[10]/C` → `u_dualpath/u_reader/tx_last_be_reg[2]/D`，皆 `capture_clk_300m`
   - `Requirement: 3.333 ns`、Data Path Delay 3.547 ns（logic 1.251 / route 2.296 = **64.7 % route**）、Logic Levels **12**（CARRY8=2, LUT3..6）

判定：**WNS 持有者（-2.760 / -1.631）是 0.002 ns 需求的非同步路徑（6 個端點），不是 300 MHz 資料路徑；
但 `capture_clk_300m` 的 -0.225 ns / 399 端點是真同域失敗**（r3 為 -0.116 / -4.956 / 79 端點，本輪惡化）。
两者皆為真失敗，**不可**用 relaxation 或假路徑掩蓋。

### 4.2 實測 CDC（`fpga/project/cdc.rpt`，`a335af78…`）

| ID | Severity | Count | 有具名例外 | Exception=None |
|---|---|---|---|---|
| CDC-1 | Critical | 2 | 2（False Path） | 0 |
| CDC-3 | Info | 349 | 349 | 0 |
| CDC-6 | Warning | 8 | 8 | 0 |
| CDC-9 | Info | 35 | 35 | 0 |
| **CDC-10** | **Critical** | **13** | 7 | **6** |
| CDC-11 | Critical | 21 | 21 | 0 |
| CDC-15 | Warning | 4294 | 4294 | 0 |
| CDC-26 | Warning | 416 | 416 | 0 |

- **CDC-12 = 0、CDC-13 = 0（`grep -c "CDC-12\|CDC-13" cdc.rpt` → 0）→ r3 的 CDC-12=10 / CDC-13=296 本輪確實消除。**
- CDC-10 由 r3 的 28 降到 **13**，其中 7 條已被具名 False Path 覆蓋，**剩 6 條無人審查**，正是 §4.1 那 6 個失敗端點：
  `rxss_tvalid/tlast/tuser_sync_reg[0]`（來源分別為 XPM FIFO `empty_fwft_i_reg_replica`、
  `DROP_INST/CDC_SINGLE_INST/aclk_line_phase_si_i_2_psbram`、`…FSM_onehot_aclk_state[0]_i_1_psbram_replica`）
  與 `phy_ch0/1/2_tvalid_sync_reg[0]`（來源 `xpm_array_single_DRU_CTRL_in_sync_inst/syncstages_ff_reg[2][1]`），
  depth=7（「synchronizer 前有組合邏輯」）。
  目的端鏈在 `rtl/sc7f0_hdmi_probe.v:331-337` 確實標了 `ASYNC_REG="TRUE"`（3-FF），但
  `constraints/sc7f0_async_io.xdc` **沒有**這 7 條鏈的具名例外，政策也沒有對應條目 → Layer A 直接紅。
- CDC-1 兩條是 RX DDC 類比 pad → vendor DDC filter（已被 False Path 覆蓋）。

### 4.3 實測 DRC / methodology / check_timing

- `drc.rpt`（`64b9dcb2…`）：Violations found **123** — DPIP-2 74、DPOP-4 30、DPOP-3 13、PDCN-1569 3、REQP-1935 2、**RTSTAT-10 1**（全 Warning，無 Critical）。
- `methodology.rpt`（`4591c75e…`）：Violations found **263** — **TIMING-6 2 / TIMING-7 2 / TIMING-8 2（Critical Warning）**、DPIR-2 192、LUTAR-1 49、TIMING-9 1、TIMING-16 6、TIMING-18 2、ULMTCS-1 1、CLKC 建議 6。TIMING-6/7/8 的兩對就是 `clkout2↔clk_pl_0` 與 `phy_rxoutclk↔clk_pl_0`（政策 `sc7f0_clock_pair_review.json` 未宣告 → 依「未知非同期對預設不接受」判紅）。
- `check-timing.rpt`（`d3112789…`）：**HIGH 1 項 = 2 個 port 無 output delay：`hdmi_rx_ddc_scl`、`hdmi_rx_ddc_sda`**；MEDIUM：8 個 input port、4 個 output port（已有具名假路徑）。其餘計數（no_clock/constant_clock/pulse_width/multiple_clock/loops/latch_loops/partial delay）全 0。
- `exceptions-coverage.rpt`：4 條具名 Max Delay 的實測值與政策期待一致 —`capture_gray_to_source_time`/`capture_gray_to_csr_time` `max_delay_measured_ns=6.0`、`probe_meter_max_delay=10.0`、`rx_ss_dpram_max_delay=15.0`，`ignored=0`、`exception_position` 219/217/152/202。128 個 Gray 端點 route 後重審 PASS。
- 內建證據鏈正常：manifest 的 `cdc_rpt_sha256=a335af78…` 與各報表 `reports_sha256` 皆為本輪實值。

### 4.4 中止點（不是時序閘門，是新增的 pad-closure 證據鉤子）

`impl_sc7f0_dual_video.tcl:451` → `scripts/check_sc7f0_named_constraints.tcl:679`：

```
SC7F0_NAMED_EVIDENCE …/named-constraint-evidence.json items=29 state=
SC7F0_NAMED_EVIDENCE_PROBLEMS 7
  async_pad_hdmi_rx_5v_det resolved to 1/0 objects
  async_pad_hdmi_rx_ddc_scl / _sda, async_pad_hdmi_tx_ddc_scl / _sda,
  async_pad_hdmi_tx_hpd_in, async_pad_hdmi_tx_refclk_rdy resolved to 1/0 objects
named constraint coverage failed: …
    (file "scripts/check_sc7f0_named_constraints.tcl" line 679)
INFO: [Common 17-206] Exiting Vivado at Thu Nov 12 01:05:45 2026...
```

`1/0` = `from_objects=1`（port 存在）、`to_objects=0`（pad 的第一級序列端點量測到 0）。
但同一份 manifest 的 `endpoint_count` 分別為 3/2/2/1/1/1/2（**非零**），而且同一 pad 的
`async_in_*` 條目量到 `first_stage_async_reg=1`、`first_stage_clock_domains=clk_pl_0` —— 也就是
**第一級同步器存在且被標記**，是 pad-closure 的列舉（pin→cell→`sc7f0_sequential`）回 0，
屬於**工具查詢 false-fail**，不是「pad 沒有同步器」。因此本輪**沒有**走到
`impl_sc7f0_dual_video.tcl:452` 的 slack 檢查、`check_sc7f0_timing.py` 正式閘門與 **XSA 匯出**。

### 4.5 讀取式診斷（不寫入、不覆寫原報告、不作為本輪閘門紀錄）

`PYTHONDONTWRITEBYTECODE=1 python3 scripts/check_sc7f0_timing.py build/vcu-release-26111202-r1/fpga/project --policies=scripts/gates`
→ rc=1、`pass_gate false`、`pass_layer_a false`、`pass_layer_b false`：

- Layer A（9）：`setup/hold/pulse-width failure`、`uncovered HIGH-severity endpoint`、
  `CDC-1 Critical=2`、`CDC-10 Critical=13`、`CDC-11 Critical=21`、`critical CDC detail`、
  `TIMING-6/7/8 Critical Warning=2`
- Layer B（37）第一條：`Invalid control character at: line 30 column 684 (char 17053)`
  —— manifest JSON 內有未跳脫的裸換行（Vivado 訊息被塞進 `probe_error`），
  因此 **manifest 整個解析失敗**，其後 30+ 條「named exception/… is absent from this round's coverage manifest」
  是這個解析錯誤的下游症狀（條目其實都在 manifest 裡）。

## 5. 本輪失敗的分類（真問題 vs 工具 false-fail）

### 5.1 真的設計/時序問題（下輪必須用設計手段解，不准放寬閘門）
1. `capture_clk_300m` 同域 **-0.225 ns / TNS -26.973 / 399 端點**（r3 為 -0.116 / -4.956 / 79，惡化）。
   代表路徑 12 級邏輯、route 佔 64.7 %，位在 `u_dualpath/u_reader`（`chunk_bytes` / `remaining` / `tx_last_be` 的減法進位鏈）。
2. `u_hdmi_probe` 的 7 條 RX-SS / vid-PHY 狀態鏈（`rxss_tvalid/tlast/tuser`、`phy_ch0..2_tvalid`）
   **沒有任何具名、經審查的非同步例外**，也沒進 `sc7f0_clock_pair_review.json` 的時鐘對清單
   → 6 個 Critical CDC-10 端點 + 6 個 0.002 ns setup 端點 + TIMING-6/7/8 全紅。
   目的端為 ASYNC_REG 3-FF（`rtl/sc7f0_hdmi_probe.v:331-337`），但「有 ASYNC_REG」不等於「跨時鐘需求已審查」；
   `depth=7`（來源經 7 級組合邏輯才進第一級 FF）這件事也必須如實寫進審查記錄或改設計。
3. `hdmi_rx_ddc_scl/sda` 輸出方向仍無 output delay（check_timing HIGH），新 XDC 只處理了輸入消費端。

### 5.2 真工具缺陷（本輪只記錄，**未**在 live source 上邊 build 邊改）
| # | 症狀 | 位置 | 下輪最小修法 |
|---|---|---|---|
| T1 | pad-closure 量到 `to_objects=0` → 7 條 `1/0 objects` 直接 abort，正式版閘門與 XSA 沒跑 | `scripts/check_sc7f0_named_constraints.tcl:543-560`（`all_fanout -flat -endpoints_only $port_obj` → `get_cells -quiet -of $ep` → `sc7f0_sequential`） | 用 `get_pins`/`get_cells -of_objects`（或 `-hier`）取得端點所屬 cell 並在回 0 時回報明確錯誤代碼而非靜默 0；先以本輪 routed DCP 單跑該段確認 API 形態，再重新起一整輪 |
| T2 | manifest 內 `probe_error` 帶裸換行 → 整份 JSON 無法被 `json.loads` 解析，Layer B 30+ 條誤報「absent」 | `sc7f0_escape`／`check_sc7f0_named_constraints.tcl` 寫出段 | 在 escape 中加入 `\n`/`\r`/`\t`；並讓 `load_coverage_manifest` 對照「解析失敗」與「條目不存在」兩種錯誤訊息 |
| T3 | 每個條目 `probe_error` 都有 `missing .tmp-exceptions-ignored.rpt / .tmp-exceptions-scope-override.rpt` | 同檔 `:204-206`（相對於 cwd 寫/tmp 檔，但 gate 以 `SC7F0_REPORT_DIR` 讀） | 臨時檔寫到 `$::env(SC7F0_REPORT_DIR)` 下（或改用 `report_exceptions -return_string`） |
| T4 | `report_bus_skew: ERROR: [Common 17-170] Unknown option '-from'` 被吞進 `probe_error` | 同檔 bus-skew 查詢 | 改為 `report_bus_skew -from … -to …` 的合法簽名或 `-of_objects` 形式；錯誤必須是致命或明確記為未量測 |
| T5 | `design_state` 寫成空字串（manifest `"design_state": ""`），政策白名單只接受 `Routed/Physopt postRoute/Fully Routed` | 同檔 `design_state` 取值 | 用 `get_property STATE [get_designs]`/`current_project` 的正取值；取不到就 abort，別寫空值 |
| T6 | 本輪證據沒有装置_fit 百分比（只寫 `report_utilization -hierarchical`） | `scripts/impl_sc7f0_dual_video.tcl` 報表區 | 追加一份不含 `-hierarchical` 的 `report_utilization`（有 `%Used`），讓 fit 有實測值 |

T1–T5 屬「checker/constraint 生成 API 故障」，**本輪一律保留精確 log/版本/exit**，
未修改原報告、未回算新指紋把該輪轉綠。

## 6. PS / package：依規則未執行

`stage_fpga` 失敗 → `--stage all` 在 FPGA 中止：無 `ps/identity-ps.json`、無 petalinux 執行、
無 `BOOT.BIN`/`image.ub`/`boot.scr`、無 `release/upgrade-26111202.tar`、無 `RELEASE.sha256`、
無 host-driver/tools-source tar。未使用任何舊 bit/image 湊產物，未 record/off/forcepass。

## 7. R0（主機側恢復基線）— 只讀完成，判定 **B2 BLOCKED**

證據目錄：`build/r0-baseline-20261111T155509Z/`（`live-read-only.txt` 為完整原始輸出）

- 連線：`ssh -o BatchMode=yes -o StrictHostKeyChecking=yes rd@sc7f0-test.local`（host key 已存在，未跳過檢查）
- 主機：`sc7f0-test`，up 14:42，load 0.00/0.00/0.00，24 cores；`qpcie` 已載入（refcount 0）、
  `/sys/module/qpcie/srcversion=2BA9C2B03340C193808943C`；`/dev/video0`、`/dev/video1` 存在且 `fuser` 無持有者、
  無 `gst-launch-1.0` → **裝置閒置**；桌面：`session 3 / uid 1000 rd / seat0 tty2 / active / gdm-wayland-session（GNOME Ubuntu）`
- 卡端（只經 `sudo /home/rd/sc7f0ctl exec '<一條指令>'`，每次一個有界交易）：
  `boot_id=3b788648-35e2-42de-bc7c-4d59f7a272e0`，`Linux qpcie-zu4ev 6.1.30-xilinx-v2023.2`，
  rootfs 為 `rootfs`（initramfs/RAM），載入 0.71
- 現行 eMMC 三檔 SHA（64 char，與 `upgrade-26111101.tar` 三位元員**逐位元組相符**）：
  ```
  BOOT.BIN  f08402c122790e1914fa137d03c476c109700f349f607161c94c87147f689e76
  image.ub  46da8a2ebe16395ceb7485c8604d66958a96b6c1ee85071ee5b5d3d8a2d773f9
  boot.scr  14c14ececc4b35eb6ac10253f06a0f3dad10b7750d7283a7892676288df3bad6
  ```
- 主機三包完整 SHA：
  ```
  upgrade-26110301-vcu-300m.tar 8798975ce0a2db95ff8eccf62fa7fd50ca7bec4e5cd310ee345223edabce38f2
  upgrade-26111001-vcu-fix.tar  8b0f0f78adae0f9e4df5f849cedd6d9e7ac4106db33eec8304b1935df8c79a9f
  upgrade-26111101.tar          0efab7acd945839d251587b1f0401091e703d5f97bd88087e3a4a4dbd6dd3236  ← 與現行 BOOT.BIN 同包
  ```
  三包皆為 4 成員 ustar（BOOT.BIN/image.ub/boot.scr/manifest.sha256）；`image.ub`/`boot.scr` 三包相同、`BOOT.BIN` 各不同
  → 已把 `upgrade-26111101.tar` 下載至本機並驗算 `0efab7ac…` 一致（唯讀下載，未上傳/未修改板上任何檔案）
- BOOT 分割區 `df -Pk`：1569776 KiB 總、106584 已用、**1463192 可用（7 %）**
- `.backup_upgrade/`（state=`COMMITTED`）三檔 SHA **與現行三檔完全相同** → 該目錄只是現行複本，**不是**前一代，**不算**恢復資產；亦無 `.backup_cli_*`
- **無法由包重現的執行期狀態**：
  - BOOT 分割區散檔 `sc7f0_vcud`（81408 bytes，mtime Nov 8 17:06）
    `sha256 d296e75d415a1fb15893504ec84f2a270f33b48eb81c0107c09dc46738162ada`，
    而且 **正在執行**：`/proc/3852/exe -> /run/media/BOOT-mmcblk0p1/sc7f0_vcud`；`/usr/bin/sc7f0_vcud` 不存在、無 `sc7f0-vcud.service`。
    已把該檔以唯讀方式取回本機（`od` hex → 本地還原），SHA256 與卡上實測**逐位元組相符**，存於同一 R0 目錄。
    → 用 `upgrade-26111101.tar` 走 VERIFY→COMMIT 後重開，**VCU 編碼路徑會消失**。
  - 卡上 `/etc/sc7f0-recovery-release` 寫 `PL_BASE_VERSION=0x26110301`（`sc7f0-ps-watchdog-20261027-r2`），
    與 BOOT.BIN 所屬包（26111101）不一致 → 身分標記本身是髒的。
  - 其他執行中 daemon 來自 `/usr/bin/`（`qpcie_debugd` 784232 B、`qpcie_hdmi_daemon`、`qpcie_upgrade_daemon`），
    随 initramfs 由 `image.ub` 決定，可随該包復原。
- **R0 判定**：「與現行 BOOT.BIN 同包的完整 tar」**存在且已驗算**，但它**不足以**構成完整恢復基線
  （散檔 vcud 不在任何包內、身分標記不一致、卡上無前一代、首次 COMMIT 由**舊 daemon** 執行，包內新保留碼救不到它）。
  依 runbook §2 與本輪授權界線：**B2（解鎖燒錄）= BLOCKED**，等父代理決定的完整復原方案；
  B1（安全建置）可在 BLOCKED 下繼續，本輪已繼續。
- 未做：未上傳、未修改板上檔、未碰 RAM 內 daemon、未動 MCU、未用 `qpcie_upgrade --status`（setpci）、
  未觸發 VERIFY/COMMIT/reboot/服務操作、未抓任何 cookie/密碼。`runbook §5.3` 的 `gen-*` 手動複製
  **不是**已授權路徑，本輪未執行也未宣稱。

## 8. 來源漂移與工作樹乾淨度（失敗後覆核）

```
python3 scripts/sc7f0_release_id.py --scope fpga --check-fingerprint build/vcu-release-26111202-r1/identity.json \
        --exclude build/vcu-release-26111202-r1 --known-version 26111202      # rc=0
  SOURCE_IDENTITY_STABLE scope=fpga files=320 37a51cbc1fe5e4b663e95a7953b614c5d4839f99d4b31d51c955ae23c2cf82f8 head aea86126 dirty True
python3 scripts/sc7f0_release_id.py --scope ps --check-fingerprint …/identity.json
  SOURCE_IDENTITY_STABLE scope=ps files=119 aae115c09a6fa8fd7b3acb41682b6fe7c8768805a4b7f1bae420ae7b4eafbd12
git diff --check        # 乾淨（DIFF_CHECK_OK）
git rev-parse --short=8 HEAD   # aea86126（未 commit）
git status --porcelain  # 33 M + 39 ?? = 本輪開始前的同一組 WIP；未新增/刪除追蹤檔，未 git add
ps …                    # 無 vivado / build_sc7f0 / petalinux 殘留程序
```
本輪在 freeze 之後**未**改任何來源/政策/腳本（含 checker/tests）；只寫 `build/`（gitignore）與 `docs/`
（不在指紋範圍）。

## 9. 下一輪最小可行修正（具體、不擴散）

1. 先修 T1–T5（§5.2），全部属 checker/證據生成工具；每項配一個負面測試（回 0 端點、含裸換行的訊息、
   缺 `design_state` 都必須以明確代碼失敗，而非靜默 0 或誤報 absent）。修完必須**另起全新 out 目錄**重跑
   `--stage all`（本輪快照與指紋不可複用）。
2. `capture_clk_300m` 真失敗：從 `u_dualpath/u_reader` 的 12 級鏈下手（`chunk_bytes`/`remaining` 進位鏈重排或
   分段計數、必要時把該域週期需求交由設計決定），**不得**用放寬閘門、`record`、waiver 湊綠。
3. 為 `u_hdmi_probe` 的 7 條 RX-SS / PHY 狀態鏈補「具名 + 量測」審查：
   `constraints/sc7f0_async_io.xdc` 每條 `-to [get_cells …/rxss_tvalid_sync_reg[0]]` 型態的具名例外
   （不用 `set_clock_groups` 之类的 blanket cut），`scripts/gates/sc7f0_cdc_review.json` 加對應條目
   （要求實測 `first_stage_async_reg`、`first_stage_clock_domains`、pair_group），
   時鐘對 `clkout2↔clk_pl_0`、`phy_rxoutclk↔clk_pl_0` 進 `scripts/gates/sc7f0_clock_pair_review.json`，
   並如實記錄 `depth=7`（組合邏輯在第一級 FF 前）的取納理由或改設計把它打平。
4. 補 `hdmi_rx_ddc_scl/sda` 輸出方向的具名 IO 約束，把 check_timing HIGH 歸 0。

## 10. 本輪明確「沒做」清單

未 full package 成功、**沒有包**、未部署/燒錄/重啟、未裝 host driver、未動 MCU、未 `git add/commit/push`、
未改板上檔案（含 RAM 內 daemon）、未跑 GStreamer 5 分鐘併發驗收、未把 raw `impl_1/*.bit` 當成果、
未以 `gen-*` 手動複製冒充恢復、未用舊 `26111103`/`26111102` 產物湊本輪。

## 11. §9 第 3、4 項的後續修正（261112 之後，本工作樹，未提交）

對應 §9 條目 3（`u_hdmi_probe` 六條外部診斷位準 + `clkout2↔clk_pl_0`、`phy_rxoutclk↔clk_pl_0`）與
條目 4（DDC 輸出方向），以及一條在實跑 DCP 複算時才發現的工具漏洞。全部只在本地：未 `git add`、
未 build、未部署。

### 11.1 設計端（§9 條目 3 的「改設計把它打平」）

`rtl/sc7f0_hdmi_probe.v`：`rx_ss_video_t{last,user,valid}` 先在 `clk_rx_video`（= `clkout2`）打一拍，
`phy_rx_axi4s_ch{0,1,2}_tvalid` 先在 `clk_rxout`（= `phy_rxoutclk`）打一拍，之後才進原本的 `pl_clk0`
3-FF `ASYNC_REG` 鏈。26111202 的六筆 CDC-10（`Exception = None`）就是因為外部域位準經vendor IP 的
組合邏輯直達 `pl_clk0` 第一級；只補同步行、不補來源暫存器，`report_cdc` 仍判 CDC-10。來源暫存器
刻意不掛 reset（要掛就得把 `pl_clk0` 的 `rst_n` 拉進外部域，正是本專案已經拆過一次的混域 reset）。
`tready` 在板層被 tie 為常數且該輪無 CDC 行，故不多加死邏輯。

代價（如實記錄）：`reg_probe_pins` 是「位準」tap，一個只有 1 個 `pl_clk0` 週期的短位準經來源域重新
計時後，可能因目標取樣邊界未落在 producer 保持窗內而被丟棄；不會丟失的計數（beat/SOF/pixel）本來
就在 producer 域計數、以 Gray 匯流排跨越。TB 的 P8b 已改成「掃 1/2/3 週期，DUT 必須與模型預測完全一致
（同一個 first edge、同一寬度）、絕不早於 `PIPE_MIN`、絕寬於保持週期+1」，並記錄 1 週期被丟棄、2/3 週期
抵達（edge 7）的實際觀察值。

### 11.2 約束與策略

* `constraints/sc7f0_async_io.xdc`：新增六條具名內部例外 `probe_*_src_to_probe`，一律
  `-from <來源暫存器> -to <鏈 [0]>`，絕不排除 `[0]→[1]/[2]`；另新增兩條 DDC 輸出方向
  `async_out_hdmi_rx_ddc_scl/_sda -to [get_ports …]`（每 port 一行、無 wildcard、無 `set_clock_groups`、
  不虛構 `set_output_delay`）。
* `scripts/gates/sc7f0_clock_pair_review.json`：新增 `clkout2__clk_pl_0`、`phy_rxoutclk__clk_pl_0`，
  每個條目要求兩個方向的 `report_clock_interaction`、六條跨越的 `first_stage_async_reg`／
  `clock_domain_count==2`／鏈仍被分析、feed-in 以來源時鐘自身需求計時、meter/Gray/DPRAM max-delay 仍
  在、`clock_groups==0`，並註明 `Partial False Path (unsafe)` 字串本身不是證據。
* `scripts/gates/sc7f0_cdc_review.json`：新增 `rx_ddc_scl_output`/`rx_ddc_sda_output`（同一
  `pair_group rx_ddc`，SCL 不可能單獨過），並把 `timing18_missing_io_delays` 改寫為 26111202 的實測
  分組（輸入 0 HIGH/8 MEDIUM、輸出 2 HIGH/4 MEDIUM）。

### 11.3 工具漏洞（複算真實 DCP 才發現）

`scripts/check_sc7f0_named_constraints.tcl` 的輸出方向分支從不查詢例外本身，只量測 pad driver，
因此刪掉 `async_out_*` 那行 XDC 也不會讓 manifest 出現任何異常。已修：`sc7f0_report_exceptions`
依實際存在的那一側組 query（`set_false_path -to <port>` 沒有 `-from`），`sc7f0_exception` 新增
`expect_from`（無 `-from` 的例外其 From (%) 記為 not applicable，不是 0 %、也不算覆蓋失敗），
輸出分支若解析不到 exception position 即命名失敗。另新增 `scripts/replay_sc7f0_named_constraint_hook.tcl`
（唯讀複算：複製報告、前後比對 sha256、輸出目錄必須是全新目錄且不得是 round 目錄）。

### 11.4 已實際執行的驗證

* `./scripts/run_sc7f0_reset_probe_validation.sh build/cdc-fix-validation-r7` → `RESET_PROBE_VALIDATION_PASS`
  （`checks=47 failures=0 model_mismatches=0 cap_mismatches=0 src_off_edge=0 src_stalled_changes=0`）。
* 突變驗證（`/tmp/sc7f0-mutation`）：來源暫存器改回 `posedge clk` → 靜態測試 2 Fail + `RESET_PROBE_VALIDATION_FAIL`
  （`cap_mismatches=9 src_off_edge=34`）；鏈改回直連外部 port → 靜態 3 Fail + sim FAIL（`model_mismatches=15`）。
* `python3 -m unittest discover -s scripts/tests` → 416 tests，僅 `test_sc7f0_mcu_app_image` 8 failures + 2 errors
  （需要 MCU 映像產物，與本題無關，事前即如此）。
* 唯讀複算同一個 26111202 checkpoint（`zu4ev_pcie_card_top_postroute_physopt.dcp`），兩次都用全新
  輸出目錄，絕不寫回原輪：
  * `build/cdc-hook-preflight-26111202-r1/`（修輸出方向查詢**之前**）：`items=37 hook_problems=12
    hook_section_errors=0`，12 筆全部是六條 `probe_*_src_to_probe`「來源暫存器不存在」。
  * `build/cdc-hook-preflight-26111202-r2/`（修好之後，正式依據）：`items=39 hook_problems=14
    hook_section_errors=0`、`REPLAY_SOURCE_UNCHANGED files=12`、`REPLAY_DONE seconds=858`。
    14 = 12（probe 來源暫存器不存在）+ 2（`named output-direction constraint
    async_out_hdmi_rx_ddc_scl/_sda is not in this design`）。後者正是漏洞修好後的證據：hook 現在會
    點名缺失的輸出方向例外，不會安靜通過。其餘探針（四個既有輸出 pad、DDC 輸入濾波器、
    meter/Gray/DPRAM max-delay、bus skew、`clock_groups = 0`）全數正常執行。
  * 兩次 Vivado 結束碼為 0，語意是「複算成功、證據完整」，**不是**約束通過；約束結果一律讀
    `REPLAY_VERDICT`（兩次都是 FAIL — 對早於新約束的 checkpoint 這是正確答案）。

### 11.5 仍需新路由才能結案

1. 六筆 CDC-10 是否真的消失、六條 `probe_*` 例外是否解析為 `False Path` 且鏈仍被分析：只能在含新 RTL
   與新 XDC 的全新 `--stage all` 輪次讀 `cdc.rpt` / `named-constraint-evidence.json`。
2. `check_timing` 的實際分類（§6 原文）：`no_output_delay (6)` = **2 HIGH**（`hdmi_rx_ddc_scl`、
   `hdmi_rx_ddc_sda`，完全無輸出延遲也無 false path）+ 4 MEDIUM（`hdmi_rx_hpd_out`、
   `hdmi_tx_tmds_clk_p`、`user_led_dma_active`、`user_led_pcie_link_up`，已各帶 false path）；
   `no_input_delay (8)` = 0 HIGH + 8 MEDIUM。新輪次預期 **HIGH 2 → 0、MEDIUM 4 → 6、該節總數仍 6**，
   所以判定必須讀 HIGH 那一列；讀總數會永遠看起來「沒改善」。
3. 其餘 **30 筆 Critical 本輪未處理，且不得宣稱安全**。「已帶 False Path」只代表該弧退出靜態時序
   分析，不等於證明了 reset 結構安全（**已約束 ≠ 已證明安全**）。實測拓撲（逐行解析 `cdc.rpt`，共
   36 筆 Critical）：

   | 規則 | 發起端 | 扇出 | 目的端（實測） | 仍欠的證明 |
   |---|---|---|---|---|
   | CDC-1 ×2 | `hdmi_rx_ddc_scl` / `hdmi_rx_ddc_sda`（pad） | 各 1 | `u_hdmi_rx_ss/inst/v_hdmi_rx/inst/SYS_INST/DDC_INST`（vendor RXSS） | 進入 vendor block 後第一級所屬時鐘域、濾波器級數與 `ASYNC_REG`、SCL/SDA 雙向取樣協定 |
   | CDC-10 ×7 | `u_pcie_ip/inst/user_reset_reg/C` | **7** | 全在 `u_dualpath/*`：`u_packet_reset`、`u_packet_commands/u_reset`、`u_packet_commands/u_read_reset`、`u_packet_completions/u_reset`、`u_packet_completions/u_read_reset`、`u_tx_cdc/u_reset`、`u_tx_cdc/u_headers/u_reset`（`clk_pl_0` 2 筆 + `capture_clk_300m` 5 筆） | 單一發起 reset flop 橫跨 2 個目的域；各目的域同步器級數/`ASYNC_REG`/第一級時鐘域；非同步 assert + 同步 deassert 是否真的成立；目的域尚未出 reset 時被發起端觸發的 payload 視窗分析 |
   | CDC-11 ×21 | **六個發起端**：`u_100m_reset/U0/…FDRE_PER_N`（8）、`u_dp_mem_reset/u_final/arststages_ff_reg[3]`（4）、`u_rx_video_reset/u_final/…`（3）、`u_300m_reset/U0/…`（2）、`u_capture_reset/u_final/…`（2）、`u_dualpath/u_packet_reset/u_final/…`（2） | 21 | `u_capture_reset`、`u_dp_mem_reset`、`u_rx_video_reset`、`u_ps_capture/u_regs/u_config{,/u_read_reset}`、`u_ps_capture/u_regs/u_metadata{,/u_reset}`、`u_ps_capture/u_tap/u_headers/u_read_reset`、`u_ps_capture/u_tap/u_pixels/u_read_reset`、`u_hdmi_rx_ss/…/M_AXIS_VIDEO_RST_CDC_INST`、`u_dma_top/u_video_fifo_reset`、`u_dma_top/u_video_req_cdc/u_rd_reset`、`u_dualpath/u_packet_{commands,completions}/u_{reset,read_reset}` | 跨 `clk_pl_0 / capture_clk_300m / clkout2 / pl_clk_300m / pcie_user_clk` 的扇出偏斜；False Path 同時關掉 recovery/removal 與 min-pulse-width 檢查這件事的顯式處置；目的時鐘被停止時發起端改變的停鐘分析；把多域共用同一條 released reset 的「統一 reset 策略」所帶來的相互拖拽風險 |

   故 CDC-11 的正確描述不是「`u_100m_reset` 一條」，而是**六條發起鏈**（括號為各自扇出數，和為 21）。

### 11.6 結案這 30 筆的兩條正確路線（本輪把決定交還，未擅自行事）

政策不變前提：Layer A **不允許把 Critical 重新分類為已審查**；操作者目前只核准 Warning/Advisory 的
審查，**未核准 Critical 豁免**；任何路線都不得用「把非同步 assert 改成同步 assert、拆掉同步
deassert、移除停鐘保護」換取數字歸零。

* **選項 A — 結構修復（不需要新政策）**：讓每個目的域擁有自己域內的發起暫存器（在發起域先打一
  拍，或各目的域各自做本地同步器），使單一發起 flop 不再橫跨 ≥2 個目的時鐘；reset 弧的 False Path
  改由可量測的結構規則（級數、`ASYNC_REG`、第一級時鐘域、脈寬）搭配新路由重測 `report_cdc` 把關。
  代價：動到 `u_dualpath`、`u_capture_reset`、`u_dp_mem_reset`、`u_ps_capture/*` 等與 300 MHz 讀取鏈
  相鄰的結構，需要一整輪 fresh synth+route；能否讓 Critical 真的消失，只能由該輪 `cdc.rpt` 回答。
* **選項 B — 操作者明確核准的嚴格證據審查**：仿本輪 `internal_async` 的做法定義「已審查 Critical
  reset CDC」證據等級，逐 root 要求實測（目的域清單、每個目的域同步器級數與 `ASYNC_REG`、第一級
  時鐘域、扇出數、脈寬/停鐘分析、reset 協定文件），證據不齊即命名失敗。**此路需操作者先核准**，
  本輪未實作，也不可被引用為「已經允許」。

**NEED_DECISION（交還操作者）**：在「不得重新分類 Critical」與「本輪未授權整板建置」的現行契約下，
這 30 筆 Critical 無法由本輪結案。請指定 A / B / A+B 混合（先收斂扇出，再以證據等級審查殘留），
並一併指定是否授權下一輪 fresh `--stage all`。
