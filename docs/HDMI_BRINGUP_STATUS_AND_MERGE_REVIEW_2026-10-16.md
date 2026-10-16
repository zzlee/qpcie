# HDMI Bring-up 階段報告與 Merge 評估

- 日期：2026-10-16
- 工作目錄：`/home/zzlee/vibecoding/qpcie-m2-720`
- 開發分支：`feat/m2-nuc100-i2c-slave`
- Merge 評估基準 HEAD：`372304f`；本輪 4K 修改與報告另依使用者要求保存為 WIP checkpoint（ID 見 `git log`），未推送
- 板卡：M2-710 / Artix-7 A50T；Jetson：`nvidia@192.168.191.32`
- 目前 FPGA：`C_VERSION=0x26101603`

## 1. 結論

**本階段先暫停開發；1080p baseline 已有實機成功證據，原生 4K60 RGB24 已打通資料通路，但尚未完成整體驗收。**

4K 長測的 18,000 個來源 frame-ID 連續，每幀 2160 行標記全部正確，平均 59.94 fps。
然而無標記畫面仍可見偏色／彩色輪廓，且 protocol error 計數異常，測試程式整體回傳失敗。
**不能只取 frame-ID 的 PASS，忽略最後的 FAIL，或宣稱完整 4K60 不掉幀已達成。**

**Merge 建議：不直接合併整支 feature branch；先整理 checkpoint、拆分 PR，保留 4K bring-up 為未完成工作。**
文件可獨立送審；1080p baseline 可評估獨立 PR，但必須先整理其前置依賴及共用程式回歸，
不能只盲目 cherry-pick 最後兩個 commits。

## 2. 已完成項目

| 項目 | 已有證據／結果 |
|---|---|
| IT68051 原生控制工具 | register clock、CAOF／工廠校準、EDID 校驗、TTL／I2S 設定、狀態回讀與格式檢查 |
| 實際 HDMI 輸入 | 3840×2160p60、VIC97、8-bit、BT.709 limited YUV444；不把降頻後解析度當成輸入解析度 |
| 1080p RGB24 baseline | RX 降頻／CSC → 單像素 SDR → FPGA → V4L2；取得目視正常的遊戲畫面 |
| 1080p 連續擷取 | `26101601` 上 3600 幀、60.061 秒、59.94 fps；當次錯誤計數 0→0 |
| Live ALSA baseline | `26101601` 上 48,128 frames，非零 PCM，左右聲道零交換錯誤，PASS |
| A50T driver 建置選擇 | `make clean && make QPCIE_A50T=1`，避免用 ZU4EV BAR1 map 存取 A50T 的 TPG／I2C／SPI |
| 4K 後端頻寬 | `26101601` 的 TPG RGB24：600 幀、66.85 fps、1586.37 MiB/s，TPG watermark 連續 |
| 4K FPGA 輸入路徑 | `26101603`：300 MHz PCLK 約束、IOB 暫存級、2048-beat async FIFO、idle drain、overflow 計數 |
| 輸入端診斷標記 | FIFO 前逐行插入來源 frame-ID／行號與 complement，可檢查後段漏幀、漏行、跨幀拼接 |
| 共用四角 watermark | 復用 `tpg_marker_overlay.v`，移至 TPG/HDMI mux 後，支援四角／中央色塊與 downstream frame counter |
| SPI 更新 | `26101603` 已經 PCIe 燒寫，2,192,012 bytes 全部逐位元回讀比對通過，再暖重載與確認版本 |

### 2.1 4K 硬體測試結果

| 測試 | 結果與限制 |
|---|---|
| 新版探針 | 實測 3840×2160、雙像素、PCLK 約 297.378 MHz，訊號鎖定 |
| Live 4K `-F` 600 幀 | frame-ID 連續、每幀全部 2160 行正確、當次錯誤計數 0→0；初測 PASS |
| Live 4K `-M -W` 600 幀 | 四角／中央值正確、downstream watermark 連續，59.94 fps；當次錯誤計數 0→0 |
| Live 4K `-F` 18,000 幀 | 300.312 秒、59.94 fps、1422.35 MiB/s；全部 frame-ID／逐行標記通過 |
| 上述長測的整體判定 | **FAIL：名為 frame-drop 的計數 0→3512，程式退出碼為 1** |
| FIFO overflow | 長測後、下一次 reset 前的探針讀值：dropped beats=0、dropped EOL=0 |
| 無標記 4K 圖片 | 可取得完整 24,883,200-byte RGB24 frame，轉為 3840×2160 PNG；**影像品質未通過** |

逐幀／逐行標記只覆寫每行前 4 個像素；四角 overlay 會覆寫部分相同區域，所以分開測試。
`-F` 強制關閉四角 overlay，並拒絕與 `-M/-W` 同時使用。

目前保留遊戲來源，沒有外部每幀唯一編號圖樣。
因此這些 ID 證據只涵蓋 **FPGA 取樣到的 VS/frame-ID → V4L2**，
不能證明來源端或 HDMI RX 在 FPGA 取樣之前沒有漏幀；標記也不是全畫面 CRC。

### 2.2 建置／時序與軟體回歸

- `26101603`：WNS **+0.108 ns**、WHS **+0.032 ns**、WPWS **0.000 ns**，bus skew 無違規。
- 有效使用的 50 個 data/DE/VS 輸入暫存器均放在 ILOGIC IFF。
- LUT 24840/32600（76.20%）、BRAM 59/75（78.67%）、DSP 45/120。
- 「所有已指定約束通過」**不等於板級 I/O timing sign-off**：仍缺有效的外部 input-delay／PCB skew 資料。
- driver 已做本機建置，A50T driver／工具亦在 Jetson 原生建置與載入；工具以 `-Wall -Wextra -Werror` 編譯。
- `make -C test_app test-it68051 test-hdmi-stamp` 通過；stamp parser 亦通過 ASan／UBSan 檢查。
- 真實 XPM 模擬通過：297 MHz 單／雙像素、1920/3840-pixel lines、IOB stage、stamp 開／關、TLAST、padding、AXIS stalls。
- idle drain、強制 FIFO full 的 loss counters、共用 corner overlay／bypass／flush、ICAP 命令序列回歸通過。
- **沒有宣稱本輪已重跑全部 system-level simulations 或所有其他板型的 Vivado／PetaLinux 建置。**

## 3. 尚未完成與風險

### P0：4K 原始畫面品質

`build/live4k-user-preview.png` 仍可見偏色及彩色輪廓／雜點，原因尚未確認。
後續應分別檢查 RX 輸出相位、CSC／量化、位元對齊、資料接腳及來源內容。
目前不能把問題直接歸因於其中一項，也不能用 FIFO 後插入的正確色塊證明原始像素正確。

### P0：錯誤計數的語義與重設行為

程式顯示的「Hardware Frame Drops」不是獨立的 lost-frame counter。程式碼追查路徑為：

```text
nv12_capture_engine.protocol_error_count
  → custom_pcie_dma_top.eng_err_count
  → telemetry CDC / v_err_sync_q
  → v_drop_cnt[0]
  → BAR0 0x007C / REG_VIDEO_ERRORS
  → V4L2_CID_QPCIE_FRAME_DROP_COUNT
```

此 counter 可能因 descriptor 格式／幾何、非預期 SOF、TLAST 位置不符而增加。
**3512 的增加原因仍未查清，不能解讀為 3512 個實際遺失影格。**

下一輪單幀擷取另觀察到 **3512→0**，app 使用 unsigned 差值後印成 `4294963784`，仍回傳 FAIL。
程式碼顯示 video engine 的 counter 與 PCIe 端 telemetry 副本有不同 reset／更新時機，需驗證其影響。
後續應區分真正 lost-frame、protocol error 與 reset epoch，修正取樣／差值邏輯，
但不能直接刪除錯誤檢查來讓測試變成 PASS。

### P1：新版回歸與覆蓋範圍

- `26101603` 尚待重新驗證 1080p 與 Live ALSA；過去成功結果屬於 `26101601` baseline。
- 尚待更長時間／溫度變化、啟停／拔插／重新開機恢復與音視訊同時擷取測試。
- 尚待 ZU4EV／其他使用共用 RTL 的板型建置與回歸；不能因 A50T 通過就宣稱其他板型安全。
- 目前 RGB24 profile 僅接受已驗證的 VIC97／8-bit／BT.709 limited YUV444 輸入。
  RGB 輸入、YUV420、deep color、HDR 或其他時序不能宣稱已支援。
- 原生 NV12 色彩路徑尚未完成；RGB profile 必須使用 RGB24 app。
- RX reset 後仍需 host 初始化；未驗證自動 cold-boot 到可擷取狀態。

## 4. 暫停時的環境與證據

- SPI／目前運行 FPGA 為 `26101603`；沒有改回 `26101601`。
- 最後將 RX 設為原生 4K RGB 雙像素，使用 Live HDMI；來源標記已關閉，最後設定 CTRL=03。
- 最後的 preview app 已結束，不是持續錄影服務；未再次切換回 1080p。
- 使用的 Jetson driver：`/home/nvidia/qpcie_dbg/driver-1080-validation/qpcie.ko`。
- 新工具：`/home/nvidia/qpcie_dbg/qpcie_it68051_4k_diag`、`v4l2_rgb24_4k_diag`。
- 燒錄前曾暫停該卡的 PulseAudio source；桌面音訊恢復狀態與新版 ALSA 留待下次確認。
- 未完成的 4K 原始碼以目前 feature branch 的 WIP checkpoint 保存；無關的 `raw/NUC100BSP` 未修改或刪除。

本機檔案（相對於工作目錄）：

| 類型 | 路徑 |
|---|---|
| 最新無標記截圖 | `build/live4k-user-preview.png` |
| 對應單幀原始 RGB24 | `build/live4k-user-preview.raw` |
| 四角標記截圖 | `build/live4k-corners.png` |
| SPI 燒寫／回讀 | `build/flash-26101603.log` |
| 重載／初始化 | `build/4k60-26101603-reload-init.log` |
| 600 幀來源標記 | `build/4k60-26101603-live-F600.log` |
| 600 幀四角／watermark | `build/4k60-26101603-live-corners.log` |
| 18,000 幀長測，整體 FAIL | `build/4k60-26101603-live-F18000.log` |
| preview 與 counter reset 誤判 | `build/4k60-user-preview.log` |
| BIT／BIN／XSA／時序／IOB 報告與 SHA256SUMS | `build/release-a50t-hdmi-26101603/` |

`build/` 是忽略的產物目錄，不會因提交 Markdown 而自動上傳；交接前應另外封存這些證據。
XSA 匯出有純 RTL 設計缺少 hardware handoff data 的警告，不應視為 PS／PetaLinux 完整交接檔。

SPIx4 BIN SHA256：

```text
4f99e847d638fdb4007c30d7e077b02fc1fd68273280952eb6f06640dc9e0eb0
```

## 5. Merge 到預設分支的評估

### 5.1 分支狀態（checkpoint 前的評估，本次已 fetch origin）

- GitHub 實際預設分支是 **`master`，不是 `main`**；本次不新增或重新命名分支。
- `origin/master`：`806bea7`（Docker-based Icarus Verilog testbench）。
- 目前 feature HEAD：`372304f`；其已提交歷史相對 `origin/master` 為 **99 個 feature-only、1 個 master-only commits**。
- 已提交差異涵蓋 **167 個檔案**，包括 A50T、MCU、ZU4EV、PetaLinux、共用 DMA RTL、driver 及產生的 PS/XSA 檔案，
  不是單純一個 HDMI feature PR。
- `git merge-tree --write-tree --messages HEAD origin/master` 回傳成功，已提交版本無文字合併衝突。
  **此檢查不包括目前未提交／未追蹤的 4K 修改，也不證明功能相容；未執行真正 merge。**

### 5.2 目前不建議整支 merge 的原因

1. 4K 畫面品質未解、長測整體 FAIL，尚不能作為已完成的 production feature。
2. `custom_pcie_dma_top.v`、`axil_reg_space.v`、`tpg_marker_overlay.v` 是共用 RTL，
   新介面／flush／overlay 位置更動需要其他板型與 system-level 回歸。
3. driver 存在不同板型 BAR1 layout；必須確認預設建置與明確 A50T 建置都符合目標板的介面契約。
4. `26101603` 是在 WIP checkpoint 之前由 working tree 建置並燒錄；checkpoint 保存來源，
   但不代表已完成 release，仍需連同 artifact checksum 保存可追溯紀錄，不能只依 C_VERSION 判定驗收。
5. 整支分支還帶有大量非本階段的 MCU／ZU4EV／PetaLinux 變更；這些未在本次 merge 評估逐項驗收。

### 5.3 建議的合併方式

| 範圍 | 建議 |
|---|---|
| 本報告與驗證紀錄 | 可作為獨立 documentation PR 先送審 |
| 可獨立的 parser／unit tests／打包檢查 | 整理成自足、可重現的小 PR；仍需確認 master 上的依賴 |
| A50T 1080p baseline | 整理 I2C／RX／driver／FPGA 前置依賴後獨立 PR，補上整合回歸，不盲目摘取最後兩個 commits |
| 本輪原生 4K／共用 overlay | 保留 feature branch／WIP checkpoint；完成 P0 問題與跨板型回歸前，不當作已完成功能 merge |
| 其他 MCU／ZU4EV／PetaLinux 歷史 | 分開整理與 review；不要因 HDMI 階段成果而順帶整批合併 |

### 5.4 正式功能 merge 前的最低清單

- [x] 依使用者要求將本輪 source／測試／文件保存為本地 WIP checkpoint，排除無關 BSP 與 build artifacts。
- [ ] 修正或充分定位 4K 原始畫面異常，取得可確認的像素／色彩證據。
- [ ] 修正 counter 的語義／reset 差值問題，查清 3512 的來源，不能只忽略 FAIL。
- [ ] 重跑 18,000 幀或更長測試：frame-ID／逐行、FIFO loss、protocol error、app exit code 全部符合驗收標準。
- [ ] 在同一候選 bitstream 上回歸 1080p、TPG、Live ALSA、啟停與重新初始化。
- [ ] 對共用 RTL 重跑相關 system-level tests，驗證受影響板型的建置；保留 master 的測試基礎設施。
- [ ] PR 說明清楚標示支援格式、未驗證項目、板級 I/O timing 限制及重現方式。

報告整理後，依使用者要求將本輪未完成修改保存為 **WIP checkpoint commit**。
**未 merge、未 rebase、未切換分支、未推送；checkpoint 不代表 4K 已通過驗收。**

## 6. 下一輪恢復工作的順序

1. 保留目前 log／raw／PNG 與 bitstream，從本分支的 WIP checkpoint 恢復工作；需要跨機器交接時再推送或封存。
2. 優先定位 4K 畫面品質，再分離與修正 counter 問題。
3. 重跑完整長測及新版 1080p／ALSA 回歸；需要端到端證明時，再提供外部逐幀編號來源。
4. 通過後整理 release 與拆分 PR，重新評估是否 merge 到 `master`。

相關紀錄：

- [1080p 實機驗證](../wiki/HDMI-1080P-LIVE-VALIDATION.md)
- [4K60 RGB24 技術紀錄](../wiki/HDMI-4K60-RGB24-VALIDATION.md)
- [26101601 初次交接](../wiki/HDMI-RX-BRINGUP-26101601.md)
