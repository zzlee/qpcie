# Wiki - 透過 Control-Layer 控制其他 FPGA 端的 IP Cores

在 PCIe 控制器中，Host（CPU 側驅動程式）對 FPGA 端的控制本質上是透過 **PCIe BAR (Base Address Register) 空間映射到 AXI4-Lite 匯流排** 來實現。

本架構目前由 [`cq_rx_decoder.v`](file:///home/zzlee/qpcie/rtl/cq_rx_decoder.v) 負責將 PCIe CQ 請求轉化為標準 **AXI4-Lite Master 介面**，而 [`axil_reg_space.v`](file:///home/zzlee/qpcie/rtl/axil_reg_space.v) 則是接在該介面下的第一個 AXI4-Lite Slave (DMA 控制暫存器)。

要擴充控制 FPGA 端的其他 IP Cores，主要有以下 **三種標準設計模式**：

---

## 模式一：AXI4-Lite Interconnect / Crossbar 總線擴充（最推薦、最彈性）

在 Vivado IP Integrator 或系統頂層中，將 `custom_pcie_dma_top` 的 AXI4-Lite Master 介面連接至一個 **AXI Interconnect** 或 **AXI Crossbar**，將不同的位址區段分發給 DMA 控制器與各個 IP Cores。

### 1.1 位址映射表 (Memory Map 範例)

| 位址範圍 (Address Range) | 目標模組 / IP Core | AXI Slave Port |
| :--- | :--- | :--- |
| `0x0000_0000` - `0x0000_00FF` | **PCIe DMA Reg Space** (`axil_reg_space.v`) | Slave 0 (M00_AXI) |
| `0x0000_1000` - `0x0000_1FFF` | **Custom IP Core 1** (例：演算法加速器 / DSP) | Slave 1 (M01_AXI) |
| `0x0000_2000` - `0x0000_2FFF` | **Custom IP Core 2** (例：UART / I2C / GPIO) | Slave 2 (M02_AXI) |
| `0x0000_3000` - `0x0000_3FFF` | **Custom IP Core 3** (例：Timer / Counter) | Slave 3 (M03_AXI) |

### 1.2 系統連接架構圖

```
+---------------------+
| Host (PCIe Driver)  |
+----------+----------+
           | (PCIe Memory Write/Read to BAR0)
           v
+----------+----------+
|  custom_pcie_dma_top|
|  - cq_rx_decoder    |
+----------+----------+
           |
           | AXI4-Lite Master Interface
           v
+----------+-------------------------------------------------------+
|                    AXI4-Lite Interconnect / Crossbar              |
+----+----------------------+----------------------+---------------+
     |                      |                      |
     v (0x0000_0000)        v (0x0000_1000)        v (0x0000_2000)
+----+-----------------+ +--+------------------+ +--+------------------+
| axil_reg_space.v     | |  User IP Core 1     | |  User IP Core 2     |
| (DMA Regs)           | |  (AXI4-Lite Slave)  | |  (AXI4-Lite Slave)  |
+----------------------+ +---------------------+ +---------------------+
```

---

## 模式二：暫存器線路直接引出 (Direct Register Wire Output)

如果控制需求較為簡單（例如僅需要幾條致能線 `enable`、複位線 `reset` 或參數設定暫存器 `config_param[31:0]`），可以直接在 `axil_reg_space.v` 中擴充額外暫存器偏移量，並將訊號引出至頂層端口。

### 2.1 實作範例：擴充 `axil_reg_space.v`

```verilog
// 擴充暫存器偏移量
localparam ADDR_USER_IP1_CTRL = 8'h30;
localparam ADDR_USER_IP1_CFG  = 8'h34;

// 匯出訊號至對外 Port
output reg [31:0] user_ip1_ctrl,
output reg [31:0] user_ip1_cfg
```

---

## 3. 多 BAR 隔離控制 (Multi-BAR Architecture)

若欲將 **DMA 控制器** 與 **User IP 暫存器** 在 PCIe 規格層級徹底隔離：

1. 在 Vivado PCIe IP 設定中開啟 **BAR0** 與 **BAR1/BAR2**。
2. 在 `cq_rx_decoder.v` 中檢查 CQ TLP Header 的 `bar_id` 欄位（`s_axis_cq_tdata[114:112]`）：
   - `bar_id == 3'b000` (BAR0) → 路由至 DMA 控制暫存器。
   - `bar_id == 3'b010` (BAR2) → 路由至 User IP Core 獨立 AXI4-Lite 匯流排。
