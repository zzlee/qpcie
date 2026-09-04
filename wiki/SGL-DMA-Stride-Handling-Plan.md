# SGL DMA 模式下 Stride 處理規劃方案

## 1. 問題定義與背景

在現行 QPCIe 視訊 DMA 架構中，視訊影格以 NV12M（Planar Y / UV）格式進行 C2H（FPGA 至 Host）傳輸。
- **Direct DMA 模式**：
  - 由 FPGA 2D 搬移邏輯處理，以固定 `dst_stride` 在連續記憶體空間中自動推進（`line_start_addr + dst_stride`）。
  - 當前實機測試（1080p60 / 4K60）在 Direct DMA 模式下已 100% 驗證通過。
- **Scatter-Gather List (SGL) Fetch 模式**：
  - 當 Host 記憶體碎片化或透過 DMABUF / SMMU 引入不連續實體頁面（Physical / IOVA Segments）時，需啟用 SGL Fetch。
  - 在 Linux V4L2 體系（尤其配合 GStreamer、NVMM、DRM 或 GPU 緩衝區）時，視訊緩衝區通常要求特定行對齊（如 `stride = ALIGN(width, 128)` 或 `ALIGN(width, 256)`）。
  - **核心挑戰**：在非連續頁面的 SGL 架構中，**行跨距填充（Stride Padding，即 `stride - active_width`）**可能橫跨 4KB 頁面邊界。若硬體 walker 或驅動在建立 SGL 時未正確同步 Stride 與 Active Width，將導致畫面水平錯位、傾斜（skewing）或 PCIe MalfTLP 錯誤。

---

## 2. 候選方案評估與決策

| 方案 | 架構機制 | 優點 | 缺點 | 評估結論 |
|---|---|---|---|---|
| **方案一：硬體純 2D SGL Engine** | 硬體 Walker 內部維護 2D X/Y 計數器，自行計算跳過 padding | 驅動層 SGL 只需映射連續全緩衝區 | 硬體 RTL 邏輯大幅膨脹，跨 4KB 與跨 SGL entry 的 2D 狀態機極其複雜，易引入 timing closure 失敗 | 不推薦 |
| **方案二：驅動層 SGL 剔除 Padding** | 驅動層為每一行視訊資料獨立建立 SGL entry，主動跳過行尾 padding | 硬體不需修改，保持 1D 線性消耗 | SGL entries 數量暴增（1080p 需要 1,620 個 entries，4K 需要 3,240 個 entries），超過單個 4KB SGL slot (255 entries)，顯著增加 PCIe MRd SGL 開銷 | 不推薦 |
| **方案三：Linux 驅動層動態協商 + 2D Descriptor 配合（選定方案）** | 驅動層 `videobuf2-dma-sg` 於 `s_fmt` 動態計算 `bytesperline`，由 2D Descriptor 明確傳遞 `line_width`、`dst_stride` 給 FPGA，SGL Table 映射完整空間，由硬體 2D 行地址產生器配合 SGL 頁面偏移轉換 | 兼具標準 V4L2 協商相容性、SGL Table 數量最小化，且已相容目前 2D Descriptor 暫存器欄位 | 需嚴格保證 stride 對齊 128/256 bytes 以符合 TLP burst 邊界 | **確定採用** |

---

## 3. 方案三詳細規格與實作細節 (Phase 2)

### 3.1 V4L2 Format 協商 (`driver/qpcie_v4l2.c`)
- 在 `qpcie_fill_pix_format()` 與 `qpcie_vidioc_try_fmt_vid_cap_mplane()` 中支援自訂或自動對齊 Stride：
  ```c
  /* NV12M Plane 0 (Y): active width = mode->width, stride 需對齊 128 或 256 位元組 */
  u32 stride = ALIGN(mode->width, 128);
  pix->plane_fmt[0].bytesperline = stride;
  pix->plane_fmt[0].sizeimage = stride * mode->height;

  /* NV12M Plane 1 (UV): active width = mode->width, stride 需與 Y plane 一致 */
  pix->plane_fmt[1].bytesperline = stride;
  pix->plane_fmt[1].sizeimage = stride * (mode->height / 2);
  ```
- 在 `qpcie_vidioc_s_fmt_vid_cap_mplane()` 中：
  - 保存用戶端傳入或協商後的 `vch->stride = f->fmt.pix_mp.plane_fmt[0].bytesperline`。
  - 驗證 `vch->stride >= vch->width` 且 `(vch->stride % 128) == 0`。

### 3.2 2D Extended Descriptor 欄位填充 (`qpcie_publish_buffer`)
在發送 64-byte 2D Descriptor 至 H2C/C2H Ring 時，精確設定：
- `desc->line_width = vch->width;` （實際有效像素位元組數，如 1920 或 3840）
- `desc->dst_stride = vch->stride;` （記憶體每行跨距，如 2048 或 4096）
- `desc->plane12_width = vch->width;`
- `desc->line_count = vch->height;`
- `desc->plane12_count = vch->height / 2;`

### 3.3 SGL Table 構建與 4KB 頁面邊界保護 (`qpcie_build_variable_sgl`)
- `sg_table` 透過 `vb2_dma_sg_plane_desc()` 取得。因分配時已包含 `sizeimage`（即包含每行 stride padding 的總容量），SGL Table 完整覆蓋該記憶體區塊。
- 驅動程式繼續執行 4KiB IOVA boundary 截斷，保證任何單一 SGL entry 絕不跨越 4KB 邊界，避免發送 PCIe MalfTLP。

### 3.4 FPGA 硬體配合確認 (`rtl/nv12_capture_engine.v`)
- 硬體在換行時：
  ```verilog
  if (y_send_offset + active_req_bytes >= width_q) begin
      y_send_offset     <= 16'd0;
      y_send_line       <= y_send_line + 1'b1;
      y_line_start_addr <= y_line_start_addr + stride_q;
      y_send_addr       <= y_line_start_addr + stride_q;
  end
  ```
- 當 `desc_sg_mode` 啟用時，確認 `y_walker` 是否能夠以 2D 跳躍重設位址，或由 Walker 自動跳過 padding 區域。

---

## 4. 實施階段規劃 (Phase 2 Milestones)

- **Milestone 2.1: 驅動層 Stride 對齊與協商開放**
  - 修改 `driver/qpcie_v4l2.c`，支援 128/256-byte stride 對齊。
  - 支援 GStreamer `video/x-raw, width=1920, height=1080` 搭配非同步 buffer 分配器。
- **Milestone 2.2: SGL Descriptor 2D 整合與邊界檢查**
  - 驗證 `qpcie_publish_buffer` 在帶有 stride 的情況下正確生成 SGL entries 與 descriptor。
- **Milestone 2.3: 實機 Loopback 驗證**
  - 於 Jetson Orin NX 執行多幀測試，檢驗畫面幾何形狀無變形、無傾斜，且 100% bit-exact。
