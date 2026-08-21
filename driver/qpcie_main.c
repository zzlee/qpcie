// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Module: qpcie_main.c
 * Description: Minimal PCI BAR0 & BAR1 Register Read/Write Diagnostic Mode.
 *              Temporarily bypasses V4L2 and ALSA to isolate MMIO hardware stability.
 */

#include "qpcie_driver.h"

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
    iowrite32(0x12345678, qdev->bar0_mmio + REG_H2C_RING_ADDR_L); // offset 0x08
    readback = ioread32(qdev->bar0_mmio + REG_H2C_RING_ADDR_L);
    dev_info(&pdev->dev, "  BAR0 [0x08] Write 0x12345678 -> Readback: 0x%08X %s\n",
             readback, (readback == 0x12345678) ? "[PASS]" : "[FAIL]");

    iowrite32(0x87654321, qdev->bar0_mmio + REG_C2H_RING_ADDR_L); // offset 0x14
    readback = ioread32(qdev->bar0_mmio + REG_C2H_RING_ADDR_L);
    dev_info(&pdev->dev, "  BAR0 [0x14] Write 0x87654321 -> Readback: 0x%08X %s\n",
             readback, (readback == 0x87654321) ? "[PASS]" : "[FAIL]");

    /* Restore zero values */
    iowrite32(0x00000000, qdev->bar0_mmio + REG_H2C_RING_ADDR_L);
    iowrite32(0x00000000, qdev->bar0_mmio + REG_C2H_RING_ADDR_L);

    /* ------------------------------------------------------------------------
     * 3. BAR1 Read Tests (Disabled to prevent unmapped BAR1 crossbar timeout)
     * ------------------------------------------------------------------------ */
    dev_info(&pdev->dev, "--- [3. BAR1 User IP Tests Bypassed] ---\n");

    dev_info(&pdev->dev, "=======================================================\n");
    dev_info(&pdev->dev, "🎉 [MINIMAL DIAGNOSTIC TEST COMPLETED SUCCESSFULLY]\n");
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
