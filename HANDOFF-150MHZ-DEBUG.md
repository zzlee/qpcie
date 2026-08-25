# HANDOFF: A50T 150MHz NV12 遷移後實機 timeout 除錯（未解）

> 產生時間：2026-08-25　｜　撰寫者：ox-alpha session（交接給下一位 coding agent）
> 溝通語言慣例：與使用者以**繁體中文**回報；程式碼/commit 訊息英文。
> **鐵則：不得自行執行 `./scripts/flash_a50t.sh` 燒錄硬體——一律由使用者執行並回饋結果。**

---

## 1. 專案與目標

QPCIe Artix-7 A50T（`xc7a50t-csg325-2`, PCI ID `12AB:E380`）PCIe Gen2 x4 DMA 擷取卡。
資料路徑：`Xilinx TPG YUV444(4PPC) → rounded 2×2 chroma downsample → NV12M → 256B C2H MWr → Host V4L2 MMAP`。

目前狀態目標：單一 V4L2 channel，支援 `1920×1080@60` 與 `3840×2160@60` 兩個離散模式。

### 已實機驗證過的里程碑（不要再懷疑這些）

| 里程碑 | 結果 |
|---|---|
| PCIe 枚舉/BAR0/BAR1 MMIO、SG C2H/H2C 4-page | ✅ |
| 1080p60 NV12M paced correctness | ✅ 彩條正確 |
| 256-byte TLP payload + path-local MPS raise | ✅ 實機 240.5 FPS / 713.57 MiB/s |
| NV16/NV12 效能門檻 | 4K60 NV12 = 711.91 MiB/s，實測在 59.86～60.14 FPS 邊緣擺盪 |

### 目前進行中（本次交接的主題）

**150 MHz 前端遷移**：把 `nv12_capture_engine` 從 125 MHz PCIe domain 搬到既有的
150 MHz video domain，解決 4K60 天花板只有 60.28 FPS（餘裕 0.5%）的問題。
RTL/driver/build-script 修改已完成、18/18 仿真通過、Vivado timing clean
（WNS +0.289）、bitstream 已產出——**但實機 1080p benchmark 直接 timeout（一幀都沒有）**。

---

## 2. Git / 交付狀態

```
HEAD = ffff925  feat(rtl): move NV12 capture engine into 150 MHz video domain   ← 已 push
上一批相關 commit：
  a9cfc96  feat(test-app): deepen VB2 queue (8 buffers) + --buffers
  15752b9  feat(driver): raise path-local MPS to 256 (取代 pci=pcie_bus_perf)
  76010b1  fix(driver): check negotiated MPS before SG diagnostic
  70ce542  feat(dma): 256-byte MWr payload（已實機驗證 OK）
  bfa21cc  docs(wiki): consolidate A50T NV12M implementation results
工作樹（未提交）：
  ?? tb/tb_video_cdc_system.v        ← 新增的整合測試bench（見 §5）
  M  sim/run_sim.sh                  ← 把它加進 TESTS 陣列
最新 bitstream（對應 ffff925，實機失敗版）：
  SHA256 115450794f935669e64c24d14d28b76eec71ba5b401aee43dcc8205b9b27ea31
  firmware hash 0xFFFF925
```

---

## 3. 150 MHz 遷移做了什麼（ffff925 內容）

### 3.1 時脈/架構

```text
舊：TPG@150 ──xpm_fifo_axis(async)──▶ 引擎@125 ──▶ RQ@125   （4K60 天花板 60.28 FPS）
新：TPG@150 ──同域直連──────────▶ 引擎@150 ──video_req_cdc──▶ RQ@125（天花板 72.3 FPS）
```

### 3.2 新增/重寫的模組

| 檔案 | 內容 |
|---|---|
| `rtl/video_req_cdc.v`（新） | 引擎 C2H request（addr+data beats）跨 150→125 的橋。使用 `xpm_fifo_async`（FWFT、block RAM）＋ writer 端保留計數（reservation）＋ 完成回執 toggle。讀端只在「整包已常駐」時開始重播（`rd_done_seen != rd_started` gating），保證 requester 不會看到 mid-TLP 斷流。固定封包大小 `REQ_DWORDS=64`（256B）。|
| `rtl/custom_pcie_dma_top.v` | 引擎改掛 `video_clk/video_rst_n`；descriptor+timestamp 與完成/遙測各走一組 `xpm_cdc_handshake`（240-bit / 96-bit）；v_done 用 2FF toggle synchronizer；pacer 常數改 `32'd2500000`（60FPS@150MHz）；新增輸入埠 `video_clk/video_rst_n/video_ch0_*`。|
| `rtl/a50t_pcie_card_top.v` | 移除舊 2048 筆 `xpm_fifo_axis` payload CDC；TPG 直接同源接引擎。|
| `constraints/a50t_pcie_pinout.xdc` | 新增 `set_clock_groups -asynchronous`（clk150_mmcm ↔ userclk2）；既有 false-path。|
| `driver/qpcie_sysfs.c` | tpg_fps 不再寫 BAR1+0x30（那是 TPG maskId 暫存器，會破壞輸出）；改為唯讀常數顯示。|

### 3.3 Build script 強化（踩雷後加的防護）

- `config_ip_cache -disable_cache`：IP cache 快取產品曾讓 v_tpg_0 卡在 'Reset' 生成狀態，
  導致 synth_1 吃 `*_stub.v` 把四個 IP 全部黑箱化（症狀：DSP=0、GTPE2=0、BRAM 崩到 1.5 tiles）。
- place/route 後 guard：檢查 `GTPE2>=4 && DSP48E1>0 && RAMB>=10`，不符即 exit 1（防止殘缺 bitstream 出貨）。
- `sim/run_sim.sh`：`--sv` 模式、加入 XPM cdc/fifo/memory 三個來源檔、glbl.v、兩個 system TB。

### 3.4 仿真狀態

`./sim/run_sim.sh` → **18/18 PASS**。

---

## 4. 實機測試結果（問題所在）

燒錄 `11545079...` bitstream、載入 driver 後：

```text
dmesg：MPS raise 正常（256 bytes）、SG diagnostic 通過（probe 成功）
./test_app/v4l2_test_app --width 1920 --height 1080 --benchmark --frames 600 --pattern 9
→ [PASS] 一路到 STREAMON
→ [FAIL] frame timeout    ← 一幀都收不到
```

driver probe 會跑 SG diagnostic（4-page C2H/H2C @256B），它能成功代表
PCIe link、requester、descriptor fetch、ring 機制都正常。
**故障被夾在「NV12 引擎 ⇄ 新 CDC」的縫合上**。

---

## 5. 除錯現況：整合仿真已重現異常（關鍵章節）

### 5.1 已建立 `tb/tb_video_cdc_system.v`（未提交）

架構複製 `tb_sg_dma_pipeline`（bridge + dma_top + host BFM），但：
- 描述子改為 **NV12M format=2**：`Y@0x1000_0000、UV@0x1100_0000、128×4、stride=128`
  （幀 = 768 bytes = 剛好 3 個 256B 封包）
- 影像源在 `video_clk`(150MHz) 上串流一幀 deterministic YUV444（golden 公式同 unit TB）
- 監聽 TX wire 收 MWr payload、比對 golden、檢查 MSI pulse
- 含 DBG heartbeat 與整合探針（desc accept / dest_req 計數）

執行方式（xsim.dir 已在 repo root，直接重跑即可）：
```bash
export PATH="/opt/Xilinx/Vivado/2023.2/bin:$PATH"
cd /home/zzlee/qpcie
xelab tb_video_cdc_system work.glbl -s sim_v11   # 若 xsim.dir 在可跳過 xvlog
xsim sim_v11 -R
```

### 5.2 仿真觀察到的現象（最新一次 run，/tmp/s.log）

正常的部分：
```text
[380000]  desc-cdc dest_req #1          ← descriptor 跨域 OK
[388000]  engine accepted descriptor #1 ← 引擎接受 OK
[1487000] VREQ: packet pushed (toggle=0) ← CDC writer 推完第 1 包 OK
[1528000] TX start: fmt=11 len=64 addr=Y_BASE ← 第一個 MWr 上線 OK
row 也會前進（capen=1，row 0→1→2→3）
```

**異常的部分（核心謎團）**：
```text
1. TX start 出現了 6 次（1528000/1680000/1832000/1984000/2152000/2304000）
   → 一幀 768B 只應有 3 個封包；多出一倍。
2. 全部 6 個 burst 的位址都是 Y_BASE(0x10000000)，沒有任何 UV(0x11000000) 封包，
   也沒有 +256 的位址推進。
3. 第 4~6 個 burst 的 payload 是全 X（讀到未初始化區域）。
4. row 前進極慢：row0→1 花了 ~500µs（應為 32 beats = 213ns @150MHz），
   代表引擎 FIFO 長時間處於滿位/反壓狀態。
```

### 5.3 目前對根因的判讀（依可信度排序）

1. **`nv12_capture_engine` 的請求位址產生器沒有推進**（六包同一地址），
   或是 `video_req_cdc` 把同一個標頭字重複播放。注意 reader 每封包彈出數 =
   header(1) + W1(RD_FIRST) + 63 次接受預取 = 65，writer 每包推 65 —— 數量吻合；
   但「最後一拍的處理」曾在除錯中途改過（flush_pending 已移除），
   需要重新確認 RD_RUN 最後接受的 pop 行為與 dout 取樣窗口。
2. **引擎的 `c2h_req_valid/ack` 與 CDC writer FSM 的握手節拍不合**：
   writer 在 `WR_ADDR` 用組合邏輯推 address word（`fifo_wr_en` 組合賦值），
   `s_req_data_ready` 晚一拍才拉高；引擎端預期 `data_ready` 每拍消一筆。
   需要比對引擎 packetizer 的握手時序假設（特別是第一筆 data beat 是否會被吃兩次或漏吃）。
3. **描述子被重複投遞的可能**：六包 ≈ 兩幀量。若 desc-CDC 的 dest_ack/src_rcv
   協議讓同一描述子被 latch 兩次（例如 hs_dest_req 與 hs_dest_ack 的窗口重疊），
   就會出現第二幀。探針顯示 dest_req 只有 #1、engine accept 只有 #1——
   所以「重複投遞」目前證據不足，但六包仍是事實。
4. **X 資料來源**：xpm_fifo_async FWFT 在空/剛填充邊界的 dout 行為，
   或讀端在 `rd_done_seen != rd_started` 條件成立當下 FIFO 尚未完整可見
   （同步延遲競爭）。gating 已要求「整包推完」的回執，理論上安全，
   但建議用 waveform 確認第一次 premature read 發生的確切位置。

### 5.4 建議給下一手的第一步

1. 在 `tb_video_cdc_system` 中把每個 burst 的**完整 17-beat 內容** dump 出來
   （header + 16 payload），與 golden 逐 DW 比對，確認第一個錯誤 DW 的位置與內容。
2. 在 `video_req_cdc` 讀端三個狀態各自加進入點 $display（含 dout 值），
   觀察 RD_HDR→RD_FIRST→RD_RUN 的位址序列何時開始重複/出錯。
3. 檢查 `nv12_capture_engine` 中 `y_send_addr/uv_send_addr/y_send_line/uv_send_line`
   在 256B payload 模式下的推進邏輯（`y_send_offset + MWR_PAYLOAD_BYTES >= width_q`
   分支），確認跨行與跨平面位址推進在 128×4 小幀上的行為。
   （小幀 WIDTH=128 時每行恰好 0.5 個 256B 封包 → 位址會跨行連續，這是預期的，
   但要確認 offset/line 的 wrap 判斷沒有把同一包發兩次。）
4. 若仿真修好：重跑 `run_sim.sh`（19 個 TB）→ Vivado clean build → 交由使用者燒錄
   重測 §4 的三條指令。

---

## 6. 重要檔案地圖

```
rtl/
  video_req_cdc.v            ← 新 CDC 橋（本輪重寫 3 次，含除錯暫存器）
  custom_pcie_dma_top.v      ← 引擎遷移 + xpm_cdc_handshake ×2 + video 埠
  nv12_capture_engine.v      ← 256B 模式；色度路徑未變
  a50t_pcie_card_top.v       ← 移除 xpm_fifo_axis；TPG 直連
  video_clock_gen.v          ← MMCME2_BASE 125→150MHz（DIV=5,MUL=24,OUT=/4 → VCO 600MHz）
driver/
  qpcie_v4l2.c               ← NV16M/NV12M 協商、TPG program/readback、MPS guard
  qpcie_main.c               ← probe 前 MPS 檢查（<256 拒絕）
  qpcie_sysfs.c              ← tpg_fps 改唯讀常數
tb/
  tb_video_cdc_system.v      ← ★ 本次除錯主戰場（未提交）
sim/run_sim.sh               ← --sv + XPM sources + glbl + 19th TB entry
scripts/build_a50t.tcl       ← ip cache disable + post-route guard
test_app/v4l2_test_app.c     ← --buffers、動態 gate（≥750MiB/s 判定）
constraints/a50t_pcie_pinout.xdc ← clock groups + false paths
wiki/                        ← bfa21cc 已整併，注意 §150MHz 相關段落需再更新
```

## 7. 常用命令

```bash
# 仿真（全部）
./sim/run_sim.sh
# 單跑整合 TB
export PATH="/opt/Xilinx/Vivado/2023.2/bin:$PATH"
xvlog --sv rtl/*.v <xpm 三個 .sv> tb/tb_video_cdc_system.v   # 詳細清單見 run_sim.sh
xelab tb_video_cdc_system work.glbl -s s1 && xsim s1 -R
# 注意：xelab 編 XPM memory 較慢（~2-4 min），勿設過短 timeout

# FPGA build（含 OOC/guard）
rm -rf build/qpcie_a50t_proj
/opt/Xilinx/Vivado/2023.2/bin/vivado -mode batch -source scripts/build_a50t.tcl

# Driver / app
make -C driver clean && make -C driver
make -C test_app clean && make -C test_app v4l2_test_app
```

## 8. 已知陷阱（務必記住）

1. **雙時脈 reg array 不會被推斷成 RAM**：`video_req_cdc` 曾用手寫 gray-pointer FIFO，
   512×128 直接變成 65k FF+mux 樹撐爆元件。已改 xpm_fifo_async；不要改回去。
2. **Verilog mode 下不能對 reg 做 continuous assign**：`fifo_wr_en/fifo_din`
   必須宣告為 `wire`（xvlog --sv 會過但 vivado synth 會炸）。
3. **IP cache 要保持 disabled**：否則偶發性四 IP 黑箱化（0 critical warning 地雷）。
4. **`m_axil_bar1_*` 的 bready/rready 是 dma_top 的輸出埠**，TB 不可接常數。
5. **TB 的 `usr_irq_seen` 需要 IRQ_CTRL=0x3** 才會有 MSI。
6. **engine 的 protocol_error_count 綁在 v_drop_cnt[0]**（BAR0 0x7C 顯示用），
   不是真的 drop counter——命名歷史因素。
7. **A50T 上 250MHz user clock 不存在也不需要**：Gen2 x4 解碼容量 2GB/s，
   128-bit@125MHz 已 1:1 匹配；瓶頸在前端而非時脈（詳見 wiki/A50T-NV12M 文件）。

## 9. 待辦優先序（給下一手）

1. **[P0] 修好 tb_video_cdc_system 重現的六包/同址/X 問題**（§5.4 步驟）。
2. [P0] 修好後：`run_sim.sh` 19/19 → clean build → 使用者燒錄 → 三條實機指令回饋。
3. [P1] 4K60 sustained gate ≥750 MiB/s（test app 已內建判定）。
4. [P1] 更新 wiki/A50T-NV12M-Implementation-and-Results.md 加入 150MHz checkpoint 結果。
5. [P2] TODO-ce0d326a 收尾（staged hardware artifacts）。
