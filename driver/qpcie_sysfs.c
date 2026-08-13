// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Module: qpcie_sysfs.c
 * Description: Linux Kernel Sysfs Device Attributes Implementation for QPCIe Video TPG,
 *              Audio Pattern Generator, and Firmware Version Registers.
 */

#include "qpcie_driver.h"

/* ============================================================================
 * 1. Video TPG (v_tpg_0) Sysfs Attributes
 * ============================================================================ */

static ssize_t tpg_pattern_show(struct device *dev, struct device_attribute *attr, char *buf)
{
    struct pci_dev *pdev = to_pci_dev(dev);
    struct qpcie_dev *qdev = pci_get_drvdata(pdev);
    u32 pattern_id = 0;

    if (qdev && qdev->bar1_mmio) {
        pattern_id = ioread32(qdev->bar1_mmio + 0x0000 + 0x20);
    }

    const char *name = "Unknown";
    switch (pattern_id) {
        case 0:  name = "Pass-through"; break;
        case 1:  name = "Horizontal Ramp"; break;
        case 2:  name = "Vertical Ramp"; break;
        case 9:  name = "Color Bars"; break;
        case 10: name = "Zone Plate"; break;
        default: name = "Custom Pattern"; break;
    }

    return sysfs_emit(buf, "%u (%s)\n", pattern_id, name);
}

static ssize_t tpg_pattern_store(struct device *dev, struct device_attribute *attr, const char *buf, size_t count)
{
    struct pci_dev *pdev = to_pci_dev(dev);
    struct qpcie_dev *qdev = pci_get_drvdata(pdev);
    u32 pattern_id = 0;

    if (kstrtou32(buf, 0, &pattern_id)) return -EINVAL;

    if (qdev && qdev->bar1_mmio) {
        /* Write Pattern ID to BAR1 Offset 0x0020 */
        iowrite32(pattern_id, qdev->bar1_mmio + 0x0000 + 0x20);
        /* Trigger AP_START & Auto-Restart on TPG Control Reg (0x0000) */
        iowrite32(0x81, qdev->bar1_mmio + 0x0000 + 0x00);
        dev_info(dev, "Updated Video TPG Pattern ID to %u\n", pattern_id);
    }

    return count;
}
static DEVICE_ATTR_RW(tpg_pattern);

static ssize_t tpg_resolution_show(struct device *dev, struct device_attribute *attr, char *buf)
{
    struct pci_dev *pdev = to_pci_dev(dev);
    struct qpcie_dev *qdev = pci_get_drvdata(pdev);
    u32 cols = 1920, rows = 1080;

    if (qdev && qdev->bar1_mmio) {
        rows = ioread32(qdev->bar1_mmio + 0x0000 + 0x10);
        cols = ioread32(qdev->bar1_mmio + 0x0000 + 0x18);
    }

    return sysfs_emit(buf, "%ux%u\n", cols, rows);
}

static ssize_t tpg_resolution_store(struct device *dev, struct device_attribute *attr, const char *buf, size_t count)
{
    struct pci_dev *pdev = to_pci_dev(dev);
    struct qpcie_dev *qdev = pci_get_drvdata(pdev);
    u32 cols = 1920, rows = 1080;

    if (sscanf(buf, "%ux%u", &cols, &rows) != 2) return -EINVAL;

    if (qdev && qdev->bar1_mmio) {
        iowrite32(rows, qdev->bar1_mmio + 0x0000 + 0x10);
        iowrite32(cols, qdev->bar1_mmio + 0x0000 + 0x18);
        iowrite32(0x81, qdev->bar1_mmio + 0x0000 + 0x00);
        dev_info(dev, "Updated Video TPG Resolution to %ux%u\n", cols, rows);
    }

    return count;
}
static DEVICE_ATTR_RW(tpg_resolution);

static ssize_t tpg_fps_show(struct device *dev, struct device_attribute *attr, char *buf)
{
    struct pci_dev *pdev = to_pci_dev(dev);
    struct qpcie_dev *qdev = pci_get_drvdata(pdev);
    u32 clks = 2083333;

    if (qdev && qdev->bar1_mmio) {
        clks = ioread32(qdev->bar1_mmio + 0x0000 + 0x30);
        if (clks == 0) clks = 2083333;
    }

    u32 fps = 125000000 / clks;
    return sysfs_emit(buf, "%u fps (Interval Clks: %u)\n", fps, clks);
}

static ssize_t tpg_fps_store(struct device *dev, struct device_attribute *attr, const char *buf, size_t count)
{
    struct pci_dev *pdev = to_pci_dev(dev);
    struct qpcie_dev *qdev = pci_get_drvdata(pdev);
    u32 target_fps = 60;

    if (kstrtou32(buf, 0, &target_fps) || target_fps == 0) return -EINVAL;

    u32 target_clks = 125000000 / target_fps;

    if (qdev && qdev->bar1_mmio) {
        iowrite32(target_clks, qdev->bar1_mmio + 0x0000 + 0x30);
        dev_info(dev, "Updated Hardware Video Frame Pacer FPS to %u (Clks: %u)\n", target_fps, target_clks);
    }

    return count;
}
static DEVICE_ATTR_RW(tpg_fps);

/* ============================================================================
 * 2. Audio Pattern Generator Sysfs Attributes
 * ============================================================================ */

static ssize_t aud_pattern_show(struct device *dev, struct device_attribute *attr, char *buf)
{
    struct pci_dev *pdev = to_pci_dev(dev);
    struct qpcie_dev *qdev = pci_get_drvdata(pdev);
    u32 ctrl_val = 0;

    if (qdev && qdev->bar1_mmio) {
        ctrl_val = ioread32(qdev->bar1_mmio + 0x0100 + 0x00);
    }

    u32 pattern_id = (ctrl_val >> 1) & 0x07;
    const char *name = "Unknown";
    switch (pattern_id) {
        case 0: name = "1kHz Sine Wave"; break;
        case 1: name = "Sawtooth Wave"; break;
        case 2: name = "440Hz Tone"; break;
        case 3: name = "Mute / Silence"; break;
        default: name = "Custom Pattern"; break;
    }

    return sysfs_emit(buf, "%u (%s)\n", pattern_id, name);
}

static ssize_t aud_pattern_store(struct device *dev, struct device_attribute *attr, const char *buf, size_t count)
{
    struct pci_dev *pdev = to_pci_dev(dev);
    struct qpcie_dev *qdev = pci_get_drvdata(pdev);
    u32 pattern_id = 0;

    if (kstrtou32(buf, 0, &pattern_id)) return -EINVAL;

    if (qdev && qdev->bar1_mmio) {
        u32 ctrl_val = ioread32(qdev->bar1_mmio + 0x0100 + 0x00);
        ctrl_val = (ctrl_val & ~0x0E) | ((pattern_id & 0x07) << 1) | 0x01; // Keep enabled
        iowrite32(ctrl_val, qdev->bar1_mmio + 0x0100 + 0x00);
        dev_info(dev, "Updated Audio Pattern ID to %u\n", pattern_id);
    }

    return count;
}
static DEVICE_ATTR_RW(aud_pattern);

static ssize_t aud_volume_show(struct device *dev, struct device_attribute *attr, char *buf)
{
    struct pci_dev *pdev = to_pci_dev(dev);
    struct qpcie_dev *qdev = pci_get_drvdata(pdev);
    u32 volume = 200;

    if (qdev && qdev->bar1_mmio) {
        volume = ioread32(qdev->bar1_mmio + 0x0100 + 0x08);
    }

    return sysfs_emit(buf, "%u\n", volume);
}

static ssize_t aud_volume_store(struct device *dev, struct device_attribute *attr, const char *buf, size_t count)
{
    struct pci_dev *pdev = to_pci_dev(dev);
    struct qpcie_dev *qdev = pci_get_drvdata(pdev);
    u32 volume = 200;

    if (kstrtou32(buf, 0, &volume)) return -EINVAL;

    if (qdev && qdev->bar1_mmio) {
        iowrite32(volume, qdev->bar1_mmio + 0x0100 + 0x08);
        dev_info(dev, "Updated Audio Volume Gain to %u\n", volume);
    }

    return count;
}
static DEVICE_ATTR_RW(aud_volume);

static ssize_t aud_sample_cnt_show(struct device *dev, struct device_attribute *attr, char *buf)
{
    struct pci_dev *pdev = to_pci_dev(dev);
    struct qpcie_dev *qdev = pci_get_drvdata(pdev);
    u32 sample_cnt = 0;

    if (qdev && qdev->bar1_mmio) {
        sample_cnt = ioread32(qdev->bar1_mmio + 0x0100 + 0x10);
    }

    return sysfs_emit(buf, "%u\n", sample_cnt);
}
static DEVICE_ATTR_RO(aud_sample_cnt);

/* ============================================================================
 * 3. Card Version & Capability Sysfs Attributes
 * ============================================================================ */

static ssize_t version_show(struct device *dev, struct device_attribute *attr, char *buf)
{
    struct pci_dev *pdev = to_pci_dev(dev);
    struct qpcie_dev *qdev = pci_get_drvdata(pdev);
    u32 ver = 0, git = 0, date = 0, caps = 0;

    if (qdev && qdev->bar0_mmio) {
        ver  = ioread32(qdev->bar0_mmio + REG_VERSION_ID);
        git  = ioread32(qdev->bar0_mmio + REG_GIT_COMMIT_HASH);
        date = ioread32(qdev->bar0_mmio + REG_BUILD_TIMESTAMP);
        caps = ioread32(qdev->bar0_mmio + REG_HARDWARE_CAPS);
    }

    return sysfs_emit(buf, "v%d.%d.%d-variant%d (Git: %08X, Date: %08X, Caps: 0x%08X)\n",
                      (ver >> 24) & 0xFF, (ver >> 16) & 0xFF, (ver >> 8) & 0xFF, ver & 0xFF,
                      git, date, caps);
}
static DEVICE_ATTR_RO(version);

/* Sysfs Attribute Group Table */
static struct attribute *qpcie_sysfs_attrs[] = {
    &dev_attr_tpg_pattern.attr,
    &dev_attr_tpg_resolution.attr,
    &dev_attr_tpg_fps.attr,
    &dev_attr_aud_pattern.attr,
    &dev_attr_aud_volume.attr,
    &dev_attr_aud_sample_cnt.attr,
    &dev_attr_version.attr,
    NULL,
};

static const struct attribute_group qpcie_sysfs_attr_group = {
    .attrs = qpcie_sysfs_attrs,
};

int qpcie_sysfs_init(struct qpcie_dev *qdev)
{
    int ret = sysfs_create_group(&qdev->pdev->dev.kobj, &qpcie_sysfs_attr_group);
    if (ret) {
        dev_err(&qdev->pdev->dev, "Failed to create sysfs attribute group\n");
        return ret;
    }
    dev_info(&qdev->pdev->dev, "Created QPCIe Sysfs Device Attributes (tpg_pattern, aud_pattern, aud_volume, version)\n");
    return 0;
}

void qpcie_sysfs_remove(struct qpcie_dev *qdev)
{
    sysfs_remove_group(&qdev->pdev->dev.kobj, &qpcie_sysfs_attr_group);
}
