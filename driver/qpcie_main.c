// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Module: qpcie_main.c
 * Description: Minimal PCI BAR0 & BAR1 Register Read/Write Diagnostic Mode.
 *              Temporarily bypasses V4L2 and ALSA to isolate MMIO hardware stability.
 */

#include "qpcie_driver.h"
#include <linux/delay.h>

#define SG_PAGES 4

void qpcie_dma_soft_reset(struct qpcie_dev *qdev)
{
    iowrite32(DMA_CTRL_RESET, qdev->bar0_mmio + REG_DMA_CTRL);
    ioread32(qdev->bar0_mmio + REG_DMA_CTRL);
    usleep_range(1000, 2000);
    iowrite32(0, qdev->bar0_mmio + REG_DMA_CTRL);
    ioread32(qdev->bar0_mmio + REG_DMA_CTRL);
    usleep_range(1000, 2000);
}

static irqreturn_t qpcie_irq_handler(int irq, void *data)
{
    struct qpcie_dev *qdev = data;
    u32 status = ioread32(qdev->bar0_mmio + REG_IRQ_STATUS);

    if (!(status & IRQ_STATUS_ALL_MASK))
        return IRQ_NONE;

    /* Pass completion interrupts to V4L2 handler */
    if (qdev->v4l2_registered && (status & (IRQ_STATUS_CHANNEL_MASK | IRQ_STATUS_H2C_GLOBAL | IRQ_STATUS_C2H_GLOBAL)))
        qpcie_v4l2_irq_handler(qdev);

    /* Pass completion interrupts to ALSA handler */
    if (qdev->alsa_registered && (status & IRQ_STATUS_AUDIO_MASK))
        qpcie_alsa_irq_handler(qdev, status);

    iowrite32(status & IRQ_STATUS_ALL_MASK, qdev->bar0_mmio + REG_IRQ_STATUS);
    return IRQ_HANDLED;
}

static int qpcie_wait_dma(struct qpcie_dev *qdev, u32 count_reg, u32 target)
{
    int retry;

    for (retry = 0; retry < 500; retry++) {
        u32 count = ioread32(qdev->bar0_mmio + count_reg);
        u32 status = ioread32(qdev->bar0_mmio + REG_DMA_STATUS);
        if (count >= target && !(status & 0x00000c00))
            return 0;
        usleep_range(1000, 2000);
    }
    return -ETIMEDOUT;
}

static void qpcie_dump_dma_state(struct qpcie_dev *qdev, const char *phase)
{
    u32 status = ioread32(qdev->bar0_mmio + REG_DMA_STATUS);
    u32 h2c = ioread32(qdev->bar0_mmio + REG_COMPLETED_H2C);
    u32 c2h = ioread32(qdev->bar0_mmio + REG_COMPLETED_C2H);
    u32 hptr = ioread32(qdev->bar0_mmio + 0x40);
    u32 hcfg = ioread32(qdev->bar0_mmio + REG_H2C_RING_CFG);
    u32 rlo = ioread32(qdev->bar0_mmio + REG_H2C_RING_ADDR_L);
    u32 rhi = ioread32(qdev->bar0_mmio + REG_H2C_RING_ADDR_H);

    dev_err(&qdev->pdev->dev,
            "[%s] DMA_STATUS=0x%08X H2C_DONE=%u C2H_DONE=%u "
            "RING=0x%08X%08X CFG(size=%u tail=%u) PTR(head=%u tail=%u)\n",
            phase, status, h2c, c2h, rhi, rlo,
            hcfg & 0xffff, hcfg >> 16, hptr & 0xffff, hptr >> 16);
}

static const struct pci_device_id qpcie_id_table[] = {
    { PCI_DEVICE(QPCIE_VENDOR_ID, QPCIE_DEVICE_ID) },
    { 0, }
};
MODULE_DEVICE_TABLE(pci, qpcie_id_table);

static int sg_fetch_mode = QPCIE_SG_MODE_HOST_FETCH;
module_param(sg_fetch_mode, int, 0644);
MODULE_PARM_DESC(sg_fetch_mode, "Scatter-Gather Page Table Fetch Mode (1: MMIO BRAM, 2: Active Host MRd Fetch)");

static int qpcie_probe(struct pci_dev *pdev, const struct pci_device_id *id)
{
    struct qpcie_dev *qdev;
    struct qpcie_dma_desc_64b *desc_ring;
    dma_addr_t desc_ring_dma;
    dma_addr_t h2c_page_dma[SG_PAGES] = { 0 };
    dma_addr_t c2h_page_dma[SG_PAGES] = { 0 };
    u32 *h2c_pages[SG_PAGES] = { NULL };
    u32 *c2h_pages[SG_PAGES] = { NULL };
    int ret, p, w;
    u32 ver, git, date, caps, ctrl, stat, readback;
    u32 dbg_wdata, dbg_waddr;
    u32 ring_head, c2h_tail, h2c_tail;
    u32 start_c2h, start_h2c;
    u32 dma_stat, comp_c2h, comp_h2c, ptr_dbg;

    dev_info(&pdev->dev, "=======================================================\n");
    dev_info(&pdev->dev, "=== [MINIMAL DIAGNOSTIC MODE] QPCIe BAR MMIO Test ===\n");
    dev_info(&pdev->dev, "=======================================================\n");

    qdev = devm_kzalloc(&pdev->dev, sizeof(*qdev), GFP_KERNEL);
    if (!qdev) return -ENOMEM;

    qdev->pdev = pdev;
    qdev->sg_fetch_mode = sg_fetch_mode;
    pci_set_drvdata(pdev, qdev);

    ret = pci_enable_device(pdev);
    if (ret) {
        dev_err(&pdev->dev, "[ERROR] pci_enable_device failed: %d\n", ret);
        return ret;
    }

    pci_set_master(pdev);

    /* The SG diagnostic and the capture engines emit 256-byte MWr payloads.
     * Instead of a system-wide pci=pcie_bus_perf boot parameter, raise the
     * negotiated MPS on this path only (upstream root port + this endpoint)
     * and restore the original values on remove. */
    {
        struct pci_dev *rp = pci_upstream_bridge(pdev);
        int mps = pcie_get_mps(pdev);

        if (mps < 0) {
            dev_err(&pdev->dev, "[ERROR] failed to read negotiated MPS: %d\n",
                    mps);
            ret = mps;
            goto disable_pci;
        }
        if (mps >= 256) {
            dev_info(&pdev->dev,
                     "Negotiated MaxPayloadSize: %d bytes (256-byte MWr enabled)\n",
                     mps);
        } else {
            if (!rp) {
                dev_err(&pdev->dev,
                        "[ERROR] MPS %d < 256 and no upstream root port to raise\n",
                        mps);
                ret = -EOPNOTSUPP;
                goto disable_pci;
            }
            qdev->rp_mps_saved = pcie_get_mps(rp);
            qdev->ep_mps_saved = mps;

            /* Receiver first, then generator: raising the root port's limit
             * before the endpoint starts emitting larger TLPs keeps the
             * transient state safe. */
            ret = pcie_set_mps(rp, 256);
            if (ret) {
                dev_err(&pdev->dev,
                        "[ERROR] cannot raise root port MPS to 256: %d\n", ret);
                goto disable_pci;
            }
            ret = pcie_set_mps(pdev, 256);
            if (ret) {
                pcie_set_mps(rp, qdev->rp_mps_saved);
                dev_err(&pdev->dev,
                        "[ERROR] cannot raise endpoint MPS to 256: %d\n", ret);
                goto disable_pci;
            }
            qdev->mps_modified = true;
            dev_info(&pdev->dev,
                     "Raised MPS for 256-byte MWr: endpoint %d -> 256, "
                     "root port %d -> 256\n",
                     qdev->ep_mps_saved, qdev->rp_mps_saved);
        }
    }

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

    /* Recover even when a warm host reboot leaves the FPGA DMA FSMs intact. */
    iowrite32(1, qdev->bar0_mmio + REG_VIDEO_CTRL);
    ioread32(qdev->bar0_mmio + REG_VIDEO_CTRL);
    qpcie_dma_soft_reset(qdev);
    iowrite32(0, qdev->bar0_mmio + REG_VIDEO_CTRL);
    ioread32(qdev->bar0_mmio + REG_VIDEO_CTRL);
    usleep_range(1000, 2000);

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
    dev_info(&pdev->dev, "  BAR0 [0x38] Build Timestamp: %08X\n", date);

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

    /* The FPGA drives the 7-series MSI cfg_interrupt handshake. Do not
     * silently fall back to legacy INTx, which requires a separate
     * assert/deassert sequence on cfg_interrupt_assert. */
    ret = pci_alloc_irq_vectors(pdev, 1, 1, PCI_IRQ_MSI);
    if (ret < 0) {
        dev_err(&pdev->dev, "[ERROR] Cannot allocate PCI IRQ: %d\n", ret);
        goto unmap_mmio;
    }
    qdev->irq = pci_irq_vector(pdev, 0);
    spin_lock_init(&qdev->tpg_lock);
    qdev->tpg_fps = 60;
    ret = request_irq(qdev->irq, qpcie_irq_handler, 0,
                      "qpcie-dma", qdev);
    if (ret) {
        dev_err(&pdev->dev, "[ERROR] Cannot request PCI IRQ: %d\n", ret);
        goto free_irq_vectors;
    }
    iowrite32(0x3, qdev->bar0_mmio + REG_IRQ_CTRL);

    /* --------------------------------------------------------------------
     * 3. Scatter-Gather (SG List) DMA Verification: 4x H2C + 4x C2H Pages
     * -------------------------------------------------------------------- */
    dev_info(&pdev->dev, "--- [3. Scatter-Gather (SG List) DMA Verification] ---\n");

    desc_ring = dma_alloc_coherent(&pdev->dev, 64 * 16,
                                   &desc_ring_dma, GFP_KERNEL);

    if (!desc_ring) {
        dev_err(&pdev->dev, "[ERROR] dma_alloc_coherent failed for Descriptor Ring!\n");
        ret = -ENOMEM;
    } else {
        memset(desc_ring, 0, 64 * 16);
        dev_info(&pdev->dev, "  Allocated Coherent Ring: Phys=0x%llX (Virt=%p)\n", (u64)desc_ring_dma, desc_ring);

        for (p = 0; p < SG_PAGES; p++) {
            h2c_pages[p] = dma_alloc_coherent(&pdev->dev, 4096, &h2c_page_dma[p], GFP_KERNEL);
            c2h_pages[p] = dma_alloc_coherent(&pdev->dev, 4096, &c2h_page_dma[p], GFP_KERNEL);
            if (!h2c_pages[p] || !c2h_pages[p]) {
                dev_err(&pdev->dev, "[ERROR] SG page allocation %d failed\n", p);
                ret = -ENOMEM;
                goto free_diag_dma;
            }
            for (w = 0; w < 1024; w++)
                h2c_pages[p][w] = 0xAA000000 | (p << 16) | w;
            memset(c2h_pages[p], 0x00, 4096);
            dev_info(&pdev->dev, "  [SG Page %d] H2C Phys=0x%llX (Pattern: 0x%08X), C2H Phys=0x%llX\n",
                     p, (u64)h2c_page_dma[p], h2c_pages[p] ? h2c_pages[p][0] : 0, (u64)c2h_page_dma[p]);
        }

        /* The FPGA head pointer and completion counters persist across Linux
         * module reloads. Anchor this fresh coherent ring at the current head;
         * programming an absolute tail of 4 on a retained head of 8 would make
         * hardware consume uninitialized descriptors 8..15 and DMA to IOVA 0. */
        ring_head = ioread32(qdev->bar0_mmio + 0x40) & 0xffff;
        if (ring_head >= RING_BUFFER_SIZE) {
            dev_err(&pdev->dev, "[ERROR] Invalid retained descriptor head %u\n",
                    ring_head);
            ret = -EIO;
            goto free_diag_dma;
        }
        c2h_tail = (ring_head + SG_PAGES) % RING_BUFFER_SIZE;
        h2c_tail = (ring_head + (2 * SG_PAGES)) % RING_BUFFER_SIZE;
        start_c2h = ioread32(qdev->bar0_mmio + REG_COMPLETED_C2H);
        start_h2c = ioread32(qdev->bar0_mmio + REG_COMPLETED_H2C);
        dev_info(&pdev->dev,
                 "  Retained DMA state: Head=%u, C2HCount=%u, H2CCount=%u\n",
                 ring_head, start_c2h, start_h2c);

        for (p = 0; p < SG_PAGES; p++) {
            u32 c2h_idx = (ring_head + p) % RING_BUFFER_SIZE;
            u32 h2c_idx = (ring_head + SG_PAGES + p) % RING_BUFFER_SIZE;

            desc_ring[c2h_idx].plane0_src_addr = 0x0ULL;
            desc_ring[c2h_idx].plane0_dst_addr = (u64)c2h_page_dma[p];
            desc_ring[c2h_idx].line_width      = 4096;
            desc_ring[c2h_idx].line_count      = 1;
            desc_ring[c2h_idx].src_stride      = 4096;
            desc_ring[c2h_idx].dst_stride      = 4096;
            desc_ring[c2h_idx].format          = 0;
            desc_ring[c2h_idx].plane_count     = 1;
            desc_ring[c2h_idx].control         = 0x02; /* C2H */

            desc_ring[h2c_idx].plane0_src_addr = (u64)h2c_page_dma[p];
            desc_ring[h2c_idx].plane0_dst_addr = 0x0ULL;
            desc_ring[h2c_idx].line_width      = 4096;
            desc_ring[h2c_idx].line_count      = 1;
            desc_ring[h2c_idx].src_stride      = 4096;
            desc_ring[h2c_idx].dst_stride      = 4096;
            desc_ring[h2c_idx].format          = 0;
            desc_ring[h2c_idx].plane_count     = 1;
            desc_ring[h2c_idx].control         = 0x00; /* H2C */
        }

        /* Flush all descriptor writes to memory before informing hardware */
        dma_wmb();

        /* Program Ring Base Address into BAR0 0x08 (Low) and 0x0C (High) */
        iowrite32((u32)(desc_ring_dma & 0xFFFFFFFF), qdev->bar0_mmio + REG_H2C_RING_ADDR_L);
        iowrite32((u32)((desc_ring_dma >> 32) & 0xFFFFFFFF), qdev->bar0_mmio + REG_H2C_RING_ADDR_H);

        /* Publish exactly four C2H descriptors after the retained head. */
        iowrite32((c2h_tail << 16) | RING_BUFFER_SIZE,
                  qdev->bar0_mmio + REG_H2C_RING_CFG);

        /* Trigger DMA Start */
        iowrite32(0x00000001, qdev->bar0_mmio + REG_DMA_CTRL);
        dev_info(&pdev->dev, "--- [3.1 Step 1: C2H 4-Page SG List DMA Write Test] ---\n");
        dev_info(&pdev->dev,
                 "  Triggered C2H SG Run (Head=%u, Tail=%u, Size=%u)...\n",
                 ring_head, c2h_tail, RING_BUFFER_SIZE);
        ret = qpcie_wait_dma(qdev, REG_COMPLETED_C2H, start_c2h + 4);
        if (ret) {
            dev_err(&pdev->dev, "[ERROR] C2H diagnostic DMA timed out\n");
            qpcie_dump_dma_state(qdev, "C2H timeout");
            goto stop_diag_dma;
        }

        dma_stat = ioread32(qdev->bar0_mmio + REG_DMA_STATUS);
        comp_c2h = ioread32(qdev->bar0_mmio + REG_COMPLETED_C2H);
        ptr_dbg  = ioread32(qdev->bar0_mmio + 0x40);
        dev_info(&pdev->dev, "  C2H SG Status: DMA_STATUS=0x%08X, Completed Count=%u, Pointers: Tail=%u, Head=%u\n",
                 dma_stat, comp_c2h, (ptr_dbg >> 16) & 0xFFFF, ptr_dbg & 0xFFFF);
        if (comp_c2h != start_c2h + SG_PAGES ||
            (ptr_dbg & 0xffff) != c2h_tail) {
            dev_err(&pdev->dev,
                    "[ERROR] C2H consumed an unexpected descriptor count/head\n");
            ret = -EIO;
            goto stop_diag_dma;
        }

        dma_rmb();
        for (p = 0; p < SG_PAGES; p++) {
            for (w = 0; w < 1024; w++) {
                u32 expected = 0xC2000000 |
                    (((start_c2h + p) & 0xff) << 16) | w;
                if (c2h_pages[p][w] != expected) {
                    dev_err(&pdev->dev,
                            "[ERROR] C2H data mismatch page=%d word=%d: got=0x%08X expected=0x%08X\n",
                            p, w, c2h_pages[p][w], expected);
                    ret = -EIO;
                    goto stop_diag_dma;
                }
            }
        }
        dev_info(&pdev->dev,
                 "  C2H payload validation: 4 pages x 4096 bytes [PASS]\n");

        /* Advance tail by four more entries for the H2C descriptors. */
        dev_info(&pdev->dev, "--- [3.2 Step 2: H2C 4-Page SG List DMA Read Test] ---\n");
        iowrite32((h2c_tail << 16) | RING_BUFFER_SIZE,
                  qdev->bar0_mmio + REG_H2C_RING_CFG);
        dev_info(&pdev->dev,
                 "  Triggered H2C SG Run (Head=%u, Tail=%u, Size=%u)...\n",
                 c2h_tail, h2c_tail, RING_BUFFER_SIZE);
        ret = qpcie_wait_dma(qdev, REG_COMPLETED_H2C, start_h2c + 4);
        if (ret) {
            dev_err(&pdev->dev, "[ERROR] H2C diagnostic DMA timed out\n");
            qpcie_dump_dma_state(qdev, "H2C timeout");
            goto stop_diag_dma;
        }

        dma_stat = ioread32(qdev->bar0_mmio + REG_DMA_STATUS);
        comp_h2c = ioread32(qdev->bar0_mmio + REG_COMPLETED_H2C);
        ptr_dbg  = ioread32(qdev->bar0_mmio + 0x40);
        dev_info(&pdev->dev, "  H2C SG Status: DMA_STATUS=0x%08X, Completed Count=%u, Pointers: Tail=%u, Head=%u\n",
                 dma_stat, comp_h2c, (ptr_dbg >> 16) & 0xFFFF, ptr_dbg & 0xFFFF);
        if (comp_h2c != start_h2c + SG_PAGES ||
            (ptr_dbg & 0xffff) != h2c_tail) {
            dev_err(&pdev->dev,
                    "[ERROR] H2C consumed an unexpected descriptor count/head\n");
            ret = -EIO;
            goto stop_diag_dma;
        }

        /* Ensure CPU observes all DMA writes from FPGA */
        dma_rmb();

        /* Inspect C2H pages */
        for (p = 0; p < SG_PAGES; p++) {
            if (c2h_pages[p]) {
                dev_info(&pdev->dev, "  C2H Page %d Content: [0]=0x%08X, [1]=0x%08X, [2]=0x%08X, [3]=0x%08X\n",
                         p, c2h_pages[p][0], c2h_pages[p][1], c2h_pages[p][2], c2h_pages[p][3]);
            }
        }

stop_diag_dma:
        iowrite32(0, qdev->bar0_mmio + REG_DMA_CTRL);
        ioread32(qdev->bar0_mmio + REG_DMA_CTRL);
        if (ret)
            pci_clear_master(pdev);
        msleep(20);
        iowrite32(1, qdev->bar0_mmio + REG_VIDEO_CTRL);
        ioread32(qdev->bar0_mmio + REG_VIDEO_CTRL);
        qpcie_dma_soft_reset(qdev);
        iowrite32(0, qdev->bar0_mmio + REG_VIDEO_CTRL);
        ioread32(qdev->bar0_mmio + REG_VIDEO_CTRL);
        usleep_range(1000, 2000);
free_diag_dma:
        dma_free_coherent(&pdev->dev, 64 * 16, desc_ring, desc_ring_dma);
        for (p = 0; p < SG_PAGES; p++) {
            if (h2c_pages[p]) dma_free_coherent(&pdev->dev, 4096, h2c_pages[p], h2c_page_dma[p]);
            if (c2h_pages[p]) dma_free_coherent(&pdev->dev, 4096, c2h_pages[p], c2h_page_dma[p]);
        }
    }

    if (ret)
        goto free_irq;
    dev_info(&pdev->dev, "=======================================================\n");
    dev_info(&pdev->dev, "🎉 [DMA STEP-BY-STEP DIAGNOSTIC TEST COMPLETED]\n");
    dev_info(&pdev->dev, "=======================================================\n");

    /* --------------------------------------------------------------------
     * 4. Stage-2 V4L2 NV12M capture bring-up (ALSA intentionally off)
     * --------------------------------------------------------------------
     * The hardware descriptor engine owns one shared ring. Preserve its
     * current head position after the diagnostic run and start the persistent
     * V4L2 ring at that same index so head/tail remain coherent.
     */
    qdev->h2c_ring_virt = dma_alloc_coherent(&pdev->dev,
                              sizeof(*qdev->h2c_ring_virt) * RING_BUFFER_SIZE,
                              &qdev->h2c_ring_dma, GFP_KERNEL);
    if (!qdev->h2c_ring_virt) {
        ret = -ENOMEM;
        dev_err(&pdev->dev, "[ERROR] Cannot allocate persistent V4L2 descriptor ring\n");
        goto free_irq;
    }
    memset(qdev->h2c_ring_virt, 0,
           sizeof(*qdev->h2c_ring_virt) * RING_BUFFER_SIZE);
    qdev->c2h_ring_virt = qdev->h2c_ring_virt;
    qdev->c2h_ring_dma = qdev->h2c_ring_dma;

    {
        u32 hw_ptr = ioread32(qdev->bar0_mmio + 0x40);
        u32 hw_head = hw_ptr & 0xffff;

        qdev->h2c_tail = hw_head;
        qdev->c2h_tail = hw_head;
        dma_wmb();
        iowrite32(lower_32_bits(qdev->h2c_ring_dma),
                  qdev->bar0_mmio + REG_H2C_RING_ADDR_L);
        iowrite32(upper_32_bits(qdev->h2c_ring_dma),
                  qdev->bar0_mmio + REG_H2C_RING_ADDR_H);
        iowrite32((hw_head << 16) | RING_BUFFER_SIZE,
                  qdev->bar0_mmio + REG_H2C_RING_CFG);
        dev_info(&pdev->dev,
                 "V4L2 shared descriptor ring: DMA=0x%llX, head=tail=%u\n",
                 (u64)qdev->h2c_ring_dma, hw_head);
    }

    ret = qpcie_v4l2_init(qdev);
    if (ret) {
        dev_err(&pdev->dev, "[ERROR] V4L2-only initialization failed: %d\n", ret);
        goto free_video_ring;
    }
    qdev->v4l2_registered = true;

    ret = qpcie_alsa_init(qdev);
    if (ret) {
        dev_err(&pdev->dev, "[ERROR] ALSA initialization failed: %d\n", ret);
        goto v4l2_remove;
    }
    qdev->alsa_registered = true;
    dev_info(&pdev->dev,
             "Stage-3 V4L2 NV12M + ALSA AES3 Audio capture ready\n");

    ret = qpcie_sysfs_init(qdev);
    if (ret)
        goto alsa_remove;
    return 0;

alsa_remove:
    qpcie_alsa_remove(qdev);
    qdev->alsa_registered = false;
v4l2_remove:
    qpcie_v4l2_remove(qdev);
    qdev->v4l2_registered = false;
free_video_ring:
    dma_free_coherent(&pdev->dev,
                      sizeof(*qdev->h2c_ring_virt) * RING_BUFFER_SIZE,
                      qdev->h2c_ring_virt, qdev->h2c_ring_dma);
    qdev->h2c_ring_virt = NULL;
    qdev->c2h_ring_virt = NULL;
free_irq:
    iowrite32(0, qdev->bar0_mmio + REG_IRQ_CTRL);
    free_irq(qdev->irq, qdev);
free_irq_vectors:
    pci_free_irq_vectors(pdev);
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

    qpcie_sysfs_remove(qdev);

    iowrite32(0, qdev->bar0_mmio + REG_DMA_CTRL);
    ioread32(qdev->bar0_mmio + REG_DMA_CTRL);
    iowrite32(0, qdev->bar0_mmio + REG_IRQ_CTRL);

    if (qdev->alsa_registered) {
        qpcie_alsa_remove(qdev);
        qdev->alsa_registered = false;
    }
    if (qdev->v4l2_registered) {
        qpcie_v4l2_remove(qdev);
        qdev->v4l2_registered = false;
    }
    if (qdev->h2c_ring_virt) {
        dma_free_coherent(&pdev->dev,
                          sizeof(*qdev->h2c_ring_virt) * RING_BUFFER_SIZE,
                          qdev->h2c_ring_virt, qdev->h2c_ring_dma);
        qdev->h2c_ring_virt = NULL;
        qdev->c2h_ring_virt = NULL;
    }

    /* Restore the pre-probe MPS values (decrease downstream first). */
    if (qdev->mps_modified) {
        struct pci_dev *rp = pci_upstream_bridge(pdev);

        pcie_set_mps(pdev, qdev->ep_mps_saved);
        if (rp)
            pcie_set_mps(rp, qdev->rp_mps_saved);
        dev_info(&pdev->dev, "Restored original MPS settings\n");
    }

    pci_clear_master(pdev);
    free_irq(qdev->irq, qdev);
    pci_free_irq_vectors(pdev);
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
