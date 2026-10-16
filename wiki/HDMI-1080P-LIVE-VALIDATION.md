# M2-710 / A50T：Live HDMI → V4L2 1080p 已取得畫面

## 2026-10-16 實機結果

Jetson `nvidia@192.168.191.32`，FPGA `C_VERSION=26101601`。
本輪僅修正 host 軟體與 RX 設定，**沒有修改 RTL，也沒有再次燒寫 Flash**。

```text
3840×2160p60 HDMI（8-bit BT.709 limited YUV444）
  → IT68051 downscale + YUV-to-RGB CSC
  → 1920×1080p60 / 148.5 MHz single-pixel SDR TTL
  → FPGA bridge / packed RGB24 DMA
  → V4L2_PIX_FMT_RGB24 / 1920×1080 / stride 5760
```

| 測試 | 結果 |
|---|---|
| 真實畫面擷取 | 10 幀，每幀 6,220,800 bytes；轉 PNG 可辨識 Mario Kart 賽道／Yoshi／HUD，目視色彩正常 |
| 600 幀 | 10.014 秒，59.91 fps；硬體錯誤計數 0→0 |
| 3600 幀 | 60.061 秒，59.94 fps；無 timeout／sequence warning，硬體錯誤計數 0→0 |
| 加入 payload 長度檢查的最新版 app | 600 幀，59.92 fps，硬體錯誤計數 0→0 |
| Live ALSA | 48,128 frames，非零 PCM，左右聲道零交換錯誤，PASS |

畫面檔：本機 `build/live1080-rgb24.png`；最新版 app 的另一張截圖已保存在
本機 `build/live1080-rgb24-verified.png` 及 Jetson
`/home/nvidia/qpcie_dbg/live1080-rgb24-verified.png`。
原始 10 幀位於 Jetson
`/home/nvidia/qpcie_dbg/live1080-rgb24.raw`。測試使用 live mux `CTRL=0x0B`，
不是 TPG。遊戲畫面有重複影格不能單憑 hash 判定擷取失敗；沒有外部 source frame counter，
上述結果也不是逐來源幀無遺失、像素精度／色度校正或長時間壓力測試的證明。

## 這次修正的三個問題

### 1. RX 輸出時脈相位

先前 B1:C4=`B0`（invert=1、delay=3）雖然讓獨立探針量到 1080p60，
Live 擷取仍逾時。擷取中 BAR0 `0088` 有 SOF、`0090` 有數十萬 beats，
但 **`008C`（已接受 TLAST）一直為 0**。

相同 FPGA 在 TPG 下可完成 60 幀，計數符合每幀 1080 個 TLAST。
對已實作的 bridge netlist 另做功能模擬，1920-pixel lines 的 TLAST/SOF 也正確。
把 RX 的 **B1:C4 改為 `00`** 後，Live 擷取即可完成。

因此 148.5 MHz 的 downscale profile 現固定使用非反相、delay=0，並回讀驗證。
這是實機相位設定的修正，**不是所有板卡／297 MHz 的完整 I/O timing sign-off**；
不得沿用此結果宣稱 4K60 雙像素輸入已驗證。

### 2. RGB 不能直接當作 YUV444 餵 NV12 engine

先前 `--downscale-1080p` 產生 RGB，卻以 `v4l2_test_app` 的 NV12M 路徑擷取。
通過 DMA 仍會出現綠／紫偏色。此次改用現有 packed RGB24 engine 與
`v4l2_rgb24_test_app`，不把 RGB 誤標為 YUV。

bridge 的原始 byte 排列是 B,G,R；新增 **B1:C2[3:2]=10**（R/B swap，R/G swap 關閉），
讓 RX 實際輸出配合 bridge，最終 host 收到的是 V4L2 RGB24 要求的 **R,G,B**。
`--status` 現會列出 C4、C2 及輸出 color mode。

**此 profile 應使用 RGB24 app，不應使用 NV12M app。** 原生 NV12 色彩轉換尚未完成驗證。

### 3. driver 的板型 BAR1 map 不同

Jetson 原本舊 driver 有 A50T map，但缺少 RGB24；倉庫新版 driver 的預設 map 是 ZU4EV。
直接載入新版會把 TPG 設定寫到 A50T 的 FRONT-I2C，導致 readback mismatch／I2C 問題。

加入明確的建置選項，預設 ZU4EV 行為保持不變：

```bash
cd driver
make clean
make QPCIE_A50T=1
```

| BAR1 | A50T (`QPCIE_A50T=1`) | 預設 ZU4EV |
|---|---|---|
| TPG | 0000 | 3000 |
| FRONT-I2C | 3000 | 4000 |
| SPI/ICAP | 4000 | 5000 |

**切換建置模式要先 `make clean`。** 不可拿本機 x86 kernel 的 `.ko` 去 Jetson 載入。

## Jetson 重現方式

本輪未覆寫 `/home/nvidia/qpcie/driver/qpcie.ko`，目前載入的是：
`/home/nvidia/qpcie_dbg/driver-1080-validation/qpcie.ko`。
停止其他擷取／I2C 工具後，必要時先卸載舊 driver，再載入：

```bash
sudo insmod /home/nvidia/qpcie_dbg/driver-1080-validation/qpcie.ko
sudo /home/nvidia/qpcie_dbg/qpcie_it68051_opencode --init --downscale-1080p --mux-hdmi
sudo /home/nvidia/qpcie_dbg/qpcie_it68051_opencode --status --probe
sudo /home/nvidia/qpcie_dbg/v4l2_rgb24_test_app -f 600
# 另存 10 幀；raw 檔案約 62 MB，不建議長時間全寫入。
sudo /home/nvidia/qpcie_dbg/v4l2_rgb24_test_app -f 10 -o /home/nvidia/qpcie_dbg/live1080-rgb24.raw
```

應看到：FPGA single pixel、CTRL=0B；RX C4=00、C2=08、RGB444。
`--status` 的輸入 timing 仍是 3840×2160，FPGA 探針是降頻後的 1920×1080。
剛完成 RX reset／切換設定時，探針短時間統計可能尚未回到 60 fps。

```bash
ffmpeg -f rawvideo -pixel_format rgb24 -video_size 1920x1080 \
    -i live1080-rgb24.raw -frames:v 1 live1080-rgb24.png
```

診斷工具與 app 已在 Jetson 原生以 `-Wall -Wextra -Werror` 編譯。
本機已重編 driver 的預設與 A50T 兩種配置，`make test-it68051`、test_app build 均通過。
原始日誌保存在本機 `build/live1080-*.log`（build artifacts，不提交 Git）。
3600 幀、最新版 600 幀及輸出檔案檢查的日誌也已複製到 Jetson
`/home/nvidia/qpcie_dbg/`。TPG RGB24 的 60 幀回歸亦通過，完成後已切回 Live HDMI。

## 下一階段：原生 4K

以此次可重現的 RGB24 1080p 路徑作為 baseline，再驗證 RX 的雙像素輸出、
297 MHz source-synchronous 取樣與 I/O 約束，以及 FPGA／PCIe 的吞吐量。
不直接移除 downscale 就宣稱能擷取 4K，也不以 TPG 4K PASS 代替 Live HDMI 4K。
