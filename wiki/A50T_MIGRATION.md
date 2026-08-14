# 📊 AMD/Xilinx Artix-7 A50T (`pg054`) 移植與專案組件共用分析 Wiki

本文件評估專案移植至 **Artix-7 `XC7A50T`** 並採用 **7 Series Integrated Block for PCIe IP (`pg054` v3.3)** 之組件共用性與改動維度。

---

## 1. 核心組件可共用性總表

| 專案層級 / 模組名稱 | 共用狀態 | 說明與需求 |
| :--- | :---: | :--- |
| **Linux 核心驅動程式 (`driver/`)** | 🟢 **100% 完整共用** | 免修改 C 語言程式碼。V4L2, ALSA, DMABUF P2P, Sysfs 100% 相容。 |
| **User App 測試生態 (`test_app/`)** | 🟢 **100% 完整共用** | `v4l2_test_app`, `alsa_test_app`, `dmabuf_p2p_test_app`, `loopback_test_app` 相容。 |
| **BAR0 暫存器空間 (`axil_reg_space.v`)** | 🟢 **100% 完整共用** | 暫存器 Offsets, DMA Ring 控制, PTS, Pacer Control 100% 相同。 |
| **2D 描述子抓取引擎 (`desc_fetch_engine.v`)** | 🟢 **100% 完整共用** | 64-Byte 2D 多平面 DMA 描述子解析邏輯完全相同。 |
| **DMA 傳輸引擎 (`h2c_dma_engine.v`, `c2h_dma_engine.v`)**| 🟢 **100% 完整共用** | 內部 AXI-Stream Burst 傳輸機制與 Ring Buffer 控制邏輯 100% 相同。 |
| **AES3 音訊串流引擎 (`audio_stream_engine.v`)** | 🟢 **100% 完整共用** | 音訊 Pattern 生成與 32-bit AES3 串流打包邏輯完全共用。 |
| **64-bit PTS 時間戳記 (`global_timer.v`)** | 🟢 **100% 完整共用** | 8ns 高精度主計時器 100% 可直接於 Artix-7 運作。 |
| **Telemetry 頻寬/延遲計量 (`dma_telemetry.v`)** | 🟢 **100% 完整共用** | 即時 PCIe Bps/MBs 吞吐量與 ACK Latency 記錄器 100% 共用。 |
| **動態 EDID RAM & HPD (`hdmi_edid_ram.v`)** | 🟢 **100% 完整共用** | 256-Byte Dual-Port EDID RAM 與 HPD 脈衝控制 100% 共用。 |
| **PCIe TLP 封裝轉譯層** | 🟡 **新增 7-Series Wrapper** | 將 UltraScale+ CQ/CC/RQ/RC 格式包裝成 7-Series `pg054` 64-bit AXI-Stream RX/TX 介面。 |

---

## 2. 結論

> **結論: 高度可行且高度共用 (Highly Feasible & 90%+ Reusable)**
> 
> 1. **90% 以上的 RTL 核心邏輯與 100% 的 Linux 驅動/應用程式** 可直接復用，無須修改軟體層。
> 2. 只需針對 Artix-7 A50T 新增 **7-Series AXI-Stream TLP 轉譯層 (Bridge Wrapper)** 與 `build_a50t.tcl` 即可完成建置！
