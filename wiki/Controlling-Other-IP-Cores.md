# BAR1 User-IP 控制指南

## 1. 現行 A50T map

```text
Host BAR1
  ├─ 0x0000–0x0FFF → Xilinx Video TPG
  ├─ 0x1000–0x1FFF → Audio Pattern Generator
  └─ 0x2000–0x2FFF → EDID/HPD
```

`cq_rx_decoder.v` 依 pg054 BAR hit 將 PCIe absolute address 轉成 BAR-relative address，再交給 AXI-Lite crossbar。舊文件中的 I2C/UART/SPI 範例並非目前 A50T map。

## 2. Clock domains

BAR1 crossbar 位於 PCIe `user_clk=125 MHz`。TPG 位於 150 MHz，因此 TPG branch 經 `axi_clock_converter_tpg`；audio/EDID 仍位於 125 MHz domain。

```text
BAR1 MWr/MRd @125
        │
        ├─ audio / EDID @125
        │
        └─ AXI Clock Converter → TPG AXI-Lite @150
```

## 3. TPG registers

| TPG-relative offset | 功能 | 目前值 |
|---:|---|---|
| `0x00` | HLS control | `0x81` START + AUTO_RESTART |
| `0x10` | active rows | 1080 或 2160 |
| `0x18` | active columns | 1920 或 3840 |
| `0x20` | pattern ID | color bars = 9 |
| `0x40` | color format | 1 = YUV444 |

正常使用應透過 V4L2 ioctls，而不是 user space 直接 mmap BAR1。`qpcie_v4l2.c` 會執行 posted-write flush 與 fatal readback validation。

## 4. Mode switch

單純改 TPG dimensions 不足以安全切換模式，因 async FIFO 可能仍有舊解析度半幀。Driver 會先透過 BAR0 `0x80` reset TPG/FIFO，再重新寫 BAR1 TPG registers。

## 5. Kernel example

```c
void __iomem *tpg = qdev->bar1_mmio;

iowrite32(height,    tpg + 0x10);
iowrite32(width,     tpg + 0x18);
iowrite32(pattern,   tpg + 0x20);
iowrite32(1,         tpg + 0x40); /* YUV444 */
iowrite32(0x81,      tpg + 0x00); /* start + auto restart */
ctrl = ioread32(tpg + 0x00);      /* flush/readback */
```

必須同時驗證 width、height、pattern、format 與 AUTO_RESTART；`0xDEC0DE1C`/`0xDEADBEEF` 類值代表 decode 錯誤，不得繼續 STREAMON。

## 6. Bring-up 範圍

Audio Pattern Generator 與 EDID/HPD RTL 保留，但本輪實體 qualification 專注 video channel 0；ALSA與外部 HDMI/I2C 功能不列為已驗證交付。
