# Wiki - 控制與暫存器層 (Control Layer)

## `axil_reg_space.v` (AXI4-Lite 控制暫存器區塊)

- **檔案位置**：[`rtl/axil_reg_space.v`](file:///home/zzlee/qpcie/rtl/axil_reg_space.v)
- **主要用途**：
  - 實現 AXI4-Lite Slave 介面，將 Host PCIe BAR0 記憶體映射區域轉譯為內部控制訊號。
  - 管理 DMA 控制、狀態、Descriptor 環形佇列指標及中斷致能暫存器。

---

## BAR0 暫存器映射表 (Register Map)

| 偏移位址 (Offset) | 暫存器名稱 | 讀/寫權限 | 位元欄位說明 (Bit Fields) |
| :---: | :--- | :---: | :--- |
| `0x00` | **`DMA_CTRL`** | R/W | Bit 0: `RUN_H2C` (啟動 H2C DMA)<br>Bit 1: `RUN_C2H` (啟動 C2H DMA)<br>Bit 2: `RST_H2C` (軟體重置 H2C)<br>Bit 3: `RST_C2H` (軟體重置 C2H) |
| `0x04` | **`DMA_STATUS`** | RO | Bit 0: `H2C_BUSY`<br>Bit 1: `C2H_BUSY`<br>Bit 2: `H2C_DONE`<br>Bit 3: `C2H_DONE`<br>Bit 4: `H2C_ERROR`<br>Bit 5: `C2H_ERROR` |
| `0x08` | **`H2C_RING_ADDR_L`** | R/W | Host 側 H2C Descriptor Ring 基底位址 [31:0] |
| `0x0C` | **`H2C_RING_ADDR_H`** | R/W | Host 側 H2C Descriptor Ring 基底位址 [63:32] |
| `0x10` | **`H2C_RING_CFG`** | R/W | Bit [15:0]: Ring Size (環形長度)<br>Bit [31:16]: Tail Pointer (Host 寫入的 Tail 指標) |
| `0x14` | **`C2H_RING_ADDR_L`** | R/W | Host 側 C2H Descriptor Ring 基底位址 [31:0] |
| `0x18` | **`C2H_RING_ADDR_H`** | R/W | Host 側 C2H Descriptor Ring 基底位址 [63:32] |
| `0x1C` | **`C2H_RING_CFG`** | R/W | Bit [15:0]: Ring Size (環形長度)<br>Bit [31:16]: Tail Pointer (Host 寫入的 Tail 指標) |
| `0x20` | **`IRQ_CTRL`** | R/W | Bit 0: H2C Interrupt Enable<br>Bit 1: C2H Interrupt Enable |
| `0x24` | **`IRQ_STATUS`** | R/W1C | Bit 0: H2C Interrupt Pending Flag<br>Bit 1: C2H Interrupt Pending Flag |
| `0x28` | **`COMPLETED_H2C`** | RO | 已完成之 H2C Descriptor 累計計數 |
| `0x2C` | **`COMPLETED_C2H`** | RO | 已完成之 C2H Descriptor 累計計數 |
