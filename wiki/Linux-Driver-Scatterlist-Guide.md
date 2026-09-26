# Wiki - Linux Kernel Scatterlist 轉置至 PCIe DMA Descriptor 範例

> **狀態：條件式啟用。** A50T V4L2使用`vb2_dma_sg`取得DMA-mapped `sg_table`；只有任一plane的`nents > 1`時才啟用FPGA host SGL fetch。Jetson Orin NX最新4K實測中每個plane均為`nents=1`，因此實際走direct IOVA DMA。強制SGL linked-page驗證計畫見[Host SGL Fetch 驗證與實施計畫](Host-SGL-Validation-Plan.md)。

在 Linux Kernel PCIe 驅動程式中，系統記憶體通常以不連續的頁面 (Pages) 形式存在，並透過 Linux Kernel 的 **`struct scatterlist` (SG List / `struct sg_table`)** 來描述實體記憶體分段。

本文說明如何撰寫 Linux 驅動程式 C 語言程式碼，將 `scatterlist` 經過 DMA 映射後，填入本專案的 **PCIe DMA Descriptor 環形佇列 (Ring Buffer)**。

---

## 1. Linux Kernel DMA 映射基本概念

1. **`dma_map_sgtable()`**：將系統 Kernel/User 頁面進行 IOMMU / Cache 快取同步，並取得 PCIe 總線可存取的 DMA 位址 (`dma_addr_t`)。
2. **`sg_dma_address(sg)`**：取得第 $i$ 個記憶體分段的device-visible DMA位址（可能是IOMMU IOVA，對應Descriptor之`src_addr`或`dst_addr`）。
3. **`sg_dma_len(sg)`**：取得第 $i$ 個分段的傳輸位元組長度（對應 Descriptor 之 `len`）。

---

## 2. Canonical v3.0 16-Byte Thin SG 描述符結構

在 Canonical v3.0 架構下，不再使用傳統的 32-Byte / 64-Byte 胖描述符（Fat Descriptors）。畫面寬度、高度、Stride 與格式皆解耦移至 BAR0 Per-Channel 暫存器（如 `CHx_WIDTH`, `CHx_HEIGHT`, `CHx_STRIDE`, `CHx_CTRL`），描述符統一精簡為 16-Byte Thin SG Entry。

### 2.1 描述符結構體：`struct qpcie_sgl_entry`

```c
#include <linux/module.h>
#include <linux/pci.h>
#include <linux/dma-mapping.h>
#include <linux/scatterlist.h>

/* 16-Byte Canonical v3.0 Hardware SG Descriptor 結構體 */
struct qpcie_sgl_entry {
    u64 pcie_addr;  /* [63:0]  Host 實體 DMA 位址 (IOVA) */
    u32 len;        /* [95:64] 位元組長度 (Bytes) */
    u32 flags;      /* [127:96] 控制標誌:
                     *   bit 0: EOF (End of Frame)
                     *   bit 1: IRQ_ENABLE
                     *   bit 2: DIRECT (1=直接數據, 0=鏈接指標)
                     *   bits 31:3: Reserved
                     */
} __packed __aligned(16);

/* DMA 環形佇列結構 (Thin Ring) */
struct qpcie_thin_ring {
    struct qpcie_sgl_entry *ring_virt;      /* dma_alloc_coherent 分配之虛擬位址 */
    dma_addr_t              ring_dma;       /* Ring Buffer 本身的 DMA 位址 */
    u16                     head_ptr;       /* 硬體消費指針 (HEAD) */
    u16                     tail_ptr;       /* 軟體發行指針 (TAIL) */
    u16                     ring_size;      /* 環形大小 (例如 1024 槽位) */
    void __iomem           *doorbell_reg;   /* BAR0 通道 Doorbell 暫存器 */
};
```

---

## 3. Scatter-Gather 驅動程式填表與發布範例

### 3.1 填入 Thin SG Entry：`qpcie_fill_thin_sg()`

```c
/**
 * qpcie_fill_thin_sg() - 將 Linux scatterlist 分段轉換並填入 Thin Ring
 */
int qpcie_fill_thin_sg(struct qpcie_thin_ring *ring, struct sg_table *sgt, bool irq_on_last)
{
    struct scatterlist *sg;
    int i, nents;
    u16 tail = ring->tail_ptr;

    nents = sgt->nents;
    for_each_sgtable_sg(sgt, sg, i) {
        dma_addr_t bus_addr = sg_dma_address(sg);
        u32 len             = sg_dma_len(sg);
        bool is_last        = (i == nents - 1);

        struct qpcie_sgl_entry *desc = &ring->ring_virt[tail];
        desc->pcie_addr = bus_addr;
        desc->len       = len;
        desc->flags     = (1U << 2); /* DIRECT = 1 */
        if (is_last) {
            desc->flags |= (1U << 0); /* EOF = 1 */
            if (irq_on_last)
                desc->flags |= (1U << 1); /* IRQ_ENABLE = 1 */
        }

        tail = (tail + 1) % ring->ring_size;
    }

    ring->tail_ptr = tail;
    /* 敲響 Doorbell，通知硬體 thin_desc_fetch_engine 抓取並啟動 DMA */
    iowrite32(ring->tail_ptr, ring->doorbell_reg);

    return 0;
}
```

### 3.2 視訊幾何與通道控制暫存器設定 (Per-Channel Configuration)

視訊幾何與格式不再由 descriptor 攜帶，改由 BAR0 暫存器設定：

```c
/* 配置視訊通道 0 幾何與格式 */
iowrite32(1920,        bar0 + CH0_WIDTH);
iowrite32(1080,        bar0 + CH0_HEIGHT);
iowrite32(2048,        bar0 + CH0_STRIDE);   /* 支援對齊或 Padding Stride */
iowrite32(FMT_NV12M,   bar0 + CH0_FMT);      /* 或 FMT_RGB24 */
iowrite32(ENABLE_MASK, bar0 + CH0_CTRL);
```

NV12M 雙平面（Y 與 UV）分別由獨立的 `RING0` 與 `RING1` 透過平行 fetch 進行佇列管理，由硬體自動關聯合成。

---

## 4. 關鍵設計注意事項 (Driver Best Practices)

1. **一致性快取同步 (Cache Coherency)**：
   - 在傳輸前必須先執行 `dma_map_sgtable()`，並在 DMA 完成中斷 handler 中執行 `dma_unmap_sgtable()`，確保 CPU Cache 與 DDR 內容一致。
2. **描述符記憶體對齊 (Coherent DMA Allocation)**：
   - 描述符 Ring 本身必須透過 `dma_alloc_coherent()` 分配，確保硬體 Descriptor Fetch Engine 讀取的 `head_ptr` 與描述符內容是最新的。
3. **環形佇列邊界溢位 (Ring Overflow Protection)**：
   - 驅動程式填入 Descriptor 前，務必檢查 `(tail_ptr + 1) % ring_size != head_ptr`（`head_ptr` 可透過讀取 BAR0 暫存器 `0x28` 或 `0x10` 取得）。
