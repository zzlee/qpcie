# SC7F0 PL Phase-1: PS DDR → HDMI TX 顯示人格 (官方 DRM/KMS 契約對齊)

日期 2026-11-12。範圍僅 PL（Vivado 2023.2）：新增 opt-in 顯示人格、跑到收斂布局布線、
交付 bit/XSA 與 PS 階段所需綁定契約。**本輪不做** PetaLinux、不 SSH、不燒錄、不建 Git 提交。

## 1. 目的與邊界

在**不動已部署 C2H 捕捉 / VCU / PCIe 基線**的前提下，新增一條 PS DDR → HDMI 輸出路徑，
且该路徑必須由 AMD/Xilinx **官方 DRM/KMS 驅動**驅動（`hdmi-modules` xlnx_rel_v2023.2，
commit `82209b00`）：不寫自有 TX 核心驅動、不用裸 MMIO daemon。

```
PS DDR framebuffer --S_AXI_HP1_FPD--> sc7f0_frmbuf_rd (v_frmbuf_rd 2.5, AXIMM 256-bit)
   -> sc7f0_display_width (256->128) -> video CDC/FIFO
   -> sc7f0_hdmi_tx_mux (mux_sel=2'b01, DRAIN_UNSELECTED=0)
   -> u_hdmi_tx_ss VIDEO_IN (v_hdmi_tx_ss 3.2, AXIS, 4PPC/8bpc)
   -> LINK_DATA0..2_OUT -> u_vid_phy_controller -> HDMI 連接器 (TMDS/FRL)
CSR: axi_crossbar_hdmi M07 -> 0xB0080000 (display frmbuf_rd) ; M02 -> 0xB0020000 (TX SS)
```

單源模式：只有 framebuffer reader 餵 VIDEO_IN。監視器顯示的內容 = PS 寫進 DDR 的內容，
不摻 RX bypass、不摻 PCIe H2C 路徑，無 alpha/mixer。

## 2. 官方驅動契約（本輪鎖定的 IP 設定 ↔ DT compatible ↔ 驅動）

| PL IP | 版本/關鍵參數 | device tree `compatible` | 官方驅動 |
|---|---|---|---|
| `v_hdmi_tx_ss_0` | 3.2；`C_INPUT_PIXELS_PER_CLOCK=4`、`C_MAX_BITS_PER_COMPONENT=8`、`C_VID_INTERFACE=0`(AXIS)、`C_INCLUDE_HDCP_1_4/2_2=false`、`C_INCLUDE_YUV420_SUP=true`、`C_HDMI_FAST_SWITCH=true` | `xlnx,v-hdmi-tx-ss-3.1` | 外掛官方模組 `xilinx-hdmi-tx.ko`（`hdmi-modules` SRCREV `82209b00`，`hdmi/xilinx_drm_hdmi.c`）。**更正（PS 階段核對）**：本輪原寫 `drivers/gpu/drm/xlnx/xlnx_drm_hdmi.c` 是錯的檔案名；in-tree 的 `drivers/gpu/drm/xlnx/xlnx_hdmi.c` 在 6.1.30-xilinx-v2023.2 只匹配 HDMI 2.1 的 `xlnx,v-hdmi-txss1-1.1/1.2`，綁不上本 IP。 |
| `vid_phy_controller_0` | 2.2，RX/TX 共用同一 GT quad | `xlnx,vid-phy-controller-2.2` | `drivers/phy/xilinx/phy-vphy.c` |
| CRTC/plane | 核心內建（非 PL IP） | `xlnx,pl-disp` | `drivers/gpu/drm/xlnx/xlnx_drm_disp.c` |
| `sc7f0_frmbuf_rd` | `v_frmbuf_rd` 2.5；AXIMM 256-bit、`SAMPLES_PER_CLOCK=4`、`MAX_COLS=4096`、`MAX_ROWS=2160`、`HAS_RGB8=1`、`HAS_BGR8=1`、`HAS_Y_UV8_420=1`、**無 `HAS_ARGB8`** | `xlnx,axi-frmbuf-rd-v2.2` | `drivers/dma/xilinx/xilinx_frmbuf.c` |

格式對應（IP property → DT 字串 → DRM fourcc）：

| IP 開關 | DT/DMA 名稱 | DRM 格式 | 備註 |
|---|---|---|---|
| `HAS_BGR8=1` | `rgb888` | `DRM_FORMAT_RGB888`（fourcc `"RG24"`） | 名稱取自 2023.2 `device-tree-xlnx framebuf_rd.tcl` + `xilinx_frmbuf.c:426` |
| `HAS_RGB8=1` | `bgr888` | `DRM_FORMAT_BGR888`（fourcc `"BG23"`） | 同上，`xilinx_frmbuf.c:396`；兩種都開，CRTC 用 `xlnx,vformat` 只選一個 |
| `HAS_Y_UV8_420=1` | `nv12` | `DRM_FORMAT_NV12` | 預留 capture→TX；與 TX SS 的 HDMI YUV420 **輸出**能力是兩件事，不互推 |
| alpha 關閉 | — | — | 2.5 版開 alpha 會強制 128-bit AXIS，與 96-bit `VIDEO_IN` 不相容；本輪不支援 alpha |

## 3. 啟用開關與建置命令

- `SC7F0_DISPLAY_TX=1`（需要 `SC7F0_PROFILE=full`）：加入 TX SS + display frmbuf_rd +
  mux + 第二個 HP1 read arbiter + `pl_ps_irq_disp[1:0]`。**未設定時所有既有发布位元組不變。**
- `SC7F0_SYNTH_DIRECTIVE=<directive>`（選填，預設空＝Vivado default）：只改 **top-level
  `synth_1`** 的合成 directive；所有 `*_synth_1` OOC IP run 維持各自預設。實際值由
  `scripts/impl_sc7f0_dual_video.tcl` 對 Vivado 自己的合法清單驗證、set 後 readback，
  並從生成的 run script 取證寫入 `synth-directive.json`（不是只有 echo）。

```bash
SC7F0_DISPLAY_TX=1 SC7F0_ENABLE_VCU=1 SC7F0_TIMING_GATE=record \
SC7F0_SYNTH_DIRECTIVE=AreaOptimized_high \
SC7F0_PLACE_DIRECTIVE=Explore SC7F0_PHYS_OPT_DIRECTIVE=AggressiveExplore \
SC7F0_ROUTE_DIRECTIVE=Explore SC7F0_POST_ROUTE_PHYS_OPT=AggressiveExplore \
bash scripts/build_sc7f0_dual_video_hw.sh build/<fresh-out>
```

## 4. PS 階段所需：位址 / 中斷 / 時鐘契約

| 項目 | 值 | 來源/備註 |
|---|---|---|
| HDMI TX SS CSR | `0xB0020000`, size `0x20000` | crossbar M02；TX@+0x0、VTC@+0x10000（`xlnx,vtc` 子節點） |
| display frmbuf_rd CSR | `0xB0080000`, size `0x10000` | crossbar M07，`hdmi_ctl_*` 向量已從 7 位寬拓到 8 |
| TX SS 中斷 | `pl_ps_irq0[1]` → GIC SPI **95** | `xlconcat` 於 BD 內；既有 SPI 90-94 不動 |
| display frmbuf_rd 中斷 | `pl_ps_irq0[0]` → GIC SPI **96**（實作上以 `pl_ps_irq_disp[1:0]` 進 cat） | 同上 |
| `s_axi_cpu_aclk` | `pl_clk0` 100 MHz | CSR 時鐘 |
| `link_clk` | VPHY `phy_txoutclk` | TX SS link 時鐘 |
| `video_clk` / `s_axis_video_aclk` | VPHY `phy_tx_video_clk`（4 PPC → 3840p60 為 148.5 MHz） | 與 reader 同域，經 CDC |
| `txref-clk` | DT 需一個名為 `txref-clk` 的 fixed-clock，**297 MHz** | 驅動 `clk_get_name(dev,"txref-clk")` + `clk_set_rate(tmds_clk, TxLineRate)`；ZU4EV 上 GT 時鐘由 VPHY 管理，此處為契約用佔位 fixed-clock，RX 側既有 `sc7f0_rx_video_clk` 同型做法 |
| PHY lanes | DT 需 `hdmi-phy0/1/2` 三 lane 子節點 | `phy-vphy` 以子節點順序綁定 |

模式表：TX 必須與 RX 基線相同 — 3840×2160p60，RGB8bpc，像素當時鐘 533.25 MHz（TMDS 148.5 MHz/PPC×…依 4PPC），porch 與 sync 極性照 RX 已鎖定的格式；不允许用較低解析度假過成功。

## 5. 資源盤點（本輪 routed 權威數據，`fpga/reports/utilization_routed*.rpt`）

器件 `xczu4ev-fbvb900-2-e`。Top 總量：

| 資源 | 使用 | 可用 | 佔比 |
|---|---|---|---|
| CLB LUTs | 86,404 | 87,840 | **98.37%** |
| ├ LUT as Logic | 75,206 | 87,840 | 85.62% |
| └ LUT as Memory（LUTRAM 9,440 + SRL 1,758） | 11,198 | 57,600 | 19.44% |
| CLB Registers | 135,042 | 175,680 | 76.87% |
| Block RAM Tile（RAMB36E2 113 + RAMB18 3） | 114.5 | 128 | 89.45% |
| URAM | 0 | 48 | 0% |
| DSPs | 88 | 728 | 12.09% |
| Bonded IOB | 15 | 204 | 7.35% |

逐模組（routed hierarchical；`Total = Logic + LUTRAM + SRL`；父列**已含**縮排子列，不可相加）：

| 實例 | 角色 | Total LUT | Logic | LUTRAM | SRL | FF | B36 | B18 | URAM | DSP |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `zu4ev_pcie_card_top` | TOP | 86,404 | 75,206 | 9,440 | 1,758 | 135,042 | 113 | 3 | 0 | 88 |
| `u_hdmi_rx_ss` | HDMI RX SS | 12,977 | 11,904 | 882 | 191 | 11,158 | 8 | 0 | 0 | 0 |
| `u_ps_capture` | 捕捉管線（frmbuf_wr） | 11,135 | 9,797 | 576 | 762 | 15,218 | 21 | 1 | 0 | 49 |
| `u_nv12_capture_engine` | NV12 捕捉（硬 macro 外膠水） | 7,835 | 2,875 | 4,960 | 0 | 1,592 | 1 | 0 | 0 | 0 |
| `u_h2c_ps_ddr_writer` | PCIe H2C→PS DDR | 9,162 | 9,162 | 0 | 0 | 32,991 | 0 | 0 | 0 | 0 |
| `u_vid_phy_controller` | VPHY（共用 GT，硬 macro 外） | 7,320 | 7,320 | 0 | 0 | 9,487 | 0 | 0 | 0 | 3 |
| `u_dualpath` | 雙_video 路徑 | 5,178 | 4,450 | 728 | 0 | 11,034 | 4 | 0 | 0 | 0 |
| `u_pcie_ip` | PCIe 硬 IP | 1,861 | 1,850 | 0 | 11 | 4,873 | 22 | 0 | 0 | 0 |
| `u_zu4ev_ps_bd` | PS BD（PS + VCU 膠水） | 3,353 | 3,204 | 0 | 149 | 4,056 | 0 | 0 | 0 | 0 |
| &nbsp;&nbsp;└ `xbar_vcu_enc` | VCU 合併 crossbar | 1,403 | 1,399 | 0 | 4 | 1,372 | 0 | 0 | 0 | 0 |
| &nbsp;&nbsp;└ `ic_hpm1` | VCU HPM1 interconnect | 1,105 | 1,034 | 0 | 71 | 1,472 | 0 | 0 | 0 | 0 |
| &nbsp;&nbsp;└ `dwc_vcu_mcu` | VCU MCU | 705 | 633 | 0 | 72 | 979 | 0 | 0 | 0 | 0 |
| &nbsp;&nbsp;└ `vcu_0` | VCU 硬 macro 接腳膠水 | 109 | 109 | 0 | 0 | 167 | 0 | 0 | 0 | 0 |
| **`u_hdmi_tx_ss`** | **新增：HDMI TX SS** | 7,797 | 6,675 | 852 | 270 | 10,931 | 4 | 0 | 0 | 1 |
| **`u_display_pipeline`** | **新增：顯示管線（父）** | 4,277 | 4,022 | 20 | 235 | 6,346 | 15 | 0 | 0 | 1 |
| &nbsp;&nbsp;└ `u_frmbuf_rd` | v_frmbuf_rd reader | 3,690 | 3,455 | 0 | 235 | 5,350 | 12 | 0 | 0 | 1 |
| &nbsp;&nbsp;└ `u_memory_width` | 256→128 寬度轉換 | 431 | 411 | 20 | 0 | 527 | 0 | 0 | 0 | 0 |
| **`u_hdmi_tx_mux`** | **新增：影格锁定 mux** | 67 | 67 | 0 | 0 | 45 | 0 | 0 | 0 | 0 |
| **`u_hp1_display_read_arbiter`** | **新增：顯示 HP1 read arbiter** | 8 | 8 | 0 | 0 | 64 | 0 | 0 | 0 | 0 |
| `u_hdmi_control` | HDMI CSR crossbar | 296 | 296 | 0 | 0 | 135 | 0 | 0 | 0 | 0 |

新增顯示人格合計 ≈ **12,149 LUT（13.8% 器件）**。

### 報告口徑必讀（避免錯誤剩餘容量）
- `synth_1/*_utilization_synth.rpt` 的 39,806（本輪）/ 41,377（上輪）是**頂層合成 run 的
  黑盒視角**（OOC IP 尚未併入），**不是整顆器件用量**，不可與後者相減。
- `utilization_synth_hierarchical.rpt` 是 link 後、opt_design 前的網表視角：
  預設合成 95,017 → `AreaOptimized_high` 93,446 Total LUT（差 1,571 logic LUT）。
- DRC `UTLZ-1` 用的是 opt 後映射需求數：上一輪 88,802 需求 vs 87,840 可用 → 放不下。
- **是否放得下，只看 routed/utilization 報告**：本輪 86,404/87,840 = 98.37%，通過。

## 6. 建置與收斂歷程（三輪，身分皆獨立）

| 輪 | 身分 | 結果 | 實際退出原因 |
|---|---|---|---|
| `build/hdmitx-display-26111205-r1` | `0x26111205` / `0x4F31754F` | synth 100%、無 bit/timing | 我在 `impl_sc7f0_dual_video.tcl` 的 personality checker 寫了錯的階層實例名（`u_display_width`，實為 `u_memory_width`）→ audit `error`。**純報表碼 typo，非硬體缺件**（同份報告已列 TX SS 23,470 cells 等 PRESENT） |
| `build/hdmitx-display-26111206-r1` | `0x26111206` / `0x91D9C44F` | synth 100%、DRC 擋下、無布局/路由 | `ERROR: [DRC UTLZ-1]` Slice LUTs 88,802 需求 > 87,840 可用（差 962，1.1%）→ `Placer not run`。**真資源容量問題** |
| `build/hdmitx-display-26111207-r1` | `0x26111207` / `0xE7DF5324` | 路由收斂 + matched bit/XSA | 通過。`SC7F0_SYNTH_DIRECTIVE=AreaOptimized_high`（只 top-level），IP/功能/約束完全未減 |

三輪共用同一 RTL 功能集（C2H 捕捉 + VCU + 顯示 TX 並存），未刪任何已驗功能、未關選配、未換器件、
未用 `drc.disableLUTOverUtilError`、未新增 false path。

## 7. 交付物與證據

```
build/hdmitx-display-26111207-r1/fpga/zu4ev_pcie_card_top.bit
  SHA256 0d767d3f783ad883a9d9266e5a596c3dd649ec4c9af631dc5475c9634255af7c   (7,797,815 B)
build/hdmitx-display-26111207-r1/fpga/hardware.xsa
  SHA256 a25cca027eb803997c5bc0a444d390226e48064a689a2bb6c5cf944d3be84241   (4,387,114 B)
build/hdmitx-display-26111207-r1/fpga/HARDWARE.sha256 / export-proof.txt
```
- 交付 bit 與 XSA 內 `hardware.bit` **同 SHA256**（byte-identical）。
- 同 session 的 `write_bitstream` 檔（保留為 `.bit.session-223556`）與交付 bit 只差 2 bytes、
  impl_1 run 自身 bit 只差 4 bytes，全部落在 bit header 的建造時間欄
  （`2026/11/12 22:35:56` vs `22:36:50` vs `21:35:46`）；設計名、器件、版本、長度皆同。
- XSA 內含 `v_hdmi_tx_ss_0.hwh`(187,945 B)、`v_hdmi_rx_ss_0.hwh`、`zu4ev_ps_bd.hwh`、
  `sc7f0_vpss_csc.hwh`、`psu_init.{c,h,tcl}`、`xsa.xml`。
- 身分：`C_VERSION=0x26111207`、GIT 暫存器 `0xE7DF5324`（dirty-content-fingerprint）、
  `SC7F0_BUILD_DATE=20261112`、HEAD `c78c495e`（dirty）、source fingerprint
  `e7df5324396efe2ee440e726dcdb87e3cdb9f3195aa9180321a3f15b0de74409`；
  `SC7F0_IDENTITY_VERIFIED C_VERSION=0x26111207` 已在合成 run log 綁定驗證。

### 時序（權威：`fpga/reports/timing_summary.rpt` 與 `impl_1/*_timing_summary_routed.rpt`）
```
WNS +0.031 ns | TNS 0.000 | failing setup endpoints 0 / 418,846
WHS +0.010 ns | THS 0.000 | failing hold  endpoints 0 / 416,801
WPWS 0.000    | "All user specified timing constraints are met."
post-route phys_opt_design: "No setup violation found. The netlist was not modified."
```
兩層 strict gate 仍 `pass_gate=false`，原因為既有 CDC/DRC/methodology warning 計數
（CDC-15 4,754、CDC-3 460、CDC-26 416、DPIR-2 192、DPIP-2 75 等），非本輪新設門檻、非時序違反；
本輪以 `SC7F0_TIMING_GATE=record` 記錄於 `fpga/reports/timing-gate-record.json`。

### routed 连通實證（`-logs/export-proof-abs4.log`）
- `SC7F0_C2H_PERSONALITY_ROUTE_PASS`：RX SS / capture / dualpath / NV12 engine / VCU 硬 macro
  全 PRESENT；legacy PCIe H2C TX video/audio bridge 與 TPG ABSENT。
- `SC7F0_DISPLAY_PROOF_PASS`，net 級證據：
  - `phy_tx_axi4s_ch{0,1,2}_tdata` 同一 net 上同時有 `u_hdmi_tx_ss` 40 pins 與
    `u_vid_phy_controller` 120 pins ⇒ 三條 TX lane 確實接到 VPHY。
  - `dp_araddr`（49 pins）同時含 `u_hp1_display_read_arbiter` 49 pins 與 `u_zu4ev_ps_bd`
    49 pins；`dp_arvalid` 1+1 ⇒ 顯示 reader 經 HP1 真的接到 PS DDR 讀取路徑。
  - `tx_ss_video_tdata` 96 pins 落在 `u_hdmi_tx_ss` ⇒ reader→mux→`VIDEO_IN`（4px×24bit）對上。

### 本輪程序偏差（如實記錄）
sanctioned 入口 `scripts/impl_sc7f0_dual_video.tcl` 在 route 成功、bit 步驟已過之後，死於本輪
新增的 routed display-proof 碼使用了 Vivado 不存在的命令 `get_object_name`（純報告碼 bug）。
事後修該命令會使 `scripts/` 偏離本輪已錄 `SOURCE_BUILD.sha256`，入口會（正確地）以
`INPUT_HASH_BUILD_MISMATCH` 拒絕重新貼標；**不改寫已錄 SHA**。因此交付由一次性唯讀後置
session `build/hdmitx-display-26111207-r1/export-and-proof.tcl` 從本輪 `routed.dcp` 完成：
僅 `open_checkpoint` + report + `write_bitstream`/`write_hw_platform`，未重 synth/place/route、
未碰 RTL/IP/constraint、未造 `identity.json` 或 `fpga.ok`。

該 `get_object_name` 誤用目前**仍在** `scripts/impl_sc7f0_dual_video.tcl`（3 處），會在每一輪布線
完成後、`write_hw_platform` 之前 abort。修復必須與「分配新 version/fingerprint」同一步做，
不可在已交付的樹上靜態偷修。本輪结束时身分仍穩定：

```
$ python3 scripts/sc7f0_release_id.py --check-fingerprint \
      build/official-drm-contract/identity-26111207.json
SOURCE_IDENTITY_STABLE scope=all files=519 e7df5324… head c78c495e dirty True   (RC=0)
```

即 PS 階段可直接以 `0x26111207` 打包本 bit/XSA，條件是那 519 個被雜湊的來源維持不動。

## 8. 尚未驗證（不得宣稱）

1. **實屏輸出**未驗（本階段不 SSH/不燒錄）。
2. **VPHY 同 GT quad 同時跑 RX+TX** 未驗：`device-tree-xlnx` 2023.2 產生 6 個 lane 子節點
   （rx0-2/tx0-2），`xvphy_xlate` 純依子節點順序綁定（`XVPHY_MAX_LANES=6`）；2023.2 的
   `XVphy` 是否支援 quad 226 雙向併用，只能在 PS 階段實機證明。若失敗，屬官方驅動限制，
   不得改走私有 MMIO。
3. **PS 端 DRM 綁定**未驗：現行 kernel 有 `CONFIG_DRM_XLNX_PL_DISP=y`、`CONFIG_XILINX_FRMBUF=y`，
   但 `CONFIG_DRM_XLNX_HDMITX is not set`。
   **更正（PS 階段核對）**：該 symbol **不該**開。它在 6.1.30-xilinx-v2023.2 對應 in-tree
   `xlnx_hdmi.c`（只匹配 HDMI 2.1 `xlnx,v-hdmi-txss1-1.x`）；本板需要的 HDMI 2.0 TX
   驅動是 `kernel-module-hdmi` 編出的 `xilinx-hdmi-tx.ko`（rootfs 已含），與該 symbol 無關。
4. TX DDC/HPD 的 async 命名例外（`async_pad_hdmi_tx_ddc_scl/sda`、`async_pad_hdmi_tx_hpd_in`）
   僅部分被既有命名約束涵蓋：檢查器回報 TX SS 內 DDC 同步器與 HPD 同步器第一級暫存器
   無對應命名例外（本輪依指示不擴 gate/policy，留待 PS/約束階段處理）。
5. 4K60 長期穩定性、reader 在 HP1 上的頻寬競爭（與捕捉共用 HP1）未做實測。

## 9. 資源進一步優化建議（僅建議，未獲准不執行）

| 項目 | 可選做法 | 代價 |
|---|---|---|
| `u_hdmi_tx_ss` 7,797 | 關 `C_HDMI_FAST_SWITCH`（TMDS/FRL 快速切換）或降 YUV420 輸出支援 | 減少模式切換能力/420 輸出，需重新評估官方 DT 屬性 |
| `u_display_pipeline/u_frmbuf_rd` 3,690 | 降 `SAMPLES_PER_CLOCK` 4→2 | 4K60 需 264 MHz video clock，與 VPHY 4PPC 契約衝突 ⇒ 實際不可行 |
| `u_nv12_capture_engine` LUTRAM 4,960 | 改 BRAM 行緩衝 | BRAM 已 89.45%，空間不足 |
| `u_hdmi_rx_ss` 12,977 | 若產品只要輸出不要輸入，可移除 RX SS | 犧牲已部署捕捉功能（需產品決策） |
| 整體 | 换 `xczu5ev/xczu6ev` 同封裝或雙 bitstream/部分重建 | 跨階段產品決策 |

## 10. 下一階段（PS）待辦清單

1. ~~開 `CONFIG_DRM_XLNX_HDMITX=y`~~ **已作廢**：保留既有 `DRM_XLNX`/`PL_DISP`/`XILINX_FRMBUF`，
   並確認 `kernel-module-hdmi`（`xilinx-hdmi-tx.ko` + `xilinx-vphy.ko`）入 rootfs；
   `CONFIG_DRM_XLNX_HDMITX` 明確保持 not set（理由見 §2/§8）。
2. 依 §4 寫 `sc7f0-hdmi-tx.dtsi`：`xlnx,v-hdmi-tx-ss-3.1` 節點（reg `0xB0020000/0x20000`，
   interrupts SPI 95）、`xlnx,vtc` 子節點 `0xB0020000+0x10000`、`xlnx,pl-disp` +
   `xlnx,axi-frmbuf-rd-v2.2`（reg `0xB0080000/0x10000`，interrupts SPI 96）、
   `xlnx,vid-phy-controller-2.2` 六 lane 子節點、`txref-clk` 297 MHz fixed-clock、
   graph：`pl_disp`→`v_hdmi_tx`，`hdmi_conn`→HDMI 連接器。
3. 模式/格式：以 3840×2160p60 RGB888 為預設，驗證 DRM mode 與 RX 锁定格式同參數；
   之後再驗 NV12 路徑。
4. 以官方 DRM/KMS（modetest / kmscube）驗實屏，不用裸 MMIO。
