# Wiki - Linux Kernel Scatterlist 轉置至 PCIe DMA Descriptor 範例

在 Linux Kernel PCIe 驅動程式中，系統記憶體通常以不連續的頁面 (Pages) 形式存在，並透過 Linux Kernel 的 **`struct scatterlist` (SG List / `struct sg_table`)** 來描述實體記憶體分段。

本文說明如何撰寫 Linux 驅動程式 C 語言程式碼，將 `scatterlist` 經過 DMA 映射後，填入本專案的 **PCIe DMA Descriptor 環形佇列 (Ring Buffer)**。

---

## 1. Linux Kernel DMA 映射基本概念

1. **`dma_map_sgtable()`**：將系統 Kernel/User 頁面進行 IOMMU / Cache 快取同步，並取得 PCIe 總線可存取的 DMA 位址 (`dma_addr_t`)。
2. **`sg_dma_address(sg)`**：取得第 $i$ 個記憶體分段的 PCIe DMA 實體位址（對應 Descriptor 之 `src_addr` 或 `dst_addr`）。
3. **`sg_dma_len(sg)`**：取得第 $i$ 個分段的傳輸位元組長度（對應 Descriptor 之 `len`）。

---

## 2. 1D 線性 Scatter-Gather 驅動程式範例 C Code

### 2.1 C 語言 C 碼：`pcie_dma_fill_sg_descriptors()`

```c
#include <linux/module.h>
#include <linux/pci.h>
#include <linux/dma-mapping.h>
#include <linux/scatterlist.h>

/* 32-Byte 1D Hardware Descriptor 結構體 (與 Verilog desc_fetch_engine 格式完全對應) */
struct pcie_dma_desc_1d {
    u64 src_addr;   /* DW0-DW1: 來源 PCIe DMA 位址 (Host RAM 或 FPGA RAM) */
    u64 dst_addr;   /* DW2-DW3: 目的 PCIe DMA 位址 (FPGA RAM 或 Host RAM) */
    u32 len;        /* DW4    : 傳輸位元組長度 (Bytes) */
    u32 ctrl;       /* DW5    : 控制位元 (Bit 0: Valid, Bit 1: Direction 0=H2C/1=C2H, Bit 3: IRQ_EN) */
    u32 reserved[2];/* DW6-DW7: 保留對齊 32-Byte */
} __packed __aligned(32);

/* DMA 環形佇列結構 */
struct pcie_dma_ring {
    struct pcie_dma_desc_1d *ring_virt_addr; /* dma_alloc_coherent 分配之虛擬位址 */
    dma_addr_t               ring_dma_handle;/* Ring Buffer 本身的 DMA 位址 */
    u16                      head_ptr;
    u16                      tail_ptr;
    u16                      ring_size;
    void __iomem            *bar0_mmio;      /* PCIe BAR0 MMIO 暫存器基底位址 */
};

/**
 * pcie_dma_map_and_fill_sg() - 將 Linux sg_table 轉換並填入 PCIe DMA Ring Buffer
 * @pdev: PCI 裝置結構體
 * @ring: DMA 環形佇列
 * @sgt:  Linux scatterlist 表格
 * @fpga_dst_addr: FPGA 側 AXI4 MM 記憶體起始目的位址
 * @is_c2h: 傳輸方向 (0: Host->FPGA H2C, 1: FPGA->Host C2H)
 */
int pcie_dma_map_and_fill_sg(struct pci_dev *pdev, struct pcie_dma_ring *ring,
                            struct sg_table *sgt, u64 fpga_dst_addr, bool is_c2h)
{
    struct scatterlist *sg;
    int i, count;
    u64 current_fpga_addr = fpga_dst_addr;

    /* 1. 呼叫 Linux DMA API 進行 Cache 同步與 IOMMU 映射 */
    count = dma_map_sgtable(&pdev->dev, sgt, is_c2h ? DMA_FROM_DEVICE : DMA_TO_DEVICE, 0);
    if (count <= 0) {
        dev_err(&pdev->dev, "Failed to map scatterlist table!\n");
        return -ENOMEM;
    }

    /* 2. 逐一遍歷每一個 DMA 散佈分段 (Scatter Segment) */
    for_each_sgtable_sg(sgt, sg, i) {
        dma_addr_t bus_addr = sg_dma_address(sg); /* 取得 mapped PCIe DMA 位址 */
        u32 segment_len     = sg_dma_len(sg);     /* 取得該區段長度 */

        struct pcie_dma_desc_1d *desc = &ring->ring_virt_addr[ring->tail_ptr];

        /* 3. 填入 Descriptor 欄位 */
        if (!is_c2h) {
            /* H2C: Host Memory (bus_addr) -> FPGA Memory (current_fpga_addr) */
            desc->src_addr = bus_addr;
            desc->dst_addr = current_fpga_addr;
        } else {
            /* C2H: FPGA Memory (current_fpga_addr) -> Host Memory (bus_addr) */
            desc->src_addr = current_fpga_addr;
            desc->dst_addr = bus_addr;
        }

        desc->len  = segment_len;
        desc->ctrl = 0x00000009; /* Bit 0: Valid=1, Bit 3: IRQ_Enable=1 */
        if (is_c2h) desc->ctrl |= (1 << 1); /* Bit 1: Is_C2H */

        /* 4. 推進指標與計算下一個區段之 FPGA 記憶體位址 */
        current_fpga_addr += segment_len;
        ring->tail_ptr = (ring->tail_ptr + 1) % ring->ring_size;
    }

    /* 5. 寫入 PCIe BAR0 暫存器 (H2C_RING_CFG 或 C2H_RING_CFG)，通知 FPGA 硬體開工 */
    u32 ring_cfg_val = ((u32)ring->tail_ptr << 16) | (ring->ring_size & 0xFFFF);
    iowrite32(ring_cfg_val, ring->bar0_mmio + (is_c2h ? 0x1C : 0x10));

    /* 啟動 DMA Engine (DMA_CTRL 暫存器 Offset 0x00) */
    iowrite32(is_c2h ? 0x02 : 0x01, ring->bar0_mmio + 0x00);

    return 0;
}
```

---

## 3. 2D Multi-Planar Video Frame (帶 Stride) 驅動程式範例 C Code

對於視訊處理 (Video4Linux2 / V4L2 `vb2_dma_sg` / `dma_buf`)，畫面資料具備 **Y, U, V 多平面** 與 **跨行步長 (Stride / Pitch)**。

### 3.1 64-Byte 2D Multi-Planar Descriptor C 結構體

```c
/* 64-Byte 2D/3D Multi-Planar Video Descriptor 結構體 */
struct pcie_dma_desc_2d_video {
    u64 plane0_src_addr; /* DW0-DW1 : Y / R / Mono 來源位址 */
    u64 plane0_dst_addr; /* DW2-DW3 : Y / R / Mono 目的位址 */
    u64 plane1_src_addr; /* DW4-DW5 : U / UV / G 來源位址 */
    u64 plane1_dst_addr; /* DW6-DW7 : U / UV / G 目的位址 */
    u64 plane2_src_addr; /* DW8-DW9 : V / B 來源位址 */
    u64 plane2_dst_addr; /* DW10-DW11: V / B 目的位址 */

    /* DW12: Line Width & Line Count (Plane 0) */
    u16 plane0_line_width; /* 有效像素 Bytes (例如 1920 Bytes) */
    u16 plane0_line_count; /* 畫面高度 Lines (例如 1080 行) */

    /* DW13: Line Stride / Pitch */
    u16 src_line_stride;   /* 來源跨行步長 (含 Padding, 例如 2048 Bytes) */
    u16 dst_line_stride;   /* 目的跨行步長 */

    /* DW14: Sub-sampled Plane 1/2 Dimension (for YUV420P) */
    u16 plane12_line_width;/* 色度平面 Line Width (例如 960 Bytes) */
    u16 plane12_line_count;/* 色度平面 Height (例如 540 行) */

    /* DW15: Format & Control Flags */
    u8  format;            /* 0x1: 2D Mono, 0x2: NV12, 0x3: YUV420P */
    u8  plane_count;       /* 平面數量 (1, 2, 或 3) */
    u16 control;           /* Bit 0: Valid, Bit 3: IRQ_Enable */
} __packed __aligned(64);
```

### 3.2 C 語言範例：`pcie_dma_fill_video_descriptor()`

```c
/**
 * pcie_dma_fill_video_descriptor() - 將 V4L2 YUV420P / NV12 畫面填入 64-Byte 2D Descriptor
 */
int pcie_dma_fill_video_descriptor(struct pcie_dma_ring *ring,
                                  dma_addr_t y_dma_addr,
                                  dma_addr_t u_dma_addr,
                                  dma_addr_t v_dma_addr,
                                  u64 fpga_frame_buffer_addr,
                                  u32 width, u32 height, u32 stride, u8 format)
{
    struct pcie_dma_desc_2d_video *desc = (struct pcie_dma_desc_2d_video *)
                                           &ring->ring_virt_addr[ring->tail_ptr];

    memset(desc, 0, sizeof(*desc));

    /* 1. 填入各 Plane 之 PCIe DMA 記憶體位址 */
    desc->plane0_src_addr = y_dma_addr;
    desc->plane0_dst_addr = fpga_frame_buffer_addr; /* FPGA 端連貫 Frame Buffer */

    if (format == 0x02) { /* NV12 (Semi-Planar: Y + UV) */
        desc->plane1_src_addr = u_dma_addr; /* UV Plane Base */
        desc->plane1_dst_addr = fpga_frame_buffer_addr + (width * height);
        desc->plane_count     = 2;
    } else if (format == 0x03) { /* YUV420P (Planar: Y + U + V) */
        desc->plane1_src_addr = u_dma_addr;
        desc->plane1_dst_addr = fpga_frame_buffer_addr + (width * height);
        desc->plane2_src_addr = v_dma_addr;
        desc->plane2_dst_addr = fpga_frame_buffer_addr + (width * height) + (width * height / 4);
        desc->plane_count     = 3;
    } else { /* 2D Single Plane / Mono */
        desc->plane_count     = 1;
    }

    /* 2. 填入 2D 尺寸與 Stride 步長 */
    desc->plane0_line_width  = width;   /* 畫面寬度 Bytes */
    desc->plane0_line_count  = height;  /* 畫面高度 Lines */
    desc->src_line_stride    = stride;  /* 含 Padding 之 Line Stride */
    desc->dst_line_stride    = width;   /* FPGA 側無 Padding 對齊寫入 */

    desc->plane12_line_width = width / 2;
    desc->plane12_line_count = height / 2;

    /* 3. 填入控制與致能 Flags */
    desc->format  = format;
    desc->control = 0x0009; /* Valid = 1, IRQ_EN = 1 */

    /* 4. 更新 Ring Tail Pointer 並通知 FPGA 啟動 DMA */
    ring->tail_ptr = (ring->tail_ptr + 1) % ring->ring_size;
    iowrite32(((u32)ring->tail_ptr << 16) | ring->ring_size, ring->bar0_mmio + 0x10);
    iowrite32(0x01, ring->bar0_mmio + 0x00); /* Start H2C DMA */

    return 0;
}
```

---

## 4. 關鍵設計注意事項 (Driver Best Practices)

1. **一致性快取同步 (Cache Coherency)**：
   - 在傳輸前必須先執行 `dma_map_sgtable()`，並在 DMA 完成中斷 handler 中執行 `dma_unmap_sgtable()`，確保 CPU Cache 與 DDR 內容一致。
2. **描述符記憶體對齊 (Coherent DMA Allocation)**：
   - 描述符 Ring 本身必須透過 `dma_alloc_coherent()` 分配，確保硬體 Descriptor Fetch Engine 讀取的 `head_ptr` 與描述符內容是最新的。
3. **環形佇列邊界溢位 (Ring Overflow Protection)**：
   - 驅動程式填入 Descriptor 前，務必檢查 `(tail_ptr + 1) % ring_size != head_ptr`（`head_ptr` 可透過讀取 BAR0 暫存器 `0x28` 或 `0x10` 取得）。
