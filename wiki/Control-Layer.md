# Wiki - 控制與暫存器層 (Control Layer & Dual-BAR Architecture)

本專案採用 **Dual-BAR (雙 BAR) 獨立映射架構**，將 **PCIe DMA 控制通道** 與 **User IP Core 控制通道** 在硬體規格層級進行完全隔離與解耦：

---

## 1. Dual-BAR 記憶體空間重新規劃 (Dual-BAR Mapping)

```
                       Host PCIe BAR Space
                               |
         +---------------------+---------------------+
         | (bar_id == 0)                             | (bar_id == 1)
         v                                           v
+------------------+                       +-------------------+
|  PCIe BAR 0      |                       |  PCIe BAR 1       |
|  (DMA Control)   |                       |  (User IP Cores)  |
+--------+---------+                       +---------+---------+
         |                                           |
         v                                           v
+------------------+                       +-------------------+
| axil_reg_space.v |                       | Top AXI4-Lite     |
| (DMA Reg Block)  |                       | Master Interface  |
+------------------+                       +---------+---------+
                                                     |
                                                     v
                                           +-------------------+
                                           | AXI Interconnect  |
                                           | / Crossbar IP     |
                                           +----+----+----+----+
                                                |    |    |
                                                v    v    v
                                              I2C  UART GPIO ...
```

### 1.1 BAR 職責區分
- **BAR0 (DMA Control Register Block)**：
  - **解碼位址**：`bar_id == 3'b000` (BAR0)
  - **對接模組**：內部 [`axil_reg_space.v`](file:///home/zzlee/qpcie/rtl/axil_reg_space.v)
  - **功能**：設定 DMA 環形佇列位址、Tail Pointer、啟動引擎與讀取中斷狀態。

- **BAR1 (User IP Cores Interconnect)**：
  - **解碼位址**：`bar_id == 3'b001` (BAR1)
  - **對接端口**：頂層 [`custom_pcie_dma_top.v`](file:///home/zzlee/qpcie/rtl/custom_pcie_dma_top.v) 的 **`m_axil_bar1_*` AXI4-Lite Master 介面**。
  - **功能**：直接透過 AXI Interconnect / Crossbar 存取外接的 IP Cores（例如 I2C, UART, SPI, Timer, System GPIO）。

---

## 2. BAR0 AXI4-Lite 暫存器映射表 (BAR0 Reg Map)

| 暫存器名稱 (Register) | Offset 位址 | 存取權限 | 位元欄位說明 (Bit Fields) |
| :--- | :--- | :--- | :--- |
| **`DMA_CTRL`** | `0x00` | R/W | Bit 0: `h2c_start`, Bit 1: `c2h_start`, Bit 31: `sw_reset` |
| **`DMA_STATUS`** | `0x04` | R | Bit 0: `h2c_busy`, Bit 1: `c2h_busy`, Bit 2: `h2c_done`, Bit 3: `c2h_done` |
| **`H2C_RING_ADDR_L`** | `0x08` | R/W | Host 側 H2C Descriptor Ring 64-bit 基底位址 [31:0] |
| **`H2C_RING_ADDR_H`** | `0x0C` | R/W | Host 側 H2C Descriptor Ring 64-bit 基底位址 [63:32] |
| **`H2C_RING_CFG`** | `0x10` | R/W | Bits [15:0]: `ring_size`, Bits [31:16]: `tail_ptr` |
| **`C2H_RING_ADDR_L`** | `0x14` | R/W | Host 側 C2H Descriptor Ring 64-bit 基底位址 [31:0] |
| **`C2H_RING_ADDR_H`** | `0x18` | R/W | Host 側 C2H Descriptor Ring 64-bit 基底位址 [63:32] |
| **`C2H_RING_CFG`** | `0x1C` | R/W | Bits [15:0]: `ring_size`, Bits [31:16]: `tail_ptr` |
| **`IRQ_CTRL`** | `0x20` | R/W | Bit 0: `irq_enable`, Bit 1: `msi_mode` |
| **`IRQ_STATUS`** | `0x24` | R/W1C | Bit 0: `h2c_irq`, Bit 1: `c2h_irq` |
| **`COMPLETED_H2C_COUNT`** | `0x28` | R | 硬體自動累加之 H2C Descriptor 完成總數 |
| **`COMPLETED_C2H_COUNT`** | `0x2C` | R | 硬體自動累加之 C2H Descriptor 完成總數 |

---

## 3. BAR1 User IP Cores 記憶體規劃 (BAR1 Memory Map)

在 Host 側存取 PCIe BAR1 時，位址將直接映射至 FPGA 側的 AXI Interconnect：

- `BAR1 + 0x0000_0000` - `0x0000_0FFF` ➔ **I2C Core**
- `BAR1 + 0x0000_1000` - `0x0000_1FFF` ➔ **UART Core**
- `BAR1 + 0x0000_2000` - `0x0000_2FFF` ➔ **SPI Core**
- `BAR1 + 0x0000_3000` - `0x0000_3FFF` ➔ **System GPIO / Timer Core**
