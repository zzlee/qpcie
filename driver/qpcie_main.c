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
    iowrite32(1, qdev->bar0_mmio + REG_NEW_GLOBAL_RESET);
    ioread32(qdev->bar0_mmio + REG_NEW_GLOBAL_RESET);
    usleep_range(1000, 2000);
    iowrite32(0, qdev->bar0_mmio + REG_NEW_GLOBAL_RESET);
    ioread32(qdev->bar0_mmio + REG_NEW_GLOBAL_RESET);
    usleep_range(1000, 2000);
}

/* After REG_NEW_GLOBAL_RESET the RTL (axil_reg_space) resets ALL registers to 0,
 * including Ring0/Ring1 base addresses for CH0 (thin) and CH1 (loopback).
 * This helper MUST be called after every soft reset to restore those ring bases.
 * Otherwise desc_fetch_engine tries to MRd from address 0 → ARM-SMMU fault.     */
void qpcie_reprogram_rings(struct qpcie_dev *qdev)
{
    struct qpcie_v4l2_channel *vch0 = &qdev->v4l2_ch[0];

    /* After global reset, hardware head pointer is 0.
     * Re-anchor software tail pointers to 0 so head == tail == 0. */
    vch0->thin_ring_tail = 0;
    vch0->thin_ring_head = 0;
    vch0->thin_ring1_tail = 0;
    vch0->thin_ring1_head = 0;
    qdev->h2c_tail = 0;
    qdev->c2h_tail = 0;

    /* CH0: Restore thin RING0 base & tail */
    if (vch0->thin_ring_virt) {
        iowrite32(lower_32_bits(vch0->thin_ring_dma),
                  qdev->bar0_mmio + REG_VCH0_RING0_BASE_L);
        iowrite32(upper_32_bits(vch0->thin_ring_dma),
                  qdev->bar0_mmio + REG_VCH0_RING0_BASE_H);
        iowrite32((0 << 16) | RING_BUFFER_SIZE,
                  qdev->bar0_mmio + REG_VCH0_RING0_CFG);
    }
    if (vch0->thin_ring1_virt) {
        iowrite32(lower_32_bits(vch0->thin_ring1_dma),
                  qdev->bar0_mmio + REG_VCH0_RING1_BASE_L);
        iowrite32(upper_32_bits(vch0->thin_ring1_dma),
                  qdev->bar0_mmio + REG_VCH0_RING1_BASE_H);
        iowrite32((0 << 16) | RING_BUFFER_SIZE,
                  qdev->bar0_mmio + REG_VCH0_RING1_CFG);
    }

    /* CH1: Restore loopback descriptor ring base & tail */
    if (qdev->h2c_ring_virt) {
        iowrite32(lower_32_bits(qdev->h2c_ring_dma),
                  qdev->bar0_mmio + REG_VCH_BASE(1) + REG_VCH_OFFSET_RING0_BASE_L);
        iowrite32(upper_32_bits(qdev->h2c_ring_dma),
                  qdev->bar0_mmio + REG_VCH_BASE(1) + REG_VCH_OFFSET_RING0_BASE_H);
        iowrite32((0 << 16) | RING_BUFFER_SIZE,
                  qdev->bar0_mmio + REG_VCH_BASE(1) + REG_VCH_OFFSET_RING0_CFG);
    }

    ioread32(qdev->bar0_mmio + REG_VCH0_RING0_CFG); /* Flush posted writes */
}

static irqreturn_t qpcie_irq_handler(int irq, void *data)
{
    struct qpcie_dev *qdev = data;

    /* Canonical v3.0 Three-Level Hierarchy Interrupt Dispatch */
    u32 top = ioread32(qdev->bar0_mmio + REG_NEW_GLOBAL_IRQ_TOP);

    if (!top)
        return IRQ_NONE;

    /* Level 3 Dispatch: Video CH0 (Bit 0) */
    if (top & BIT(0)) {
        u32 ch_irq = ioread32(qdev->bar0_mmio + REG_VCH0_IRQ_STATUS);
        if (ch_irq & BIT(0)) {
            /* Frame done completion */
            if (qdev->v4l2_registered)
                qpcie_v4l2_node_done(qdev, 0);
        }
        if (ch_irq & BIT(1))
            dev_warn_ratelimited(&qdev->pdev->dev, "VCH0 overflow IRQ detected\n");
        if (ch_irq & BIT(2))
            dev_err_ratelimited(&qdev->pdev->dev, "VCH0 descriptor error IRQ detected\n");
        if (ch_irq & BIT(3))
            dev_err_ratelimited(&qdev->pdev->dev, "VCH0 FIFO error IRQ detected\n");

        /* Step 1: Clear branch / channel status first (W1C) */
        iowrite32(ch_irq, qdev->bar0_mmio + REG_VCH0_IRQ_STATUS);
    }

    /* Level 3 Dispatch: Video CH1 Capture (Bit 1) */
    if (top & BIT(1)) {
        u32 ch_irq = ioread32(qdev->bar0_mmio + REG_VCH_BASE(1) + REG_VCH_OFFSET_IRQ_STATUS);
        if (ch_irq & BIT(0)) {
            if (qdev->v4l2_registered)
                qpcie_v4l2_node_done(qdev, 2);
        }
        if (ch_irq & BIT(1))
            dev_warn_ratelimited(&qdev->pdev->dev, "VCH1 overflow IRQ detected\n");
        if (ch_irq & BIT(2))
            dev_err_ratelimited(&qdev->pdev->dev, "VCH1 descriptor error IRQ detected\n");
        if (ch_irq & BIT(3))
            dev_err_ratelimited(&qdev->pdev->dev, "VCH1 FIFO error IRQ detected\n");
        iowrite32(ch_irq, qdev->bar0_mmio + REG_VCH_BASE(1) + REG_VCH_OFFSET_IRQ_STATUS);
    }

    /* Level 3 Dispatch: Audio DEV0 (Bit 4: AUD) */
    if ((top & IRQ_TOP_AUD) && qdev->alsa_registered)
        qpcie_alsa_irq_handler(qdev, 0);

    /* Bit 5 (ERR): xrun events are dispatched inside the ALSA handler via ADEV0_IRQ_STATUS */
    if ((top & IRQ_TOP_ERR) && qdev->alsa_registered)
        qpcie_alsa_irq_handler(qdev, 0);

    /* Level 3 Dispatch: H2C DMA (Bit 7: Video Node 1) */
    if ((top & BIT(7)) && qdev->v4l2_registered)
        qpcie_v4l2_node_done(qdev, 1);

    /* Step 2: Clear Level 2 TOP status (W1C) */
    iowrite32(top, qdev->bar0_mmio + REG_NEW_GLOBAL_IRQ_TOP);
    return IRQ_HANDLED;
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
    int ret, i;
    u32 magic, ver, git, date, caps, ctrl, readback;
    u32 dbg_wdata, dbg_waddr;

    dev_info(&pdev->dev, "=======================================================\n");
    dev_info(&pdev->dev, "=== [CANONICAL v3.0 MODE] QPCIe Artix-7 A50T Probe ===\n");
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

    magic = ioread32(qdev->bar0_mmio + REG_NEW_GLOBAL_ID);
    if (magic != 0x12ABE380) {
        dev_err(&pdev->dev, "[ERROR] Canonical v3.0 Magic ID mismatch: 0x%08X (expected 0x12ABE380)\n", magic);
        ret = -ENODEV;
        goto unmap_mmio;
    }

    ver = ioread32(qdev->bar0_mmio + REG_NEW_GLOBAL_VERSION);
    git = ioread32(qdev->bar0_mmio + REG_NEW_GLOBAL_GITHASH);
    date = ioread32(qdev->bar0_mmio + REG_NEW_GLOBAL_BUILDTIME);
    caps = ioread32(qdev->bar0_mmio + REG_NEW_GLOBAL_CAPS);
    ctrl = magic;

    dev_info(&pdev->dev, "  BAR0 [0x00] Magic Device ID: 0x%08X (Canonical v3.0 Map Active)\n", magic);
    dev_info(&pdev->dev, "  BAR0 Version ID     : 0x%08X (Parsed: v%u.%u.%u Variant %u)\n",
             ver, (ver >> 24) & 0xFF, (ver >> 16) & 0xFF, (ver >> 8) & 0xFF, ver & 0xFF);
    dev_info(&pdev->dev, "  BAR0 Git Commit Hash: 0x%08X\n", git);
    dev_info(&pdev->dev, "  BAR0 Build Timestamp: %08X\n", date);
    dev_info(&pdev->dev, "  BAR0 Hardware Caps  : 0x%08X (VideoCh=%u, AudioCh=%u, Flags=0x%X)\n",
             caps, (caps >> 8) & 0xFF, (caps >> 16) & 0xFF, caps & 0xFF);

    /* ------------------------------------------------------------------------
     * 2. BAR0 Write & Read-back Test
     * ------------------------------------------------------------------------ */
    dev_info(&pdev->dev, "--- [2. BAR0 Write & Readback Test] ---\n");

    iowrite32(0x12345678, qdev->bar0_mmio + REG_VCH0_RING0_BASE_L); // offset 0x120
    readback = ioread32(qdev->bar0_mmio + REG_VCH0_RING0_BASE_L);
    dbg_wdata = ioread32(qdev->bar0_mmio + REG_NEW_DEBUG_LAST_WDATA);
    dbg_waddr = ioread32(qdev->bar0_mmio + REG_NEW_DEBUG_LAST_WADDR);
    dev_info(&pdev->dev, "  BAR0 [0x120] Write 0x12345678 -> Readback: 0x%08X %s (Hardware Captured: Addr=0x%03X, Data=0x%08X)\n",
             readback, (readback == 0x12345678) ? "[PASS]" : "[FAIL]", dbg_waddr, dbg_wdata);

    iowrite32(0x87654321, qdev->bar0_mmio + REG_VCH0_RING0_BASE_H); // offset 0x124
    readback = ioread32(qdev->bar0_mmio + REG_VCH0_RING0_BASE_H);
    dbg_wdata = ioread32(qdev->bar0_mmio + REG_NEW_DEBUG_LAST_WDATA);
    dbg_waddr = ioread32(qdev->bar0_mmio + REG_NEW_DEBUG_LAST_WADDR);
    dev_info(&pdev->dev, "  BAR0 [0x124] Write 0x87654321 -> Readback: 0x%08X %s (Hardware Captured: Addr=0x%03X, Data=0x%08X)\n",
             readback, (readback == 0x87654321) ? "[PASS]" : "[FAIL]", dbg_waddr, dbg_wdata);

    /* Restore zero values */
    iowrite32(0x00000000, qdev->bar0_mmio + REG_VCH0_RING0_BASE_L);
    iowrite32(0x00000000, qdev->bar0_mmio + REG_VCH0_RING0_BASE_H);

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

    /* ------------------------------------------------------------------------
     * 3. Canonical v3.0 Native Mode: Thin Descriptor Ring Initialization
     * ------------------------------------------------------------------------ */
    dev_info(&pdev->dev, "--- [3. Canonical v3.0 Native Mode: Thin Descriptors Active] ---\n");

    /* Switch hardware to Canonical v3.0 mode via DMA_CTRL[3] */
    ctrl = ioread32(qdev->bar0_mmio + REG_DMA_CTRL);
    iowrite32(ctrl | BIT(3), qdev->bar0_mmio + REG_DMA_CTRL);

    {
        struct qpcie_v4l2_channel *vch0 = &qdev->v4l2_ch[0];
        vch0->ch_reg_base = REG_VCH_BASE(0);
        vch0->thin_ring_virt = dma_alloc_coherent(&pdev->dev,
                                sizeof(*vch0->thin_ring_virt) * RING_BUFFER_SIZE,
                                &vch0->thin_ring_dma, GFP_KERNEL);
        if (!vch0->thin_ring_virt) {
            dev_err(&pdev->dev, "[ERROR] Cannot allocate thin descriptor ring 0 for CH0\n");
            ret = -ENOMEM;
            goto free_irq;
        }
        memset(vch0->thin_ring_virt, 0,
               sizeof(*vch0->thin_ring_virt) * RING_BUFFER_SIZE);
        vch0->thin_ring_tail = 0;
        vch0->thin_ring_head = 0;

        vch0->thin_ring1_virt = dma_alloc_coherent(&pdev->dev,
                                sizeof(*vch0->thin_ring1_virt) * RING_BUFFER_SIZE,
                                &vch0->thin_ring1_dma, GFP_KERNEL);
        if (!vch0->thin_ring1_virt) {
            dev_err(&pdev->dev, "[ERROR] Cannot allocate thin descriptor ring 1 for CH0\n");
            ret = -ENOMEM;
            goto free_video_ring;
        }
        memset(vch0->thin_ring1_virt, 0,
               sizeof(*vch0->thin_ring1_virt) * RING_BUFFER_SIZE);
        vch0->thin_ring1_tail = 0;
        vch0->thin_ring1_head = 0;

        qdev->thin_ring_virt = (struct qpcie_sgl_entry *)vch0->thin_ring_virt;
        qdev->thin_ring_dma  = vch0->thin_ring_dma;
        qdev->thin_ring_tail = 0;
        qdev->thin_ring_head = 0;

        dev_info(&pdev->dev,
                 "CH0 Thin Ring: RING0=0x%llX, RING1=0x%llX, Size=%u, RegBase=0x%03X\n",
                 (u64)vch0->thin_ring_dma, (u64)vch0->thin_ring1_dma, RING_BUFFER_SIZE, vch0->ch_reg_base);
        /* Initialize RING0 Base and initial CFG */
        iowrite32(lower_32_bits(vch0->thin_ring_dma),
                  qdev->bar0_mmio + REG_VCH0_RING0_BASE_L);
        iowrite32(upper_32_bits(vch0->thin_ring_dma),
                  qdev->bar0_mmio + REG_VCH0_RING0_BASE_H);
        iowrite32(RING_BUFFER_SIZE,
                  qdev->bar0_mmio + REG_VCH0_RING0_CFG);
        /* Initialize RING1 Base and initial CFG */
        iowrite32(lower_32_bits(vch0->thin_ring1_dma),
                  qdev->bar0_mmio + REG_VCH0_RING1_BASE_L);
        iowrite32(upper_32_bits(vch0->thin_ring1_dma),
                  qdev->bar0_mmio + REG_VCH0_RING1_BASE_H);
        iowrite32(RING_BUFFER_SIZE,
                  qdev->bar0_mmio + REG_VCH0_RING1_CFG);
    }

    /* ------------------------------------------------------------------------
     * Allocate & Initialize CH1 Loopback Descriptor Ring
     * ------------------------------------------------------------------------ */
    qdev->h2c_ring_virt = dma_alloc_coherent(&pdev->dev,
                            sizeof(*qdev->h2c_ring_virt) * RING_BUFFER_SIZE,
                            &qdev->h2c_ring_dma, GFP_KERNEL);
    if (!qdev->h2c_ring_virt) {
        dev_err(&pdev->dev, "[ERROR] Cannot allocate CH1 descriptor ring\n");
        ret = -ENOMEM;
        goto free_video_ring;
    }
    memset(qdev->h2c_ring_virt, 0,
           sizeof(*qdev->h2c_ring_virt) * RING_BUFFER_SIZE);
    qdev->h2c_tail = 0;
    qdev->c2h_tail = 0;

    iowrite32(lower_32_bits(qdev->h2c_ring_dma),
              qdev->bar0_mmio + REG_VCH_BASE(1) + REG_VCH_OFFSET_RING0_BASE_L);
    iowrite32(upper_32_bits(qdev->h2c_ring_dma),
              qdev->bar0_mmio + REG_VCH_BASE(1) + REG_VCH_OFFSET_RING0_BASE_H);
    iowrite32(RING_BUFFER_SIZE,
              qdev->bar0_mmio + REG_VCH_BASE(1) + REG_VCH_OFFSET_RING0_CFG);
    dev_info(&pdev->dev,
             "CH1 Loopback Ring: RingBase=0x%llX, Size=%u, RegBase=0x%03X\n",
             (u64)qdev->h2c_ring_dma, RING_BUFFER_SIZE, REG_VCH_BASE(1));

    ret = qpcie_v4l2_init(qdev);
    if (ret) {
        dev_err(&pdev->dev, "[ERROR] V4L2 initialization failed: %d\n", ret);
        goto free_video_ring;
    }
    qdev->v4l2_registered = true;

    ret = qpcie_alsa_init(qdev);
    if (ret) {
        dev_err(&pdev->dev, "[ERROR] ALSA initialization failed: %d\n", ret);
        goto v4l2_remove;
    }
    qdev->alsa_registered = true;

    dev_info(&pdev->dev, "Canonical v3.0 V4L2 NV12M + ALSA AES3 Audio capture ready\n");

    ret = qpcie_sysfs_init(qdev);
    if (ret)
        goto alsa_remove;
    return 0;

alsa_remove:
    if (qdev->alsa_registered) {
        qpcie_alsa_remove(qdev);
        qdev->alsa_registered = false;
    }
v4l2_remove:
    if (qdev->v4l2_registered) {
        qpcie_v4l2_remove(qdev);
        qdev->v4l2_registered = false;
    }
free_video_ring:
    for (i = 0; i < NUM_VIDEO_NODES; i++) {
        struct qpcie_v4l2_channel *vch = &qdev->v4l2_ch[i];
        if (vch->thin_ring_virt) {
            dma_free_coherent(&pdev->dev,
                              sizeof(*vch->thin_ring_virt) * RING_BUFFER_SIZE,
                              vch->thin_ring_virt, vch->thin_ring_dma);
            vch->thin_ring_virt = NULL;
        }
        if (vch->thin_ring1_virt) {
            dma_free_coherent(&pdev->dev,
                              sizeof(*vch->thin_ring1_virt) * RING_BUFFER_SIZE,
                              vch->thin_ring1_virt, vch->thin_ring1_dma);
            vch->thin_ring1_virt = NULL;
        }
    }
    qdev->thin_ring_virt = NULL;
    if (qdev->h2c_ring_virt) {
        dma_free_coherent(&pdev->dev,
                          sizeof(*qdev->h2c_ring_virt) * RING_BUFFER_SIZE,
                          qdev->h2c_ring_virt, qdev->h2c_ring_dma);
        qdev->h2c_ring_virt = NULL;
    }
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
    int i;

    dev_info(&pdev->dev, "Removing QPCIe Driver (Minimal Diagnostic Mode)...\n");

    qpcie_sysfs_remove(qdev);

    /* 1. Halt all DMA engines and interrupt controller before freeing memory */
    if (qdev->bar0_mmio) {
        /* Stop Video CH0 in new map */
        iowrite32(0, qdev->bar0_mmio + REG_VCH0_CTRL);
        /* Stop Video CH1 (Loopback) in new map */
        iowrite32(0, qdev->bar0_mmio + REG_VCH_BASE(1) + REG_VCH_OFFSET_CTRL);
        /* Stop Audio DEV0 in new map */
        iowrite32(0, qdev->bar0_mmio + REG_ADEV0_CTRL);
        /* Disable interrupts */
        iowrite32(0, qdev->bar0_mmio + REG_IRQ_CTRL);
        ioread32(qdev->bar0_mmio + REG_VCH0_CTRL); /* Flush posted writes */

        /* Full DMA soft reset to flush hardware FIFOs */
        qpcie_dma_soft_reset(qdev);
    }

    /* Drain in-flight PCIe TLPs to host memory */
    msleep(20);

    if (qdev->alsa_registered) {
        qpcie_alsa_remove(qdev);
        qdev->alsa_registered = false;
    }
    if (qdev->v4l2_registered) {
        qpcie_v4l2_remove(qdev);
        qdev->v4l2_registered = false;
    }
    for (i = 0; i < NUM_VIDEO_NODES; i++) {
        struct qpcie_v4l2_channel *vch = &qdev->v4l2_ch[i];
        if (vch->thin_ring_virt) {
            dma_free_coherent(&pdev->dev,
                              sizeof(*vch->thin_ring_virt) * RING_BUFFER_SIZE,
                              vch->thin_ring_virt, vch->thin_ring_dma);
            vch->thin_ring_virt = NULL;
        }
        if (vch->thin_ring1_virt) {
            dma_free_coherent(&pdev->dev,
                              sizeof(*vch->thin_ring1_virt) * RING_BUFFER_SIZE,
                              vch->thin_ring1_virt, vch->thin_ring1_dma);
            vch->thin_ring1_virt = NULL;
        }
    }
    qdev->thin_ring_virt = NULL;
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
