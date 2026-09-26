# DMA Core Layer：SG、128-byte MWr 與 NV12M Engine

## 1. 16-byte Thin SG Descriptor（Canonical v3.0）

目前正式 descriptor wire format 為 4 DW（16 Bytes / 128-bit）：

```text
DW0–1   [63:0]   host_addr    sgl->dma_address 直行（實體基底位址）
DW2     [95:64]  len_bytes    sgl->length 直行（連續傳輸長度）
DW3     [127:96] flags        bit 0: chain_ptr, bit 1: last_seg
```

- **Driver 零計算**：驅動只需直行遍歷 Linux `sg_table` 填入位址與長度，不分平面、不包幾何參數。
- **幾何下放**：幀幾何（`WIDTH`、`HEIGHT`、`STRIDE0~3`）改由各通道獨立的 BAR0 暫存器（如 `0x0108`、`0x010C` 等）在 `STREAMON` 時統一配置一次。
- **Per-plane 獨立 Ring**：NV12M 下 `RING0` 負責 Y 平面，`RING1` 負責 UV 平面；RGB24 僅使用 `RING0`。

## 2. Thin SG Descriptor Fetch

`thin_desc_fetch_engine.v` 監聽各通道 Doorbell（`head != tail`），使用 MRd（Tag 0）直接抓取 16-byte descriptor：
- 自動平行抓取雙環（RING0 與 RING1）。
- Byte-count Framing：硬體累計傳輸長度達到幀目標大小時自動發出幀完成信號。
- 剝除 CplD header 後，直推至 150MHz 視訊域 CDC FIFO，免去舊版中間層 linked-page 轉換開銷。

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

4K60需求是711.91 MiB/s。16-tag H2C direct-I/O-VA 4K loopback已實測H2C/C2H各934.60 MiB/s、100% bit-exact；此結果不包含host SGL fetch linked-page。

## 8. 目前範圍

- 已實機驗證：SG DMA、1080p/4K NV12M loopback、128-byte requester、16-tag H2C direct-I/O-VA loopback。
- 已仿真驗證：4K NV12M performance/backpressure。
- 待實機：強制host SGL fetch linked-page的4K correctness與throughput驗證。
- 尚未交付：YUV420M 三平面、USERPTR/DMABUF、multi-channel、ALSA。
