# ⏱️ 低延遲採集架構 (Sub-5ms Latency) 與 PCIe 中斷技術 Wiki

本文件介紹如何在 FPGA + Linux 驅動架構下，實現 **5ms 以下的超低延遲視訊採集與傳輸**。

---

## 1. 核心觀念：Sub-Frame Slice DMA

在 60Hz 視訊下，一幀完整傳送耗時 **$16.67\text{ ms}$**。若要達成 **$< 5\text{ ms}$** 的總系統延遲，系統採用 **Slice (切片) DMA 機制**：

1. **4-Slice 模式 (推薦)**：每幀分為 4 個 Slices (每 270 行為一 Slice)。
2. **傳輸重疊**：FPGA 在接收 Slice 1 (耗時 $4.16\text{ ms}$) 後，立即將 Slice 1 透過 DMA 寫入 Host 記憶體並發送 MSI 中斷。
3. **並行處理**：當 HDMI / SDI 訊號還在傳輸 Slice 2 時，Host Application / GPU 已開始渲染/處理 Slice 1。

---

## 2. PCIe 中斷 (MSI/MSI-X) 頻率與負載評估

- **MSI 封包**：PCIe MSI 為 32-bit Memory Write TLP，單次發送耗時 $< 50\text{ ns}$。
- **240 IRQ/s (4-Slice 60FPS)**：CPU 開銷 $< 0.01\%$，系統極度穩定。
- **零拷貝 P2P**：結合 `qpcie_dmabuf.c` 直接寫入 GPU VRAM，完全消除 CPU 記憶體複製延遲。
