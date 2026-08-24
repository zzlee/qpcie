# Artix-7 A50T pg054 移植完成記錄

本文件由早期可行性分析更新為實際移植結果。詳細現況見 [A50T NV12M 實作總結](A50T-NV12M-Implementation-and-Results.md)。

## 1. 已完成項目

| 項目 | 結果 |
|---|---|
| `xc7a50t-csg325-2` Vivado build | 完成，timing clean |
| pg054 Gen2 x4 / 128-bit bridge | 完成 |
| BAR0/BAR1 decode | 實機通過 |
| MWr/MRd/CplD endian/header adaptation | 實機通過 |
| Descriptor fetch 與 SG C2H/H2C | 實機通過 |
| MSI completion | 實機通過 |
| Xilinx TPG YUV444 | 實機通過 |
| 1080p60 NV12M | 實機通過 |
| 4K60 RTL/V4L2 modes | 已完成，待最新實機 gate |

## 2. 實際需要的 A50T-specific 工作

早期預估「只需新增 wrapper」過度樂觀。實際完成項目包括：

1. pg054 RX/TX byte-lane ordering 修正。
2. 64-bit address 4-DW MWr 的雙 beat payload handling。
3. RC CplD Tag/Requester/Lower Address 切片修正。
4. BAR hit sideband 與 BAR-relative address normalization。
5. 7-Series RQ multi-beat 128-byte MWr streamer。
6. 4 KiB boundary split。
7. A50T resource-aware chroma BRAM/Y-UV FIFOs。
8. 125→150 MHz video MMCM、AXI-Lite CDC、AXIS async FIFO。
9. Reset recovery/CDC constraints 與 timing closure。
10. Jetson ARM64 retained ring state、memory barriers、SMMU safety。

## 3. 可共用與目前停用

共用核心包含 descriptor format、SG engine、BAR0 registers、timer、interrupt controller 與 Linux PCI skeleton。但目前 A50T bring-up 特別收斂為：

- 一個 V4L2 capture channel。
- NV12M。
- DMA-contiguous MMAP。
- 1080p60/4K60。

ALSA、多通道、DMABUF/P2P、slice DMA 雖有歷史 source/design，尚未完成本輪 A50T physical qualification。

## 4. 歷史 loopback

最初 `pcie_7x_tlp_loopback.v` checkpoint 驗證 `12AB:E380` 枚舉與基本 BAR MRd/MWr。後續已逐步加入完整 SG DMA、V4L2、NV12 engine 與 150 MHz video CDC；loopback 文件只保留作早期除錯參考。
