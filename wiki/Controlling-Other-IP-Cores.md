# Wiki - 透過 Control-Layer 控制其他 FPGA 端 IP Cores 指南

在專案最新架構中，系統已實現 **BAR0 / BAR1 雙通道獨立控制架構 (Dual-BAR Architecture)**。

---

## 1. 架構特色 (Architecture Highlights)

1. **BAR0 (DMA Control Channel)**：
   - 專用於 DMA 控制暫存器、 Descriptor Ring 指標與中斷暫存器存取。
2. **BAR1 (User IP Cores Interconnect Channel)**：
   - 頂層模組 [`custom_pcie_dma_top.v`](file:///home/zzlee/qpcie/rtl/custom_pcie_dma_top.v) 獨立引出 **`m_axil_bar1_*` AXI4-Lite Master 介面**。
   - 可在 Vivado Block Design 中將此介面直接連接至 **AXI Interconnect / Crossbar IP**，延伸控制多個外設 IP Cores (如 I2C, UART, SPI, GPIO, Timer 等)。

---

## 2. 系統接線示意圖 (Block Design Connection)

```
+------------------------------------+
|        custom_pcie_dma_top         |
|                                    |
|  [BAR1 AXI4-Lite Master]           |
|  - m_axil_bar1_awaddr              |
|  - m_axil_bar1_wdata               |          +--------------------------+
|  - m_axil_bar1_araddr   --------------------> | AXI Interconnect / Cross |
|  - m_axil_bar1_rdata               |          +----+---------+-----------+
+------------------------------------+               |         |
                                                     v         v
                                                +---------+ +---------+
                                                | I2C Core| |UART Core|
                                                +---------+ +---------+
```

---

## 3. Host 端 Linux 驅動程式存取範例

在 Linux 驅動程式中，透過 `pci_iomap()` 分別映射 BAR0 與 BAR1：

```c
void __iomem *bar0_mmio; /* DMA 控制暫存器 */
void __iomem *bar1_mmio; /* 外設 IP Cores 暫存器 */

/* 1. 映射 BAR0 與 BAR1 */
bar0_mmio = pci_iomap(pdev, 0, 0); // BAR0
bar1_mmio = pci_iomap(pdev, 1, 0); // BAR1

/* 2. 透過 BAR0 啟動 DMA Engine */
iowrite32(0x00000001, bar0_mmio + 0x00); // Start H2C DMA

/* 3. 透過 BAR1 存取 I2C IP Core (例如 Base 0x0000) */
iowrite32(0x00000045, bar1_mmio + 0x0000); // I2C Control Register

/* 4. 透過 BAR1 存取 UART IP Core (例如 Base 0x1000) */
iowrite32('H', bar1_mmio + 0x1000); // UART TX Register
```
