// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Module: qpcie_main.c
 * Description: Minimal PCI BAR0 & BAR1 Register Read/Write Diagnostic Mode.
 *              Temporarily bypasses V4L2 and ALSA to isolate MMIO hardware stability.
 */

#include "qpcie_driver.h"
#include <linux/delay.h>

static const struct pci_device_id qpcie_id_table[] = {
    { PCI_DEVICE(QPCIE_VENDOR_ID, QPCIE_DEVICE_ID) },
    { 0, }
};
MODULE_DEVICE_TABLE(pci, qpcie_id_table);

static int qpcie_probe(struct pci_dev *pdev, const struct pci_device_id *id)
{
    struct qpcie_dev *qdev;
    int ret;
    u32 ver, git, date, caps, ctrl, stat, readback;

    dev_info(&pdev->dev, "=======================================================\n");
    dev_info(&pdev->dev, "=== [MINIMAL DIAGNOSTIC MODE] QPCIe BAR MMIO Test ===\n");
    dev_info(&pdev->dev, "=======================================================\n");

    qdev = devm_kzalloc(&pdev->dev, sizeof(*qdev), GFP_KERNEL);
    if (!qdev) return -ENOMEM;

    qdev->pdev = pdev;
    pci_set_drvdata(pdev, qdev);

    ret = pci_enable_device(pdev);
    if (ret) {
        dev_err(&pdev->dev, "[ERROR] pci_enable_device failed: %d\n", ret);
        return ret;
    }

    pci_set_master(pdev);

    dev_info(&pdev->dev, "[PCI BAR0 Resource] Start=0x%llx, Len=0x%llx, Flags=0x%lx\n",
             (unsigned long long)pci_resource_start(pdev, 0),
             (unsigned long long)pci_resource_len(pdev, 0),
             (unsigned long)pci_resource_flags(pdev, 0));
    dev_info(&pdev->dev, "[PCI BAR1 Resource] Start=0x%llx, Len=0x%llx, Flags=0x%lx\n",
             (unsigned long long)pci_resource_start(pdev, 1),
             (unsigned long long)pci_resource_len(pdev, 1),
             (unsigned long)pci_resource_flags(pdev, 1));

    ret = pci_request_regions(pdev, "qpcie-dma");
    if (ret) {
        dev_err(&pdev->dev, "[ERROR] pci_request_regions failed: %d\n", ret);
        goto disable_pci;
    }

    /* BAR0 Mapping: DMA Control & Firmware Version Regs */
    qdev->bar0_mmio = pci_iomap(pdev, 0, 0);
    if (!qdev->bar0_mmio) {
        dev_err(&pdev->dev, "[ERROR] BAR0 MMIO pci_iomap failed!\n");
        ret = -ENOMEM;
        goto release_regions;
    }
    dev_info(&pdev->dev, "[MMIO] BAR0 Mapped Virt Addr: %p\n", qdev->bar0_mmio);

    /* BAR1 Mapping: User IP Cores / EDID / Audio Gen */
    qdev->bar1_mmio = pci_iomap(pdev, 1, 0);
    if (!qdev->bar1_mmio) {
        dev_warn(&pdev->dev, "[MMIO WARN] BAR1 User IP MMIO not mapped\n");
    } else {
        dev_info(&pdev->dev, "[MMIO] BAR1 Mapped Virt Addr: %p\n", qdev->bar1_mmio);
    }

    /* ------------------------------------------------------------------------
     * 1. BAR0 Read Tests (Firmware Version, Git Hash, Build Timestamp)
     * ------------------------------------------------------------------------ */
    dev_info(&pdev->dev, "--- [1. BAR0 Register Read Tests] ---\n");

    ver = ioread32(qdev->bar0_mmio + REG_VERSION_ID);
    dev_info(&pdev->dev, "  BAR0 [0x30] Version ID     : 0x%08X (Parsed: v%u.%u.%u Variant %u)\n",
             ver, (ver >> 24) & 0xFF, (ver >> 16) & 0xFF, (ver >> 8) & 0xFF, ver & 0xFF);

    git = ioread32(qdev->bar0_mmio + REG_GIT_COMMIT_HASH);
    dev_info(&pdev->dev, "  BAR0 [0x34] Git Commit Hash: 0x%08X\n", git);

    date = ioread32(qdev->bar0_mmio + REG_BUILD_TIMESTAMP);
    dev_info(&pdev->dev, "  BAR0 [0x38] Build Timestamp: 0x%08X (Date: %08X)\n", date, date);

    caps = ioread32(qdev->bar0_mmio + REG_HARDWARE_CAPS);
    dev_info(&pdev->dev, "  BAR0 [0x3C] Hardware Caps  : 0x%08X (VideoCh=%u, AudioCh=%u, Flags=0x%X)\n",
             caps, (caps >> 8) & 0xFF, (caps >> 16) & 0xFF, caps & 0xFF);

    ctrl = ioread32(qdev->bar0_mmio + REG_DMA_CTRL);
    dev_info(&pdev->dev, "  BAR0 [0x00] DMA Control    : 0x%08X\n", ctrl);

    stat = ioread32(qdev->bar0_mmio + REG_DMA_STATUS);
    dev_info(&pdev->dev, "  BAR0 [0x04] DMA Status     : 0x%08X\n", stat);

    /* ------------------------------------------------------------------------
     * 2. BAR0 Write & Read-back Test
     * ------------------------------------------------------------------------ */
    dev_info(&pdev->dev, "--- [2. BAR0 Write & Readback Test] ---\n");
    u32 dbg_wdata, dbg_waddr;

    iowrite32(0x12345678, qdev->bar0_mmio + REG_H2C_RING_ADDR_L); // offset 0x08
    readback = ioread32(qdev->bar0_mmio + REG_H2C_RING_ADDR_L);
    dbg_wdata = ioread32(qdev->bar0_mmio + 0x68);
    dbg_waddr = ioread32(qdev->bar0_mmio + 0x6C);
    dev_info(&pdev->dev, "  BAR0 [0x08] Write 0x12345678 -> Readback: 0x%08X %s (Hardware Captured: Addr=0x%02X, Data=0x%08X)\n",
             readback, (readback == 0x12345678) ? "[PASS]" : "[FAIL]", dbg_waddr, dbg_wdata);

    iowrite32(0x87654321, qdev->bar0_mmio + REG_C2H_RING_ADDR_L); // offset 0x14
    readback = ioread32(qdev->bar0_mmio + REG_C2H_RING_ADDR_L);
    dbg_wdata = ioread32(qdev->bar0_mmio + 0x68);
    dbg_waddr = ioread32(qdev->bar0_mmio + 0x6C);
    dev_info(&pdev->dev, "  BAR0 [0x14] Write 0x87654321 -> Readback: 0x%08X %s (Hardware Captured: Addr=0x%02X, Data=0x%08X)\n",
             readback, (readback == 0x87654321) ? "[PASS]" : "[FAIL]", dbg_waddr, dbg_wdata);

    /* Restore zero values */
    iowrite32(0x00000000, qdev->bar0_mmio + REG_H2C_RING_ADDR_L);
    iowrite32(0x00000000, qdev->bar0_mmio + REG_C2H_RING_ADDR_L);

    /* Enable Bus Mastering and configure 64-bit DMA Mask */
    ret = dma_set_mask_and_coherent(&pdev->dev, DMA_BIT_MASK(64));
    if (ret) {
        ret = dma_set_mask_and_coherent(&pdev->dev, DMA_BIT_MASK(32));
        if (ret) {
            dev_err(&pdev->dev, "[ERROR] Cannot set DMA mask!\n");
            goto unmap_mmio;
        }
    }
    pci_set_master(pdev);

    /* --------------------------------------------------------------------
     * 3. Scatter-Gather (SG List) DMA Verification: 4x H2C + 4x C2H Pages
     * -------------------------------------------------------------------- */
    dev_info(&pdev->dev, "--- [3. Scatter-Gather (SG List) DMA Verification] ---\n");

    #define SG_PAGES 4
    dma_addr_t desc_ring_dma;
    dma_addr_t h2c_page_dma[SG_PAGES];
    dma_addr_t c2h_page_dma[SG_PAGES];
    u32 *h2c_pages[SG_PAGES];
    u32 *c2h_pages[SG_PAGES];
    int p, w;

    struct qpcie_dma_desc_64b *desc_ring = dma_alloc_coherent(&pdev->dev, 64 * 16, &desc_ring_dma, GFP_KERNEL);

    if (!desc_ring) {
        dev_err(&pdev->dev, "[ERROR] dma_alloc_coherent failed for Descriptor Ring!\n");
    } else {
        memset(desc_ring, 0, 64 * 16);
        dev_info(&pdev->dev, "  Allocated Coherent Ring: Phys=0x%llX (Virt=%p)\n", (u64)desc_ring_dma, desc_ring);

        for (p = 0; p < SG_PAGES; p++) {
            h2c_pages[p] = dma_alloc_coherent(&pdev->dev, 4096, &h2c_page_dma[p], GFP_KERNEL);
            c2h_pages[p] = dma_alloc_coherent(&pdev->dev, 4096, &c2h_page_dma[p], GFP_KERNEL);
            if (h2c_pages[p]) {
                for (w = 0; w < 1024; w++) {
                    h2c_pages[p][w] = 0xAA000000 | (p << 16) | w;
                }
            }
            if (c2h_pages[p]) {
                memset(c2h_pages[p], 0x00, 4096);
            }
            dev_info(&pdev->dev, "  [SG Page %d] H2C Phys=0x%llX (Pattern: 0x%08X), C2H Phys=0x%llX\n",
                     p, (u64)h2c_page_dma[p], h2c_pages[p] ? h2c_pages[p][0] : 0, (u64)c2h_page_dma[p]);
        }

        /* Build SG Ring: Descriptors 0..3 for H2C, Descriptors 4..7 for C2H */
        for (p = 0; p < SG_PAGES; p++) {
            desc_ring[p].plane0_src_addr = (u64)h2c_page_dma[p];
            desc_ring[p].plane0_dst_addr = 0x0ULL;
            desc_ring[p].line_width      = 4096;
            desc_ring[p].line_count      = 1;
            desc_ring[p].src_stride      = 4096;
            desc_ring[p].dst_stride      = 4096;
            desc_ring[p].format          = 0;
            desc_ring[p].plane_count     = 1;
            desc_ring[p].control         = 0x00; /* H2C: Host -> FPGA */

            desc_ring[p + SG_PAGES].plane0_src_addr = 0x0ULL;
            desc_ring[p + SG_PAGES].plane0_dst_addr = (u64)c2h_page_dma[p];
            desc_ring[p + SG_PAGES].line_width      = 4096;
            desc_ring[p + SG_PAGES].line_count      = 1;
            desc_ring[p + SG_PAGES].src_stride      = 4096;
            desc_ring[p + SG_PAGES].dst_stride      = 4096;
            desc_ring[p + SG_PAGES].format          = 0;
            desc_ring[p + SG_PAGES].plane_count     = 1;
            desc_ring[p + SG_PAGES].control         = 0x02; /* C2H: FPGA -> Host */
        }

        /* Program Ring Base Address into BAR0 0x08 (Low) and 0x0C (High) */
        iowrite32((u32)(desc_ring_dma & 0xFFFFFFFF), qdev->bar0_mmio + REG_H2C_RING_ADDR_L);
        iowrite32((u32)((desc_ring_dma >> 32) & 0xFFFFFFFF), qdev->bar0_mmio + REG_H2C_RING_ADDR_H);

        /* Set Ring Config: Size=16, Tail=4 (Trigger 4x H2C Descriptors) */
        iowrite32((4 << 16) | 16, qdev->bar0_mmio + REG_H2C_RING_CFG);

        /* Trigger DMA Start */
        iowrite32(0x00000001, qdev->bar0_mmio + REG_DMA_CTRL);
        dev_info(&pdev->dev, "--- [3.1 Step 1: H2C 4-Page SG List DMA Read Test] ---\n");
        dev_info(&pdev->dev, "  Triggered H2C SG Run (Tail=4, Size=16)... Waiting 20ms\n");
        msleep(20);

        u32 dma_stat = ioread32(qdev->bar0_mmio + REG_DMA_STATUS);
        u32 comp_h2c = ioread32(qdev->bar0_mmio + REG_COMPLETED_H2C);
        u32 ptr_dbg  = ioread32(qdev->bar0_mmio + 0x40);
        dev_info(&pdev->dev, "  H2C SG Status: DMA_STATUS=0x%08X, Completed Count=%u, Pointers=0x%08X (Tail=%u, Head=%u)\n",
                 dma_stat, comp_h2c, ptr_dbg, (ptr_dbg >> 16) & 0xFFFF, ptr_dbg & 0xFFFF);

        /* Advance Tail Pointer to 8 (Trigger 4x C2H Descriptors) */
        dev_info(&pdev->dev, "--- [3.2 Step 2: C2H 4-Page SG List DMA Write Test] ---\n");
        iowrite32((8 << 16) | 16, qdev->bar0_mmio + REG_H2C_RING_CFG);
        dev_info(&pdev->dev, "  Triggered C2H SG Run (Tail=8, Size=16)... Waiting 20ms\n");
        msleep(20);

        dma_stat = ioread32(qdev->bar0_mmio + REG_DMA_STATUS);
        u32 comp_c2h = ioread32(qdev->bar0_mmio + REG_COMPLETED_C2H);
        ptr_dbg  = ioread32(qdev->bar0_mmio + 0x40);
        dev_info(&pdev->dev, "  C2H SG Status: DMA_STATUS=0x%08X, Completed Count=%u, Pointers=0x%08X (Tail=%u, Head=%u)\n",
                 dma_stat, comp_c2h, ptr_dbg, (ptr_dbg >> 16) & 0xFFFF, ptr_dbg & 0xFFFF);

        /* Inspect C2H pages */
        for (p = 0; p < SG_PAGES; p++) {
            if (c2h_pages[p]) {
                dev_info(&pdev->dev, "  C2H Page %d Content: [0]=0x%08X, [1]=0x%08X, [2]=0x%08X, [3]=0x%08X\n",
                         p, c2h_pages[p][0], c2h_pages[p][1], c2h_pages[p][2], c2h_pages[p][3]);
            }
        }

        /* Stop DMA */
        iowrite32(0x00000000, qdev->bar0_mmio + REG_DMA_CTRL);

        /* Free DMA Buffers */
        dma_free_coherent(&pdev->dev, 64 * 16, desc_ring, desc_ring_dma);
        for (p = 0; p < SG_PAGES; p++) {
            if (h2c_pages[p]) dma_free_coherent(&pdev->dev, 4096, h2c_pages[p], h2c_page_dma[p]);
            if (c2h_pages[p]) dma_free_coherent(&pdev->dev, 4096, c2h_pages[p], c2h_page_dma[p]);
        }
    }

    dev_info(&pdev->dev, "=======================================================\n");
    dev_info(&pdev->dev, "🎉 [DMA STEP-BY-STEP DIAGNOSTIC TEST COMPLETED]\n");
    dev_info(&pdev->dev, "=======================================================\n");
    return 0;

unmap_mmio:
    if (qdev->bar1_mmio) pci_iounmap(pdev, qdev->bar1_mmio);
    pci_iounmap(pdev, qdev->bar0_mmio);
release_regions:
    pci_release_regions(pdev);
disable_pci:
    pci_disable_device(pdev);
    return ret;
}

static void qpcie_remove(struct pci_dev *pdev)
{
    struct qpcie_dev *qdev = pci_get_drvdata(pdev);

    dev_info(&pdev->dev, "Removing QPCIe Driver (Minimal Diagnostic Mode)...\n");

    if (qdev->bar1_mmio) pci_iounmap(pdev, qdev->bar1_mmio);
    if (qdev->bar0_mmio) pci_iounmap(pdev, qdev->bar0_mmio);
    pci_release_regions(pdev);
    pci_disable_device(pdev);

    dev_info(&pdev->dev, "QPCIe Driver Removed Cleanly\n");
}

static struct pci_driver qpcie_driver = {
    .name     = "qpcie-dma",
    .id_table = qpcie_id_table,
    .probe    = qpcie_probe,
    .remove   = qpcie_remove,
};

module_pci_driver(qpcie_driver);

MODULE_AUTHOR("Advanced Agentic Coding Team");
MODULE_DESCRIPTION("QPCIe Minimal PCI BAR0/BAR1 Register Diagnostic Driver");
MODULE_LICENSE("GPL");
