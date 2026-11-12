# SC7F0 板端 HDMI RX→PS DDR→HDMI TX（loop-through）三層完成度盤點（2026-11-12，唯讀）

方法：只讀 `rtl/`、`scripts/`、`petalinux/qpcie-zu4ev/project-spec/`、`test_app/`、`docs/` 與現成 r3
產物。無 compile / Vivado / PetaLinux / SSH / 板上命令 / 燒錄 / 改源碼 / git 動作。
盤點對象 = 已部署 r3：`build/wns-fix-20261112T044035Z/release-26111204-r3/`
（`release/upgrade-26111204.tar` sha `45c5952506c7a9…` 實測相符、`fpga/hardware.xsa` sha
`e3eb2eb0cb17a0…` 相符、bit sha `11f45c28d0359f…`；FPGA 全程同 round 26111204，PL `0x26111204`）。

## 結論表

| 層 | 狀態 | 已具備（實據） | 尚缺（尚未存在／未證） |
|---|---|---|---|
| 1. Vivado / PL | **部分**：RX→PS DDR 已部署；PS DDR→TX **不在 bitstream** | 部署 netlist 實據 `build/vcu-release-26111204-r1/fpga/project/c2h-personality.rpt:23-31` = PRESENT `u_hdmi_rx_ss`(29274 cell)、`u_vid_phy_controller`(20279)、`u_ps_capture`(35022)、`u_nv12_capture_engine`、`u_dualpath`、`u_h2c_ps_ddr_writer`、VCU hard macro；同檔 `:1-3` = **ABSENT `u_hdmi_tx_ss` / `u_hdmi_tx_video_bridge` / `u_hdmi_tx_audio_bridge` = 0 cell**。TX 物理層在 TOP：`rtl/zu4ev_pcie_card_top.v:49-70`（GT bank226 pads、`hdmi_tx_tmds_*`、`hdmi_tx_hpd_in`、DDC）、`:859-917`（`u_vid_phy_controller` tx_tmds/phy_txp/tx_axi4s）。RX→PSDDR writer 於 DT：`petalinux/.../device-tree/files/sc7f0-ps-capture.dtsi:96-107` `framebuffer@b0050000` `xlnx,axi-frmbuf-wr-v2.2`（nv12, 4096x2160），graph `:15-31` hdmirx→frame_tap→vpss-csc→capture | 目前 build 入口**從未建立** TX/reader IP：`scripts/build_zu4ev.tcl:344-347` 只呼叫 `create_sc7f0_frmbuf_ip`(wr)＋`create_sc7f0_vpss_csc_ip`；`scripts/create_sc7f0_hdmi_tx_ip.tcl`、`scripts/create_sc7f0_frmbuf_rd_ip.tcl` 除自身外無人 source。TX SS 被 production define 關掉：`rtl/zu4ev_pcie_card_top.v:1201 \`ifndef SC7F0_C2H_ONLY`→`:1202 v_hdmi_tx_ss_0`、`:1304 \`else`→`:1311 u_disabled_hdmi_tx`＋`:1306-1308 phy_tx_axi4s_ch* = 0`；而 `scripts/build_zu4ev.tcl:110` production 一定加 `SC7F0_C2H_ONLY=1`，且 full-profile gate **反向要求** TX 細胞不存在（`scripts/check_sc7f0_full_profile.py:242-248`、`scripts/check_sc7f0_r7_profile.py:69-78,273`）。`rtl/sc7f0_display_pipeline.v`（PS DDR→`v_frmbuf_rd`→TX，含 0xB008_0000 CSR）與 `rtl/sc7f0_hdmi_tx_mux.v`（RX bypass／frmbuf／host H2C 三選一）僅被 `scripts/build_zu4ev.tcl:88 add_files [glob ./rtl/*.v]` 收進來，**全 rtl/ 無任何 instantiation**→不在 netlist。DT 無 `b0080000` aperture、無 `axi-frmbuf-rd`、無 hdmi-tx 節點（`images/system.dtb` strings：`b0080000`=0 hits）。alpha 路徑另有已知阻塞：`scripts/create_sc7f0_frmbuf_rd_ip.tcl:14-19,73`（v_frmbuf_rd 2.5 無 HAS_ARGB8；128-bit→96-bit packer 未做） |
| 2. PetaLinux DRM/KMS | **部分**：框架有、PL HDMI TX driver 關掉、DT 無 TX pipeline | r3 kernel config（`release-26111204-r3/ps/kernel.config`）：`CONFIG_DRM=y`、`CONFIG_DRM_XLNX=y`、`CONFIG_DRM_XLNX_PL_DISP=y`（frmbuf driver）、`CONFIG_DRM_XLNX_MIXER/BRIDGE/CSC/SCALER/VTC=y`、`CONFIG_DRM_ZYNQMP_DPSUB=y`（**PS DP**，非板端 HDMI TX）、`CONFIG_XILINX_VTC=y`、`CONFIG_VIDEO_XILINX_VPSS_CSC=y`、`CONFIG_VIDEO_SC7F0_FRAME_TAP=y`。DT 節點（`images/system.dtb`，與 XSA 同源，見 `gates/ps-image-match.json`）：`/amba_pl@0/hdmi-rx@b0010000`、`vpss-csc@b0060000`、`vcu@b0100000`、`framebuffer@b0050000`(frmbuf-**wr**)、`/axi/display@fd4a0000`(=DPSUB＋dp-snd) | **`# CONFIG_DRM_XLNX_HDMITX is not set`**（綁 `v_hdmi_tx_ss` 的 DRM bridge driver 未編）。DT 無 `xlnx,display-core` pipeline、無 frmbuf_rd→mixer→hdmitx→connector 的 port/endpoint、無 TX clock/reset/EDID-DDC/HPD 綁定。meta-user 无相關 recipe/patch（`project-spec/meta-user/recipes-bsp/device-tree/files/` 7 檔中無 TX）。上板是否有 `/dev/dri` 可用：**未證**（本轮無板上命令） |
| 3. 板端 daemon | **未做**（現成 daemon 均非 display pipeline） | 實際部署 rootfs（自 `images/image.ub` 內 initrd 解析，2547 entries）：enabled = `sc7f0-vcud`、`qpcie-hdmi-daemon`、`qpcie-upgrade-daemon`、`sc7f0-ps-watchdog`、`qpcie-debugd`；`usr/lib/sc7f0/sc7f0-capture-init.sh` 已裝。角色：`test_app/qpcie_hdmi_daemon.c:1-25` = **RX telemetry 寫 BAR0**（unit Description「HDMI RX telemetry publisher」）；`recipes-apps/sc7f0-vcud/files/sc7f0-vcud.service:17-31` = VIPP capture→VCU H.264→packet DMA 給 host | 整個 `test_app/` ＋ `meta-user/` **零** `libdrm` / `drmModeSetCrtc` / `drmModeAddFB` / `drmModePageFlip` / `/dev/dri`（grep 0 hits）；部署 rootfs **零** `libdrm*.so` / `modetest` / weston / wayland / gbm。故無 capture DMABUF→DRM 交接、無 atomic commit/pageflip、無 fence 同步、無 buffer return queue，也无 display unit |

## 最重要防混淆（不得當成 loop-through PASS）

- `video0` 桌面畫面 = PCIe→**host RAM**→host Wayland，**不是**板端 HDMI TX 輸出。
- `video1` 300 s 硬 H264／先前 5 min 硬體編碼 = 證明 **RX→PS DDR→VCU**
  （`docs/sc7f0_26111204_flash_gstreamer_acceptance_20261112.md:24-26`），**不證** PS DDR→TX。
- 標準 `upgrade.sh` 47.115 s 把 r3 燒成功 + eMMC/boot-ID SHA 實據，只證部署與開機，不證 TX。
- `docs/sc7f0_multiphase_hdmi_plan.md:75,130-150`「階段 4 HDMI TX 環出」/`M4.1 v_hdmi_tx_ss_0 整合`
  = **規劃完成**（proposal），不得引用為實作或上板實據。
- 直接 PL RX→TX bypass 不等於經 PS DDR；PS DP（DPSUB/HDMI-A 连接器）不等於板端 HDMI TX。

## 最小依賴順序（依上述證據，非先射箭）

1. **PL**：決定 production personality 是否放行 TX（`SC7F0_C2H_ONLY` gate 需反轉/新增 profile）→
   建立 `sc7f0_frmbuf_rd`＋`sc7f0_display_pipeline`＋`sc7f0_hdmi_tx_mux` 的 instantiation 與互連
   （PS HP read port、0xB008_0000 aperture、TX clock/reset、alpha 128→96 決策）→ 重建 XSA/bit。
2. **PS/DRM**：`CONFIG_DRM_XLNX_HDMITX=y` ＋ DT display pipeline graph（frmbuf_rd→mixer/bridge→
   hdmitx→connector、port/endpoint、clock/reset、DDC/HPD）；或明確改走「不用 DRM，daemon 直控
   frmbuf_rd＋TX SS 暫存器」路線（擇一，先定案再動 DT/recipe）。
3. **daemon**：新增/擴充一支 display daemon（capture buffer→TX framebuffer 擁有權與同步、
   commit/pageflip、fence、return queue）＋ systemd unit ＋ recipe/package 安裝。
4. **板端實測**：接真實螢幕驗 HPD/DDC/EDID、實見影像與時序/FPS 量測；验收不得以 host `video0`
   桌面或 MP4 代替。

## 備註

- 源碼 WIP（已在 git，HEAD `aea8612`）與已部署 bitstream 不同層：`rtl/sc7f0_hdmi_tx_mux.v`、
  `rtl/sc7f0_display_pipeline.v`、`scripts/create_sc7f0_hdmi_tx_ip.tcl`、
  `scripts/create_sc7f0_frmbuf_rd_ip.tcl`、`scripts/create_sc7f0_hdmi_crossbar.tcl`(M07 規劃)
  目前都**未進入** round 26111204 的物理設計。
- HWH 限制：`hardware.xsa` 內 `zu4ev_ps_bd.hwh` 只覆蓋 PS BD（VCU+PS），頂層直接 instance 的 IP
  不在其中；本盤點因此以 `c2h-personality.rpt` 細胞計數、TOP RTL 條件編譯、build 入口 IP 呼叫、
  DT 節點與 gate 指令碼交叉作證，而非僅靠 grep 源碼。
- 本輪未驗證項（如實記錄）：板端 `/dev/dri` 是否存在/可用、TX GT/PHY 目前是否已輸出黑畫面時序、
  螢幕端 HPD/DDC 行為。
