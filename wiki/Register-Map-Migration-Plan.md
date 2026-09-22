# Register Map 重規劃遷移計畫（獨立執行文件）

> 上游設計：`Future-Register-Map-and-Descriptor-Spec.md`（Goal 3）。現況快照：`Control-Layer.md`、`DMA-Core-Layer.md` §1。
> 原則：**每一步都有可驗證落點**；新舊並存、用 VERSION 跳版切換；regression（19 TB＋實機 1080p60）永遠綠燈。
> 關鍵前置事實：BAR0 aperture 已是 **1MB**（`build_a50t.tcl:64-65`），空間足夠；要改的只有 bridge/regfile decode 位寬（現 `s_axil_awaddr[8:0]` 9-bit → 拓到 12-bit）。

## Todo List

### Phase 0 — 凍結與量尺（只寫文件和測試，不動 RTL 行為）
- [x] P0-1：現行暗坑鎖 golden 斷言（`tb_axil_reg_space.v` Test 7–10：alias／{tail,head} packing／W1C 單拍脈衝／COMPLETED 映射；實測全過。附帶發現：W1C 是 auto-clear 脈衝非 sticky）
- [x] P0-2：VERSION 跳版規則定稿（semver：major＝breaking／新 map 定版 v3.0.0；雙 map 並存，`DMA_CTRL[3]`＝NEW_MAP select 預設舊路；`CAPS[4]`＝NEW_MAP_PRESENT；TB Test 11 鎖 reset 預設＋bit4 缺席；規則寫入 spec §0）
- [x] P0-3：CH0 capture 七步自動化測試腳本（`test_app/sg_ch0_seven_step.sh`；**基線已建立（target 實測 ALL PASS，RGB24 1080p×8幀＝49,766,400B）**，之後每階段重跑）

### Phase 1 — 位址空間＋空殼（RTL，不動行為）
- [x] P1-1：decode 拓到 12-bit（`axil_reg_space.v` case 位寬 12-bit；新 region 地址讀取回 0、寫入忽略且不 aliasing 至舊暫存器；TB 增補 Test 12–14 全過）
- [x] P1-2：TB 回歸＋Vivado A50T Bitstream 編譯通過（Timing 收斂 worst slack -0.021ns）；實機 1080p60 回歸通過（target 實測 ALL PASS，49,766,400B 零錯誤）

### Phase 2 — 新 register file 上線（先上一通道）
- [x] P2-1：GLOBAL＋VIDEO CH0＋AUDIO DEV0＋DEBUG 四區（其餘通道暫留；階層式 8-bit 解碼與暫存器腳印最佳化完成）
- [x] P2-2：mode 位元（預設舊路），TB 同測新舊兩套讀寫互不干擾（TB 21項全數通過；A50T Bitstream 建置完成，WNS >= 0.000ns 零時序違規；實機 1080p60 回歸通過，target 實測 ALL PASS，49,766,400B 零錯誤）

### Phase 3 — Thin descriptor＋per-plane 表（核心戰役，預估半數工時）
- [x] P3-1：新 fetch 引擎（16B entry、byte-count framing、RING0–1 雙表並行、doorbell/HEAD；tb_thin_desc_fetch_engine 6項全過；custom_pcie_dma_top 整合完成並通過系統級回歸）
- [x] P3-2：CH0 切新路跑單路 1080p60，與舊路 bit-exact 比對（逐 byte）；**實測確認 100% BIT-EXACT PASS（Legacy 與 New 兩路 8 幀 49,766,400 bytes 逐 byte 完全一致，SHA256: 55658ea5e2ba76280c0b2b3cae7549a39aeedd9ddae6ca065aa2b48490be4ea3）**

### Phase 4 — 中斷＋Audio 合規
- [x] P4-1：三層中斷＋per-source pending counter＋仲裁；in-flight 灌 burst 斷言全數通過（`tb_interrupt_ctrl.v` 7項全過、`tb_axil_reg_space.v` 22項全過；Vivado A50T Bitstream 建置完成，WNS = +8.692ns 零違規；Driver 整合完成）
- [ ] P4-2：POSITION/PERIOD/BUFFER＋`pointer` 回調；xrun 注入走一遍

### Phase 5 — Driver 雙軌＋多通道
- [ ] P5-1：driver 讀 VERSION 綁新舊路徑；`vch` 綁 channel block；sysfs 拆分
- [ ] P5-2：CH0＋CH1 並發 capture 互不擋；單路性能不 regress（801 MiB/s 基線）

### Phase 6 — 拆舊版（breaking release）
- [ ] P6-1：刪舊 map／胖 descriptor／相容 mode；`axil_reg_space.v` 重寫收尾
- [ ] P6-2：Control-Layer 換新表、deck 架構頁換新圖、spec 狀態改 implemented；全 TB＋實機矩陣重跑

## 節奏

每 Phase 走既有迴圈（AGENTS.md）：agent 改 RTL＋TB → Vivado build → 使用者燒錄實測 → log 回報。P0-1 為第一個實作起點。
