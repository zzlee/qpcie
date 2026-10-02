// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * File: qpcie_flash.c
 * Description: Linux Kernel SPI Flash & ICAPE2 In-System Reconfiguration Driver.
 *              Controls Macronix MX25L12835F SPI Flash on Artix-7 A50T over PCIe BAR1.
 */

#include "qpcie_driver.h"

#define CMD_READ_ID         0x9F
#define CMD_WRITE_ENABLE    0x06
#define CMD_READ_STATUS     0x05
#define CMD_READ_DATA       0x03
#define CMD_PAGE_PROGRAM    0x02
#define CMD_SECTOR_ERASE_4K 0x20
#define CMD_BLOCK_ERASE_64K 0xD8

#define STATUS_WIP          BIT(0) /* Write in progress */

static inline u32 qpcie_spi_read(struct qpcie_dev *qdev, u32 reg)
{
    return ioread32(qdev->bar1_mmio + BAR1_OFFSET_SPI_FLASH + reg);
}

static inline void qpcie_spi_write(struct qpcie_dev *qdev, u32 reg, u32 val)
{
    iowrite32(val, qdev->bar1_mmio + BAR1_OFFSET_SPI_FLASH + reg);
    (void)ioread32(qdev->bar1_mmio + BAR1_OFFSET_SPI_FLASH + reg); /* Flush PCIe write */
    udelay(5);
}

static void qpcie_spi_set_cs(struct qpcie_dev *qdev, bool assert)
{
    /* CS_N=0 when asserted, CS_N=1 when deasserted. Use divider=6 for safe ~10MHz SPI clock */
    u32 cr = (6 << 4) | SPI_CR_SPI_EN | (assert ? 0 : SPI_CR_CS_N);

    qpcie_spi_write(qdev, REG_SPI_CR, cr);
    udelay(10);
}

static u8 qpcie_spi_xfer_byte(struct qpcie_dev *qdev, u8 tx_byte)
{
    u32 rx_val;
    int timeout = 500;

    qpcie_spi_write(qdev, REG_SPI_TXD, tx_byte);

    /* Wait for SPI engine to finish shifting byte (SPISR busy bit 0 cleared) */
    while (timeout-- > 0) {
        u32 sr = qpcie_spi_read(qdev, REG_SPI_SR);
        if (!(sr & 0x01))
            break;
        udelay(2);
    }

    rx_val = qpcie_spi_read(qdev, REG_SPI_RXD);
    return (u8)(rx_val & 0xFF);
}

static int qpcie_flash_wait_busy(struct qpcie_dev *qdev, unsigned int timeout_ms)
{
    unsigned long timeout = jiffies + msecs_to_jiffies(timeout_ms);

    while (time_before(jiffies, timeout)) {
        u8 status;

        qpcie_spi_set_cs(qdev, true);
        qpcie_spi_xfer_byte(qdev, CMD_READ_STATUS);
        status = qpcie_spi_xfer_byte(qdev, 0xFF);
        qpcie_spi_set_cs(qdev, false);

        if (!(status & STATUS_WIP))
            return 0;

        usleep_range(500, 1000);
    }

    return -ETIMEDOUT;
}

static void qpcie_flash_write_enable(struct qpcie_dev *qdev)
{
    qpcie_spi_set_cs(qdev, true);
    qpcie_spi_xfer_byte(qdev, CMD_WRITE_ENABLE);
    qpcie_spi_set_cs(qdev, false);
}

static int qpcie_flash_read_id(struct qpcie_dev *qdev, u32 *id)
{
    u8 b0, b1, b2;

    mutex_lock(&qdev->flash_lock);
    qpcie_spi_set_cs(qdev, true);

    qpcie_spi_xfer_byte(qdev, CMD_READ_ID);
    b0 = qpcie_spi_xfer_byte(qdev, 0xFF);
    b1 = qpcie_spi_xfer_byte(qdev, 0xFF);
    b2 = qpcie_spi_xfer_byte(qdev, 0xFF);
    qpcie_spi_set_cs(qdev, false);
    mutex_unlock(&qdev->flash_lock);

    *id = ((u32)b0 << 16) | ((u32)b1 << 8) | b2;
    dev_info(&qdev->pdev->dev, "SPI_READ_ID: Result=0x%06X (Manufacturer=0x%02X, Type=0x%02X, Capacity=0x%02X)\n",
             *id, b0, b1, b2);
    return 0;
}

static ssize_t flash_id_show(struct device *dev, struct device_attribute *attr, char *buf)
{
    struct qpcie_dev *qdev = dev_get_drvdata(dev);
    u32 id = 0;

    if (!qdev || !qdev->bar1_mmio)
        return -ENODEV;

    qpcie_flash_read_id(qdev, &id);
    return sprintf(buf, "0x%06X (Manufacturer: 0x%02X, Memory Type: 0x%02X, Capacity: 0x%02X)\n",
                   id, (id >> 16) & 0xFF, (id >> 8) & 0xFF, id & 0xFF);
}
static DEVICE_ATTR_RO(flash_id);

static ssize_t flash_reload_store(struct device *dev, struct device_attribute *attr,
                                  const char *buf, size_t count)
{
    struct qpcie_dev *qdev = dev_get_drvdata(dev);
    int val = 0;

    if (kstrtoint(buf, 0, &val) || val != 1)
        return -EINVAL;

    dev_info(dev, "Triggering FPGA ICAPE2 warm boot (IPROG reload)...\n");
    qpcie_spi_write(qdev, REG_ICAP_CMD, ICAP_MAGIC_RELOAD);

    return count;
}
static DEVICE_ATTR_WO(flash_reload);

#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 13, 0)
#define BIN_ATTR_ARG const struct bin_attribute *
#else
#define BIN_ATTR_ARG struct bin_attribute *
#endif

/* Sysfs Binary Attribute for Flash Read & Write */
static ssize_t flash_bin_read(struct file *filp, struct kobject *kobj,
                              BIN_ATTR_ARG bin_attr,
                              char *buf, loff_t off, size_t count)
{
    struct device *dev = kobj_to_dev(kobj);
    struct qpcie_dev *qdev = dev_get_drvdata(dev);
    size_t i;

    if (!qdev || !qdev->bar1_mmio)
        return -ENODEV;

    if (off >= 16 * 1024 * 1024) // 16MB SPI Flash limit
        return 0;
    if (off + count > 16 * 1024 * 1024)
        count = 16 * 1024 * 1024 - off;

    mutex_lock(&qdev->flash_lock);
    qpcie_spi_set_cs(qdev, true);
    qpcie_spi_xfer_byte(qdev, CMD_READ_DATA);
    qpcie_spi_xfer_byte(qdev, (off >> 16) & 0xFF);
    qpcie_spi_xfer_byte(qdev, (off >> 8) & 0xFF);
    qpcie_spi_xfer_byte(qdev, off & 0xFF);

    for (i = 0; i < count; i++) {
        buf[i] = qpcie_spi_xfer_byte(qdev, 0xFF);
    }
    qpcie_spi_set_cs(qdev, false);
    mutex_unlock(&qdev->flash_lock);

    return count;
}

static ssize_t flash_bin_write(struct file *filp, struct kobject *kobj,
                               BIN_ATTR_ARG bin_attr,
                               char *buf, loff_t off, size_t count)
{
    struct device *dev = kobj_to_dev(kobj);
    struct qpcie_dev *qdev = dev_get_drvdata(dev);
    size_t written = 0;

    if (!qdev || !qdev->bar1_mmio)
        return -ENODEV;

    mutex_lock(&qdev->flash_lock);

    while (written < count) {
        u32 cur_addr = off + written;
        size_t chunk = min_t(size_t, count - written, 256 - (cur_addr & 0xFF));
        size_t i;

        /* If at 64KB boundary, erase 64KB block */
        if ((cur_addr & 0xFFFF) == 0) {
            qpcie_flash_write_enable(qdev);
            qpcie_spi_set_cs(qdev, true);
            qpcie_spi_xfer_byte(qdev, CMD_BLOCK_ERASE_64K);
            qpcie_spi_xfer_byte(qdev, (cur_addr >> 16) & 0xFF);
            qpcie_spi_xfer_byte(qdev, (cur_addr >> 8) & 0xFF);
            qpcie_spi_xfer_byte(qdev, cur_addr & 0xFF);
            qpcie_spi_set_cs(qdev, false);
            if (qpcie_flash_wait_busy(qdev, 2000)) {
                mutex_unlock(&qdev->flash_lock);
                return -EIO;
            }
        }

        /* Page Program */
        qpcie_flash_write_enable(qdev);
        qpcie_spi_set_cs(qdev, true);
        qpcie_spi_xfer_byte(qdev, CMD_PAGE_PROGRAM);
        qpcie_spi_xfer_byte(qdev, (cur_addr >> 16) & 0xFF);
        qpcie_spi_xfer_byte(qdev, (cur_addr >> 8) & 0xFF);
        qpcie_spi_xfer_byte(qdev, cur_addr & 0xFF);

        for (i = 0; i < chunk; i++) {
            qpcie_spi_xfer_byte(qdev, buf[written + i]);
        }
        qpcie_spi_set_cs(qdev, false);

        if (qpcie_flash_wait_busy(qdev, 100)) {
            mutex_unlock(&qdev->flash_lock);
            return -EIO;
        }

        written += chunk;
    }

    mutex_unlock(&qdev->flash_lock);
    return count;
}

static struct bin_attribute flash_bin_attr = {
    .attr = {
        .name = "flash_bin",
        .mode = 0600,
    },
    .size  = 16 * 1024 * 1024,
    .read  = flash_bin_read,
    .write = flash_bin_write,
};

int qpcie_flash_init(struct qpcie_dev *qdev)
{
    int ret;

    mutex_init(&qdev->flash_lock);

    if (!qdev->bar1_mmio)
        return -ENODEV;

    /* Initialize SPI Flash controller: deassert CS_N */
    qpcie_spi_set_cs(qdev, false);

    ret = device_create_file(&qdev->pdev->dev, &dev_attr_flash_id);
    if (ret)
        return ret;

    ret = device_create_file(&qdev->pdev->dev, &dev_attr_flash_reload);
    if (ret)
        goto err_reload;

    ret = device_create_bin_file(&qdev->pdev->dev, &flash_bin_attr);
    if (ret)
        goto err_bin;

    dev_info(&qdev->pdev->dev, "Initialized SPI Flash & ICAPE2 interface\n");
    return 0;

err_bin:
    device_remove_file(&qdev->pdev->dev, &dev_attr_flash_reload);
err_reload:
    device_remove_file(&qdev->pdev->dev, &dev_attr_flash_id);
    return ret;
}

void qpcie_flash_remove(struct qpcie_dev *qdev)
{
    device_remove_bin_file(&qdev->pdev->dev, &flash_bin_attr);
    device_remove_file(&qdev->pdev->dev, &dev_attr_flash_reload);
    device_remove_file(&qdev->pdev->dev, &dev_attr_flash_id);
}
