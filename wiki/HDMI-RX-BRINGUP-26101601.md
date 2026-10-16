# M2-710 HDMI RX 接手紀錄 — 26101601

> **後續實測已更新：** [Live 1080p V4L2 驗證](HDMI-1080P-LIVE-VALIDATION.md)。
> 26101601 已透過 PCIe 燒錄並回讀驗證；調整 RX C4=00、C2=08，使用 A50T map driver
> 與 **RGB24 app** 後，已取得真實遊戲畫面及連續 3600 幀。本頁以下保留最初交接時的狀態；
> 舊的 NV12 app 指令不適用於 RGB downscale profile。

## 已證實／尚未證實

2026-10-15 在 Jetson `192.168.191.32`，使用本倉庫的
`qpcie_it68051_tool.c` 原生編譯版本完成測試；不需要下載的參考驅動才能初始化。

| 項目 | 結果 |
|---|---|
| MCU | VER=5；本輪未修改／燒寫 MCU |
| IT68051 | Device=6805、Rev=B1；Reg13=BF、Reg19=BE，clock/IPLL/H2V/SCDT 鎖定 |
| 實際 HDMI 輸入 | 3840×2160p60，VIC 97，8-bit BT.709 limited YUV444 |
| RX 降頻輸出 | 單像素 SDR、RGB、1920×1080p60；設定暫存器回讀通過 |
| PL 探針（舊 bitstream 26101501） | PCLK 約 148.689 MHz、60 fps、I2S SCK/DATA 活動、WS 約 48109 Hz |
| **Live HDMI → DMA → ALSA** | **48128 frames，左右聲道零交換錯誤，非零 PCM，PASS** |
| **Live HDMI → DMA → V4L2** | **尚待新 bitstream 燒錄後實測；不能以 TPG PASS 代替** |

舊 bitstream 的探針固定以每時脈兩像素計算寬度，所以在 RX 單像素輸出時會顯示
`3840×1080`。這不是已擷取到 3840×1080 的證據。新版 bitstream 增加單像素模式，
才應顯示 `1920×1080`。

原始實機日誌保留於 Jetson：

- `/home/nvidia/qpcie_dbg/it68051-native-downscale.log`
- `/home/nvidia/qpcie_dbg/it68051-native-settled.log`
- `/home/nvidia/qpcie_dbg/it68051-live-alsa.log`

該次 ALSA 摘要：

```text
Audio Capture Finished: 48128 frames (1.00 sec)
Left/Right Channel Sync : PERFECT (0 swap errors)
AES3 Signal Status      : ACTIVE (Energy & Framing Verified)
Verdict                 : PASS
```

2026-10-16 再接手時 SSH 回覆 `No route to host`。以上是前次實測結果，
不是對目前板卡開機狀態的推測。已部署工具名為
`/home/nvidia/qpcie_dbg/qpcie_it68051_opencode`，避免覆寫原本的診斷執行檔。

## 已修正的根因

- **ACK 不等於設定生效**：B0:20[4] 為 1 時，B0:69 寫 20 回讀仍為 00；
  清除時鐘閘後同樣寫入可回讀 20。初始化及 register reset 後均需開啟 register clock。
- 加入 Port-0 CAOF（實測 IRQ08=13、PASS）及工廠 oscillator 校準讀值。
  本板工廠資料為 36734 kHz；據此設定 watchdog、1 µs 和 B1 SCDC timers，
  不再套用其他晶片的固定門檻。此為工廠校準資料，不是外部儀器量測。
- 不可將 B3:A7 整個覆寫為 40：保留校準與 PLL/phase 位元；HDMI 的
  B3:3A EQ mode 為 02，04 是 MHL，不是 HDMI2。
- B0:26 是 **active-high power down**，不可用 FF「解除 reset」。
- 新版 B1 參考流程的 auto-mute/data gate 位於 B0:4F[7]/[5]；
  B1:B0 是 DE regeneration，不是 PCLK gate。
- 垂直時序正確來源為 A2/A3=VTotal、A4/A5=VActive。
- EDID PA offset 隨表而變（FHD=99、4K=A5），不可填 00 以免替換 EDID header。
  工具校驗 254 RAM bytes、兩個獨立 DDC checksum registers 和 PA registers。
- BAR0 在未鎖定時回傳的 1920×1080／148.5 MHz 是**可設定的 fallback**，
  不是探針實測值。工具已明確標示。`--monitor` 現為 passive，不會持續重置 EQ/PLL。
- 偶爾觀察到 MCU STATUS 的保留位元非零（例如 85）；這種 sample 不應解讀為有效
  pin telemetry。工具會警告；本輪 RX lock 判定依 IT68051 和 PL 探針，不依該值。

## RTL／版本

`C_VERSION=26101601`：

- BAR0 `0610[3]`：0=雙像素、1=單像素；`[2]` 仍為 capture FIFO reset。
  切換 pixel mode 時先 assert FIFO reset，再解除，避免混入舊格式資料。
- `hdmi_dual_pixel_bridge.v` 支援 1/2 pixels per clock，輸出仍為 128-bit、4 PPC BGRA。
  修正每行寬度可被 4 整除時未送出 `TLAST` 的問題；保留最後一個完整 word 到 DE falling edge。
- `hdmi_rx_probe.v` 依單／雙像素模式計算寬度。
- `spi_flash_controller.v` 的 ICAPE2 從 125 MHz 改成 62.5 MHz，使用 BUFG 與 generated-clock
  約束，word/control 在該時脈 falling edge 準備。

**26101502 候選不可燒錄**：其 setup WNS=0.067 ns、hold WHS=0.032 ns，
但既有 ICAPE2 最小週期違規為 −2 ns。該次產物僅留作除錯紀錄，
`build/release-a50t-hdmi-26101502/DO_NOT_FLASH.txt` 已標示。

## 軟體／模擬回歸

```bash
cd test_app
make test-it68051
make all
```

`test-it68051` 檢查兩份 EDID checksum/PA、錯誤 CTA 邊界及不支援的色彩／時序拒絕。
`qpcie_it68051_tool.c` 另以 `-Wall -Wextra -Werror` 編譯通過；本機 driver 與 test_app 均已 clean build。
本機 `.ko` 是本機 kernel 版本，不能直接拿到 Jetson 載入。

```bash
source /opt/Xilinx/Vivado/2023.2/settings64.sh
vivado -mode batch -source scripts/sim_hdmi_pixel_bridge.tcl
vivado -mode batch -source scripts/sim_spi_icap_clock.tcl
tclsh tb/a50t_timing_gate_test.tcl
```

必須看到三個 `TB_PASS`：

- 真實 XPM async FIFO：單／雙像素、兩幀、1920-pixel lines、RGB/pixel order、
  SOF/TLAST、partial-word padding、AXIS backpressure。
- ICAP protocol monitor：16 ns clock period、byte bit-swap、8-word IPROG sequence、
  BUSY 時拒絕重複命令、完成後再次觸發。此測試不模擬 FPGA 實際重配置效果。
- 發佈時序 gate：拒絕負 setup／hold／pulse-width slack 和無法解析的報告；
  已用實際 26101502 報告驗證會拒絕其 −2 ns ICAP 違規。

## 發佈與硬體交接

2026-10-16 `26101601` build/package 已完成，**尚未燒錄**：

- Setup WNS **+0.094 ns**、Hold WHS **+0.027 ns**、WPWS **0.000 ns**，失敗 endpoints 均為 0。
- ICAPE2 最小週期：requirement 10 ns、actual **16 ns**、slack **+6 ns**。
- LUT 24807/32600（76.10%）、BRAM 53.5/75（71.33%）、DSP 45/120。
- 這是「所有已指定約束通過」；報告仍有 58 個 no-input-delay、6 個 no-output-delay
  警告，**不是完整板級 I/O timing sign-off**，仍需實際擷取／色彩／穩定性驗證。

SHA256：

```text
5970fb0512e10a97d5b53ca53c11b3081041fd9f3867303f9c64a6487a0bd2ea  a50t_pcie_card_top.bit
f9aac9eb4eadc42458a7436866fa821881127d0f64a321ee6e679409c258f188  a50t_pcie_card_top_spix4.bin
```

```bash
./scripts/build_a50t.sh
source /opt/Xilinx/Vivado/2023.2/settings64.sh
vivado -mode batch -source scripts/package_a50t_hdmi.tcl
```

打包工具必須通過 setup／hold／pulse-width gates，才會匯出：

```text
build/release-a50t-hdmi-26101601/a50t_pcie_card_top.bit
build/release-a50t-hdmi-26101601/a50t_pcie_card_top_spix4.bin
build/release-a50t-hdmi-26101601/a50t_pcie_card_top.xsa
```

此設計是純 RTL Artix-7，不含 PS/BD；XSA 不具有 PetaLinux 的 PS hardware handoff。
打包不連硬體、不燒錄。依 AGENTS.md，由使用者執行 `./scripts/flash_a50t.sh` 並重新開機／載入
Jetson driver，代理程式不自行燒錄。

恢復 Jetson 連線並確認已燒錄 **26101601** 後，使用最新版工具：

先停止擷取及其他會存取此卡 I2C／HDMI 控制暫存器的 daemon/tool。
此診斷工具直接使用 BAR MMIO，不會取得 kernel I2C adapter mutex，
不可與其他 I2C 使用者並行切換 IT68051 bank。

```bash
sudo /home/nvidia/qpcie_dbg/qpcie_it68051_opencode --probe
sudo /home/nvidia/qpcie_dbg/qpcie_it68051_opencode --init --downscale-1080p --mux-hdmi
sudo /home/nvidia/qpcie_dbg/qpcie_it68051_opencode --probe
sudo timeout 20 /home/nvidia/qpcie/test_app/v4l2_test_app --frames 10
sudo timeout 10 /home/nvidia/qpcie/test_app/alsa_test_app -s 1
```

要求：single pixel、CTRL=0B、1920×1080、60 fps、PCLK 約 148.5 MHz；
V4L2 取得 10 幀，另外確認畫面內容／色彩，不只檢查 buffer 完成；ALSA 非零 PCM、左右同步。
若需回到 TPG，`--mux-tpg`；切回 `--mux-hdmi` 會清 capture FIFO 並保留 pixel-mode 位元。

目前降頻 profile 僅接受 **VIC97、BT.709 limited YUV444、8-bit**；RGB/YUV420、deep color、
其他幀率會被拒絕，不能宣稱所有 4K/HDMI 格式皆已支援。FIFO 長時間塞滿的恢復、
長時間擷取及拔插恢復仍需硬體驗證。RX reset 後仍需 host 初始化，並非 MCU 自動執行。

## 原始資料

- `~/llm-wiki/raw/IT68051 Programming Guide.release.v0.11_YUAN.pdf`
- `~/llm-wiki/raw/M2_710_N1_HDMI_4KP60_V21/M2 710 N1 HDMI 4KP60 V21_ROHS2_YUAN_DSN-S.pdf`
  sheet 4：SM1（HPD pull-down MOS）、SR39（IT68051 CBUS_HPD 路徑）均標為 NC。
  **實際 population 要另行確認**；寫 MCU CTRL 成功不能證明 HPD 腳位真的有變化。
- 對照用 IT6805 MCUSRC 1.31（2019-03-05）：
  `https://github.com/Qiuzixing/IP5000-A302/tree/b7f61f612672301979b6f062129f8ffd0163c45d/modules/ast_modules/it6805`
  臨時移植對照測試產生過 lock/ALSA 證據，但新版 native tool 不依賴這些暫存參考檔案。
