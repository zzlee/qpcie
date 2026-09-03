# QPCIe A50T 系統總覽

## 1. 現行交付目標

QPCIe 目前以 Artix-7 A50T + pg054 PCIe Gen2 x4 為主要平台，實作一個可靠的 V4L2 NV12M capture pipeline：

```text
TPG YUV444 @150 MHz
→ 4 PPC async CDC
→ rounded YUV444-to-NV12M @125 MHz
→ 128-byte C2H MWr
→ Host V4L2 MMAP buffers
```

1080p60與4K loopback已實機通過。最新16-tag H2C direct-I/O-VA 4K loopback為78.77 FPS、H2C/C2H各934.60 MiB/s、100% bit-exact；host SGL linked-page仍待獨立驗證。

## 2. 分層架構

```text
+--------------------------------------------------------------+
| a50t_pcie_card_top                                            |
|  pcie_7x_0 / pg054, Gen2 x4                                  |
|  video_clock_gen, TPG, AXI-Lite CDC, AXIS CDC FIFO           |
+-------------------------------+------------------------------+
                                |
+-------------------------------v------------------------------+
| pcie_7x_axi_bridge                                            |
|  pg054 RX/TX byte order、4-DW MWr、internal CQ/CC/RQ/RC      |
+-------------------------------+------------------------------+
                                |
+-------------------------------v------------------------------+
| custom_pcie_dma_top                                           |
|  CQ decoder / CC encoder / BAR0 regs / BAR1 master           |
|  descriptor fetch / SG DMA / RQ requester / RC decoder       |
|  nv12_capture_engine / interrupt controller / timer          |
+-------------------------------+------------------------------+
                                |
+-------------------------------v------------------------------+
| Linux custom_pcie_av.ko                                       |
|  PCI probe + SG self-test + one V4L2 NV12M MMAP node          |
+--------------------------------------------------------------+
```

## 3. PCIe interfaces

A50T physical core uses 7-Series RX/TX interfaces；`pcie_7x_axi_bridge.v` 提供 internal CQ/CC/RQ/RC-like separation：

- CQ：host BAR MRd/MWr。
- CC：BAR MRd completion。
- RQ：descriptor MRd、C2H MWr、MSI。
- RC：descriptor/H2C CplD。

所有 pg054-specific byte order 與 header adaptation 都集中在 bridge boundary，核心 RTL 與軟體維持正常 little-endian semantics。

## 4. 現行功能矩陣

| 功能 | RTL | 仿真 | 實機 |
|---|:---:|:---:|:---:|
| BAR0/BAR1 | ✅ | ✅ | ✅ |
| SG C2H/H2C | ✅ | ✅ | ✅ |
| 128-byte requester | ✅ | ✅ | ✅ |
| 1080p60 NV12M | ✅ | ✅ | ✅ |
| 150 MHz TPG CDC | ✅ | timing clean | ✅ |
| 4K60 NV12M | ✅ | ✅ | ⏳ |
| Video ch1–3 | parameter/stub | 非目標 | 停用 |
| ALSA | source 保留 | 非目標 | 停用 |
| USERPTR/DMABUF/P2P | 歷史/規劃 | 非目標 | 未驗證 |

## 5. 重要指標

- 4K60 payload：746.496 MB/s = 711.91 MiB/s。
- 最新 1080p 等效 benchmark：713.47 MiB/s。
- 最新 timing：WNS +0.069 ns。
- 最新 bitstream SHA256：`52b4b02c6fa747bd9f5e1a340e395c18322b4fb5adf884654a36730eb61f7a81`。

完整內容：[A50T NV12M 實作總結與驗證結果](A50T-NV12M-Implementation-and-Results.md)。
