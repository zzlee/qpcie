// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Module: qpcie_main.c
 * Description: PCIe Driver Main Entry for Custom PCIe Multi-Channel V4L2 Video & ALSA AES3 Audio.
 *              Handles PCI probe/remove, Dual-BAR ioremap, Coherent Descriptor Alloc, and Interrupts.
 */

#include "qpcie_driver.h"

static const struct pci_device_id qpcie_id_table[] = {
    { PCI_DEVICE(QPCIE_VENDOR_ID, QPCIE_DEVICE_ID) },
    { 0, }
};
MODULE_DEVICE_TABLE(pci, qpcie_id_table);

static irqreturn_t qpcie_irq_handler(int irq, void *dev_id)
{
    struct qpcie_dev *qdev = dev_id;
    u32 irq_stat;

    irq_stat = ioread32(qdev->bar0_mmio + REG_IRQ_STATUS);
    if (!irq_stat) return IRQ_NONE;

    /* Clear Interrupt W1C */
    iowrite32(irq_stat, qdev->bar0_mmio + REG_IRQ_STATUS);

    if (irq_stat & 0x01) qpcie_v4l2_irq_handler(qdev); /* Video Frame Done IRQ */
    if (irq_stat & 0x02) qpcie_alsa_irq_handler(qdev); /* Audio Block Elapsed IRQ */

    return IRQ_HANDLED;
}

static int qpcie_probe(struct pci_dev *pdev, const struct pci_device_id *id)
{
    struct qpcie_dev *qdev;
    int ret;

    dev_info(&pdev->dev, "=======================================================\n");
    dev_info(&pdev->dev, "=== [STEP 1 DEBUG] QPCIe Driver Probe Initialization ===\n");
    dev_info(&pdev->dev, "=======================================================\n");

    qdev = devm_kzalloc(&pdev->dev, sizeof(*qdev), GFP_KERNEL);
    if (!qdev) return -ENOMEM;

    qdev->pdev = pdev;
    pci_set_drvdata(pdev, qdev);

    ret = pci_enable_device(pdev);
    if (ret) {
        dev_err(&pdev->dev, "[DEBUG ERROR] pci_enable_device failed: %d\n", ret);
        return ret;
    }

    pci_set_master(pdev);

    dev_info(&pdev->dev, "[BAR0 Resource] Start=0x%llx, Len=0x%llx, Flags=0x%lx\n",
             (unsigned long long)pci_resource_start(pdev, 0),
             (unsigned long long)pci_resource_len(pdev, 0),
             (unsigned long)pci_resource_flags(pdev, 0));
    dev_info(&pdev->dev, "[BAR1 Resource] Start=0x%llx, Len=0x%llx, Flags=0x%lx\n",
             (unsigned long long)pci_resource_start(pdev, 1),
             (unsigned long long)pci_resource_len(pdev, 1),
             (unsigned long)pci_resource_flags(pdev, 1));

    ret = pci_request_regions(pdev, "qpcie-dma");
    if (ret) {
        dev_err(&pdev->dev, "[DEBUG ERROR] pci_request_regions failed: %d\n", ret);
        goto disable_pci;
    }

    /* Dual-BAR Remapping: BAR0 for DMA Control, BAR1 for User IP Cores Interconnect */
    qdev->bar0_mmio = pci_iomap(pdev, 0, 0);
    if (!qdev->bar0_mmio) {
        dev_err(&pdev->dev, "[DEBUG ERROR] BAR0 MMIO pci_iomap failed!\n");
        ret = -ENOMEM;
        goto release_regions;
    }
    dev_info(&pdev->dev, "[DEBUG] BAR0 MMIO mapped at virt addr: %p\n", qdev->bar0_mmio);

    qdev->bar1_mmio = pci_iomap(pdev, 1, 0);
    if (!qdev->bar1_mmio) {
        dev_warn(&pdev->dev, "[DEBUG WARN] BAR1 User IP Cores MMIO not mapped\n");
    } else {
        dev_info(&pdev->dev, "[DEBUG] BAR1 MMIO mapped at virt addr: %p\n", qdev->bar1_mmio);
    }

    /* Verbose Register Read Debugging */
    dev_info(&pdev->dev, "[DEBUG STEP 1.1] Reading BAR0 offset 0x30 (REG_VERSION_ID)...\n");
    u32 ver = ioread32(qdev->bar0_mmio + REG_VERSION_ID);
    dev_info(&pdev->dev, " -> Raw 0x30 = 0x%08X (Parsed Ver: v%u.%u.%u Variant %u)\n",
             ver, (ver >> 24) & 0xFF, (ver >> 16) & 0xFF, (ver >> 8) & 0xFF, ver & 0xFF);

    dev_info(&pdev->dev, "[DEBUG STEP 1.2] Reading BAR0 offset 0x34 (REG_GIT_COMMIT_HASH)...\n");
    u32 git = ioread32(qdev->bar0_mmio + REG_GIT_COMMIT_HASH);
    dev_info(&pdev->dev, " -> Raw 0x34 = 0x%08X\n", git);

    dev_info(&pdev->dev, "[DEBUG STEP 1.3] Reading BAR0 offset 0x38 (REG_BUILD_TIMESTAMP)...\n");
    u32 date = ioread32(qdev->bar0_mmio + REG_BUILD_TIMESTAMP);
    dev_info(&pdev->dev, " -> Raw 0x38 = 0x%08X\n", date);

    dev_info(&pdev->dev, "[DEBUG STEP 1.4] Reading BAR0 offset 0x3C (REG_HARDWARE_CAPS)...\n");
    u32 caps = ioread32(qdev->bar0_mmio + REG_HARDWARE_CAPS);
    dev_info(&pdev->dev, " -> Raw 0x3C = 0x%08X (VideoCh=%u, AudioCh=%u)\n",
             caps, (caps >> 8) & 0xFF, (caps >> 16) & 0xFF);

    dev_info(&pdev->dev, "[DEBUG STEP 1.5] Reading BAR0 offset 0x00 (REG_DMA_CTRL)...\n");
    u32 ctrl = ioread32(qdev->bar0_mmio + REG_DMA_CTRL);
    dev_info(&pdev->dev, " -> Raw 0x00 = 0x%08X\n", ctrl);

    dev_info(&pdev->dev, "[DEBUG STEP 1.6] Reading BAR0 offset 0x04 (REG_DMA_STATUS)...\n");
    u32 stat = ioread32(qdev->bar0_mmio + REG_DMA_STATUS);
    dev_info(&pdev->dev, " -> Raw 0x04 = 0x%08X\n", stat);

    /* Allocate Coherent Descriptor Ring Buffers (64-Byte 2D Descriptors) */
    dev_info(&pdev->dev, "[DEBUG STEP 1.7] Allocating H2C & C2H DMA Coherent Rings...\n");
    qdev->h2c_ring_virt = dma_alloc_coherent(&pdev->dev,
                                             RING_BUFFER_SIZE * sizeof(struct qpcie_dma_desc_2d),
                                             &qdev->h2c_ring_dma, GFP_KERNEL);
    if (!qdev->h2c_ring_virt) {
        dev_err(&pdev->dev, "[DEBUG ERROR] Failed to allocate H2C Ring!\n");
        ret = -ENOMEM;
        goto unmap_mmio;
    }
    dev_info(&pdev->dev, " -> H2C Ring DMA Addr: 0x%llx\n", (unsigned long long)qdev->h2c_ring_dma);

    qdev->c2h_ring_virt = dma_alloc_coherent(&pdev->dev,
                                             RING_BUFFER_SIZE * sizeof(struct qpcie_dma_desc_2d),
                                             &qdev->c2h_ring_dma, GFP_KERNEL);
    if (!qdev->c2h_ring_virt) {
        dev_err(&pdev->dev, "[DEBUG ERROR] Failed to allocate C2H Ring!\n");
        ret = -ENOMEM;
        goto free_h2c_ring;
    }
    dev_info(&pdev->dev, " -> C2H Ring DMA Addr: 0x%llx\n", (unsigned long long)qdev->c2h_ring_dma);

    /* Write Ring Base Addresses to BAR0 Registers */
    dev_info(&pdev->dev, "[DEBUG STEP 1.8] Writing Ring Base Addrs to BAR0 (0x08, 0x0C, 0x14, 0x18)...\n");
    iowrite32(lower_32_bits(qdev->h2c_ring_dma), qdev->bar0_mmio + REG_H2C_RING_ADDR_L);
    iowrite32(upper_32_bits(qdev->h2c_ring_dma), qdev->bar0_mmio + REG_H2C_RING_ADDR_H);
    iowrite32(lower_32_bits(qdev->c2h_ring_dma), qdev->bar0_mmio + REG_C2H_RING_ADDR_L);
    iowrite32(upper_32_bits(qdev->c2h_ring_dma), qdev->bar0_mmio + REG_C2H_RING_ADDR_H);
    dev_info(&pdev->dev, " -> Ring Base Addresses Written OK\n");

    /* Setup MSI-X / MSI Multi-Vector Interrupts */
    dev_info(&pdev->dev, "[DEBUG STEP 1.9] Allocating PCIe IRQ Vectors...\n");
    ret = pci_alloc_irq_vectors(pdev, 1, 8, PCI_IRQ_MSIX | PCI_IRQ_MSI | PCI_IRQ_INTX);
    if (ret < 0) {
        dev_err(&pdev->dev, "[DEBUG ERROR] pci_alloc_irq_vectors failed: %d\n", ret);
        goto free_c2h_ring;
    }

    dev_info(&pdev->dev, " -> Allocated %d PCIe Interrupt Vectors\n", ret);

    qdev->irq = pci_irq_vector(pdev, 0);
    dev_info(&pdev->dev, "[DEBUG STEP 1.10] Requesting IRQ %d...\n", qdev->irq);
    ret = request_irq(qdev->irq, qpcie_irq_handler, IRQF_SHARED, "qpcie-dma", qdev);
    if (ret) {
        dev_err(&pdev->dev, "[DEBUG ERROR] request_irq failed: %d\n", ret);
        goto free_irq_vectors;
    }

    /* Enable IRQ in BAR0 */
    dev_info(&pdev->dev, "[DEBUG STEP 1.11] Enabling Interrupts in BAR0 (0x20)...\n");
    iowrite32(0x01, qdev->bar0_mmio + REG_IRQ_CTRL);

    /* Initialize V4L2 and ALSA Subsystems */
    dev_info(&pdev->dev, "[DEBUG STEP 1.12] Initializing V4L2 Subsystem...\n");
    ret = qpcie_v4l2_init(qdev);
    if (ret) {
        dev_err(&pdev->dev, "[DEBUG ERROR] qpcie_v4l2_init failed: %d\n", ret);
        goto free_irq;
    }

    dev_info(&pdev->dev, "[DEBUG STEP 1.13] Initializing ALSA Subsystem...\n");
    ret = qpcie_alsa_init(qdev);
    if (ret) {
        dev_err(&pdev->dev, "[DEBUG ERROR] qpcie_alsa_init failed: %d\n", ret);
        goto cleanup_v4l2;
    }

    dev_info(&pdev->dev, "🎉 [DEBUG STEP 1 COMPLETE] QPCIe Driver Probe Successful!\n");
    return 0;

cleanup_v4l2:
    qpcie_v4l2_remove(qdev);
free_irq:
    free_irq(qdev->irq, qdev);
free_irq_vectors:
    pci_free_irq_vectors(pdev);
free_c2h_ring:
    dma_free_coherent(&pdev->dev, RING_BUFFER_SIZE * sizeof(struct qpcie_dma_desc_2d),
                      qdev->c2h_ring_virt, qdev->c2h_ring_dma);
free_h2c_ring:
    dma_free_coherent(&pdev->dev, RING_BUFFER_SIZE * sizeof(struct qpcie_dma_desc_2d),
                      qdev->h2c_ring_virt, qdev->h2c_ring_dma);
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

    dev_info(&pdev->dev, "Removing QPCIe Driver...\n");

    /* Disable IRQ in BAR0 */
    iowrite32(0x00, qdev->bar0_mmio + REG_IRQ_CTRL);

    qpcie_alsa_remove(qdev);
    qpcie_v4l2_remove(qdev);

    free_irq(qdev->irq, qdev);
    pci_free_irq_vectors(pdev);

    dma_free_coherent(&pdev->dev, RING_BUFFER_SIZE * sizeof(struct qpcie_dma_desc_2d),
                      qdev->c2h_ring_virt, qdev->c2h_ring_dma);
    dma_free_coherent(&pdev->dev, RING_BUFFER_SIZE * sizeof(struct qpcie_dma_desc_2d),
                      qdev->h2c_ring_virt, qdev->h2c_ring_dma);

    if (qdev->bar1_mmio) pci_iounmap(pdev, qdev->bar1_mmio);
    pci_iounmap(pdev, qdev->bar0_mmio);
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
MODULE_DESCRIPTION("QPCIe Multi-Channel 2D Video (V4L2) & Audio (ALSA) DMA Driver");
MODULE_LICENSE("GPL");
