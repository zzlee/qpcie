# DMA Core Layer：SG、128-byte MWr 與 NV12M Engine

## 1. 64-byte descriptor

目前 descriptor wire format 為 16 DW：

```text
DW0–1   plane0 source address
DW2–3   plane0 destination address
DW4–5   plane1 source address
DW6–7   plane1 destination address
DW8–9   plane2 source address
DW10–11 plane2 destination address
DW12    [15:0] line_width, [31:16] line_count
DW13    [15:0] src_stride, [31:16] dst_stride
DW14    [15:0] plane12_width, [31:16] plane12_count
DW15    format / plane_count / control
```

`format=0x2` 為雙平面 NV12M。V4L2 capture descriptor 使用 Y/UV destination DMA addresses、`line_width=width`、`line_count=height`、`plane12_count=height/2`。

## 2. SG descriptor fetch

`desc_fetch_engine.v` 使用 MRd 取得完整 64-byte descriptor。Tag 0 保留給 descriptor completion；pg054 bridge/RC decoder 會剝除 CplD header 並按 Tag 路由。

Ring head 與 completion counter 是硬體 retained state。driver 每次 module probe 都從硬體 head 建立新 tail，並在 doorbell 前使用 `dma_wmb()`。

## 3. Diagnostic SG DMA

SG diagnostic 每個 4096-byte page 使用 32 個 128-byte MWr，而不是舊版 256 個 16-byte MWr。`sg_dma_engine.v` 會：

- 根據 descriptor address/length 產生請求。
- 在 4 KiB boundary 前自動縮短 TLP。
- 等待 requester/data-stream backpressure。
- 完成後更新 head 與 completion counter。

已在仿真驗證 `64B + 128B + 64B` boundary split，並在實機驗證 4 pages × 4096 bytes C2H/H2C。

## 4. 128-byte requester protocol

`rq_tx_encoder.v` 的 C2H interface：

```text
c2h_req_valid
c2h_req_addr[63:0]
c2h_req_dw_len[10:0] = 32 DW
c2h_req_data[127:0]
c2h_req_data_ready
c2h_req_ack
```

一個預設 MWr：

```text
4-DW MWr64 header
+ 8 × 128-bit payload beats
= 128-byte payload
```

Owner 在 packet 結束前鎖定。`data_ready` 只在真正接受 payload beat 時拉高；sender 必須保持 data/valid 穩定直到 handshake。Requester 支援連續 payload beats，消除舊架構每 16 bytes 一次 request/ack 的 bubble。

## 5. NV12 capture engine

`nv12_capture_engine.v` 只例化在 video channel 0；其餘通道保留 stub/loopback wiring。

主要單元：

- 4-PPC input，每 clock 最多接受一個 128-bit beat。
- `MAX_WIDTH=3840`。
- `960×36` synchronous chroma line RAM，Vivado inference 為 block RAM。
- 獨立 `128×128-bit` Y FIFO 與 UV FIFO。
- Y/UV round-robin packet selection。
- 獨立 plane address/line/offset counter。
- frame completion 必須同時滿足 frontend done、兩個 FIFO empty、沒有 active MWr。

接受 descriptor 時會檢查：width 不超過 3840、width 為 128-byte multiple、height 為偶數、stride 不小於 width，以及 PCIe/payload width 是否為已驗證的 128-bit/128-byte 設定。錯誤累加至 BAR0 `0x7C`。

## 6. Plane sizing

| Mode | width/stride | Y lines | UV lines | MWr/frame |
|---|---:|---:|---:|---:|
| 1920×1080 | 1920 | 1080 | 540 | 24,300 |
| 3840×2160 | 3840 | 2160 | 1080 | 97,200 |

因 1920 與 3840 都可被 128 整除，現行 mode 每條 scanline 不需要尾端 partial MWr。

## 7. 效能演進

| 架構 | 實機 1080p FPS | Payload | 請求率 |
|---|---:|---:|---:|
| 16-byte serialized MWr | 80.135 | 237.71 MiB/s | 15.578M MWr/s |
| 128-byte pipeline、125 MHz source | 230.482 | 683.68 MiB/s | 約 5.6M MWr/s |
| 128-byte pipeline、150 MHz source+CDC | 240.526 | 713.47 MiB/s | 5.845M MWr/s |

4K60 需求是 711.91 MiB/s。最新實機等效餘裕只有 0.22%，所以仍需直接 4K physical gate。

## 8. 目前範圍

- 已實機驗證：SG DMA、1080p NV12M、128-byte requester。
- 已仿真驗證：4K NV12M performance/backpressure。
- 待實機：commit `2450dcb7` 的 4K60 600 frames。
- 尚未交付：YUV420M 三平面、USERPTR/DMABUF、multi-channel、ALSA。
