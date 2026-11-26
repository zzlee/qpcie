# SC7F0 4K60 HDMI Passthrough + H2C Overlay + V4L2 C2H 交接文件

- **日期**：2026-11-23
- **分支 / 最新提交**：`feat/zu4ev-sc7f0-bringup` (`7eee23f` + 本交接文件)
- **目前驗證基線版本**：`0x26112306`
- **釋出包路徑**：`/mnt/data-root/home/zzlee/sc7f0-vivado-builds/rgb-cb-26112306/release/upgrade-26112306.tar`
- **測試機**：`rd@192.168.190.247` (`sc7f0-test.local`)，所有測試機檔案位於 `/home/rd/sc7f0/`

---

## 1. 目前系統架構與已驗證功能

目前資料通路均採 **Zero PS DDR** 設計（不經過 ZU4EV PS DDR4 / HP2 / HP3）：

1. **HDMI RX -> Alpha Blend -> HDMI TX 直通（4K60）**
   - 板卡端由 `sc7f0-modetest.service` 透過 DRM (`modetest -M xlnx -s 38:3840x2160-60@AR24`) 維持 HDMI TX 輸出（**注意：須使用 `sleep infinity | modetest ...`，不可使用 `sleep 3600`，否則 1 小時後 TX 會關閉並反壓導致 Overlay 逾時**）。
   - `BAR0 0x4040` (`STATUS`) 穩定於 `0x00001e11`，`0x4054` (`WR_FRAMES_DONE`) 每秒 `+60`。
2. **H2C 4K60 RGBA8888 Overlay**
   - 通路：`Host RAM -> PCIe H2C Pull -> sc7f0_overlay_ingress -> URAM Prefetch FIFO -> sc7f0_alpha_blend_2ppc -> HDMI TX`。
   - 採用 **2-deep 硬體雙緩衝 (`P_RUN` + `pending_*`) + 4-slot 軟體佇列**，搭配 `ovl_wr_done`（Global IRQ Top Bit 8）與新增的 `ovl_vblank_irq`（Global IRQ Top Bit 9），完全不依賴 `hrtimer`。
   - 測試App [sc7f0_ovl_ball_demo.c](file:///home/zzlee/qpcie/test_app/sc7f0_ovl_ball_demo.c) 下方橫幅已移除舊版 `PS DDR` 字樣。
3. **C2H V4L2 Capture（已從 RGB24 改為 NV12/NV16，不保留 RGB24）**
   - `/dev/video0` 僅開放 **`NM12` (`V4L2_PIX_FMT_NV12M`)** 與 **`NM16` (`V4L2_PIX_FMT_NV16M`)**。
   - RTL 將 `u_rx_ppc_upsize`（2 PPC -> 4 PPC `rx_ss_video_up_*`）接至 `u_rx_pixel_pack` -> `video_rgb_to_yuv709` (`u_rx_csc`) -> `u_hdmi_rx_video_cdc_fifo` -> `nv12_capture_engine`，同時將未使用的 `s_video_tvalid[0]` 靜默為 `0`（避免 loopback FIFO overflow IRQ）。
   - `sc7f0_video_launch_arbiter.v` 已修正 `thin_launch_refused` 未受 `ENABLED` 遮罩導致 `NV12`/`NV16` 被誤擋的問題（改用 `!thin_launch_ok`）。

---

## 2. 本階段實測紀錄

| 測試項目 | 版本 | 測試條件 | 結果 |
| :--- | :--- | :--- | :--- |
| Vivado 實作時序 | `0x26112306` | `ExtraTimingOpt` / `AggressiveExplore` / `Explore` | **PASS**（`WNS = +0.018 ns`、`WHS = +0.010 ns`、`0 failing` / 400,448 endpoints） |
| 1 小時併行壓測 (RGB24 期) | `0x26112303` | HDMI 直通 + Overlay 60fps + V4L2 `RGB3` 60fps | **PASS**（Overlay `216,180 frames @ 60.00 fps` 零逾時；V4L2 `RGB3` 全程 `60.00 fps`） |
| 30 分鐘併行壓測 (`NM16`) | `0x26112306` | HDMI 直通 + Overlay 60fps + V4L2 `NM16` 60fps | **PASS**（V4L2 `NM16` `108,000 frames @ 60.00 fps`、`video_errors=0`；Overlay `107,220 frames` 正常結束，註見第 4 節） |

---

## 2.5 2026-11-24 更新：VCU 編碼器啟用與四路併發實測（交接重點）

- **測試版號**：`0x26112403`（已燒錄於 `rd@192.168.190.247`；目前工作目錄有未提交修改）
- **釋出包路徑**：`/mnt/data-root/home/zzlee/sc7f0-vivado-builds/rgb-vcu-26112403/release/upgrade-26112403.tar`
- **PetaLinux 隔離建置目錄**：`/mnt/data-root/home/zzlee/sc7f0-vivado-builds/rgb-vcu-26112401/ps-work/petalinux/qpcie-zu4ev`

### 本次已完成整合與修改（尚未 commit）
1. **RTL / BD 解除 `SC7F0_RGB_COMPOSITOR` 與 `SC7F0_ENABLE_VCU` 互斥**：
   - [scripts/create_zu4ev_ps_bd.tcl](file:///home/zzlee/qpcie/scripts/create_zu4ev_ps_bd.tcl)：因 H2C Overlay 已改用 PL URAM direct-pull（不再使用 `HP2`/`HP3`），將 `HP2`/`HP3` 歸還 VCU；將 `vcu_host_interrupt` 透過 `vcu_irq_cat` 接至 `pl_ps_irq0[5]`（SPI 94），保留 `pl_ps_irq1[3:0]`（SPI 104–107）；並在 `xbar_vcu_enc/M00_AXI` 與 `S_AXI_HP2_FPD` 之間加入 `reg_vcu_enc`（`axi_register_slice`）切開 300 MHz 路徑。
   - [scripts/build_zu4ev.tcl](file:///home/zzlee/qpcie/scripts/build_zu4ev.tcl)：傳遞 `SC7F0_ENABLE_VCU=1`；僅在 `rgb_enable && !vcu_enable` 時定義 `SC7F0_PS_FRMBUF_RGBX=1`；`rgb_enable` 搭配 VCU 時使用精簡 `xbar8`。
   - [rtl/zu4ev_pcie_card_top.v](file:///home/zzlee/qpcie/rtl/zu4ev_pcie_card_top.v)：`SC7F0_ENABLE_VCU` 時隱藏 `S_AXI_HP2_FPD` / `S_AXI_HP3_FPD` / `ovl_hp3_clk` 外部 idle tie-off。
   - [rtl/sc7f0_ps_frmbuf_writer.v](file:///home/zzlee/qpcie/rtl/sc7f0_ps_frmbuf_writer.v)：改以 `` `ifdef SC7F0_PS_FRMBUF_RGBX `` 切換，使 VCU 啟用時 `u_ps_capture` 切回支援 NV12 的 `sc7f0_frmbuf_wr`。
2. **PetaLinux / Device Tree**：
   - [petalinuxbsp.conf](file:///home/zzlee/qpcie/petalinux/qpcie-zu4ev/project-spec/meta-user/conf/petalinuxbsp.conf)、[device-tree.bbappend](file:///home/zzlee/qpcie/petalinux/qpcie-zu4ev/project-spec/meta-user/recipes-bsp/device-tree/device-tree.bbappend)、[system-user.dtsi](file:///home/zzlee/qpcie/petalinux/qpcie-zu4ev/project-spec/meta-user/recipes-bsp/device-tree/files/system-user.dtsi)：新增 `SC7F0_VCU_ENABLE = "1"` 並重新引入 `vcu.dtsi`。
   - [sc7f0-rgb-compositor.dtsi](file:///home/zzlee/qpcie/petalinux/qpcie-zu4ev/project-spec/meta-user/recipes-bsp/device-tree/files/sc7f0-rgb-compositor.dtsi)：移除未使用的 `sc7f0_overlay_pool`，調整 CMA 為 `cma,vcu@54000000`（544 MiB）+ `cma,display@76000000`（128 MiB）。
   - [sc7f0-ps-capture.dtsi](file:///home/zzlee/qpcie/petalinux/qpcie-zu4ev/project-spec/meta-user/recipes-bsp/device-tree/files/sc7f0-ps-capture.dtsi)：`SC7F0_VCU_ENABLE=1` 時切回 `nv12` 與 YCbCr 4:2:0 CSC 設定。
   - [petalinux-image-minimal.bbappend](file:///home/zzlee/qpcie/petalinux/qpcie-zu4ev/project-spec/meta-user/recipes-core/images/petalinux-image-minimal.bbappend)：`SC7F0_VCU_ENABLE=1` 時保留 `sc7f0-vcud` / `libvcu-xlnx` / `vcu-firmware`，並停用 `sc7f0-capture-init-rgb`。

### `0x26112403` 實測數據
- **Vivado 資源與時序（全數收斂）**：
  - `CLB LUTs`: `84,828 / 87,840 (96.57%)`、`Block RAM Tile`: `121.5 / 128 (94.92%)`、`URAM`: `8 / 48 (16.67%)`
  - `WNS = +0.055 ns`、`WHS = +0.010 ns`、`WPWS = 0.000 ns`（0 failing endpoints）
- **30 秒四路併發測試**（HDMI 直通 + H2C Overlay + `/dev/video0` `NM16` + `/dev/video1` GStreamer H.264 CBR 40Mbps MP4）：
  - **V4L2 `NM16` (`/dev/video0`)**：穩定 `60.00 fps`（1800 frames）。
  - **H2C Overlay**：前段 `30.00 fps`、後段穩定 `60.00 fps`（`frames=840..960`）。
  - **VCU H.264 MP4 (`/dev/video1` → `/home/rd/sc7f0/captures/test_vcu_40m_cbr.mp4`, 128 MiB)**：
    - 完成 1800 frames 錄影且 PCIe DMA `ERR=0`。
    - **瓶頸**：因目前 `ENC_BUFFER_EN = false`（`l2 prefetch size: 0`），VCU 編碼效能受限於 PS DDR4 頻寬，板卡 `sc7f0_vcud` 僅能維持 **`34–41 fps`（平均 ~37 fps）**，導致 1800 frames 耗時 `69.19 秒`（`ffprobe` 平均 `25.90 fps`、碼率 `15.5 Mbps`，且期間有 2 次掉幀造成解碼 MB error）。

### 下一位 Agent 的 P0 交接任務（VCU URAM L2 Buffer + 60fps 驗證）
1. **P0-1：開啟 VCU `URAM_ONLY` L2 Prefetch Buffer**：
   - 在 [scripts/create_zu4ev_ps_bd.tcl](file:///home/zzlee/qpcie/scripts/create_zu4ev_ps_bd.tcl#L1215) 將 `CONFIG.ENC_BUFFER_EN` 設為 `{true}`、明確指定 `CONFIG.ENC_BUFFER_TYPE {0}`（`URAM_ONLY`，不動到 94.9% 滿載的 BRAM），並確認所需 URAM 數 ≤ 剩餘 40 顆（若超過則用 `ENC_BUFFER_MANUAL_OVERRIDE` 或 `ENC_BUFFER_MOTION_VEC_RANGE` 限縮在 40 顆內）。
   - 重新建置 Vivado（匯出 XSA 時注意 `check_sc7f0_named_constraints.tcl` 會因既有 `u_overlay_writer`/`u_vid_phy_controller` 重命名而回報 FAIL，可確認 `timing_summary_routed.rpt` `WNS>=0` 後直接 `write_hw_platform`）、重編 PetaLinux、打包燒錄測試機。
2. **P0-2：重測四路併發 4K60 + GStreamer CBR 40Mbps MP4**：
   - 驗證 `sc7f0_vcud` 達到滿速 **60.0 fps**、`drops` 不再增加、MP4 `duration` 與 `nb_frames` 一致（`30s / 1800 frames @ 60 fps`）、實測碼率貼近 **40 Mbps CBR** 且 `ffprobe` 解碼零錯誤。
   - 若功能與 60fps 全部通過，記得整理 `petalinux` 自動生成檔案（勿將 `.petalinux/metadata` / `statistics` 等雜檔誤 commit）並 commit 乾淨程式碼。

---

## 3. 主要異動檔案清單

- **RTL**：
  - [rtl/sc7f0_ovl_pull_prefetch.v](file:///home/zzlee/qpcie/rtl/sc7f0_ovl_pull_prefetch.v)：新增 `ovl_vblank_irq_pulse`（`pending_irq_armed` 晉升至 `P_RUN` 時觸發）。
  - [rtl/interrupt_ctrl.v](file:///home/zzlee/qpcie/rtl/interrupt_ctrl.v)：新增 `SRC_OVL_VBL`（Global IRQ Top Bit 9 / `arb_code = 8'h09`）。
  - [rtl/custom_pcie_dma_top.v](file:///home/zzlee/qpcie/rtl/custom_pcie_dma_top.v)：串接 `ovl_vblank_irq_pulse`；將 C2H `RGB24` 引擎改由 `SC7F0_C2H_RGB24` 控管，`SC7F0_RGB_COMPOSITOR` 改用 `nv12_capture_engine`。
  - [rtl/zu4ev_pcie_card_top.v](file:///home/zzlee/qpcie/rtl/zu4ev_pcie_card_top.v)：`SC7F0_RGB_COMPOSITOR` 下改將 `rx_ss_video_up_*`（4 PPC）送入 `u_rx_pixel_pack` + `u_rx_csc`，並靜默 `s_video_tvalid[0]`。
  - [rtl/sc7f0_video_launch_arbiter.v](file:///home/zzlee/qpcie/rtl/sc7f0_video_launch_arbiter.v)：`thin_launch_refused` 改為 `!thin_prof_ok || !thin_launch_ok`，確保 `ARB_ENABLED=0` 時放行 `NV12`/`NV16`。
- **Host Kernel Driver & Test App**：
  - [driver/qpcie_overlay.c](file:///home/zzlee/qpcie/driver/qpcie_overlay.c)、[driver/qpcie_main.c](file:///home/zzlee/qpcie/driver/qpcie_main.c)、[driver/qpcie_driver.h](file:///home/zzlee/qpcie/driver/qpcie_driver.h)：支援 4-slot `sw_q` 非阻塞管線與 `qpcie_overlay_vblank_irq_handler()`（無 `hrtimer`）。
  - [driver/qpcie_v4l2.c](file:///home/zzlee/qpcie/driver/qpcie_v4l2.c)：移除 `V4L2_PIX_FMT_RGB24`，僅保留 `NV12M` / `NV16M`。
  - [test_app/sc7f0_ovl_ball_demo.c](file:///home/zzlee/qpcie/test_app/sc7f0_ovl_ball_demo.c)：移除額外 `nanosleep`、改用 2-deep `QOVL_IOC_WAIT`/`SUBMIT` 管線、更新無 `PS DDR` 橫幅。

---

## 4. 後續待辦工作（交接重點）

### P0：Host 端 Overlay 轉為標準 DRM Plane / V4L2 Output 裝置
- **目標**：將目前 `/dev/qpcie-ovl-*` 自訂 ioctl 改為標準 **DRM Atomic KMS Plane Driver**（或 V4L2 Output），以支援未來複雜 UI 以不穩定幀率（0–60 fps）透過 `drmModeAtomicCommit(DRM_MODE_ATOMIC_NONBLOCK | DRM_MODE_PAGE_FLIP_EVENT)` 更新。
- **實作建議**：
  1. **記憶體配置**：因硬體 `sc7f0_overlay_ingress.v` 目前吃單一連續 64-bit `host_src_addr`（無 SGL），建議先使用 `drm_gem_dma_helper`（CMA）；若需支援 GPU / PRIME `dma-buf` 零拷貝，於 Host 開啟 IOMMU 後可用 `dma_map_sgtable()` 映成單一連續 IOVA。
  2. **繪圖效能**：`dma_mmap_coherent` 在 x86 為 Write-Combining (WC)，複雜 UI 應在 Cached System RAM（或 GPU）渲染完成後再以 Dirty-Rect / `memcpy` 寫入 DMA buffer，避免對 WC 做 Read-Modify-Write。
  3. **Mailbox 覆寫語意**：非 60 fps UI 若連續送出多幀，建議在 DRM 層保留「active + 最新 pending」即可，避免深佇列造成操作延遲（input lag）。

### P1：補齊 RTL 真正 60 Hz VBlank 中斷與消除偶發 30 fps 掉相
- **觀察現象**：30 分鐘測試尾段（`23:09:07` `v4l2-ctl` 執行 `STREAMOFF` 時），Overlay 曾短暫從 `60.00 fps` 掉回 `30.00 fps` 相位（雖然仍無逾時且正常完成）。
- **原因**：目前 `ovl_vblank_irq_pulse` 僅在 `pending_irq_armed` 晉升時觸發，且穩態時 `hw_active_armed` 保持 `true`。一旦某幀 `QOVL_IOC_SUBMIT` 剛好在 `P_IDLE` 自動重播後 10 µs 才抵達，硬體進入未 arm 的重播幀，而驅動仍以為 `hw_active_armed=true` 而無法自動補齊相位。
- **建議改法**：
  1. 將 `ovl_vblank_irq_pulse` 改為由 `QOVL_REG_CTRL[2]`（`vblank_irq_en`）控制，於每個 `base_vblank_p` 發出標準 60 Hz VBlank 中斷（直接對接 `drm_crtc_handle_vblank()`）。
  2. 或在驅動中斷／提交時比對 `WR_FRAMES_DONE` 是否跳號，若跳過一幀則自動重設 `hw_active_armed = false` 以重新對齊。

### P2：清理建置腳本與補驗 `NM12` 畫面內容
1. **更新約束與單元測試腳本**：
   - [scripts/check_sc7f0_named_constraints.tcl](file:///home/zzlee/qpcie/scripts/check_sc7f0_named_constraints.tcl) 仍檢查已移除的 `overlay_arm_sync_max_delay`（已於 `e83a428` 改為 BRAM async FIFO），導致 `build_zu4ev.tcl` 尾段報錯中斷（雖然 `.bit` 已產生且時序過關）。建議同步更新該檢查腳本。
   - 修正 `scripts/tests/` 內 3 項既有環境失敗（`test_backup_retention_tb` / `test_commit_integration_tb` `/tmp/opencode` 與 `test_sc7f0_timing_state.py`）。
2. **`NM12`（NV12M）與 `NM16` 實拍畫面內容檢查**：
   - 本次已驗證 `NM16` 4K60 連續 30 分鐘吞吐與零 protocol error；建議接手後再各抓 1 幀 `NM12` 與 `NM16` 實際 `.yuv` 檔以 `ffplay` / YUV 工具確認色彩矩陣（BT.709 `video_rgb_to_yuv709`）與 `R/G/B` 通道順序無誤。

---

## 5. 常用指令速查（測試機 `rd@192.168.190.247`）

```bash
# 1. 板卡端啟動 HDMI TX 直通（於 Host 執行）
sudo /home/rd/sc7f0/bin/sc7f0ctl exec 'systemd-run --unit=sc7f0-modetest /bin/sh -c "sleep infinity | modetest -M xlnx -s 38:3840x2160-60@AR24"'

# 2. Host 端啟動 60 FPS Overlay Demo
sudo /home/rd/sc7f0/bin/sc7f0_ovl_ball_demo --msi --seconds 1800

# 3. Host 端啟動 V4L2 4K60 NV16 (NM16) / NV12 (NM12) 採集
v4l2-ctl -d /dev/video0 --set-fmt-video=width=3840,height=2160,pixelformat=NM16 --stream-mmap=4 --stream-count=108000 --stream-to=/dev/null

# 4. Host 端啟動 VCU H.264 40Mbps CBR 錄製成 MP4（30 秒範例）
v4l2-ctl -d /dev/video1 -c video_bitrate_mode=1,video_bitrate=40000000
gst-launch-1.0 -e v4l2src device=/dev/video1 num-buffers=1800 do-timestamp=true ! "video/x-h264,width=3840,height=2160,framerate=60/1" ! h264parse ! mp4mux ! filesink location=/home/rd/sc7f0/captures/test_vcu_40m_cbr.mp4
```
