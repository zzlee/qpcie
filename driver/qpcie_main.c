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

    dev_info(&pdev->dev, "Probing QPCIe Multi-Channel Video (V4L2) & Audio (ALSA) DMA Device...\n");

    qdev = devm_kzalloc(&pdev->dev, sizeof(*qdev), GFP_KERNEL);
    if (!qdev) return -ENOMEM;

    qdev->pdev = pdev;
    pci_set_drvdata(pdev, qdev);

    ret = pci_enable_device(pdev);
    if (ret) return ret;

    pci_set_master(pdev);

    ret = pci_request_regions(pdev, "qpcie-dma");
    if (ret) goto disable_pci;

    /* Dual-BAR Remapping: BAR0 for DMA Control, BAR1 for User IP Cores Interconnect */
    qdev->bar0_mmio = pci_iomap(pdev, 0, 0);
    if (!qdev->bar0_mmio) {
        ret = -ENOMEM;
        goto release_regions;
    }

    qdev->bar1_mmio = pci_iomap(pdev, 1, 0);
    if (!qdev->bar1_mmio) {
        dev_warn(&pdev->dev, "BAR1 User IP Cores MMIO not mapped\n");
    }

    /* Read Firmware Version & Hardware Capabilities from BAR0 */
    {
        u32 ver   = ioread32(qdev->bar0_mmio + REG_VERSION_ID);
        u32 git   = ioread32(qdev->bar0_mmio + REG_GIT_COMMIT_HASH);
        u32 date  = ioread32(qdev->bar0_mmio + REG_BUILD_TIMESTAMP);
        u32 caps  = ioread32(qdev->bar0_mmio + REG_HARDWARE_CAPS);

        dev_info(&pdev->dev, "Firmware Ver: v%d.%d.%d (Variant %d)\n",
                 (ver >> 24) & 0xFF, (ver >> 16) & 0xFF, (ver >> 8) & 0xFF, ver & 0xFF);
        dev_info(&pdev->dev, "Git Commit: 0x%08X, Build Date: %08X\n", git, date);
        dev_info(&pdev->dev, "HW Caps: Video Channels=%d, Audio Channels=%d, Caps Flags=0x%X\n",
                 (caps >> 8) & 0xFF, (caps >> 16) & 0xFF, caps & 0xFF);
    }

    /* Allocate Coherent Descriptor Ring Buffers (64-Byte 2D Descriptors) */
    qdev->h2c_ring_virt = dma_alloc_coherent(&pdev->dev,
                                             RING_BUFFER_SIZE * sizeof(struct qpcie_dma_desc_2d),
                                             &qdev->h2c_ring_dma, GFP_KERNEL);
    if (!qdev->h2c_ring_virt) {
        ret = -ENOMEM;
        goto unmap_mmio;
    }

    qdev->c2h_ring_virt = dma_alloc_coherent(&pdev->dev,
                                             RING_BUFFER_SIZE * sizeof(struct qpcie_dma_desc_2d),
                                             &qdev->c2h_ring_dma, GFP_KERNEL);
    if (!qdev->c2h_ring_virt) {
        ret = -ENOMEM;
        goto free_h2c_ring;
    }

    /* Write Ring Base Addresses to BAR0 Registers */
    iowrite32(lower_32_bits(qdev->h2c_ring_dma), qdev->bar0_mmio + REG_H2C_RING_ADDR_L);
    iowrite32(upper_32_bits(qdev->h2c_ring_dma), qdev->bar0_mmio + REG_H2C_RING_ADDR_H);
    iowrite32(lower_32_bits(qdev->c2h_ring_dma), qdev->bar0_mmio + REG_C2H_RING_ADDR_L);
    iowrite32(upper_32_bits(qdev->c2h_ring_dma), qdev->bar0_mmio + REG_C2H_RING_ADDR_H);

    /* Setup MSI-X / MSI Multi-Vector Interrupts (compatible across Linux Kernel 5.x / 6.x) */
    ret = pci_alloc_irq_vectors(pdev, 1, 8, PCI_IRQ_MSIX | PCI_IRQ_MSI | PCI_IRQ_INTX);
    if (ret < 0) goto free_c2h_ring;

    dev_info(&pdev->dev, "Allocated %d PCIe MSI-X / MSI Interrupt Vectors\n", ret);

    qdev->irq = pci_irq_vector(pdev, 0);
    ret = request_irq(qdev->irq, qpcie_irq_handler, IRQF_SHARED, "qpcie-dma", qdev);
    if (ret) goto free_irq_vectors;

    /* Enable IRQ in BAR0 */
    iowrite32(0x01, qdev->bar0_mmio + REG_IRQ_CTRL);

    /* Initialize V4L2 and ALSA Subsystems */
    ret = qpcie_v4l2_init(qdev);
    if (ret) goto free_irq;

    ret = qpcie_alsa_init(qdev);
    if (ret) goto cleanup_v4l2;

    dev_info(&pdev->dev, "QPCIe Multi-Channel Driver Initialized Successfully\n");
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
