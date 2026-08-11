# Wiki - DMA 資料搬移核心層 (DMA Core Layer)

本層模組負責 Scatter-Gather (SG) 環形佇列處置、**多平面影像 Frame (Multi-Planar Video Frame) 帶 Stride/Step 之 2D/3D DMA**，以及 Host 與 FPGA 間雙向 AXI4 Memory Mapped 資料搬移。

---

## 1. 系統功能擴充：支援 Multi-Planar Video Frame 與 Stride/Step 傳輸

在影像處理（如 4K/1080p 視訊編解碼、影像影像處理解速器、AI 檢測）中，影像資料通常具備以下特性：
1. **跨行步長 (Line Stride / Pitch)**：為符合記憶體對齊（例 64-Byte 或 128-Byte 對齊），每行有效像素資料 (`Line Width`) 後可能包含 Padding 填補區段，實際行距為 `Stride`。
2. **多平面格式 (Multi-Planar Format)**：
   - **Planar YUV420P**：包含 Y、U、V 三個獨立平面（Y 平面為全解析度，U/V 平面寬高各為 1/2）。
   - **Semi-Planar NV12 / NV21**：包含 Y 平面與 UV 交錯平面。
   - **Planar RGB**：R、G、B 分別於三個獨立 Plane 儲存。

---

## 2. 擴充版 2D/3D Multi-Planar Descriptor 格式 (64-Byte 結構)

為支援 Multi-Planar 與 2D Stride 傳輸，Descriptor 格式由傳統 32-Byte 擴充為 **64-Byte 描述符**：

```
+-----------------------------------------------------------------------------------+
| DW0 - DW1 : Plane 0 Source Address [63:0] (Y / R / Mono Base Addr)               |
+-----------------------------------------------------------------------------------+
| DW2 - DW3 : Plane 0 Destination Address [63:0] (FPGA / Host Dst Addr)             |
+-----------------------------------------------------------------------------------+
| DW4 - DW5 : Plane 1 Source Address [63:0] (U / UV / G Base Addr)                  |
+-----------------------------------------------------------------------------------+
| DW6 - DW7 : Plane 1 Destination Address [63:0]                                    |
+-----------------------------------------------------------------------------------+
| DW8 - DW9 : Plane 2 Source Address [63:0] (V / B Base Addr)                       |
+-----------------------------------------------------------------------------------+
| DW10- DW11: Plane 2 Destination Address [63:0]                                    |
+-----------------------------------------------------------------------------------+
| DW12      : Bit [15:0] Plane 0 Line Width (Bytes)  | Bit [31:16] Line Count (Height) |
+-----------------------------------------------------------------------------------+
| DW13      : Bit [15:0] Src Line Stride (Pitch)     | Bit [31:16] Dst Line Stride    |
+-----------------------------------------------------------------------------------+
| DW14      : Bit [15:0] Plane 1/2 Line Width        | Bit [31:16] Plane 1/2 Height   |
+-----------------------------------------------------------------------------------+
| DW15      : Bit [3:0] Format | Bit [7:4] Plane Count | Bit [31:8] Control & IRQ     |
+-----------------------------------------------------------------------------------+
```

### 格式欄位詳細說明 (Field Descriptions)

- **`Plane 0/1/2 Base Addr`**：三個獨立平面的記憶體基底位址。
- **`Line Width (Active Bytes)`**：每行有效影像資料的位元組數（例：1920 像素 YUV422 = 3840 Bytes）。
- **`Line Stride (Pitch)`**：記憶體中相鄰兩行開頭位址的跨距（例：2048 像素對齊 = 4096 Bytes）。
- **`Line Count (Height)`**：畫面垂直高度（行數，例：1080 行）。
- **`Format` 影像格式**：
  - `0x0`：傳統 1D 連續記憶體傳輸 (Linear 1D)
  - `0x1`：單平面 2D 影像 (Monochrome / Packed RGB/YUV422 2D with Stride)
  - `0x2`：雙平面 Semi-Planar (NV12 / NV21)
  - `0x3`：三平面 Planar (YUV420P / Planar RGB)

---

## 3. 多平面 2D 記憶體對齊與 Stride 搬移示意圖

```
Host Memory (帶 Padding 的 Strided 影像頁面)                FPGA Local DDR / Frame Buffer
+------------------------------------------+               +----------------------------------+
| Valid Line Data (Width) | Padding (Stride)|               | Contiguous Frame Data            |
| [Line 0]                | (Ignored)      |               | [Line 0]                         |
+-------------------------+----------------+   DMA H2C     +----------------------------------+
| Valid Line Data (Width) | Padding (Stride)| ------------> | [Line 1]                         |
| [Line 1]                | (Ignored)      |  Auto Stride  +----------------------------------+
+-------------------------+----------------+  Address Gen  | [Line 2]                         |
| Valid Line Data (Width) | Padding (Stride)|               +----------------------------------+
| [Line 2]                | (Ignored)      |               | ...                              |
+-------------------------+----------------+               +----------------------------------+
```

---

## 4. 模組架構擴充說明 (Module Expansion Architecture)

### 4.1 `desc_fetch_engine.v` (Descriptor 抓取與解析引擎)
- **檔案位置**：[`rtl/desc_fetch_engine.v`](file:///home/zzlee/qpcie/rtl/desc_fetch_engine.v)
- **功能擴充**：
  - 抓取位寬支援 **64-Byte (16 DWs)** Extended Descriptor。
  - 解析出 Plane 0/1/2 獨立基底位址、`Line Width`、`Src Stride`、`Dst Stride`、`Line Count` 與 `Plane Count`。
  - 將完整的 2D Multi-Planar 參數組包派發至 H2C 或 C2H DMA 引擎。

---

### 4.2 `h2c_dma_engine.v` (Host-to-Card DMA 引擎)
- **檔案位置**：[`rtl/h2c_dma_engine.v`](file:///home/zzlee/qpcie/rtl/h2c_dma_engine.v)
- **功能擴充**：
  - **內建 2D 雙層定址產生器 (2D State Machine & Address Generator)**：
    - **外層 Plane 迴圈**：依序處理 Plane 0 (Y) ➔ Plane 1 (U/UV) ➔ Plane 2 (V)。
    - **中層 Row/Line 迴圈**：`for (line = 0; line < height; line++)`
    - **內層 DMA TLP Burst 產生器**：對每一行計算獨立位址：
      $$\text{Line\_Src\_Addr} = \text{Plane\_Src\_Base} + (\text{line} \times \text{Src\_Stride})$$
      $$\text{Line\_Dst\_Addr} = \text{Plane\_Dst\_Base} + (\text{line} \times \text{Dst\_Stride})$$
  - 自動跳過 Stride Padding 區段，僅對有效 `Line Width` 發起 PCIe MRd TLP 與 AXI4 MM Master Write 寫入。

---

### 4.3 `c2h_dma_engine.v` (Card-to-Host DMA 引擎)
- **檔案位置**：[`rtl/c2h_dma_engine.v`](file:///home/zzlee/qpcie/rtl/c2h_dma_engine.v)
- **功能擴充**：
  - 支援將 FPGA 端處理完畢的 Multi-Planar 影像數據（例如硬體 H.264/H.265 編碼前處理或 AI 辨識後影像）跨平面回寫至 Host Memory。
  - 同樣具備 2D 雙層定址產生器，精確將 FPGA 連續或非連續的圖像 Scanline 依照 Host 側指派的 `Dst Stride` 格式填入 Host 記憶體 Plane 0/1/2 區域。

---

## 5. 應用情境範例 (Application Example: YUV420P 4K Frame Transfer)

以 **4K 解析度 (3840x2160) YUV420P** 影像為例：

1. **Y Plane (Plane 0)**:
   - `Line Width` = 3840 Bytes, `Line Count` = 2160 行
   - `Src Stride` = 4096 Bytes (Host 端 4KB 對齊)
   - 傳輸資料量 = $3840 \times 2160 = 8.29 \text{ MB}$
2. **U Plane (Plane 1)**:
   - `Line Width` = 1920 Bytes, `Line Count` = 1080 行
   - `Src Stride` = 2048 Bytes
3. **V Plane (Plane 2)**:
   - `Line Width` = 1920 Bytes, `Line Count` = 1080 行
   - `Src Stride` = 2048 Bytes

DMA 控制器僅需**單一 Descriptor**，即可由硬體自動完成全部 3 個平面的 2D 逐行硬體自動計址與搬移，極大地降低 Host CPU 中斷與 Descriptor Ring 管理負擔！
