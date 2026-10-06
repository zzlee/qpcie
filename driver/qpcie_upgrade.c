// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * File: qpcie_upgrade.c
 * Description: Linux Kernel PCIe H2C DMA Fast-Push In-System Firmware Upgrade Driver.
 *              Enables pushing firmware bundles (upgrade.tar.gz) directly into
 *              AMD Zynq UltraScale+ XCZU4EV PS DDR4 memory via PCIe H2C DMA (~3.2 GB/s).
 */

#include "qpcie_driver.h"
#include <linux/crc32.h>

#define REG_DMA_UPG_CTRL       0x0780
#define REG_DMA_UPG_SIZE       0x0784
#define REG_DMA_UPG_CRC32      0x0788
#define REG_DMA_UPG_PS_ADDR_L  0x078C
#define REG_DMA_UPG_PS_ADDR_H  0x0790
#define REG_DMA_UPG_STATUS     0x0794
#define REG_DMA_UPG_PROGRESS   0x0798
#define REG_DMA_UPG_DOORBELL   0x079C
#define REG_DMA_UPG_HOST_ADDR_L 0x07A0
#define REG_DMA_UPG_HOST_ADDR_H 0x07A4

#define DMA_UPG_CMD_NONE       0x00
#define DMA_UPG_CMD_START      0x01
#define DMA_UPG_CMD_DMA_DONE   0x02

#define UPG_CHUNK_SIZE         (2 * 1024 * 1024) /* 2 MB safe coherent chunk */

static ssize_t firmware_upgrade_write(struct file *filp, struct kobject *kobj,
                                      BIN_ATTR_ARG attr,
                                      char *buf, loff_t off, size_t count)
{
    struct device *dev = kobj_to_dev(kobj);
    struct pci_dev *pdev = to_pci_dev(dev);
    struct qpcie_dev *qdev = pci_get_drvdata(pdev);
    dma_addr_t dma_handle;
    void *cpu_addr;
    unsigned long timeout;
    u32 ctrl;

    if (!qdev || !qdev->bar0_mmio || count == 0)
        return -EINVAL;

    /* Allocate physically contiguous coherent DMA buffer for this chunk */
    cpu_addr = dma_alloc_coherent(&qdev->pdev->dev, count, &dma_handle, GFP_KERNEL);
    if (!cpu_addr) {
        dev_err(&qdev->pdev->dev, "Failed to allocate %zu bytes coherent DMA buffer for upgrade\n", count);
        return -ENOMEM;
    }

    /* Copy user payload to DMA buffer */
    memcpy(cpu_addr, buf, count);

    u64 ps_phys_addr = 0x70000000ULL + (u64)off;

    /* Program destination PS DDR4 physical address */
    iowrite32(lower_32_bits(ps_phys_addr), qdev->bar0_mmio + REG_DMA_UPG_PS_ADDR_L);
    iowrite32(upper_32_bits(ps_phys_addr), qdev->bar0_mmio + REG_DMA_UPG_PS_ADDR_H);

    /* Program chunk transfer size */
    iowrite32((u32)count, qdev->bar0_mmio + REG_DMA_UPG_SIZE);

    /* Program Host physical DMA bus address */
    iowrite32(lower_32_bits(dma_handle), qdev->bar0_mmio + REG_DMA_UPG_HOST_ADDR_L);
    iowrite32(upper_32_bits(dma_handle), qdev->bar0_mmio + REG_DMA_UPG_HOST_ADDR_H);
    ioread32(qdev->bar0_mmio + REG_DMA_UPG_HOST_ADDR_H); /* Flush posted PCIe write */

    /* Trigger PCIe H2C DMA Fast-Push */
    iowrite32(DMA_UPG_CMD_START, qdev->bar0_mmio + REG_DMA_UPG_CTRL);
    ioread32(qdev->bar0_mmio + REG_DMA_UPG_CTRL);

    /* Poll for completion (expected in < 1ms for 2MB @ 3.2GB/s) */
    timeout = jiffies + msecs_to_jiffies(3000);
    ctrl = 0;
    while (time_before(jiffies, timeout)) {
        ctrl = ioread32(qdev->bar0_mmio + REG_DMA_UPG_CTRL);
        if (ctrl & DMA_UPG_CMD_DMA_DONE)
            break;
        usleep_range(50, 150);
    }

    /* Clear command to return hardware to S_IDLE */
    iowrite32(DMA_UPG_CMD_NONE, qdev->bar0_mmio + REG_DMA_UPG_CTRL);
    ioread32(qdev->bar0_mmio + REG_DMA_UPG_CTRL);

    dma_free_coherent(&qdev->pdev->dev, count, cpu_addr, dma_handle);

    if (!(ctrl & DMA_UPG_CMD_DMA_DONE)) {
        dev_err(&qdev->pdev->dev, "Firmware upgrade H2C DMA transfer timed out! (ctrl=0x%08X)\n", ctrl);
        return -ETIMEDOUT;
    }

    return count;
}

static struct bin_attribute firmware_upgrade_attr = {
    .attr = {
        .name = "firmware_upgrade",
        .mode = 0200, /* Write-only by root */
    },
    .size = 0, /* Dynamic stream size */
    .write = firmware_upgrade_write,
};

int qpcie_upgrade_init(struct qpcie_dev *qdev)
{
    int ret;
    ret = device_create_bin_file(&qdev->pdev->dev, &firmware_upgrade_attr);
    if (ret)
        dev_warn(&qdev->pdev->dev, "Failed to create firmware_upgrade sysfs attribute: %d\n", ret);
    else
        dev_info(&qdev->pdev->dev, "Registered PCIe H2C Firmware Upgrade Fast-Push interface\n");
    return ret;
}

void qpcie_upgrade_remove(struct qpcie_dev *qdev)
{
    device_remove_bin_file(&qdev->pdev->dev, &firmware_upgrade_attr);
}
