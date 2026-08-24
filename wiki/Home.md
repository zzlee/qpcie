# QPCIe Project Wiki

QPCIe 是以 Artix-7 A50T 為目前主要驗證平台的 PCIe Gen2 x4 視訊 DMA 專案。現行 bring-up 交付範圍是：

```text
單一 V4L2 capture channel
Xilinx TPG YUV444 → rounded 2×2 chroma downsample → NV12M
1920×1080@60 與 3840×2160@60
128-byte PCIe C2H MWr
```

> **先讀：[A50T NV12M 實作總結與驗證結果](A50T-NV12M-Implementation-and-Results.md)**
> 這是目前 commit、架構、效能、bitstream 與待驗證項目的權威摘要。注意：1080p60 已實機通過；最新 4K60 mode 尚待直接實機驗證。

## 文件導覽

### 目前實作與驗證

- [A50T NV12M 實作總結與驗證結果](A50T-NV12M-Implementation-and-Results.md)
- [A50T 實機測試與除錯日誌](A50T-Hardware-Verification-Log.md)
- [AV Datapath](AV_DATAPATH_WIKI.md)
- [仿真、timing 與硬體測試](Verification-and-Simulation.md)
- [A50T FPGA 建置與 SPI Flash](FPGA-Build-Guide.md)
- [Linux V4L2 Driver 與測試程式](Linux-V4L2-ALSA-Driver-Guide.md)

### RTL 與協定

- [系統總覽](Overview.md)
- [TLP Layer：pg054 bridge、CQ/CC/RQ/RC](TLP-Layer.md)
- [DMA Core：SG、128-byte requester、NV12 engine](DMA-Core-Layer.md)
- [Control Layer：BAR0/BAR1 register map](Control-Layer.md)
- [BAR1 IP 控制](Controlling-Other-IP-Cores.md)
- [A50T pg054 移植記錄](A50T_MIGRATION.md)
- [歷史 A50T TLP Loopback](A50T-TLP-Loopback-Test.md)

### 設計延伸與歷史文件

下列文件描述可參數化架構或未來方向，不代表目前 A50T bring-up 已啟用：

- [Multi-Channel Stream Architecture](Multi-Channel-Stream-Architecture.md)
- [Multi-Channel Video/Audio Config](Multi-Channel-Video-Audio-Config.md)
- [Linux Scatterlist Guide](Linux-Driver-Scatterlist-Guide.md)
- [Low-Latency Slice Capture](Low-Latency-Capture-Guide.md)
- [System Support Layer](System-Support-Layer.md)
- [AU15P Feasibility](AU15P_FEASIBILITY.md)

## 目前明確限制

- 只註冊 `/dev/video0`；channel 1–3 停用。
- 只啟用 V4L2 MMAP + DMA-contiguous planes。
- ALSA 暫停 bring-up。
- USERPTR、DMABUF、EXPBUF、GPU P2P 與 slice DMA 尚未列入目前實體通過範圍。
- 不可把仿真通過或等效吞吐量達標寫成「4K60 實機已通過」。
