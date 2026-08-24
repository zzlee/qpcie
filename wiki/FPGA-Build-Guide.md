# Artix-7 A50T FPGA Build 與 SPI Flash 指南

## 1. 目標

- Part：`xc7a50t-csg325-2`。
- PCIe：7-Series Integrated Block (`pcie_7x_0`)，Gen2 x4，128-bit stream。
- SPI flash：Macronix MX25L12872F。
- Vivado：2023.2。
- Top：`rtl/a50t_pcie_card_top.v`。

## 2. 產生的主要 IP

`scripts/build_a50t.tcl` 會建立：

1. `pcie_7x_0`。
2. `v_tpg_0`：4 PPC、max 3840×2160、YUV444 capable。
3. `axi_clock_converter_tpg`：BAR1 AXI-Lite 125→150 MHz。
4. RTL MMCM wrapper `video_clock_gen.v`：125→150 MHz。

視訊 payload CDC 使用 RTL 內的 `xpm_fifo_axis`，depth 2048、128-bit、independent clocks。

## 3. Clean build

```bash
cd /home/zzlee/qpcie
rm -rf build/qpcie_a50t_proj
/opt/Xilinx/Vivado/2023.2/bin/vivado \
  -mode batch -source scripts/build_a50t.tcl
```

Bitstream：

```text
build/qpcie_a50t_proj/qpcie_a50t_card.runs/impl_1/a50t_pcie_card_top.bit
```

Build script 會在 BAR0 `0x34` 注入目前 Git short hash，因此正式 checkpoint 應在 commit 後重新 clean build。

## 4. Signoff

Build success 不等於可燒錄；還需確認：

- `WNS >= 0`、`TNS=0`。
- `WHS >= 0`、`THS=0`。
- 沒有 critical warning/error。
- route status 無 unrouted nets。
- bitstream SHA256 已記錄。

commit `2450dcb7`：

```text
WNS +0.069 ns
WHS +0.041 ns
LUT 31.33%
FF 16.01%
BRAM 36.67%
DSP 31.67%
SHA256 52b4b02c6fa747bd9f5e1a340e395c18322b4fb5adf884654a36730eb61f7a81
```

## 5. SPI flash

硬體燒錄只由使用者執行：

```bash
cd /home/zzlee/qpcie
./scripts/flash_a50t.sh
```

腳本會呼叫 `scripts/program_flash_a50t.tcl`：

1. 將 bitstream 轉成 SPI image。
2. 連線 hw_server/JTAG。
3. program MX25L12872F。
4. 以 `PROGRAM.VERIFY=1` verify 已寫入的 flash 內容（script 明確停用獨立 `PROGRAM.CHECKSUM`）。

燒錄完成後必須完整斷電重啟，確保 PCIe endpoint 從新 image cold boot；只 reload driver 不會重載 FPGA。

## 6. Driver 與 smoke test

```bash
make -C driver clean && make -C driver
make -C test_app v4l2_test_app
sudo insmod driver/custom_pcie_av.ko
dmesg | tail -n 180
```

必要 readback：

```text
Version 0x02010001
Firmware Git 0x2450DCB7
Caps 0x0004040F
TPG0 readback ... YUV444 ... format=1 ... AUTO_RESTART
```

## 7. 注意事項

- FPGA head/counters 會跨 module reload 保留；driver 已從 retained head 接續，不可用舊 driver。
- 最新 image 新增 BAR0 `0x80` video pipeline reset；新版 driver 搭配舊 bitstream 會因 readback 失敗而拒絕 V4L2 init，這是刻意的安全檢查。
- Kintex UltraScale+ build flow 屬歷史/其他平台，不是目前 A50T checkpoint 的建置方式。
