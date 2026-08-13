# 📊 AMD/Xilinx Artix UltraScale+ AU15P Cost-Down 可行性評估 Wiki

本文件為專案 Cost-Down 版本評估：將 FPGA 晶片由 Kintex UltraScale+ `XCKU3P` 切換為 Artix UltraScale+ `XCAU15P` 之可行性分析與硬體規格對比。

---

## 1. 晶片規格與資源對比 (XCKU3P vs. XCAU15P)

| 關鍵硬體資源 | 原方案: Kintex UltraScale+ `XCKU3P-ffva676` | Cost-Down 方案: Artix UltraScale+ `XCAU15P-ffvb676` | 專案實際需求與佔用率 (AU15P) | 可行性結論 |
| :--- | :--- | :--- | :--- | :---: |
| **Logic Cells (LUTs)** | 356K Logic Cells (~163K LUTs) | **170K Logic Cells (~78K LUTs)** | 專案當前使用 ~15,200 LUTs (**佔用率 ~19.4%**) | 🟢 **資源充裕** |
| **BRAM / URAM** | 12.6 Mb BRAM / 14.4 Mb URAM | **5.3 Mb BRAM (無 UltraRAM)** | DMA FIFO & Video Buffer 需 ~1.6 Mb (**佔用率 ~30.1%**) | 🟢 **足夠使用** |
| **DSP Slices (DSP48E2)** | 1,368 DSPs | **576 DSPs** | 影音引擎與 TPG 僅需 8 DSPs (**佔用率 ~1.4%**) | 🟢 **資源極度充裕** |
| **PCIe Block** | Integrated PCIe4 Block | **Integrated PCIe3 Block** | 支援 **PCIe Gen3 x4 (256-bit AXI-Stream)** | 🟢 **原生支援** |
| **Transceivers** | 16x GTH (最高 32.75 Gbps) | **12x GTP/GTY (最高 16.0 Gbps)** | 4x Lanes 給 PCIe Gen3，其餘可接 4K60 HDMI 2.0 / SDI | 🟢 **滿足腳位需求** |
| **晶片成本 (Cost)** | 基準成本 (100%) | **節省 50% ~ 65% 單價成本** | 商業 Cost-Down 效果顯著 | 💰 **極具優勢** |

---

## 2. 結論與建議

> **結論: 強烈推薦 (Highly Feasible & Recommended)**
> 
> 切換至 **Artix UltraScale+ AU15P** 具有 **極高可行性**：
> 1. **單價節省 50% ~ 65%**，極具商用量產競爭力。
> 2. 完整支援 **4K60 YUV444 零壓縮擷取** 與 **$3.2\text{ GB/s}$ PCIe Gen3 x4 吞吐量**。
> 3. **Linux 驅動程式與用戶端應用程式 100% 零修改相容**。
