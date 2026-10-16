# A50T / M2-710：原生 4K60 RGB24 驗證紀錄

> **本階段已暫停，完整成果與 merge 評估見：**
> [2026-10-16 階段報告](../docs/HDMI_BRINGUP_STATUS_AND_MERGE_REVIEW_2026-10-16.md)。
> 26101603 已燒錄；18,000 幀來源標記通過，但 protocol error 計數導致整體 FAIL，
> 原始畫面也仍有偏色／彩色輪廓，不能宣稱整體驗收完成。

## 目標與目前狀態

目標：3840×2160p60 HDMI → IT68051 雙像素 RGB SDR → FPGA → PCIe Gen2 x4 → V4L2 RGB24。
有效影像 payload 為每幀 **24,883,200 bytes**，60 fps 需 **1,492,992,000 bytes/s**。

2026-10-16，目前可確定的硬體證據：

- 1080p baseline `26101601`：3600 幀／59.94 fps，見 [1080p 紀錄](HDMI-1080P-LIVE-VALIDATION.md)。
- 相同 FPGA 的 **4K RGB24 TPG**：600 幀、平均 66.85 fps、1586.37 MiB/s，
  畫面內 TPG 編號連續。這只驗證後端，不代表 Live HDMI 已通過。
- 直接用 `26101601` 接原生 297 MHz 雙像素：探針讀值不穩，10 幀測試在第 8 幀後逾時。
  該 bitstream 的 PCLK 約束只有 148.5 MHz，**不能用來宣稱可靠的 Live 4K 接收**。
- `26101603` 建置／嚴格時序檢查已通過，PCIe Flash 燒寫與全部 2,192,012 bytes 回讀比對通過，
  暖重載後版本確認正確；**尚未宣稱完整 4K 不掉幀與影像品質達成**。
  `26101602` 的中途 build 已取消，改納入使用者要求的共用四角 overlay；不作發佈或燒錄。

使用者已授權：嚴格時序 gates 通過後，可經 SSH／PCIe 燒寫 SPI、完整回讀比對，再暖重載 FPGA。
來源先保留目前遊戲，不提供外部逐幀編號圖樣。

建置證據：WNS **+0.108 ns**、WHS **+0.032 ns**、WPWS **0.000 ns**，
bus skew 無違規；PCLK 約束為 3.333 ns。50 個有效 data/DE/VS 輸入暫存器均在 ILOGIC IFF。
LUT 24840/32600（76.20%）、BRAM 59/75（78.67%）。
產物與報告在 `build/release-a50t-hdmi-26101603/`。

SPIx4 BIN SHA256：

```text
4f99e847d638fdb4007c30d7e077b02fc1fd68273280952eb6f06640dc9e0eb0
```

## 新候選的變更

- PCLK 約束改為 **300 MHz / 3.333 ns**，不再以 1080p 的時脈約束實作 4K 路徑。
- 新增 `hdmi_parallel_input.v`：資料、DE/VS/HS 在 IOB 取樣一級，再送至同時脈的 bridge／probe。
- HDMI async FIFO 從 512 增至 2048 beats（130-bit、32 KiB pixel payload）。
- 沒有 descriptor active 時持續排空 FIFO，避免尚未 STREAMON 就先塞滿。
  有 descriptor 時仍保留 AXIS backpressure；若停頓超過容量，明確累計丟棄 beat／EOL，不能宣稱無限緩衝。
- BAR0 `0610[4]` 可啟用診斷標記，**覆寫每行最前面的 4 個像素**。
  ID 在 PCLK domain 按原始取樣 VS 邊緣遞增，標記在 CDC FIFO 前插入，不使用 DMA 完成數偽造來源 ID。
- BAR0 新增 Gray-code CDC 診斷計數：

| 位址 | 內容 |
|---|---|
| 0680 | 取樣 VS frame count |
| 0684 | DE 行數 |
| 0688 | FIFO full 丟棄的 beat 數 |
| 068C | FIFO full 丟棄的 EOL 數 |

上述計數會在 HDMI FIFO reset（0610[2]）時重設；不包括 reset-busy 期間主動丟棄的資料。
各計數獨立跨時脈，讀值不是同一時間點的原子 snapshot。

### 共用四角 watermark（依使用者要求）

既有 `tpg_marker_overlay.v` 從 TPG 專用路徑移到 **TPG/HDMI mux → overlay → capture engine**。
不重複增加另一份 overlay；原本的 V4L2 overlay 控制／`-M -W` 介面保留。
四角分別為紅／綠／藍／黃，中央為洋紅，另在 (8,0) 放上 16-bit downstream frame watermark。
關閉時保留原始像素，只增加 registered skid buffer 的延遲。

Live HDMI descriptor 不 active 時，flush skid buffer 的舊資料，但保留 watermark frame counter，
避免 descriptor 間隙把計數器重設成同一數字。這是後端空間／資料排列診斷，不能取代 FIFO 前的來源 ID。
兩種模式會覆寫相同區域，所以 **`-F` 強制關閉四角 overlay，且拒絕與 `-M/-W` 同時使用**。

**輸入 I/O 的限制：** 新 IOB 暫存級與 300 MHz 內部時序檢查，不等同完整板級 setup/hold sign-off。
仍缺 IT68051 實際輸出時序／PCB skew 的有效 input-delay 數值，不能用 IT68050 的 162 MHz
規格代替 IT68051 的 297 MHz 規格，也不能填入任意 input-delay 數值來掩蓋警告。

## 每行診斷標記與 fail-closed 檢查

RGB24 前 12 bytes：

```text
A5  IDlo IDmid  IDhi ROWlo ROWhi  ~IDlo ~IDmid ~IDhi  ~ROWlo ~ROWhi 5A
```

`v4l2_rgb24_test_app -F` 要求：

1. 每幀 payload 長度及 V4L2 sequence 正確。
2. 全部 2160 行都有正確 header、complement 與行號。
3. 同一幀的所有行使用相同 24-bit ID，避免跨幀拼接。
4. 下一幀 ID 必須精確加一（24-bit wrap 除外）；遺失、重複或倒退立即失敗。

這驗證的是**取樣到 FPGA 的 frame ID 到 V4L2** 的連續性。
它不是全畫面 CRC，也不能證明外部來源／HDMI RX 在 FPGA 取樣之前沒有漏幀。
最終端到端驗證仍需外部來源每幀唯一的圖樣／編號；目前使用者選擇先維持遊戲。

## 軟體與模擬回歸

```bash
make -C test_app test-it68051 test-hdmi-stamp
source /opt/Xilinx/Vivado/2023.2/settings64.sh
vivado -mode batch -source scripts/sim_hdmi_pixel_bridge.tcl
vivado -mode batch -source scripts/sim_hdmi_fifo_policy.tcl
vivado -mode batch -source scripts/sim_hdmi_corner_overlay.tcl
```

- 297 MHz 輸入／150 MHz 輸出、IOB stage、單／雙像素、1920/3840-pixel lines、
  標記開／關、TLAST、padding、AXIS stalls。
- idle drain、強制 FIFO full 時的 beat/EOL loss counters、恢復 drain。
- HDMI bridge → 共用 corner overlay：RGB 四角／中央、watermark、bit-exact bypass、AXIS stalls，
  以及 flush 丟棄舊 skid 資料但保留 frame counter。
- host parser 拒絕錯誤 marker、漏行、torn frame、重複／跳號 ID，接受正常 wrap。

## 實機結果與後續重現

- Live 600 幀來源標記初測通過；Live 600 幀四角／watermark 通過，59.94 fps。
- `-F` 18,000 幀：300.312 秒、59.94 fps；所有 frame-ID 連續、每幀全部 2160 行標記正確。
  但「frame-drop」計數 0→3512，**app 整體退出碼為 1**。程式碼確認此欄實際來自 capture engine
  `protocol_error_count`，不是獨立的 lost-frame 計數；3512 的原因尚未查清。
- 下一輪單幀擷取又觀察到 3512→0，被 unsigned 差值誤判成增加 4294963784；需修正 reset 語義。
- 長測後、下一次 reset 前，bridge dropped beats／dropped EOL 均為 0。
- 無標記原始圖片 `build/live4k-user-preview.png` 仍有偏色／彩色輪廓，影像品質待查。

以下指令供後續重現，**不是目前已保證全部 PASS 的驗收流程**。

driver 仍使用 `make clean && make QPCIE_A50T=1` 版本。
Jetson 新工具使用 `_4k_diag` 名稱，保留已驗證的 1080p 執行檔。

```bash
sudo /home/nvidia/qpcie_dbg/qpcie_it68051_4k_diag --native-4k-rgb --mux-hdmi --frame-stamp
sudo /home/nvidia/qpcie_dbg/qpcie_it68051_4k_diag --status --probe
sudo /home/nvidia/qpcie_dbg/v4l2_rgb24_4k_diag -w 3840 -h 2160 -f 600 -F
# 通過後延長到 18000 幀，記錄 frame IDs／計數／FPS，並另外保存未加標記的真實畫面。
```

要求 C_VERSION=26101603、CTRL=13、雙像素、3840×2160、約 297 MHz；
以獨立 wall-clock 吞吐量與 frame-ID 共同驗證，不只看探針的短時間 FPS 值。
`--native-4k-rgb` 僅接受 VIC97／8-bit／BT.709 limited YUV444 輸入，經 CSC 輸出 RGB24。

關閉標記或回復 baseline（停止擷取後執行）：

```bash
sudo /home/nvidia/qpcie_dbg/qpcie_it68051_4k_diag --no-frame-stamp
# 另做共用四角／watermark 測試（只能驗證後端，不證明 FIFO 前不掉幀）：
sudo /home/nvidia/qpcie_dbg/v4l2_rgb24_4k_diag -w 3840 -h 2160 -f 600 -M -W
sudo /home/nvidia/qpcie_dbg/qpcie_it68051_4k_diag --downscale-1080p --mux-hdmi
```
