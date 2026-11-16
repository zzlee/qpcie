# SC7F0 Defect 3（C2H 0 payload）根因定位：SGL `almost_full` 極性接反（2026-11-16）

執行者：本輪唯一地端代理（未 spawn 子代理）。**未** `git commit` / `git push`；**未**啟動
Vivado 建置；**未** `rmmod` / `rescan` / `reboot`；**未**改任何 RTL／driver／DTSI／腳本。
卡端唯一「寫入」是 26111204 §12.2 授權的兩次 `media-ctl -V`（vpss-csc pad 尺寸）與一次
VIPP `S_FMT`；host 端只有有界 `v4l2-ctl` 擷取嘗試。

Evidence 根目錄：`build/defect3-rootcause-20261116T052146Z/logs/`（`01`–`19`）。
測試機產物：`/home/rd/sc7f0/tmp/defect3-probe.sh`、
`/home/rd/sc7f0/captures/20261116T053158Z-defect3-live/`（均在規範允許目錄）。

## 0. 結論（一句話）

**`rtl/sc7f0_rgb24_c2h_engine.v:178` 把 `sg_segment_walker` 的 active-high
`fifo_almost_full` 直接接到名為 `sgl_pop_ready` 的「可接收」輸出上（少一個 `!`）**，
使 `rtl/custom_pcie_dma_top.v:2642` 的 `sgl_wr_en` 與同檔 `:2566` 的 SGL 來源 FIFO
`rd_en` 永遠為 0 ⇒ SGL 區段永遠進不到 walker ⇒ `seg_valid=0` ⇒ `pl_seg_ready=0`
⇒ `burst_start` 永不成立 ⇒ 引擎一個 C2H MWr 都不發、`S_ARM` 下 `p_axis_tready` 恆 0
⇒ packer 跨時鐘 FIFO 從不排空 ⇒ **Payload = 0 bytes / frames = 0 / drops = 0**，
且 thin ring 因來源 FIFO 達 `prog_full` 而卡在 `head=12, tail=50`。

同一條線在**能正常出图的 legacy NV12 引擎**中是帶反相的：
`rtl/nv12_capture_engine.v:165` `assign sgl_y_pop_ready = !y_walker_almost_full;`
（`:194` 同）。**這就是 26111204（NV12 personality、Git `09C2C4F5`）能量測到 18,489 影框、
而本 RGB-compositor personality 從未取得一幀的差別。**

## 1. 卡端像素流判別（任務 1，无需 Vivado）

### 1.1 `0xA00006BC / 6C0 / 6C4` 的真實語意（RTL 對照）

`rtl/sc7f0_hdmi_probe.v:552-559`（暫存器對照 `rtl/axil_reg_space.v` HDMI block
`8'hBC/8'hC0/8'hC4`）：

| CSR | 訊號 | 計數條件 |
|---|---|---|
| `0xA00006BC` | `vid_sof_cnt` | `rx_ss_video_tvalid && tready && tuser`（影框起） |
| `0xA00006C0` | `vid_eol_cnt` | `... && tlast`（行尾） |
| `0xA00006C4` | `vid_pix_cnt` | `... ` 全部被接受的 beat |

**兩個必讀注意事項：**
1. 這三個值是 `sample_req_1s` 每秒鎖存的快照（`:586-596`），**短窗口相減會被 1 s 量化誤導**
   （我 3 s 窗口量到 EOL/frame=1431 的假值；30 s 窗口才是真值）。
2. 計數器**不含 reset、也不受任何 enable 閘控**，且本 personality 的
   `rx_ss_video_tready` 由 `u_rx_ppc_upsize` 驅動、實質恆 1
   （`rtl/zu4ev_pcie_card_top.v:1172` 的 `assign rx_ss_video_tready=1'b1` 在
   `ifndef SC7F0_RGB_COMPOSITOR` 內）。所以它證明的是「**RX SS 正在輸出完整光柵**」，
   **不**證明下游有在收。

### 1.2 30 s 窗口實測（`logs/01`）與換算

`PIX` 是 32-bit、每秒 +7.46e9 級、17 s 溢位一次，必須做 mod-2^32 溢位還原：

| 區間 | ΔSOF | ΔEOL | ΔPIX | **EOL/影框** | **PIX/影框** | **beat/行** |
|---|---|---|---|---|---|---|
| 1 | 1799 | 3,887,737 | 3,169,488,711 (+1×2³²) | **2161.05** | **4,149,225** | **1920.00** |
| 2 | 1800 | 3,887,648 | 3,169,315,862 (+1×2³²) | **2159.80** | **4,146,824** | **1920.00** |
| 3 | 1800 | 3,887,647 | 3,169,316,328 (+1×2³²) | **2159.80** | **4,146,824** | **1920.00** |

理論值：3840×2160@60、2 PPC ⇒ **2160 行/影框、3840/2 = 1920 beat/行、
4,147,200 beat/影框、248.832 Mbeat/s**。實測吻合到 0.01 %。
`0xA000068C/690` = 296,974,195 / 296,974,194 Hz、`0xA0000600=0x3`、`0xA000060C=594,120,832`。

⇒ **`v_hdmi_rx_ss` VIDEO_OUT 完全健康：SOF 恰 60 Hz、每影框恰 2160 行、每行恰 1920 beat、
全速率從不被反壓。** Defect 3 與 RX/時脈/GT 無關，先前 §5 的判斷成立且更精確。

### 1.3 §12.2 卡端 `media-ctl -V`（已執行）＋ PS 分支擷取（任務 1 後半）

* 執行前（`logs/04`,`05`）：`b0060000.vpss-csc` pad0/pad1 = `1280x720`，卡端 `/dev/video0`
  `1920/0, YUYV, planes=0`，`sc7f0-vcud` = inactive（無人佔用）。
* **§12.2 兩條設定照文件原文引號語法重跑成功**（`logs/07`，rc=0/rc=0）：
  ```sh
  sc7f0ctl exec 'media-ctl -V "\"b0060000.vpss-csc\":0 [RBG888_1X24/3840x2160]"'   # rc=0
  sc7f0ctl exec 'media-ctl -V "\"b0060000.vpss-csc\":1 [VYYUYY8_1X24/3840x2160]"'   # rc=0
  ```
  （第一次我用未帶實體引號的寫法回 `Unable to setup formats: Invalid argument (22)`；
  文件 §12.2 的 `\"` 是**必需**的，不是裝飾。）
* `S_FMT NV12 3840x2160` 成功、`PLANE index=0 stride=3840 sizeimage=12441600`（`logs/12`）。
* **但 `sc7f0_ps_capture /dev/video0 NV12 3840 2160 30` 回報 `STREAMON: Broken pipe`（-EPIPE）**，
  且卡端 dmesg 有一條**開機就存在**的
  `xilinx-video video-capture: DMA initialization failed`（`logs/13`,`14`）。
  全 kernel 只有 `xvip_graph_pipeline_start_stop()` 與其失敗分支會回 -EPIPE，
  而該分支必印 `dev_err`；dmesg 在嘗試期間**沒有新訊息** ⇒ EPIPE 來自 composite
  device 的 DMA/pipeline 建置層（`DMA initialization failed`），不是 RX、不是 VPSS、不是反壓。
  卡端 `v4l2-ctl` 是精簡版（不支援 `--stream-mmap`/`--stream-timeout`），故以
  `/usr/bin/sc7f0_ps_capture` 代跑。

⇒ **卡端 media-ctl / VIPP 設定無法讓任何一條路收到影框**；PS 分支被自己的
V4L2 composite 初始化缺陷擋住（**獨立缺陷，記為 Defect 3b**，見 §4）。
因此 **GStreamer 桌面顯示的啟動條件未成立，本輪未啟動**（任務 1 的 if 條件不成立）。
另註：`0x6BC/6C0/6C4` 在 `media-ctl -V` **之前**就已在計數，與 media graph 無關，
不能把它當作「設定後才開始收像素」的證據。

### 1.4 用于判別「斷點在那一級」的兩個既有可讀暫存器（本輪新发现，建議保留）

| CSR | 來源 | 實測 |
|---|---|---|
| `0xA0000088 / 8C / 90` | `rtl/custom_pcie_dma_top.v:603-633`：`video_transfer = video_ch0_tvalid && video_ch0_tready`，即 **RGB 引擎在 packer 輸出端「實際接受」的 SOF/EOL/beat** | **恆 0（含串流中）** |
| `0xB0070060/0x64` | `sc7f0_tap_regs`：`capture_clk` 自由跑計數（`sc7f0_frame_tap.v:24-28`） | 3.02 s 走 905,881,454 ⇒ **capture_clk ≈ 300 MHz 確實活著** |

`0xB0070030 = 0x7`（frmbuf_wr / CSC / display reader 三個 reset 全釋放）、
`0xB0070008 = 0x2`（tap ready=1、enable=0，符合未串流）。
⇒ **排除「300 MHz capture 域未跑 / reset 未釋放 / GT 像素未出來」這整類假設。**

## 2. 串流中的判別實測（`logs/18`，`/home/rd/sc7f0/tmp/defect3-probe.sh`）

有界 `v4l2-ctl -d /dev/video0 --set-fmt-video=3840x2160,RGB3 --stream-mmap --stream-count=2`
（30 s 上限），t+4 / t+10 / t+18 三取樣，全部穩定同一狀態：

| 觀察 | 空閒 | 串流中 | 意義 |
|---|---|---|---|
| `0xA0000100` CH0_CTRL | `0x00200110` | **`0x00200111`** | bit0 enable=1、`[7:4]=1`(RGB24)、`[21:20]=2`(HDMI) ⇒ **驅動侧設定正確** |
| `0xA0000104` CH0_STATUS | `0x00000201` | `0x00000001` | bit0 `v_busy[0]`=1；bit9 `desc_fetch_idle` 1→0 ⇒ **thin walker 有在跑、`frame_active=1`** |
| `ch0_head / tail`（= `0xA000012C`） | 0 / 0 | **12 / 50** | **取了 12 個描述子後凍死**（一個 buffer 的 SGL） |
| `0xA0000088 / 0xA0000090` | 0 / 0 | **0 / 0** | **引擎從未接受一個 beat、從未鎖到 SOF** |
| `0xA00006BC` RX-SS SOF | 遞增 | **持續遞增**（86,817→87,249） | RX SS 全程健康 |
| `0xB00A0068 / 0x70` format-guard | 0 / 0 | **0 / 0** | **格式守門從未拒絕** ⇒ 不是 `desc_format`/幾何被拒 |
| `perf_stats` | Payload 0 B、TLP 12 | 同一時刻 **TLP 仍 12、Payload 0 B** | 那 12 個 TLP = 12 次描述子 **MRd**；**一個 MWr 也沒有** |
| `packet_stats` | 全 0、`fsm_state=0x20` | 全 0 | 与本缺陷无关（dualpath 未觸發） |
| `ch0_frames / ch0_drops` | 0 / 0 | 0 / 0 | 影框從未完成，也從未被計數為丟棄 |

`0x201` 空閒解碼：bit0 `v_busy[0]`=1（名義上 running=1）、bit9 `desc_fetch_idle`=1。

## 3. RTL 資料鏈逐級追蹤（任務 2）

路徑（`SC7F0_RGB_COMPOSITOR` personality，`zu4ev_pcie_card_top.v:1113-1131, 2093-2098`
→ `custom_pcie_dma_top.v:2629-2676`）：

```
v_hdmi_rx_ss VIDEO_OUT (rx_ss_video_*, 2PPC/48-bit)
 ├─ u_rx_ppc_upsize (2→4PPC) ─→ u_ps_capture (frame tap→VPSS→frmbuf_wr)   ← PS 分支
 └─ u_rgb24_pack (sc7f0_rgb24_axis_pack, 6B→16B gearbox, xpm_fifo_async 1024×129)
      → video_ch0_mux (tlast 恆 0) → custom_pcie_dma_top
        → u_rgb24_capture_engine (sc7f0_rgb24_c2h_engine) → video_req_cdc → rq_tx_encoder → C2H MWr
launch: thin_desc_fetch_engine → sc7f0_video_launch_arbiter → xpm_cdc_handshake(245b) → eng_desc_valid
地址:   thin SGL entries → u_v_sgl_y_cdc → sgl_wr_en → u_sgl(sg_segment_walker) → seg_addr
```

逐級判定：

| 級 | 判定 | 依據 |
|---|---|---|
| RX SS → packer 輸入 | **正常**（全速率、無死鎖） | §1.2 實測 1920 beat/行、2160 行/框 |
| reset 極性 / clock domain | **正確** | `capture_clk` 300 MHz 實測在跑、`0xB0070030=7`；packer 兩端 `sc7f0_reset_sync` 各源各跨（`sc7f0_rgb24_axis_pack.v:148-153`）；`rx_video_rst`/`capture_rst_n` 皆釋放 |
| `sc7f0_rgb24_axis_pack` | **邏輯正確**（但下游不排空時必然 `abandon`） | `xpm_fifo_async` `USE_ADV_FEATURES="0404"` 已核對 `/opt/Xilinx/Vivado/2023.2/data/ip/xpm/xpm_fifo/hdl/xpm_fifo.sv:206-216`：`EN_WDC=bit2`、**`EN_RDC=bit10` 確實啟用** ⇒ `rd_data_count`/`m_axis_avail` 有效（不是「avail 恆 0」那一型缺陷） |
| 描述子 launch / format guard | **正常**，非拒收 | `guard_sticky/count = 0`；`WIDTH_FIELD_PIXELS=1`（`custom_pcie_dma_top.v:2075-2084`）⇒ 匯流排寬度欄為 3840 px ≤ 4096、`bus_matches_profile` 成立；引擎 `desc_ok`（`:130-132`）= 1 |
| `enable/mux/format` 條件 | **已滿足** | CTRL `0x200111`（enable=1、format=1、源=HDMI）；`video_ch0_mux_* = rgb24_*` 連線一致（`:2093-2098` ↔ `:2874-2878`） |
| **`burst_start`（引擎發 payload 的唯一門）** | **永不成立 ← 根因** | `:420-422` 需 `pl_seg_ready`；`:305` `s_seg_ready = !desc_sg_mode \|\| (seg_valid && ...)`，thin 一律 `sg_mode=1`（`thin_desc_fetch_engine.v` `frame_launch_bus` 的 `1'b1`），而 `seg_valid` 需要 SGL 條目 ⇒ 見 §3.1 |
| `tvalid/tready` 死鎖 | **有，但是後果不是原因** | `:428` `p_axis_tready = burst_start \|\| pop_stream \|\| pop_discard`；`S_ARM` 三項全 0 ⇒ `tready` 恆 0 ⇒ `ENGINE_BEATS` 恆 0 |

### 3.1 根因鏈（含行號）

```verilog
// rtl/sg_segment_walker.v:57                     —— active-high「將爆」旗標
assign fifo_almost_full = (count >= (FIFO_DEPTH - 20));      // 64-20 = 44

// rtl/sc7f0_rgb24_c2h_engine.v:178               —— ★ 少一個 ! ★
.fifo_almost_full(sgl_pop_ready),        // port :80  output wire sgl_pop_ready

// rtl/custom_pcie_dma_top.v:2647 / :2642
.sgl_pop_ready (v_sgl_y_pop_ready),
.sgl_wr_en     (!v_sgl_y_empty && v_sgl_y_pop_ready && eng_busy),   // 恆 0
// rtl/custom_pcie_dma_top.v:2566 （SGL 來源 CDC FIFO 的讀使能，同一反相項）
.rd_en         (!v_sgl_y_empty && v_sgl_y_pop_ready && eng_busy),   // 恆 0
```

自鎖死循環：`count=0` ⇒ `almost_full=0` ⇒ `sgl_wr_en=0` ⇒ `count` 永遠 0。
（`sg_segment_walker.v:110-116` 的「count=0 時零延遲 bypass」也無法進入，因為它同樣以
`sgl_wr_en` 為條件。）

後果，與 §2 每一項實測一一對應：

1. `u_sgl` FIFO 空 ⇒ `seg_valid=0` ⇒ `s_seg_ready=0` ⇒ `pl_seg_ready=0`
   ⇒ **`burst_start` 恆 0** ⇒ `c2h_req_valid` 從不拉起 ⇒ **Payload 0 B、0 個 MWr TLP、
   `frames_completed`/`ch0_frames=0`**。
2. `S_ARM` 中 `p_axis_tready=0` ⇒ packer FIFO 1024 項約 11 µs 填滿 ⇒
   `sc7f0_rgb24_axis_pack.v` 的 `refuse_evt → abandon` 棄掉**整幅**影框 ⇒
   **`0xA0000088/0x90` 恆 0**、`overflow_sticky` 恆 1（且該 sticky 只在 `!s_rst_n` 清，
   上電即被設起，對本缺陷無診斷價值）。
3. SGL 來源 FIFO（`u_v_sgl_y_cdc`）從不讀出 ⇒ `prog_full → ch0_sgl_y_almost_full`
   ⇒ `thin_desc_fetch_engine` 停止取描述子 ⇒ **`head` 凍在 12（tail=50）**。
4. `pcie_frame_done` 永不來 ⇒ `ch0_owner_busy`（`sc7f0_video_launch_arbiter.v` 的
   `owner_release`）永不釋放 ⇒ 之後再也無法 launch，`frame_active` 恆 1
   （`desc_fetch_idle=0`）。

### 3.2 同檔第二個缺陷（必須一併修）

`sc7f0_rgb24_c2h_engine.v` 的 `video_busy` **只有設 1、從不清 0**
（宣告 `:100`、reset `:469`、`desc_accept` 設 1 `:503`，無任何清 0 指派）：

* `eng_busy → v_busy[0]（:2491）→ ch0_status bit0` **永久 running=1**
  ⇒ 空閒讀到 `0x201`，驱动 `drained=`/overflow 判讀全失真；
* `sgl_wr_en` 的 `eng_busy` 項恆真；
* legacy 引擎是把 `video_busy` 當「影框在飛 + 一次一顆描述子」並在 retire/abort 清
  （`nv12_capture_engine.v:158, 617, 643, 647`），RGB 引擎已改用 `desc_launched` 做後者，
  所以 `video_busy` 只剩狀態輸出語意，卻被忘在設 1 後不管。

### 3.3 為什麼既有閘門全部看不出

`tb/tb_sc7f0_rgb24_c2h_engine.sv`（含 T8 散集gather 案例）**把 `sgl_wr_en` 當自由激勵直接拉
（:857 `sgl_wr_en <= 1'b1;`）**，從不以 DUT 自己的 `sgl_pop_ready` 輸出為條件；
而 `sgl_wr_en` 在真實整合中**恰恰就是被 `sgl_pop_ready` 閘控的**。
此外 `tb_sc7f0_rgb24_c2h_engine.sv` 與 `tb_rgb24_capture_4k.v` **未被任何 `scripts/sim_*.tcl`
引用**（`grep -rl` 為空），`scripts/sim_sc7f0_rgb_compositor.tcl` 只跑
`sc7f0_rgb24_pack_tb` + `sc7f0_alpha_blend_2ppc_tb`。⇒ 這是「整合縫隙」而非模組內演算法缺陷。

## 4. 順帶確定的獨立缺陷（不屬本根因，需另外排程）

* **Defect 3b（卡端 PS 擷取路徑）**：`xilinx-video video-capture: DMA initialization failed`
  於開機即存在 ⇒ VIPP `STREAMON -EPIPE`、`sc7f0_ps_capture` 無法收幀、`sc7f0_vcud` 因此
  無法工作。這是 image/DT/驅動層缺陷（非 RTL），**是 VCU 那一路的第二個阻塞點**。
* **除錯盲點（必隨本次修復一併處理）**：
  `custom_pcie_dma_top.v:2646` `.cur_sgl_count()`、`:2664-2670` 的
  `drop_count/error_sticky/frames_completed/align_discard_count/bytes_committed/
  active_line_bytes/active_stride` **全部懸空未接 CSR**；
  `video_ch0_avail`（`:2652`）與 `src_overflow_sticky/src_line_align_sticky`（`:2671-2672`）
  已接進引擎但**不可讀**。只要 `cur_sgl_count` 與 `avail` 可讀，本缺陷一個 devmem 就能定位。
* **`reg_video_sub_reset[1]`（video_engine_reset）在本 personality 對 RGB 引擎無效**：
  `zu4ev_pcie_card_top.v:277-291` 非 DEBUG 构建下 `capture_rst_n = capture_all_n`
  （只由 `sys_300m_rst_n/sys_100m_rst_n` 決定），而驅動 STREAMOFF 逾時的
  「pulsing video sub-reset」動的是 `video_engine_rst_n` ⇒ 該救濟動作實際上是空動作。

## 5. 具體修復方案（**本輪未動任何 RTL**）

### 5.1 一行根因修正（必要且充分）

```verilog
// rtl/sc7f0_rgb24_c2h_engine.v:178
-        .fifo_almost_full(sgl_pop_ready),
+        .fifo_almost_full(walker_sgl_almost_full),
     );
+    // walker 的 almost_full 是 active-high「將爆」旗標；對上游語意是「可接收」，
+    // 必須反相後才輸出（與 rtl/nv12_capture_engine.v:165/194 完全一致）。
+    assign sgl_pop_ready = !walker_sgl_almost_full;
```
並新增 `wire walker_sgl_almost_full;`。
**建議同時把 port 改名**（`sgl_pop_ready` → 保持，但在 `sg_segment_walker` 端把
`fifo_almost_full` 另出 `fifo_has_room = ~fifo_almost_full` 供新代碼使用），
避免同型錯誤重現。

### 5.2 `video_busy` 生命週期修正（同檔）

在影框完成（`:525-531` 的 `frames_completed + video_frame_done` 那一支）與
影框被拒/中止路徑清 `video_busy <= 1'b0;`，語意對齊 `nv12_capture_engine.v:643/647`；
`ch0_owner_busy` 的釋放仍走既有 `pcie_frame_done`，不改 ABI。

### 5.3 順邊接出的 debug CSR（建議必做，否則下一輪仍靠猜）

全部走**既有可讀模式**（`ovl_video_guard_sticky/count` 已是
`u_ch0_arbiter → custom_pcie_dma_top → u_overlay_ctrl 0x68/0x70` 的可讀鏈），
新增唯讀建議放在 **GLOBAL block 空閒區 `0x0E0–0x0F4`**
（`rtl/axil_reg_space.v` GLOBAL 已用到 `0xDC`；`0xE0+` 未用 ⇒
卡端 `devmem 0xA00000E0`、host BAR0 `0x0E0`，**不改位址映射、不改 DT**）：

| 建議偏移 | 內容 | 來源訊號（目前懸空） |
|---|---|---|
| `0x0E0` | `[6:0]` walker SGL 條目數、`[8]` `pl_seg_ready`、`[9]` `seg_valid`、`[12:10]` 引擎 `state` | `u_sgl.fifo_count`、`:322`、`:305`、`state` |
| `0x0E4` | `[10:0]` packer `avail`、`[12]` `p_axis_tvalid`、`[13]` `p_axis_tready`、`[14]` `burst_start`、`[16:15]` `pl_valid/have_all` | `rgb24_avail`、`:420-428` |
| `0x0E8` | `bytes_committed[31:0]` | `:2668`（現懸空） |
| `0x0EC` | `drop_count[31:0]` | `:2667`（現懸空） |
| `0x0F0` | `frames_completed[31:0]` | `:2669`（`:2666` 未接線 → 同時修掉 `ch0_frames` 只反映 thin 引擎的問題） |
| `0x0F4` | `[0] error_sticky [1] src_overflow_sticky [2] src_line_align_sticky [3] video_busy [4] desc_valid [5] desc_ready [6] SGL 來源 FIFO prog_full（已同步）`[7] empty `[8] pop gate`；`[31:9]` 保留讀 0 | `:2671-2673`、`:469/503` |

`0x0E0` 這一組的判讀力：修好前後分别是
`{fifo_count=0, seg_valid=0, pl_seg_ready=0, avail=1024, tready=0}` 與
`{fifo_count>0, seg_valid=1, pl_seg_ready=1, avail 在穩態流過, tready 週期性 1}`。

### 5.4 必補的閘門（防同型缺陷）

1. 把 `tb/tb_sc7f0_rgb24_c2h_engine.sv` **接進一個 `scripts/sim_*.tcl` 閘門**，並把激勵改成
   **`sgl_wr_en <= (!v_sgl_y_empty && sgl_pop_ready && eng_busy)` 的整合同等式**
   （即重現 `custom_pcie_dma_top.v:2642` 的接法），並新增斷言
   `assert (sgl_pop_ready == !walker_almost_full)` 與「N 影框必須 retire」的最終判定。
2. 新增一個 packer+engine 的**雙時鐘端到尾**閘門（297 MHz s_clk / 300 MHz m_clk、
   真實 `xpm_fifo_async`、真实 thin launch），斷言 `bytes_committed == 24,883,200/影框`。
   現有 `sc7f0_rgb24_pack_tb` 只測 packer，無法看到本缺陷。
3. 在 `scripts/sc7f0_rx_tdlock_acceptance.sh` 的 capture 階段加入 `0xA0000088/0x90` 與
   新增 `0xA00000E0/E4` 的取樣與判讀，把「RX 已鎖但 fabric 0 payload」細分為
   「引擎未 arm / 無 SGL / 無 payload / 反壓」。

## 6. 需要的重跑流程（**本輪未啟動**，待授權）

1. **RTL**：`rtl/sc7f0_rgb24_c2h_engine.v`（§5.1+§5.2）、可選
   `rtl/custom_pcie_dma_top.v`＋`rtl/zu4ev_pcie_card_top.v`＋`rtl/axil_reg_space.v`（§5.3 debug CSR）。
2. **先跑軟體閘門（不需長建置）**：
   `vivado -mode batch -source scripts/sim_sc7f0_rgb_compositor.tcl`、
   新增的 engine/端到端閘門、`python3 -m unittest discover -s scripts/tests`。
3. **FPGA**：`vivado -mode batch -source scripts/build_sc7f0_hdmi_08.tcl`
   （经 `./scripts/sc7f0_build.sh` 時先跑回歸），需 `HDMI08_BUILD_PASS`、`report_cdc` 無新增
   critical、DRC 無違反；注意 §5.3 若只在既有 slave 內加暫存器，**位址映射不變**，
   XSA 的.address 段不動（`check_sc7f0_vcu_bd.tcl` 的 `SEG_M_AXI_HPM0_FPD_Reg @ 0x00A0000000`
   要求仍成立）。
4. **PetaLinux**：`make -C petalinux/qpcie-zu4ev hw-desc linux XSA_DIR="$OUT/fpga/hardware.xsa"`
   （bitstream/BOOT.BIN 內容變 ⇒ 必須重组 `BOOT.BIN`；
   `SC7F0_IMPL_DIR="$OUT/fpga" SC7F0_IMG_DIR="$OUT/images" bash scripts/package_zu4ev_bootbin.sh`）。
   若只改 RTL 不改 DT，`image.ub` 可不變，但 `BOOT.BIN` 必變。
5. **版本與驗收**：`C_VERSION` 遞增至新值（現行 `0x26111503`）；打包後走
   **VERIFY → COMMIT 兩階段**，每輪恰好一次 COMMIT，eMMC SHA 與兩側 boot_id 實際取證；
   燒錄後**必須補跑** §12.2 的兩條 `media-ctl -V`（非持久）與 §12.1 的一次既有 runtime reset。
6. **驗收順序**：先看 `0xA00000E0/E4`（SGL/seg_ready/avail）→ `0xA0000088/0x90`
   （引擎接受 beat/SOF）→ `ch0_frames`/`perf_stats Payload` → 才轮到 GStreamer 桌面顯示。

## 7. 本輪結束時狀態與安全取證

| 項目 | 值 |
|---|---|
| host boot_id | `fe876eaf-ce74-4a0e-a347-b28d3f41b669`（**與 261116 報告同一開機，未重啟**） |
| 卡 boot_id | `6fe3bb53-7409-4e3f-8eda-faae214078e4`（**同上，未重啟**） |
| PL | `v38.17.21-variant3 Git C78C495E Date 20261115 Caps 0x1001011F`（未重燒） |
| AER | correctable / fatal / nonfatal 全 0 |
| 卡端殘留變更 | `vpss-csc` pad0/pad1 = 3840x2160（§12.2 正確設定，**重開機後不持久**）；`sc7f0-vcud` 仍 inactive；無程式碼改動 |
| 仓库 | `HEAD=c78c495` 未變、未 commit；既有 WIP（含未追蹤的 `rtl/sc7f0_rgb24_*.v`）**未動** |


## 8. 實作階段的兩個新缺陷（round N r1 建置實測，2026-11-16）

r1 = `rgb-c2h-fix-26111601-20261116T055423Z`（§5.1/§5.2/§5.3 已全部實作並通過
`RGB24_C2H_SIM_GATE_PASS`、108 checks 0 errors）。整板建置完成並寫出 bitstream，
但**時序未過**，且政策閘門比 round M 多出五筆 critical：

| 項目 | round M（已部署） | r1 |
|---|---|---|
| WNS / TNS / failing endpoints | `+0.143 / 0.000 / 0`（`All user specified timing constraints are met`） | `-2.246 / -9.404 / 126` |
| Layer A critical | CDC-1=4、CDC-10=8、CDC-11=27（既有基線） | 同左 **+ setup/hold、TIMING-6×2、TIMING-7×2、TIMING-8×1** |
| LUT / FF / BRAM | 87.40 % / 74.29 % / 86.33 % | 88.00 % / 75.22 % / 86.33 % |

（Layer B 其餘項目兩輪相同：本 personality 的政策閘門在 round M 也未通過，
`ARTIFACT_CLASS=BRINGUP_ONLY_NOT_RELEASE_ACCEPTED`，故判讀只看「與 M 的差分」。）

### 8.1 `prog_full` 是寫域訊號，直接取样就是一條未同步的 125→300 MHz 路徑

`xpm_fifo_async` 的 `prog_full` 屬**寫域**（此例 `pcie_user_clk`），而 debug bundle
在 `capture_clk_300m` 形成。r1 把 `ch0_sgl_y_almost_full` 直接放進
`rgb_dbg5_v[6]`，實測即為一條真實跨域路徑：

```
u_sgl_y_cdc/gen_pf_ic_rc.gpf_ic.prog_full_i_reg (pcie_user_clk)
  -> rgb_dbg5_v_reg[6] (capture_clk_300m)   requirement 0.337 ns   slack -1.003 ns
```

修法：該位元改經自己的 `xpm_cdc_single`（`u_sgl_src_af_cdc`, DEST_SYNC_FF=4）後再
進入 bundle。同時取消 `u_sgl_y_cdc` 的 `rd_data_count`（`USE_ADV_FEATURES` 回到
每版都用的 `0002`），把「來源 FIFO 還有多少條目」換成
`empty`+`prog_full`+`pop gate` 三位元判讀 + walker 自身計數（`0x0E0[6:0]`），
在这 88 % LUT / 86 % BRAM 的器件上不換取額外佈線風險。

### 8.2 packer 的兩個 sticky 旗標同步器從未被約束（r1 的 WNS 持有者）

`rtl/sc7f0_rgb24_axis_pack.v:224-296` 把 overflow / line-align 兩個 **sticky 位準**
先在源時鐘暫存，再用兩級鏈跨到目的時鐘 —— 與 `constraints/sc7f0_async_io.xdc`
已收錄的六條 `u_hdmi_probe` 位準跨域同型，但從未寫進任何約束。RGB personality 下
`s_clk = clkout2`（VPHY RX MMCM，3.367 ns）、`m_clk = capture_clk_300m`
（`pl_clk_300m_p` 經 BUFGCE_DIV，3.333 ns）：兩個獨立物理來源，工具推得的邊界對只有
**0.035 ns**，比一顆 FF 的 clock-to-out + 任何佈線還小：

```
ovf_sticky_s_reg -> sync_ovf_reg[0]   -2.246 ns  data 0.283 ns  skew -1.890 ns  req 0.035 ns
eol_sticky_s_reg -> sync_eol_reg[0]   -2.209 ns  （同一 requirement）
```

`report_cdc` 早就把兩條列為 CDC-2（`1-bit synchronized`, `Exception = None`）；
`report_methodology` 隨後对 `clkout2 <-> capture_clk_300m` 開 TIMING-6/7 Critical。
**過去各輪「過了」只是時鐘佈線剛好給 +2 ns skew**（M 的同一條路徑是正 slack），
不是設計成立。修法沿用本檔既有慣例 —— 一對命名 FF 一條
`set_false_path -from ..._sticky_s_reg -to ..._sync_reg[0]`，不加 `-from-clock`、
不加 clock group、不動第二級；在 r1 自己的 post-route DCP 上實測
（`diag-timing-004`）：TIMING-6/7/8 行數 `S0=5 → S1=3（加這兩條）→ S2=0`
（S2 再把 8.1 那條以 false path 代擬，等同 RTL 同步器移除該路徑的效果）。

### 8.3 其餘 123 個端點是同域擁擠，非跨域

扣掉上述三條後，WNS 剩 `-0.130 / TNS -3.946 / 123 endpoints`，全部是
`capture_clk_300m` 同域：HLS `u_ps_capture/u_csc`、`u_overlay_writer` 的 FIFO
致能、`u_tap` FIFO RAM 的復位 recovery、本引擎 `protocol_error_count_reg[*]/CE`，
皆 `-0.066 ~ -0.130 ns`。round M 在同器件為 `+0.143`，故 r2 只動流程自己允許的
一個旋紐：`SC7F0_PLACE_DIRECTIVE=ExtraTimingOpt → Explore`
（`docs/sc7f0_coherent_release_26111204.md` 記錄的 300 MHz capture group 解法），
`PHYS_OPT=AggressiveExplore / ROUTE=Explore / POST_ROUTE_PHYS_OPT=AggressiveExplore`
與所有 requirement、例外、閘門 JSON 一律不變。

### 8.4 r2 來源 custody

`rgb-c2h-fix-26111601-r2-<stamp>`：round M 密封快照 359 路徑 byte-for-byte 複製，
內容差分**恰好十個檔案**（r1 的九個 + `constraints/sc7f0_async_io.xdc`），
`PATHSET_VS_ROUND_M diff_lines=0`、`MANIFEST_VERIFY_BEFORE rc=0 ok=359/359`。

### 8.5 r2 中止記錄（未產出任何工件）

`rgb-c2h-fix-26111601-r2-20261116T073556Z` 在 impl_1 的約束載入階段回報

```
CRITICAL WARNING: [Designutils 20-1307] Command '//' is not supported in the xdc
constraint file. (snap/constraints/sc7f0_async_io.xdc:313)
```

原因是 §8.2 新增的說明區塊有一行註解誤用 `//` 而非 `#`。雖然兩條
`set_false_path` 位於其後、語法本身有效，但「受管 XDC 讀者無法完整解析的約束檔」
不能當硬體輪次的證據基礎，故於 place_design 前 25 分鐘**主動中止**，該輪的
bit / DCP / XSA / release 一律不用（見該輪根目錄 `DISCARDED.txt`）。
r3 已把註解改回 `#`，並在來源 custody 新增一個零成本的啟動前檢查
（`STAGE_1b_LINT_APPLIED_XDC`：套用的 `constraints/*.xdc` 若出現 `//`、`/*`、`*/`
行首即 `REFUSE_XDC_SYNTAX` 拒絕啟動）。
