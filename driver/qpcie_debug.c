// SPDX-License-Identifier: GPL-2.0
/* Exclusive, root-only, bounded debug aperture. No second PCI driver/mmap.
 * Object and open files outlive PCI remove; dead fds cannot touch freed MMIO.
 */
#include "qpcie_driver.h"
#include "../include/qpcie_debug.h"
#include <linux/miscdevice.h>
#include <linux/kref.h>
#include <linux/slab.h>
#include <linux/uaccess.h>

struct qpcie_debug {
    struct miscdevice misc;
    struct kref refs;
    struct mutex lock;
    void __iomem *base;
    bool dead, opened;
    char name[64];
};
static void debug_free(struct kref *ref)
{
    kfree(container_of(ref, struct qpcie_debug, refs));
}
static int debug_open(struct inode *inode, struct file *file)
{
    struct qpcie_debug *d = container_of(file->private_data,
                                        struct qpcie_debug, misc);
    int rc = 0;
    mutex_lock(&d->lock);
    if (d->dead) rc = -ENODEV;
    else if (d->opened) rc = -EBUSY;
    else {
        d->opened = true;
        kref_get(&d->refs);
        file->private_data = d;
    }
    mutex_unlock(&d->lock);
    return rc;
}
static int debug_release(struct inode *inode, struct file *file)
{
    struct qpcie_debug *d = file->private_data;
    mutex_lock(&d->lock);
    d->opened = false;
    mutex_unlock(&d->lock);
    kref_put(&d->refs, debug_free);
    return 0;
}
static bool host_writable(loff_t offset)
{
    return offset == DB_HOST_EPOCH || offset == DB_HOST_BEAT ||
           offset == DB_H2C_SEQ || offset == DB_H2C_TYPE ||
           offset == DB_H2C_ID || offset == DB_H2C_LEN ||
           offset == DB_C2H_ACK || offset == DB_TIMEOUT_MS ||
           (offset >= DB_H2C_DATA && offset < DB_H2C_DATA + DB_PAYLOAD);
}
static ssize_t debug_read(struct file *file, char __user *buf,
                          size_t count, loff_t *pos)
{
    struct qpcie_debug *d = file->private_data;
    __le32 *words;
    size_t i;
    ssize_t rc;
    if (*pos < 0 || *pos > QDBG_SIZE || (*pos & 3) || (count & 3) ||
        count > QDBG_SIZE - *pos) return -EINVAL;
    if (!count) return 0;
    words = kmalloc(count, GFP_KERNEL);
    if (!words) return -ENOMEM;
    mutex_lock(&d->lock);
    if (d->dead) rc = -ENODEV;
    else {
        for (i = 0; i < count / 4; ++i)
            words[i] = cpu_to_le32(ioread32(d->base + *pos + i * 4));
        rc = copy_to_user(buf, words, count) ? -EFAULT : count;
        if (rc > 0) *pos += rc;
    }
    mutex_unlock(&d->lock);
    kfree(words);
    return rc;
}
static ssize_t debug_write(struct file *file, const char __user *buf,
                           size_t count, loff_t *pos)
{
    struct qpcie_debug *d = file->private_data;
    __le32 *words;
    size_t i;
    ssize_t rc;
    if (*pos < 0 || *pos > QDBG_SIZE || (*pos & 3) || (count & 3) ||
        count > QDBG_SIZE - *pos) return -EINVAL;
    if (!count) return 0;
    for (i = 0; i < count; i += 4)
        if (!host_writable(*pos + i)) return -EPERM;
    words = memdup_user(buf, count);
    if (IS_ERR(words)) return PTR_ERR(words);
    mutex_lock(&d->lock);
    if (d->dead) rc = -ENODEV;
    else {
        for (i = 0; i < count / 4; ++i)
            iowrite32(le32_to_cpu(words[i]), d->base + *pos + i * 4);
        /* Flush PCIe posted writes to this endpoint, NOT smp_wmb(). */
        ioread32(d->base + DB_MAGIC);
        *pos += count;
        rc = count;
    }
    mutex_unlock(&d->lock);
    kfree(words);
    return rc;
}
static loff_t debug_seek(struct file *file, loff_t off, int whence)
{
    return fixed_size_llseek(file, off, whence, QDBG_SIZE);
}
static const struct file_operations debug_fops = {
    .owner = THIS_MODULE, .open = debug_open, .release = debug_release,
    .read = debug_read, .write = debug_write, .llseek = debug_seek,
};
int qpcie_debug_init(struct qpcie_dev *qdev)
{
    struct qpcie_debug *d;
    int rc;
    /* Old bitstreams have no slave at 0x2000: don't even read that address.
     * Exact version gate until future maps have been explicitly reviewed. */
    if (!qdev->is_zu4ev ||
        ioread32(qdev->bar0_mmio + REG_NEW_GLOBAL_VERSION) != QDBG_HW_VERSION)
        return 0;
    if (pci_resource_len(qdev->pdev, 0) < QDBG_BAR_OFFSET + QDBG_SIZE)
        return -ENODEV;
    if (ioread32(qdev->bar0_mmio + QDBG_BAR_OFFSET) != QDBG_MAGIC ||
        ioread32(qdev->bar0_mmio + QDBG_BAR_OFFSET + DB_ABI) != QDBG_ABI)
        return -ENODEV;
    d = kzalloc(sizeof(*d), GFP_KERNEL);
    if (!d) return -ENOMEM;
    kref_init(&d->refs);
    mutex_init(&d->lock);
    d->base = qdev->bar0_mmio + QDBG_BAR_OFFSET;
    snprintf(d->name, sizeof(d->name), "qpcie-debug-%s", pci_name(qdev->pdev));
    d->misc.minor = MISC_DYNAMIC_MINOR;
    d->misc.name = d->name;
    d->misc.fops = &debug_fops;
    d->misc.mode = 0600;
    d->misc.parent = &qdev->pdev->dev;
    rc = misc_register(&d->misc);
    if (rc) { kref_put(&d->refs, debug_free); return rc; }
    qdev->debug = d;
    dev_info(&qdev->pdev->dev, "Debug mailbox: /dev/%s (exclusive, root only)\n", d->name);
    return 0;
}
void qpcie_debug_remove(struct qpcie_dev *qdev)
{
    struct qpcie_debug *d = qdev->debug;
    if (!d) return;
    misc_deregister(&d->misc);
    mutex_lock(&d->lock);
    d->dead = true;
    d->base = NULL;
    mutex_unlock(&d->lock);
    qdev->debug = NULL;
    kref_put(&d->refs, debug_free);
}
