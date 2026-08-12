# Wiki - Kintex UltraScale+ (XCKU3P) PCIe 卡建構指南

本指南說明如何透過 Vivado 自動化 TCL 腳本整合所有 RTL 模組，建構基於 **AMD/Xilinx Kintex UltraScale+ XCKU3P (`xcku3p-ffva676-2-e`)** 的 PCIe 擴充卡專案並產生 Bitstream 檔。

---

## 1. 硬體晶片與 PCIe IP 規格

- **目標晶片 Part Number**：`xcku3p-ffva676-2-e` (Kintex UltraScale+)
- **PCIe 硬體 IP Core**：`pcie4_uscale_plus` (Gen3 x4, 256-bit AXI4-Stream Interface)
- **PCIe 介面頻寬**：Gen3 x4 (Line Rate: 8.0 GT/s per lane, 實測頻寬約 3.2 GB/s)
- **Dual-BAR 設定**：
  - **BAR0**：64-KB 64-bit AXI4-Lite (DMA 控制暫存器與 64B 2D Descriptor 引擎)
  - **BAR1**：64-KB 64-bit AXI4-Lite (User IP Cores 內部匯流排外設控制)

---

## 2. 專案建構腳本說明 (`scripts/build_project.tcl`)

建構腳本位於 [`scripts/build_project.tcl`](file:///home/zzlee/qpcie/scripts/build_project.tcl)，執行內容包含：

1. 自動建立 Vivado 專案 (`build/qpcie_ku3p_proj`) 並指定 `xcku3p-ffva676-2-e`。
2. 自動匯入 `rtl/*.v` 所有原生 AXI4-Stream Video 及 AES3 Audio 模組。
3. 自動引進 Constraints 設定 [`constraints/ku3p_pcie_pinout.xdc`](file:///home/zzlee/qpcie/constraints/ku3p_pcie_pinout.xdc)。
4. 自動設定並生成 `pcie4_uscale_plus` IP Core（開立 256-bit AXI4-Stream CQ/CC/RQ/RC 數據通道）。
5. 自動執行 Synthesis (`synth_1`)、Implementation (`impl_1`) 與 Bitstream 產生 (`write_bitstream`)。

---

## 3. Vivado 一鍵編譯指令 (Build Commands)

在 Linux 終端機執行：

```bash
# 一鍵批次模式編譯 (Vivado Batch Mode)
vivado -mode batch -source scripts/build_project.tcl
```

編譯完成後 Bitstream 檔案位置：
`build/qpcie_ku3p_proj/qpcie_ku3p_card.runs/impl_1/custom_pcie_dma_top.bit`
