# SC7F0-RGB-COMPOSITOR-2PPC 計畫書（v3 規格同步版：RX 主契約 = RGB888）

| 項目 | 內容 |
|---|---|
| 性質 | **計畫書（PLAN ONLY）**。本輪未做任何 build / Vivado / PetaLinux / 仿真 / SSH / 燒錄 / 工具執行 / RTL・driver・script 改動 / git 操作 |
| 本版地位 | **本檔為正式版（v3，規格同步）**：v2 的重大修正全部保留；v3 僅做規格更正——**RX 採集主契約由 RGBA 更正為 RGB888（HDMI 無 alpha）**、應用名改 `SC7F0-RGB-COMPOSITOR-2PPC`、撤銷「C2H 必須 256」舊結論（§12）。本檔由 `docs/sc7f0_rgba_compositor_2ppc_plan.md` 更名而來，**目錄內不留兩份互相矛盾的正式版**；先前 managed artifact 初稿/v2 保留原歷史不改 |
| **[M]/[S] 的範圍限制** | 需求矩陣中的 [M]/[S] **只**指 legacy 基線（既有工具、既有 source、已路由/已部署版本）之證據。**新 persona 的所有條目皆為設計要求/待驗收**；「新 persona 與現有工具/driver 往返相容」**尚未實測**，一律視同 [T]，本計畫不宣稱已通過 |
| 範圍 | 僅 `/home/zzlee/qpcie`；參考 `/home/zzlee/docker/sc6f0-sdi-alphablending`（使用者指定，僅讀少量 alpha/dataflow source 與報告） |
| 證據等級 | **[M]** 本機已量測/已路由/已上板 · **[S]** 本機 source/config 實讀 · **[E]** 本計畫理論估算 · **[R]** 參考專案內容（非本板驗證） · **[T]** 待核實/待使用者確認 |

---

## 1. 需求矩陣（含使用者最新硬性要求）

| # | 需求 | 本計畫處置 | 證據 |
|---|---|---|---|
| 1 | 同板另開應用場景（資源不足） | 新獨立 personality，舊 VCU profile 來源完全不動、不覆蓋 | [S] |
| 2 | 保留 PCIe 燒 image `upgrade_xxx.tar` | 既有**唯一**燒錄入口 `scripts/sc7f0_flash.sh` + `qpcie_upgrade` 即可燒（該入口會一併編譯／安裝該 release 自帶的 matching host driver）；舊→新、**新→舊**皆可直接燒，**不得**以「先升級工具/driver」為前置 | [M] `scripts/sc7f0_flash.sh`、`scripts/check_sc7f0_upgrade_tar.py` |
| 3 | 保留 PCIe 燒 **MCU firmware** | **現有工具 `scripts/sc7f0_mcu_flash.py` 與 PCIe→`sc7f0ctl exec`→PS I2C0 升級協定（slave `0x2A`）完整保留**；詳見 §3.6 | [M] |
| 4 | 保留 MCU 控制 | 保留 runtime 狀態 `0x32`、proxy `0x33`、`i2ctransfer -y 0 w2@0x32 0x06 0x01`（runtime restart，與燒錄是兩件事） | [S] |
| 5 | **移除 VCU 及其專用 PCIe 路徑** | **新 persona 一開始就移**（`SC7F0_ENABLE_VCU=0`、无 VCU 硬 macro、无 vcud/OMX、无 VCU 專用 packet 出口與 BAR0 VCU CFG/RING）。**非**「fit 不下才刪」，也不再列為待批准 | [S] |
| 6 | 保留 HDMI RX 採集 → PCIe DMA → host DDR（**主契約更正為 4K 8-bit RGB 60P**） | **RX/host capture 主契約 = 3840×2160 RGB888，每 channel 8 bit、**24 bit/pixel**、60P；HDMI 線沒有 alpha**。RX SS 保留改 2PPC；C2H 預設 **packed RGB24**（byte `R,G,B`）、stride **11,520 B**、frame **24,883,200 B**、60 fps ⇒ **1.492992 GB/s**。**不再一律補 A=255、不輸出 RGBA**；RGBX32 僅在工具強制時為**額外選項**，不默默取代 RGB24 主案。V4L2/DRM FourCC 以實際 headers／colorbar 核對，**不自造標準 FourCC 字串** | 設計要求 [T]（RX SS 現為 4PPC/8bpc 為 [S]） |
| 7 | 新增 PS DDR（framebuffer reader IP）→ HDMI TX（DRM 4K 8-bit RGBA 60P） | **官方 `v_frmbuf_rd` + 官方 DRM（`xlnx,pl-disp` + 官方 HDMI TX 模組）**；base 記憶體契約維持 **32-bit RGBA/RGBX** | [M]/[S] |
| 8 | 新增 host DDR → PCIe DMA → FPGA alpha over PS DDR → HDMI TX | H2C → PS DDR overlay staging → **第二個獨立 framebuffer reader** → 自研 2PPC alpha → 官方 TX | [R] |
| 9 | 外部 300 MHz／PS 產 100 MHz／PCIe clock 三主域，2PPC | 三 fabric 主域 + 必要 HDMI/GT 297 MHz 等 IO 時鐘，界線見 §6 | [S]/[M] |
| 10 | 新名字，PS/host driver/app 可區分 | `PERSONALITY_ID` + `APP_FEATURE_CAPS` + `APP_DATA_ABI` + release metadata + image 內標記；**只新增無衝突 CSR/外部 metadata**，不改 PCI ID、不做第 5 tar 檔 | [S] |
| 11 | **新版燒錄格式/工具必須相容現有版**（燒錄平面 ABI 不動） | §3.1–3.5：共用 programming plane 位元級不動；新 data-plane ABI 另立且**不被燒錄平面依賴** | [S] |
| 12 | 每次 flash 無條件一次 I2C runtime reset；無 HDMI 訊號也能 flash | 語意已整併進唯一入口 `scripts/sc7f0_flash.sh` 步驟 11（**無條件且恰好一次** runtime restart，per-staging `mcu-restart.done` 擋第二次）與步驟 12（advisory 不判定），不回退 | [M] |

> 上表 [M]/[S] 均為 **legacy 基線**證據（既有工具、既有 source、已部署版本）；**新 persona 的規格與雙向燒錄相容性全為設計要求，尚未以現有工具實測往返**（視同 [T]）。

---

## 2. 身分現況（建置 ≠ 已部署）

| | **卡上現行 r3** | 26111208（display 原型） | B1（2PPC A/B 量測） |
|---|---|---|---|
| 來源 | `build/vcu-release-26111204-r1` → `release-26111204-r3` | `build/hdmitx-display-26111208-r1` | `build/ppc-resource-ab-2611130455` |
| `C_VERSION` / GIT 暫存器 | `0x26111204` / `0x09C2C4F5`（**值是 source fingerprint 前 8 位，git head 實為 `AEA86126`**） | `0x26111208` / `0xA58A108F` | 同 08 來源 + `SC7F0_PPC` 參數化 |
| 旗標 | `full` + `ENABLE_VCU=1`（release flow 固定）；**`DISPLAY_TX` 未設定** | `full` + `ENABLE_VCU=1` + `DISPLAY_TX=1` | 同 08 + 2PPC |
| 時序 | WNS **0.000 ns** → **依使用者標準 WNS ≥ 0 達標** [M] | WNS +0.033 / WHS +0.009 / 0 failing EP [M] | 未 place & route、無 WNS |
| 資源 | — | routed **86,271 LUT (98.21%)**、114.5 BRAM (89.45%)、VCU hard macro 1/1 [M] | synth 連結後 85,255 LUT（同階段 A/B）[M] |
| 部署 | **是** | 否（被 retimer blocker 擋） | 否（僅合成） |

現行 profile 名稱實讀：`SC7F0_PROFILE ∈ {debug,full}`、`SC7F0_ENABLE_VCU`、`SC7F0_DISPLAY_TX`（`scripts/build_zu4ev.tcl:15-59`）＋ RTL 巨集 `SC7F0_C2H_ONLY`/`SC7F0_DISPLAY_TX`/`SC7F0_DEBUG_ONLY`。**沒有可讀回的單一應用身分碼**，且同一日期版存在 r1/r2/r3 不同 PS 內容 ⇒ 日期版不可當應用身分。

---

## 3. 相容性與新身分（本版重點）

### 3.1 Programming plane（燒錄平面）位元級不動清單

| 保持項 | 值/位置 |
|---|---|
| PCI ID | `0x12AB` / `0xE380`（`build_zu4ev.tcl:192-195`；`driver/qpcie_driver.h:70-71`） |
| BAR0 magic | `0x12ABE380` = `MAGIC_DEVICE_ID_VAL`（`rtl/axil_reg_space.v:323`），driver probe 硬檢查 |
| BAR 佈局 | BAR0 1 MB、BAR1 64 KB；既有全域/VideoCH/DMA/PERF/mailbox 偏移沿用（`qpcie_driver.h`、`axil_reg_space.v` localparam） |
| 升級 CSR | `REG_DMA_UPG_CTRL/PS_ADDR_L/H(0x078C/0x0790)/SIZE`、`REG_NEW_GLOBAL_*`、mailbox BAR0+0x2000（`PS 0xA0002000`） |
| H2C/C2H 控制 | 環位址/環大小/desc 取得、`dw_len`/`first_be`/`last_be`/byte-length 協議與完成記錄格式**全部沿用**（`sg_dma_engine`、`h2c_ps_ddr_writer`、`sc7f0_ps_packet_reader` 介面上限） |
| Mailbox ABI | **`QDBG_ABI = 1`**（`DB_ABI` @ block+0x04）不變 |
| 打包 | strict-ustar **恰好 4 成員** `BOOT.BIN, image.ub, boot.scr, manifest.sha256`，`manifest` 與 3 筆雜湊**嚴格相等**；外部 `RELEASE.sha256`／`release.json`；檔名 `release/upgrade-<VERSION>.tar` |

⇒ 結果：**舊工具/舊 driver 可燒新卡、新工具/新 driver 可燒舊卡**，不需任何前置升級；新 persona 不新增 tar 第 5 成員、不動檔名規則（`check_sc7f0_release_package.py:307`、`package_sc7f0_vcu_release.sh:116` 寫死）。

### 3.2 「0x800」不是 ABI 版本（v1 錯誤修正）

`include/qpcie_debug.h:11,17,45-47`：`ABI 1` 由 **`DB_ABI`（block+0x04）**宣告；`DB_H2C_DATA 0x800`／`DB_C2H_DATA 0x1000`／`DB_PAYLOAD 2048` 只是**載入視窗偏移**（0x800 是為避開 BAR0+0x2200 的 VCU ring 而搬的）。因此：
1. 「0x800-ABI daemon」一詞在計畫書改寫為「**mailbox ABI 1 的 daemon，H2C payload @0x800**」。
2. **不得**由「0x800/0x1000 未變」推論新資料面（RGB888 C2H / RGBA overlay H2C / blend）ABI major 不變。控制 ABI（=1）與**新資料面 ABI 分開管理**。

### 3.3 新增身分（只加不破壞）

| 產出 | 內容 | 讀取者 |
|---|---|---|
| `PERSONALITY_ID`（新 RO CSR） | `0x52434737`（`'R''C''G''7'` = **RGB** Compositor；取代 v2 原 `0x52434137`）；建議放全域 block 空位，**須先做全 map 空位檢查** [T] | host driver、PS app、`sc7f0ctl` |
| `APP_FEATURE_CAPS`（新 RO CSR） | 見下表（**提案新位**） | 同上 |
| `APP_DATA_ABI`（新 RO CSR） | RGB888 C2H / RGBA overlay H2C / blend 的 data-plane major.minor，**與 mailbox ABI 1 無關** | 新 driver/app |
| `release.json` 新欄 + image 內 `/etc/sc7f0-release` 追加 | `personality`、`app_feature_caps`、`app_data_abi` | 打包 audit、PS 端自检 |

`APP_FEATURE_CAPS` **提案**位（新 persona 值）：`APP_CAP_VCU_H264=0`、**`APP_CAP_RX_RGB888=1`**（取代原 `APP_CAP_RX_RGBA`，避免名稱誤導為 RGBA 採集）、`APP_CAP_H2C_OVERLAY=1`、`APP_CAP_DRM_TX=1`、`APP_CAP_MCU=1`、`APP_CAP_UPGRADE=1`。

**Legacy 對應（不得冒充舊寄存器已有這些位）** [S]：現有 `HARDWARE_CAPS_VAL` 常數依 profile 為 debug `0x8000_0010`、`c2h_only` **`0x1001_011F`**（bit28 `QPCIE_CAP_C2H_ONLY`、NumVideoCh=1、NumAudioCh=1、flags 0x1F）、`QPCIe_single_rgb24_path` `0x0001_041F`、其餘 `{VIDEO_CH, AUDIO_CH, 8'h1F}`。**r3 的 0x1001_011F 內沒有任何 VCU／MCU／overlay 位**；舊應用身分辨識一律由「profile 名稱 + `BIT(28)` + 既有版本/GIT/日期暫存器 + release metadata」映射。

### 3.4 舊 driver 必須「可燒但不會誤啟新資料面 DMA（RGB888 C2H / overlay H2C）」

新資料面由 FPGA 端做 **data-plane ABI ACK + descriptor 檢查**（**設計要求，本輪未實測，不得標 PASS**）：

- 啟用 RGB888 C2H / overlay H2C 前，host 須先讀 `APP_DATA_ABI` 並寫下 ACK；未 ACK 時資料面 FSM 保持 reset。（本節全為**設計要求**，本輪未實測）
- 每筆 descriptor 的位址/長度檢查**按目的地址空間分別定義**（host DDR 與 PS DDR 是**不同** address space，不可用同一個 pool 範圍規則套兩邊）：
  - **C2H（RX RGB24 → host）**：目的位址只限 host driver 經 `dma_map_sg`／登記的 **host DMA/IOVA buffer** 及其 length；檢查 **required frame 24,883,200 B / stride 11,520 B** 不超出已分配緩衝；**不得**拿 §8.3 的 PS pool 去套 C2H。
  - **H2C（overlay → PS DDR）**：目的位址只限 **PS 端核准的 overlay staging pool**（§8.3）及其 buffer length。
  - **升級（upgrade）**：仍限**原 staging `dau_fpga@0x30000000` 與原規則**，**不等待也不依賴** video ACK（§3.1）。不符即**拒收 + 錯誤計數 + 中斷**，不寫入（此條同時防止新 persona 覆寫舊 NV12 小緩衝）。
- 升級/控制路徑（`qpcie_upgrade`、mailbox、ICAP/QSPI、`dau_fpga@0x30000000` staging）**不讀也不等**此 ACK ⇒ 舊 host driver/舊工具在任何情況下都能完成 VERIFY/COMMIT。

### 3.5 升級流程語意保留（不可回退）

`./scripts/sc7f0_flash.sh --build <BUILD_DIR>`（唯一燒錄入口；第二條 host 端燒錄路徑已於 2026-11-16 移除）固定順序：package-audit → 環境/身分 → transfer → host-tool（由該 release 的 `host-tools-src.tar.gz` 編譯）→ eMMC 備份 → VERIFY（Status 0x05）→ **一次 COMMIT**（結果不明不重試）→ **獨立 eMMC SHA 回讀** → warm reboot + PCIe rescan（**不重啟 x86**）→ PL version／三個 PS daemon 覆核 → **無條件且恰好一次** `i2ctransfer -y 0 w2@0x32 0x06 0x01` MCU runtime restart → boot/hash 核對。capture 屬 **advisory，非閘** ⇒ **無 HDMI 訊號也能完成燒錄**（既有行為，新 persona 維持）。

### 3.6 MCU：PCIe → PS I2C0 真燒錄路徑（v1 錯誤修正）

**先前「本倉只有 reset / NoEvidence」為錯誤敘事，本節取代之。** 本倉**已有**可實際寫 NUC1262 APROM 的工具與協定：

| 項目 | 事實 | 來源 |
|---|---|---|
| 工具 | `scripts/sc7f0_mcu_flash.py`（In-System MCU Firmware Upgrade **over PCIe**；無 JTAG/Nu-Link） | `scripts/sc7f0_mcu_flash.py:1-30` [S] |
| 通道 | x86 → `ssh … sudo -n sc7f0ctl exec` → PS 端 `i2ctransfer -y 0 …` | 同上 `:43-52` [S] |
| 升級協定從址 | **`UPG_SLAVE_ADDR = 0x2A`**；`REG_SLAVE_ADDR = 0x32`（runtime 狀態）、proxy `0x33` | `:22-24` [S]、`docs/sc7f0_system_architecture.md:103-108` [S] |
| 分段上限 | **`UPG_STAGE_MAX = 8192`** bytes、`MAX_CHUNK_SIZE = 32`；CRC8 + CRC32 | `:23-35` [S] |
| 已實測先例 | v1.1.13 部署：255 chunks 全 ACK、COMMIT ACK=0、reset 後讀回版本；v1.1.15 映像 8088 B < 8192 B；回滾指令白名單化 | `docs/sc7f0_takeover_20261021.md:210-231`、`docs/sc7f0_hpd_fix_v1.1.15_20261021.md:100-110` [M] |
| 誠實界線 | 「無獨立 APROM 全內容讀回雜湊介面，不宣稱 byte-for-byte readback」；MCU **不在** `upgrade-*.tar` 自動更新內容內 | `docs/sc7f0_takeover_20261021.md:231`、`docs/sc7f0_system_architecture.md:103-105` [S] |

處置：新 persona **保留**此工具與 0x2A/0x32/0x33 通道；**未來真正執行 MCU 燒錄仍需另行明確授權 + 原版本備份 + 救援（變磚）風險評估**；**不得**以唯讀版本查詢或 runtime restart 冒充「韌體已更新驗證」。本輪**未執行**任何工具。

---

## 4. 保留 / 移除 / 新增矩陣

資源欄只列**已核的 A 基準絕對 LUT**（同階段 `open_run synth_1` 連結後）；FF/BRAM/DSP 逐模組數值請查完整報表 `build/ppc-resource-ab-2611130455/reports/ppc_ab_compare.csv`（v1 誤把 Δ 欄當絕對值，本版移除）。

| 模組（real instance） | A 基準 LUT | 判定 | 說明 |
|---|---|---|---|
| `u_hdmi_rx_ss` | 13,424 | **保留**（改 2PPC 組態） | 需求 6（輸出主契約 **RGB888**） |
| `u_vid_phy_controller` | 7,520 | 保留 | RX/TX GT |
| `u_dma_top`（PCIe DMA 頂） | 30,891 | **共享保留** | C2H/H2C/CSR/升級 |
| `u_dma_top/u_h2c_ps_ddr_writer` | 9,195 | **保留＋改資料域** | 升級 staging 與 overlay 共用，**不可當 VCU 專用刪** |
| `u_dma_top/u_axil_reg_space`、`u_debug_mailbox`、`u_qpcie_perfmon` | 5,577 / 369 / 461 | 保留＋新身分暫存器 | 控制/升級共用 |
| `u_dma_top/u_nv12_capture_engine`（+ch1/ch2） | 7,873（另加 ch 實例） | **移除**，改 **packed RGB24 2PPC C2H engine + byte gearbox** | 新主契約為 4K60 **RGB888**（非 NV12、亦非 RGBA） |
| `u_dualpath`（含 `u_reader` 2,603、`u_regs` 632、`u_packet_*` 1,228、`u_tx_cdc` 796） | 5,442 | **移除（必刪，初期）** | VCU 碼流專用 PS-DDR→PCIe packet 出口（檔頭自述 No codec） |
| BAR0 `QPCIE_BAR0_VCU_CFG_OFFSET 0x2100`、`QPCIE_BAR0_VCU_RING_OFFSET 0x2200` + driver `ch1_*`/VCU ring 路徑 | — | **移除（VCU 專用 PCIe 路徑）** | ⚠ 地址保留為**空洞**、不回收：mailbox 視窗（BAR0+0x2000，H2C@0x2800）與其相对關係不可改，避免舊工具偏移失效（`include/qpcie_debug.h:43-46`） |
| PS 端 `sc7f0-vcud.service` / OMX / V4L2 `V4L2_PIX_FMT_H264` video1 出口、`cma,vcu@0x54000000` 672 MB pool | — | **移除／釋放**（新 persona） | 舊 profile 照原樣保留 |
| VCU **硬 macro** 本體 | 0（不計 CLB LUT；routed 顯示 hard macro 1/1） | **移除** | 但 **`u_zu4ev_ps_bd`（A 基準 3,759 LUT）是 PS BD wrapper，共享、不可整筆當 VCU 刪**；真正可省僅其 VCU glue、HP2/HP3 埠與 `xbar_vcu_enc`/`smc_vcu_*` 互連（`create_zu4ev_ps_bd.tcl:1098-1293`），**實際數值待新 persona synth** [T] |
| `u_ps_capture/u_csc`（VPSS）、`u_ps_capture/u_writer`（frmbuf_wr） | 6,153 / 3,403 | **獨立候選**（非使用者已要求必刪） | 條件：新 persona 不需要 PS 端 NV12 旁路且 RX→host 為 packed RGB24 直出（不经 PS DDR）時才裁；裁時仍需保留共用 GPIO reader reset / CSR |
| `u_ps_capture/u_regs`（frame-tap CSR）、`u_ps_capture/u_tap` | 1,006 / 958 | **必須保留** | CSR `reset_n[2:0]`（`sc7f0-frame-tap.c:373 ngpio = 3`）是官方 frmbuf reader `reset-gpios` 的來源 |
| `u_display_pipeline`（`u_frmbuf_rd` 3,805、256→128 1,103、CDC 149） | 5,118 | **保留＋改 2PPC**，並**新增第二 reader**（§5） | 需求 7 |
| `u_hdmi_tx_ss`、`u_hdmi_tx_mux` | 8,537 / 70 | 保留（mux 改 48-bit 2PPC） | 官方 TX，**不重寫 driver** |
| **新增** 第二 framebuffer reader（官方 `v_frmbuf_rd`）+ 讀取仲裁 + CDC | 待測 | 新增 | §5.2 |
| **新增** 自研 alpha compositor（RGB 域） | **待本板 synth**；參考值 449 LUT / 16 DSP **含 YCbCr 10-bit CSC**，**不可**當本 RGB8 核心已測成本 [R]；理論 3 分量×2 = 6 DSP/beat-pair 屬 **[E]** | 新增 | §5.3 |
| **新增** RGB24 **byte gearbox**（2PPC = 6 B/beat → PCIe 16/32 B beat）＋ packed RGB24 C2H engine | 待測 | 新增 | ⚠ 6 B 對 16/32 B **非整數比**：必須正確處理 `TKEEP`/`TLAST`/pitch 與 4K line **11,520 B**（可整除 32）邊界；**不得丟像素、不得補 A 偷換格式** |

紅線：**不父子 hier 雙重計數**；**不跨階段相減**（A/B 同為 synth 連結後才可比）；新 persona 的資源數字**只能**由後續 synth 產生，本計畫不承諾任何「省多少」或「整顆縮一半」。已知事實：26111208 routed LUT 98.21%、BRAM 89.45% ⇒ 新 persona 必須先刪再排。

---

## 5. 架構

### 5.1 主案（**兩個獨立讀取通道**，v1 單 reader 分兩路不成立，已修正）

```
 [PCIe 125 MHz / 128-bit（現况）或 256-bit（推薦，§8）]   [PS 100 MHz AXI-Lite: 控制/ownership/fence/modeset]
   C2H RGB888 1.492992 GB/s   <-- 新 data-plane ABI（不被燒錄平面依賴）      daemon 不做 CPU blend
        ^
 HDMI RX 4K60 RGB8 (IP 297 MHz) -> [packed RGB24 2PPC + byte gearbox] -> [C2H DMA] --> host DDR (RGB888 app)
   注：不補 A=255、不輸出 RGBA；stride 11,520 B、frame 24,883,200 B。RGBX32 僅為額外選項
                                                                                      |
                                                                        H2C RGBA8888 1.990656 GB/s v
                                                              [PS DDR overlay staging, 2~3 buf]
                                                                       |
                                     [Reader-B: 官方 v_frmbuf_rd #2, RGBA8888 2PPC, 自有 DMA/CSR/IRQ/reset]
                                                                       | overlay AXIS 64b
 [PS base FB (RGBA8888/RGBX, 32-bit)] -> [Reader-A: 官方 v_frmbuf_rd #1, 官方 DRM xlnx,pl-disp 擁有]
                                                                       | base AXIS 64b
                                                                       v
                             [自研 alpha compositor @300 MHz，串流中間 block]
                                                                       | RGB 2PPC 48b（逐 pixel 去 alpha）
                                                                       v  async FIFO（300 ↔ 297）
                                 [v_hdmi_tx_ss + vid_phy]  <- 官方 DRM 圖：pl-disp(CRTC/plane) -> hdmi-tx
```

要點：**官方 DRM 只擁有並驅動 Reader-A 與 TX**；自研 blend 是 **AXIS 串流上的透明中間 block**（插在 base AXIS 與 `VIDEO_IN` 之間），**不是** `drm_bridge`、不需要也不存在對應 bridge driver，也**不做私有 TX MMIO**。Reader-B 走官方 DMA engine（`xlnx,axi-frmbuf-rd-v2.2` 綁定的 `xilinx_frmbuf.c`）或「僅做 enable/地址/中斷清除的必要薄控制層」，由新 persona 的 app/daemon 負責 buffer ownership 與 frame ID。DRM 圖形與控制路徑因此**不依賴任何不存在的 driver**。

### 5.2 Reader-A / Reader-B 必需資源（列新增，不假估省）

| 項目 | Reader-A（base） | Reader-B（overlay） |
|---|---|---|
| IP | 官方 `v_frmbuf_rd` 2.5，2PPC、`HAS_RGBA8`（**無 `HAS_ARGB8`**，`create_sc7f0_frmbuf_rd_ip.tcl:16-18`） | **第二顆官方 `v_frmbuf_rd`**（同規格） |
| DMA 記憶體埠 | HP1（`dp_mem_clk = capture_clk`） | **HP2**（VCU 移除後釋出，`create_zu4ev_ps_bd.tcl:1229`）— 埠時鐘域與 outstanding **待核** [T] |
| AXI-Lite 控制視窗 | `0xB0080000`（`axi_crossbar_hdmi` M07） | **新 slice/新視窗**（現行僅 8 slices M00–M07 ⇒ 需重建 crossbar）[S] |
| IRQ | `pl_ps_irq_disp[1]` → SPI 96 [S] | **新 IRQ 來源 + DT 節點** |
| 真 reset | frame-tap CSR bit2（`reset-gpios = <&sc7f0_frame_tap 2 GPIO_ACTIVE_LOW>`） | **新增 bit3**（CSR `reset_n[3:0]` + write-mask + `sc7f0-frame-tap.c ngpio 3→4`）；DTG 只在 `ap_rst_n` 直連 GPIO 時才自動產 `reset-gpios`（**這是 DTG 自動追蹤的限制，不是禁止必需的 reset_sync**）；硬體必須保留**真 GPIO → 正確 reset 同步鏈 → `ap_rst_n`**，若 DTG 穿不過 `module_ref` 就**照現行 Reader-A 在 user DT 明確綁真實 `reset-gpios` 並核對連線**，**不得**為了 auto-DTG 跳過同步或放 dummy GPIO [R] |
| buffer ownership | DRM framebuffer / CRTC | app/daemon（frame ID + 雙/參重緩衝） |
| 讀取仲裁 | 共用/新增 AXI read arbiter（現行 `u_hp1_display_read_arbiter` 僅 1 reader） | 第二通道 + 仲裁 + CDC async FIFO |

新增資源/頻寬**必須**在 synth/route 後實測填寫；本計畫不預填數字。
備選（僅一個）：**單一多平面等價 IP（官方 `v_mix`/v_composer 雙 DMA 平面）** — 本倉目前 0 筆 `v_mix` [S]，需新 IP + 自有 reset GPIO + 重估資源 + 確認 `xlnx,pl-disp` 雙平面綁定方式 [T]。**禁止**由同一個 reader 通道同時分出 base 與 overlay。

### 5.3 alpha 公式（8-bit straight alpha，端點精確）

```
d   = FG - BG ;  p = A * d ;  out = BG + ((257*p + 32767) >>> 16)     // 257 = 2^8+1, 255*257 = 65535 ⇒ 精確 /255
```
`A=0` ⇒ 逐位 BG；`A=255` ⇒ 逐位 FG；`FG==BG` ⇒ 不變；無需 clamp。直覺式 `(A*FG+(255-A)*BG+128)>>8` 混用 1/255 權重與 /256 位移，參考專案窮盡量測顯示 **93.3% 與理想 /255 不同（最大 4 LSB）、透明/不透明端點各 916,480 筆失敗** [R] ⇒ **不得盲 `>>8`**。合成器兩層（PS base RGBA/RGBX ＋ host overlay RGBA）皆在 RGB 域混合 ⇒ **不做 CSC**；`A=0/128/255` 端點測試屬**overlay/base 合成**驗證，**與 RX 路徑無關**（RX→host 為 RGB888，本就無 alpha）。參考的 straight alpha 前提相同，premultiplied/linear-light 非本版目標。

### 5.4 長期流量匹配與「underflow」正確敘述（v1 修正）

- **async FIFO 不能吸收長期 1% 時鐘差**。長期匹配由 **AXIS `TREADY` 背壓 + SOF 對齊的 reader 節流（per-frame enable/restart，沿用 `sc7f0_display_pipeline.v` 已記的 per-frame 節流要求）+ 每幀一次整份交換**保證；async FIFO 只吸收相位抖動與短突發。
- **TX 物理時序不停止**（HDMI link 必須連續輸出）；**DDR reader 允許被背壓**（frmbuf_rd 可停/可等，TX 端不跟著停）。
- 「**這一刻沒有新 overlay frame**」⇒ 重複讀取**上一個完整 overlay buffer**（合法、常見）。
- 「**DDR reader 真的 underflow / 頻寬不足**」⇒ **這是錯誤，不是可靠機制**：需 prefill（開機與換檔前先填滿 staging）、頻寬/QoS 規劃、**錯誤計數器**（frmbuf_rd overflow irq、`STAT_*` 計數、`VIDEO_ERRORS`）與**安全輸出**（保持上一完整畫面或全透明）來「發現並處理」，**不得**宣稱靠保持舊 buffer 就能掩蓋 DDR 欠載。

**本版非目標**：整幀 only；不做小 ROI 更新（不得以 ROI 掩蓋頻寬不足）、多層、色域/gamma/HDR、premultiplied alpha、CPU blend。

---

## 6. 時鐘（三主域 + 必要 IO/GT 時鐘）

| 域 | 頻率 | 本機證據 | 承載 |
|---|---|---|---|
| **D1 外部 300 MHz** | 3.333 ns | `constraints/zu4ev_pcie_pinout.xdc:98-105`：`pl_clk_300m_p/n = AD17/AE17` LVDS、`create_clock -period 3.333 -name pl_clk_300m`、`capture_clk_300m` generated；`rtl/zu4ev_pcie_card_top.v:73-74,157-173,266-269`（IBUFDS+BUFG+`BUFGCE_DIV 1`→`capture_clk`）[S]；A-clocks `pl_clk_300m/capture_clk_300m = 3.333` [M] | 自研 data/alpha、AXI-MM（HP1/HP2）、frmbuf_rd、（若保留）VPSS |
| **D2 PS 100 MHz** | `pl_clk0` | `zu4ev_pcie_card_top.v:91-95`、`axi_crossbar_hdmi aclk(pl_clk0)` | **AXI-Lite 控制/CSR/mailbox/MCU 控制面**；（新 persona 不再放 H2C 資料域，見 §8.2） |
| **D3 PCIe user clock** | **125 MHz**（`pcie_user_clk period_ns=8.000`）[M] | IP `pcie4_uscale_plus_0`、Gen3 x4、`axisten_if_width {256_bit}`（`build_zu4ev.tcl:182-186`） | DMA/TLP、C2H/H2C 請求與資料 |

**必要之外時鐘**（不得由「三域」敘事吞掉）：HDMI `hdmi_rx_clk_p`/`hdmi_tx_clk_p` = 3.367 ns（297 MHz GT refclk）、`phy_txoutclk`（現 4PPC = 148.5 MHz）、RX recovered clock、`hdmi_dru_clk_p`、PCIe GT CPLL/TXOUTCLK 等 [M/A-clocks]。
**4K60 算術**：pixel rate 594 Mpixel/s ⇒ **2PPC 需 297 MHz video clock**（現 4PPC 為 148.5 MHz）。300 ≠ 297，兩域間以 async FIFO + 背壓連接（參考專案亦為 300 fabric ↔ 297 link [R]）。
**跨域元件**：AXIS `xpm_fifo_async`／`axis_clock_converter`；AXI `axi_clock_converter`；請求/應答 `video_req_cdc.v`、`sc7f0_packet_cdc.v`；狀態計數 `xpm_cdc_gray/single/handshake`；reset 一律 `sc7f0_reset_sync`（每來源一次跨域、域內合并）。

**「三主域」的講法定調**：本計畫指「**三個由我們管理的 fabric 主域 + 必要的 HDMI/GT 297 MHz 等 IO 時鐘**」，此點需使用者確認 [T]；**不暗中收緊**成「全晶片只有 3 個時鐘」——那與 4K60 標準 mode 不相容。
**外部 300 MHz 佐證缺口** [T]：本機有腳位、約束與 `si5341_request.md`（`OUT8 = 300 MHz LVDS`）；**無板上實測頻率證據**（DT 註解引述的 300.030 MHz 是 Vivado routed clock 模型值）。不得以 PS FCLK 300（參考專案即 `clk_pl_1`）冒充外部時鐘源。

---

## 7. 格式契約（RX = RGB888；base/overlay = RGBA8888；以 byte 順序為準，不靠名稱猜）

| 段 | 表示 | 位元/像素 |
|---|---|---|
| **RX → host（主契約）** | **packed RGB24**，byte 序 `R,G,B`；stride **11,520 B**、frame **24,883,200 B**；**不補 A**（HDMI 無 alpha） | **24 bit** |
| RX → host（可選） | RGBX32（byte `R,G,B,X`）**僅**當工具強制 32-bit 時作為**額外選項**；**不默默取代 RGB24 主案** | 32 bit（選） |
| 記憶體（**PS base / overlay staging**） | **R,G,B,A 四位元組**（word `[31:0]=A:B:G:R`；IP 自附標頭 `v_frmbuf_rd.h`「memory formats `RGBA8 13 // [31:0] A:B:G:R`」[R]，本板需覆核 [T]） | **32 bit（此雨平面不得以 24-bit 降要求；24-bit 僅限 RX→host）** |
| 官方 IP 間 AXI4-Stream（base/overlay） | 每像素 `A,R,B,G`（alpha 在 MSB；UG934 Table 1-4/1-5 [R]） | 32 ⇒ 2PPC = **64 bit** |
| RX 側 AXI4-Stream（2PPC） | RGB 三分量 × 8 bit × 2 pixel | **48 bit**（6 B/beat） |
| HDMI 線 | RGB8bpc，**線層不帶 alpha** | 48 bit @2PPC |

- **RX 走 RGB24 直出**：不經 PS DDR、不進合成器；因此 PS DDR 三流預算（§8.2）**不包含** RX。
- **RGB24 → PCIe beat 需 byte gearbox**：2PPC 6 B 對 16/32 B beat **非整數比**，必須以 `TKEEP`/`TLAST`/pitch 正確打包；4K line **11,520 B 可整除 32**；**不得丟像素、不得補 A 偷換格式**。
- **去 alpha 發生在 blend 輸出、逐 pixel 64→48**（各分量運算後丢 A），**不是**砍掉高 16 bit。
- 本地「名稱 ≠ 格式」實例 [S]：`HAS_BGR8 → "rgb888" → DRM RGB888`、`HAS_RGB8 → "bgr888" → BGR888`（`create_sc7f0_frmbuf_rd_ip.tcl:26-28`、`sc7f0-hdmi-tx.dtsi:255-262`）⇒ 一律走「IP 參數 → DTG 字串 → DRM fourcc → 記憶體 byte 序列」四步實測核對；**FourCC 字串待核 [T]**，不發明/不宣稱標準 FourCC（例如不把 `"RGBA"` 當已定義值）。
- IP 能力 [S]：v_frmbuf_rd 2.5 **有 `HAS_RGBA8`、無 `HAS_ARGB8`**；`HAS_RGBA8` 使 `NUM_VIDEO_COMPONENTS=4` ⇒ 4PPC 需 128-bit AXIS（現行撐不住 96-bit `VIDEO_IN`），**2PPC 正好 64-bit**。
- 官方 AXIMM 規則 `PPC×32×2` ⇒ **2PPC → native FB128**（4PPC 強制 FB128 曾重現 overflow [M]）；2PPC 是否可省 256→128 converter **必須**重新合成/上板驗證才算 [T]。

---

## 8. 頻寬與內存（**全部十進位 GB/s = 10⁹ B/s**；如需 GiB/s 另列，不混用）

### 8.1 基本算式（v1/v2 算錯者已修正；v3 新增 RX RGB24 主契約行）

| 項目 | 正確容量 | 備註 |
|---|---|---|
| **RX 一幀 RGB24（主契約）** | 3840×2160×3 = **24,883,200 B**（stride 11,520 B/line） | 60 fps ⇒ **1.492992 GB/s**（C2H 方向） |
| 一幀 RGBA8888（overlay / base） | 3840×2160×4 = **33,177,600 B** | 60 fps ⇒ **1.990656 GB/s**（H2C 方向） |
| PCIe Gen3 x4 | ≈ **3.94 GB/s 每方向（全雙工）** | C2H/H2C 各走自己方向；**不是**共用 3.98 半雙工 |
| 48-bit × 300 MHz（**RX RGB24 2PPC fabric**） | **1.8 GB/s** | > 1.492992 ⇒ 約 17% 餘裕（未含 blanking/背壓）[E] |
| 64-bit × 300 MHz（base/overlay RGBA 2PPC） | **2.4 GB/s** | v1 誤寫 128×300=2.4 |
| 128-bit × 300 MHz | **4.8 GB/s** | v1 誤寫 3.75 |
| 128-bit × 100 MHz | **1.6 GB/s** | v1 誤寫 1.25；**即舊 HP0（H2C writer）容量**，< 1.990656 ⇒ 不夠 |
| 256-bit × 100 MHz | **3.2 GB/s** | v1 誤寫 2.5 |
| **128-bit × 125 MHz（現行 C2H/H2C 內部）** | **2.0 GB/s** | ⚠ **v2 誤寫 1.6**。對 C2H RGB24：1.492992 / 2.0 = **74.6496%** ⇒ **保留 128-bit 為待實測可行選項**；對 H2C RGBA overlay：1.990656 / 2.0 = **99.5328%** ⇒ **無餘裕**（TLP header/空拍/背壓） |
| 256-bit × 125 MHz | **4.0 GB/s** | **推薦統一採用**（與 IP 原生 `axisten_if_width {256_bit}` 一致），**但理由不是舊 RGBA C2H throughput 門檻**，而是 H2C overlay 需 >1.990656 且希望 C2H/H2C 共用一條高效資料路徑；既有 `[Synth 8-689] 'c2h_req_data' 128 vs 256` 為現況佐證 [M] |
| 256-bit × 300 MHz | **9.6 GB/s** | |
| PS DDR4-2400 / 64-bit | 理論 peak **19.2 GB/s**（`PSU__DDRC__SPEED_BIN DDR4_2400T`、`BUS_WIDTH {64 Bit}`）[S] | **peak ≠ 可持續**；且 `SPEED_BIN` 只是**器件標稱能力**，**不證明目前 DDRC 實際以 2400 MT/s 運行** [T]：須先核實 DDR 實際工作時鐘/配置算出**實際峰值**，再以板上 stream benchmark + HP 埠 outstanding/仲裁量**可持續**值 |

以上皆為**理論容量、不含協定/空白/仲裁開銷**。

### 8.2 PS DDR 三流與寫入通道

- **RX 不走 PS DDR**（packed RGB24 直出到 host），因此不計入 PS DDR 流。PS DDR 只有合成器三流：base read 1.990656 + overlay write 1.990656 + overlay read 1.990656 = **5.971968 GB/s**；若 PS base 每幀由 CPU 更新再 +1.990656 ⇒ **7.962624 GB/s**（禁止整幀 CPU memcpy）。此數字**不因 C2H 改 RGB24 而變**。
- **真正需高效資料路徑的是 H2C overlay**（不是 C2H）：現行 128-bit@125 MHz 對 1.990656 只剩 0.467% 餘裕，且舊 H2C→PS DDR writer 跑 `pl_clk0` 128-bit@100 MHz = **1.6 GB/s < 1.990656**，**不足**。
- **推薦（非一串未定案選項）**：overlay 資料域走 **300 MHz fabric**（writer 由 `pl_clk0` 搬至 `capture_clk`，128-bit ⇒ 4.8 GB/s）**且** PCIe 端統一 **native 256-bit@125 MHz**（4.0 GB/s）；保留同一 AXI 位址/突發/位元組使能語意與**共用 programming ABI 無損**（升級 staging 行為不可變）。
- **C2H 保留 128-bit@125 MHz 為待實測可行選項**（1.492992 / 2.0 = 74.6496%，理論可容）；是否統一升到 256 由 P1 實測後定案，**舊「C2H 一定要 256」結論已撤銷**。
- Reader-A/Reader-B 分屬不同 HP 埠（HP1 / HP2）+ 仲裁；overlay writer 用另一埠，避免三流擠同一埠。

### 8.3 內存配置（不照抄舊 `cma=1000M`）

卡上驗證基線 [S]：低 bank `0x0–0x7ff00000`；`dau_fpga@0x30000000` 256 MB（no-map，**升級 staging**，`test_app/qpcie_upgrade_daemon.c:86 DEFAULT_DDR4_DMA_PHYS=0x30000000`）；`cma,video@0x40000000` 256 MB；`cma,qdmabuf@0x50000000` 64 MB；`cma,vcu@0x54000000` 672 MB；`sc7f0-memory-layout.dtsi` **刻意不含全域 cma**（曾被 import 加回 `cma=1000M` 導致無法進 userspace）。

- 兩平面 2–3 buffer：2×2 = **132.7 MB**、2×3 = **199.1 MB**，另加 `xlnx,dma-align`（DT 實值）與 stride 對齊餘量。
- 新 persona 用**具名 reserved region**（回收 `cma,vcu` 的大部分）承載 base + overlay，`memory-region` 指向該 pool；**嚴禁第二個全域 CMA**；overlay/base **一律不得落在 0x30000000–0x3FFFFFFF**。
- 修改 `check_sc7f0_memory_layout.py` 基準屬 PS 端變更，列入 P1 交付 [T]。

### 8.4 頻寬驗收點

量測計數源：既有 `REG_PERF_*`（0xA0..0xDC：payload bytes、TX active/idle、`TREADY_STALL`、128B/256B TLP 數、峰值 FIFO 深度、idle-empty）＋ frmbuf_rd overflow irq ＋ `VIDEO_ERRORS`；項目為 **C2H RGB24 單流（≥1.492992 GB/s）**、**H2C RGBA overlay 單流（≥1.990656 GB/s）**、三流合跑、全雙工同時性（兩方向計數器同時非零）；另驗 **RGB24 gearbox 正確性**（逐 line 11,520 B 對齊、TKEEP/TLAST 無丟失位元組、與 host 端逐幀 hash 一致）。**基本通過 = 連續 300 s 無錯誤計數**（§9）。

---

## 9. 里程碑（VCU 必刪放在新 persona 初期）

| 期 | 內容 | 交付 | 驗收（未達不進下一期） |
|---|---|---|---|
| **P0** 身分 + 相容性證明 | 新增 `rgb-compositor` build target（舊 profile 不動）；`PERSONALITY_ID`/`APP_FEATURE_CAPS`/`APP_DATA_ABI`；release.json/image 標記；**立即** `SC7F0_ENABLE_VCU=0`、移除 VCU 硬 macro/vcud/OMX/`u_dualpath`/BAR0 VCU CFG+RING 出口 | 新 persona 全套 artefact（bit/XSA/PS 四件） | （皆為**待驗**目標）① 現有 `scripts/sc7f0_flash.sh`：舊→新燒錄成功；新→舊（回燒舊 tar）亦成功（**燒錄平面不讀新 ACK**）② eMMC 獨立 SHA + boot-id 變更 + 恰好一次 MCU runtime reset ③ 舊 driver probe 正常、`0x1001_011F` 舊位不變 |
| **P1** 資料面 ABI + **RGB888 C2H** | packed **RGB24** 2PPC C2H engine + **byte gearbox**（6 B/beat → 16/32 B，TKEEP/TLAST/pitch）；ABI ACK + descriptor length/位址範圍檢查；128-bit@125 實測判定是否統一升 256；PS memory pool 重劃 | RTL + testbench + synth 報表（同階段 A/B） | 仿真逐位一致（含 line 11,520 B 邊界）；**route WNS ≥ 0**；C2H 連續 **300 s** 平均 ≥ **1.492992 GB/s** 且 0 錯誤計數、逐幀 hash 與 host 一致；未 ACK 時 DMA 確保不啟動 |
| **P2** overlay H2C + Reader-B | writer 移 300 MHz 資料域；第二顆 `v_frmbuf_rd`（HP2、新 CSR/IRQ/reset bit3、ngpio→4）+ 仲裁 + CDC；staging pool 隔離 | 同上 | 逐幀 hash 回讀一致；與升級 staging 互不踩；新/舊 driver 仍可燒（ABI 隔離復歸） |
| **P3** 官方 DRM 固定 pattern | base Reader-A 2PPC RGBA + `xlnx,pl-disp` + 官方 HDMI TX；frame pacing | DT + PS 鏡像 | DRM modeset 成功、reader irq 正常、**人眼實屏**（新 feature 必須人看） |
| **P4** FPGA alpha | 串流中間 blend block（RGB 域、EXACT 公式、輸出 48-bit）+ golden 模型 + `A=0/128/255` 端點 + 隨機 | RTL + 窮盡數值程式（仿 `numeric_check.c` 方法學）+ 仿真報告 | 端點逐位精確、與 golden ≤1 LSB、仿真 0 error、**route WNS ≥ 0**；三流合跑 **300 s** 無 overflow/撕裂 |
| **P5（獨立候選）** PS capture 支路裁切 | 僅在評估條件成立時裁 `u_ps_capture/u_csc`、`u_writer`；保留 frame-tap bit0/1/2/3 與 CSR | diff + 同階段 synth A/B | 升級/MCU/overlay/DRM 復歸全過；**不刪 H2C writer、不刪 frame-tap CSR** |
| **P6** 出貨包 | matching bit/XSA/PS 四件 tar（`upgrade-<datever>.tar`）＋ release.json（含 personality）＋ 驗收報告 | `./scripts/sc7f0_flash.sh --build <BUILD_DIR>` 全綠 | 完整 `sc7f0_flash.sh` 流程通過；**不允許單檔補板**、不新增 tar 成員 |

時序紀律：仿真先行 → synth 資源 → route **WNS ≥ 0**（**使用者唯一時序閘**；r3 的 WNS 0.000 **即達標**）。其他 warning（`[Synth 8-689]` 寬度 4 筆、`DRC PDCN-1569`、`lutar1` async-reset 結構審查項等）**記錄並比對新增數量**，**不引入額外 strict `>0` 閘**。297 MHz video clock 收斂與否**不得**由全域 +0.033 外推，須 route 後**按 clock group** 分別量測 [T]。
長時測：**10 min / 24 h soak 僅為後續可選建議**，非本版門檻。

---

## 10. 風險與待決

| # | 項目 | 類別 | 說明 |
|---|---|---|---|
| 1 | routed 98.21% LUT / 89.45% BRAM（26111208） | 已測 | 新 persona 必刪（VCU + packet DMA）後才談排佈；實際可省僅後續 synth 可知，**不承諾百分比** |
| 2 | 內部 128-bit@125 MHz = **2.0 GB/s**（v2 誤寫 1.6）：C2H RGB24 佔 **74.6496%**（保留 128 為**待實測可行選項**）；H2C RGBA overlay 佔 **99.5328%**（無餘裕）且舊 HP0 writer 128@100 = **1.6 GB/s < 1.990656** | 估算（源自實讀參數） | 旧「C2H 一定要 256」結論**已撤銷**；**必須**解決的是 H2C，而且這是**串聯的兩個瓶頸**：需**同時**解除舊 HP0 寫入路徑（128@100 = 1.6 GB/s）**與** PCIe H2C 內部（128@125 = 2.0 GB/s、估 99.5328%）兩個限制——主案採 **writer 改 300 MHz 資料域 ＋ H2C native 256@125 兩者併用**（可改用其他**等效且已驗**設計，但**只改一端不構成保證**，與 §8.2 一致）；C2H 保留 128@125 是**另一個待驗選項**，與此無關；改寬後 `u_h2c_ps_ddr_writer`（9,195 LUT/大 FF）資源重估，且不得破壞共用 programming ABI |
| 3 | 第二 reader 的控制面擴充 | 待建 | 新 crossbar slice/視窗、新 IRQ、frame-tap bit3（`ngpio 3→4`）、DT `reset-gpios`；DTG 自動追 reset 來源的規則（穿不過 `module_ref`）為已知陷阱——屬 **DTG 限制而非禁止 reset_sync**，必要時照 Reader-A 在 user DT 明確綁真實 GPIO [R] |
| 4 | 官方 HDMI TX 在無 retimer 板上 `devm_clk_get("retimer-clk")` 回 `-ENOENT`（binding 明載 optional） | **待使用者批准** | 一行 `devm_clk_get_optional()` 官方 bug patch 仍是 P3 前置；**本計畫未批准、未撰寫**；不得以 dummy clock 掩蓋 |
| 5 | 三主域敘事（+ 必要 HDMI/GT 297 IO 時鐘） | 待確認 | 需使用者認可；不收緊為「全片只有 3 個時鐘」 |
| 6 | 外部 300 MHz 板上實測缺口 | 待測 | 僅腳位/約束/Si5341 需求文件；無板上頻率實測證據 |
| 7 | 2PPC ⇒ IP 端 297 MHz video clock | 待建 | 現 4PPC 為 148.5 MHz；需 route 後按 clock group 量測，**不預測失敗也不預測收斂** |
| 8 | 格式位元組序與 FourCC（RX RGB24 與 base/overlay RGBA） | 待核 | 四步核對表填實值；`HAS_ARGB8` 不存在；不發明 FourCC 字串；**不得用 RGBX32 默默取代 RGB24 主契約** |
| 13 | **RGB24 byte gearbox 正確性**（2PPC 6 B/beat → 16/32 B PCIe beat） | 新增待建 | 非整數比；TKEEP/TLAST/pitch 與 line 11,520 B 邊界需仿真＋逐幀 hash 驗證；不得丟像素或補 A 偷換格式 |
| 14 | 新 persona 與現有工具/driver **雙向**燒錄相容 | **待驗（尚未測）** | 目前僅為**設計要求**；既有工具能往返燒 legacy 版本的事實（[M]）不能推論新 persona 已通過；P0 驗收①②③完成前不得標 PASS |
| 9 | HP2 作為 overlay reader 埠 | 待核 | VCU 移除後 HP2/HP3 釋出的位址/時鐘域/outstanding 需重設並實測 |
| 10 | 長期 1% 時鐘差 | 設計原則 | 由 `TREADY` 背壓 + SOF 節流 + 每幀整份交換保證；async FIFO 只吸收抖動。DDR 欠載是**錯誤**，需 prefill/QoS/錯誤計數/安全輸出 |
| 11 | MCU 燒錄 | 已測能力、需另行授權 | 現有 `scripts/sc7f0_mcu_flash.py`（0x2A/8192 B/CRC）可寫 APROM；真執行仍需明確授權＋備份＋救援風險；runtime restart／唯讀版本查詢**不算**更新驗收 |
| 12 | PS capture WR/CSC 裁切 | 獨立候選 | 條件清楚且非使用者必刪；保留共用 GPIO reader reset/CSR |

---

## 11. 引用（實際讀過者）

`scripts/sc7f0_flash.sh`、`scripts/check_sc7f0_upgrade_tar.py`、`scripts/check_sc7f0_release_package.py`、`scripts/package_sc7f0_vcu_release.sh`、`scripts/build_zu4ev.tcl`、`scripts/create_sc7f0_frmbuf_rd_ip.tcl`、`scripts/create_sc7f0_frmbuf_ip.tcl`、`scripts/create_zu4ev_ps_bd.tcl`、**`scripts/sc7f0_mcu_flash.py`**、`include/qpcie_debug.h`、`driver/{qpcie_driver.h,qpcie_main.c,qpcie_v4l2.c,qpcie_sysfs.c}`、`test_app/qpcie_upgrade_daemon.c`、`rtl/{zu4ev_pcie_card_top.v,custom_pcie_dma_top.v,h2c_ps_ddr_writer.v,sc7f0_display_pipeline.v,sc7f0_capture_pipeline.v,sc7f0_dualpath.v,sc7f0_ps_packet_reader.v,nv12_capture_engine.v,axil_reg_space.v,video_req_cdc.v,sc7f0_packet_cdc.v}`、`constraints/zu4ev_pcie_pinout.xdc`、`si5341_request.md`、`petalinux/.../files/{sc7f0-hdmi-tx.dtsi,common.dtsi,sc7f0-memory-layout.dtsi}`、`petalinux/.../linux-xlnx/sc7f0-frame-tap.c`、`build/hdmitx-display-26111208-r1/PL-HANDOFF.md`、`build/ppc-resource-ab-2611130455/reports/{README-resource-comparison.md,ppc_key_modules_table.md,ppc_ab_compare.csv,width_warnings_A_vs_B1.md,A-clocks.rpt}`、`build/wns-fix-20261112T044035Z/release-26111204-r3/{release.json,PROVENANCE-fpga.json}`、`build/vcu-release-26111204-r1/identity.json`、`docs/{sc7f0_system_architecture.md,sc7f0_hpd_fix_v1.1.15_20261021.md,sc7f0_takeover_20261021.md}`。
參考專案（僅 `[R]`）：`vivado/ip/sdi_alpha_blender/src/sdi_alpha_blender_blend.v`、`tool/numeric_check.c`、`README.md`、`vivado/rtl/sdi_axis_overlay_remap.v`、`docs/research/sdi_tx_and_frmbuf_investigation.md`。

---

## 12. 修正對照（v1→v2 重大修正；v3 RX 規格同步）

| # | 修正 | 位置 |
|---|---|---|
| 1 | **MCU**：刪除「本倉只有 runtime reset／NoEvidence」；改為 `scripts/sc7f0_mcu_flash.py` + PS I2C0 `0x2A` 真燒錄協定，並列來源與誠實界線 | §3.6 |
| 2 | **VCU**：由「fit 不下才刪／待批准」改為**新 persona 初期必刪**；共享 H2C writer/PCIe/CSR/MCU 明示不可刪；PS capture WR/CSC 降為獨立候選 | §4、P0/P5 |
| 3 | **架構**：主案改為**兩個獨立 framebuffer reader 通道**（各有 DMA/CSR/IRQ/reset/ownership）；blend 為透明串流 block，非 `drm_bridge`、無私有 TX MMIO；備選僅一個 | §5 |
| 4 | **頻寬算術**（十進位 GB/s）：128×300=**4.8**、128×100=**1.6**、256×100=**3.2**、64×300=**2.4**、256×300=**9.6**、256×125=**4.0**；三流 5.971968／含 base write 7.962624 | §8 |
| 5 | **資源表**：移除被誤當絕對值的 FF/BRAM/DSP 欄（實為 A→B1 的 Δ 欄），僅留已核 LUT＋角色＋完整報表連結；alpha 的 449 LUT/16 DSP 標明**含 YCbCr CSC**，理論 6 DSP 為 `[E]` | §4 |
| 6 | **ABI**：`0x800/0x1000` 是 mailbox **payload 偏移**，ABI 版本為 `QDBG_ABI=1`（`DB_ABI`）；控制 ABI 與新資料 ABI 分離；legacy `0x1001_011F` **無**新位，`APP_FEATURE_CAPS` 僅提案 | §3.2–3.3 |
| 7 | **時序閘**：刪除「嚴格 >0 未滿足」敘事；**使用者標準 WNS ≥ 0**（r3 0.000 達標）；不以全域 +0.033 預測 297 MHz 好壞 | §2、§9 |
| 8 | **FIFO/underflow**：刪除「async FIFO 吸收 1% 長期差」與「reader underflow 可靠舊 buffer 掩蓋」；改 `TREADY` 背壓＋SOF 節流＋prefill/錯誤計數 | §5.4 |
| 9 | **RGBA**：PS base 維持 32-bit RGBA/RGBX；去 alpha 在 blend 輸出逐 pixel 64→48；FourCC 待核、不發明字串 | §7 |
| 10 | **驗收**：基本穩定 **300 s**；10 min／24 h 降為後續可選，不成為新門檻 | §9 |
| 11 | **新增需求 11**：燒錄平面與現有未修改工具/driver **雙向**相容，且燒錄平面不依賴新 data-plane ACK | §3.1、§3.4、P0 |
| 12 | **v3：RX 主契約更正為 4K60 RGB888**（24 bit/pixel、byte `R,G,B`、stride 11,520 B、frame 24,883,200 B、C2H **1.492992 GB/s**）；移除 RX 專用 RGB→RGBA/A=255 段（alpha 公式與 `A=0/128/255` 端點測試保留，與 RX 無關）；host→FPGA overlay 仍 RGBA8888/1.990656 GB/s；PS base 仍 RGBA/RGBX32；兩獨立 reader 不變；PS DDR 三流數字不變（RX 不走 PS DDR） | §1、§5.1、§7、§8 |
| 13 | **v3：撤銷「C2H 一定要 256」舊結論**；更正 128×125=**2.0 GB/s**（C2H 估 74.6496%、H2C 估 99.5328%）；保留 128 為待實測選項，統一 256 為推薦但理由改為 H2C 與統一資料路徑 | §8.1、§8.2、§10-2 |
| 14 | **v3：名稱與 caps 同步**：`SC7F0-RGB-COMPOSITOR-2PPC`（短碼 `RGB-COMP-2PPC`）、`PERSONALITY_ID 0x52434737`、**`APP_CAP_RX_RGB888`** 取代 `APP_CAP_RX_RGBA`；檔名同步為 `docs/sc7f0_rgb_compositor_2ppc_plan.md` | 標題、§3.3 |
| 15 | **v3：[M]/[S] 語意澄清**：新 persona 條目一律視為設計要求/待驗收（包括雙向燒錄相容）；既有工具的 [M] 僅為 legacy 基線 | 首頁、§1、§9-P0、§10-14 |

---

**待使用者確認後才可動工**：① 名稱 `SC7F0-RGB-COMPOSITOR-2PPC`（短碼 `RGB-COMP-2PPC`）與 RX=RGB888 主契約 ② 三主域 + 必要 HDMI/GT 297 IO 時鐘的敘事 ③ 官方 HDMI TX `retimer-clk` patch 授權 ④ **H2C overlay 高效資料路徑**（writer 改 300 MHz 域與否、是否統一 native 256@125）與 C2H 是否保留 128@125（待 P1 實測） ⑤ 第二 reader 的 HP2/CSR/IRQ/reset-bit3 資源配置 ⑥ PS capture WR/CSC 是否列入本版候選 ⑦ 實屏人工目視為必要驗收。
**本檔為計畫，非功能實作完成。**
