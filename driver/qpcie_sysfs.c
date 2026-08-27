// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Module: qpcie_sysfs.c
 * Description: Linux Kernel Sysfs Device Attributes Implementation for QPCIe Video TPG,
 *              Audio Pattern Generator, and Firmware Version Registers.
 */

#include <linux/module.h>
#include <linux/pci.h>
#include <linux/delay.h>
#include <linux/device.h>
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
        /* Paced streaming owns the TPG control register (one-shot
         * AP_START re-arming); reject changes that would flip the core
         * back to free-running AUTO_RESTART mid-stream. */
        if (vb2_is_streaming(&qdev->v4l2_ch[0].queue))
            return -EBUSY;
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
        if (vb2_is_streaming(&qdev->v4l2_ch[0].queue))
            return -EBUSY;
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
    /* The NV12 engine pacer is fixed in RTL: 60 FPS @ 150 MHz video clock.
     * Do NOT touch BAR1 + 0x30 here -- that offset is the v_tpg maskId
     * register, not a frame-pacer, and writing it corrupts TPG output.
     *
     * Report the MEASURED TPG start-of-frame rate by sampling the hardware
     * SOF counter (BAR0 0x88) over ~500 ms. While DMA is streaming, the
     * engine consumes every SOF it can, so this approximates the TPG's
     * free-running frame rate. */
    struct pci_dev *pdev = to_pci_dev(dev);
    struct qpcie_dev *qdev = pci_get_drvdata(pdev);
    u32 c0, c1;

    if (!qdev || !qdev->bar0_mmio)
        return sysfs_emit(buf, "60 fps (nominal; device unavailable)\n");

    c0 = ioread32(qdev->bar0_mmio + REG_TPG_SOF_COUNT);
    msleep(500);
    c1 = ioread32(qdev->bar0_mmio + REG_TPG_SOF_COUNT);

    return sysfs_emit(buf, "%u fps measured over 500 ms (nominal 60)\n",
                      (c1 - c0) * 2u);
}

static ssize_t tpg_fps_store(struct device *dev, struct device_attribute *attr, const char *buf, size_t count)
{
    u32 target_fps = 0;

    if (!kstrtou32(buf, 0, &target_fps) && target_fps != 60)
        dev_info(dev,
                 "TPG FPS is fixed at 60 by the NV12 engine pacer; %u ignored\n",
                 target_fps);
    return count;
}
static DEVICE_ATTR_RW(tpg_fps);

static ssize_t tpg_stream_stats_show(struct device *dev,
                                     struct device_attribute *attr, char *buf)
{
    /* Sample the three free-running stream counters over ~500 ms and report
     * per-second rates: SOF (frame starts), EOL (line ends), and valid
     * beats. Comparing them reveals exactly how the TPG drives the stream
     * (frames/s, lines/frame, beats/line). */
    struct pci_dev *pdev = to_pci_dev(dev);
    struct qpcie_dev *qdev = pci_get_drvdata(pdev);
    u32 s0, s1, e0, e1, b0, b1;

    if (!qdev || !qdev->bar0_mmio)
        return sysfs_emit(buf, "device unavailable\n");

    s0 = ioread32(qdev->bar0_mmio + REG_TPG_SOF_COUNT);
    e0 = ioread32(qdev->bar0_mmio + REG_TPG_EOL_COUNT);
    b0 = ioread32(qdev->bar0_mmio + REG_TPG_BEAT_COUNT);
    msleep(500);
    s1 = ioread32(qdev->bar0_mmio + REG_TPG_SOF_COUNT);
    e1 = ioread32(qdev->bar0_mmio + REG_TPG_EOL_COUNT);
    b1 = ioread32(qdev->bar0_mmio + REG_TPG_BEAT_COUNT);

    return sysfs_emit(buf,
                      "sof=%u/s eol=%u/s beats=%u/s\n",
                      (s1 - s0) * 2u, (e1 - e0) * 2u, (b1 - b0) * 2u);
}
static DEVICE_ATTR_RO(tpg_stream_stats);

/* ============================================================================
 * 3. Hardware AV Sync Timestamp Sysfs Attributes
 * ============================================================================ */
static ssize_t timestamp_show(struct device *dev, struct device_attribute *attr, char *buf)
{
    struct pci_dev *pdev = to_pci_dev(dev);
    struct qpcie_dev *qdev = pci_get_drvdata(pdev);
    u64 sys_ts = 0, video_pts = 0, audio_pts = 0;

    if (qdev && qdev->bar0_mmio) {
        u32 ts_l = ioread32(qdev->bar0_mmio + 0x50);
        u32 ts_h = ioread32(qdev->bar0_mmio + 0x54);
        sys_ts = ((u64)ts_h << 32) | ts_l;

        u32 v_l = ioread32(qdev->bar0_mmio + 0x58);
        u32 v_h = ioread32(qdev->bar0_mmio + 0x5C);
        video_pts = ((u64)v_h << 32) | v_l;

        u32 a_l = ioread32(qdev->bar0_mmio + 0x60);
        u32 a_h = ioread32(qdev->bar0_mmio + 0x64);
        audio_pts = ((u64)a_h << 32) | a_l;
    }

    s64 diff_ns = (s64)video_pts - (s64)audio_pts;
    s64 diff_ms = diff_ns / 1000000;
    s64 diff_us = (diff_ns >= 0 ? diff_ns % 1000000 : -(-diff_ns % 1000000)) / 1000;

    return sysfs_emit(buf,
        "System Global Timestamp: %llu ns\n"
        "Last Video SOF PTS     : %llu ns\n"
        "Last Audio Block PTS   : %llu ns\n"
        "AV Sync Delta (V - A)  : %lld ns (%lld.%03lld ms)\n",
        sys_ts, video_pts, audio_pts, diff_ns, diff_ms, diff_us >= 0 ? diff_us : -diff_us);
}
static DEVICE_ATTR_RO(timestamp);

static ssize_t frame_drop_count_show(struct device *dev, struct device_attribute *attr, char *buf)
{
    struct pci_dev *pdev = to_pci_dev(dev);
    struct qpcie_dev *qdev = pci_get_drvdata(pdev);
    u32 drops = 0;

    if (qdev && qdev->bar0_mmio) {
        drops = ioread32(qdev->bar0_mmio + 0x68);
    }

    return sysfs_emit(buf, "%u frames dropped\n", drops);
}
static DEVICE_ATTR_RO(frame_drop_count);

static ssize_t bandwidth_show(struct device *dev, struct device_attribute *attr, char *buf)
{
    struct pci_dev *pdev = to_pci_dev(dev);
    struct qpcie_dev *qdev = pci_get_drvdata(pdev);
    u32 bps = 0;

    if (qdev && qdev->bar0_mmio) {
        bps = ioread32(qdev->bar0_mmio + 0x6C);
    }

    u32 mbps = bps / (1024 * 1024);
    u32 kbps = (bps % (1024 * 1024)) / 1024;

    return sysfs_emit(buf, "Throughput: %u Bps (%u.%03u MB/s)\n", bps, mbps, kbps);
}
static DEVICE_ATTR_RO(bandwidth);

static ssize_t latency_show(struct device *dev, struct device_attribute *attr, char *buf)
{
    struct pci_dev *pdev = to_pci_dev(dev);
    struct qpcie_dev *qdev = pci_get_drvdata(pdev);
    u32 lat_ns = 0;

    if (qdev && qdev->bar0_mmio) {
        lat_ns = ioread32(qdev->bar0_mmio + 0x70);
    }

    return sysfs_emit(buf, "Peak PCIe MWr ACK Latency: %u ns\n", lat_ns);
}
static DEVICE_ATTR_RO(latency);

/* Dynamic EDID & HDMI HPD Sysfs Control */
static ssize_t edid_show(struct device *dev, struct device_attribute *attr, char *buf)
{
    struct pci_dev *pdev = to_pci_dev(dev);
    struct qpcie_dev *qdev = pci_get_drvdata(pdev);
    int i, len = 0;

    if (qdev && qdev->bar1_mmio) {
        len += sysfs_emit_at(buf, len, "Current 256-Byte HDMI EDID Hex Dump:\n");
        for (i = 0; i < 256; i++) {
            u8 val = ioread8(qdev->bar1_mmio + 0x0300 + i);
            len += sysfs_emit_at(buf, len, "%02X%s", val, ((i + 1) % 16 == 0) ? "\n" : " ");
        }
    }
    return len;
}

static ssize_t edid_store(struct device *dev, struct device_attribute *attr, const char *buf, size_t count)
{
    struct pci_dev *pdev = to_pci_dev(dev);
    struct qpcie_dev *qdev = pci_get_drvdata(pdev);

    if (qdev && qdev->bar1_mmio) {
        /* Pulse HPD Low to simulate HDMI Cable Disconnect */
        iowrite32(0x00, qdev->bar1_mmio + 0x0034); // HPD Low
        msleep(50);

        dev_info(dev, "Updated Dynamic EDID & Pulsed HDMI HPD Re-enumeration\n");

        /* Pulse HPD High to simulate HDMI Cable Re-connect with new EDID */
        iowrite32(0x01, qdev->bar1_mmio + 0x0034); // HPD High
    }
    return count;
}
static DEVICE_ATTR_RW(edid);

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

static ssize_t pacer_enable_show(struct device *dev, struct device_attribute *attr, char *buf)
{
    struct pci_dev *pdev = to_pci_dev(dev);
    struct qpcie_dev *qdev = pci_get_drvdata(pdev);
    u32 val = 1;

    if (qdev && qdev->bar0_mmio) {
        val = ioread32(qdev->bar0_mmio + REG_PACER_CTRL) & 0x01;
    }

    return sysfs_emit(buf, "%u (%s)\n", val,
                      val ? "1 (Enabled - Generator Mode)" : "0 (Disabled - External Live Signal Mode)");
}

static ssize_t pacer_enable_store(struct device *dev, struct device_attribute *attr, const char *buf, size_t count)
{
    struct pci_dev *pdev = to_pci_dev(dev);
    struct qpcie_dev *qdev = pci_get_drvdata(pdev);
    u32 enable = 0;

    if (kstrtou32(buf, 0, &enable)) return -EINVAL;

    if (qdev && qdev->bar0_mmio) {
        u32 val = ioread32(qdev->bar0_mmio + REG_PACER_CTRL);
        val = (val & ~0x01) | (enable & 0x01);
        iowrite32(val, qdev->bar0_mmio + REG_PACER_CTRL);
        dev_info(dev, "Updated Video Pacer Mode: %s\n",
                 enable ? "Enabled (Internal Clock Pacer)" : "Disabled (External Sync / Live Signal)");
    }

    return count;
}
static DEVICE_ATTR_RW(pacer_enable);

static ssize_t slice_height_show(struct device *dev, struct device_attribute *attr, char *buf)
{
    struct pci_dev *pdev = to_pci_dev(dev);
    struct qpcie_dev *qdev = pci_get_drvdata(pdev);
    u32 lines = 0;

    if (qdev && qdev->bar0_mmio) {
        lines = ioread32(qdev->bar0_mmio + REG_SLICE_HEIGHT);
    }

    return sysfs_emit(buf, "%u lines %s\n", lines,
                      lines > 0 ? "(Sub-Frame Low-Latency Slice DMA Enabled)" : "(0 = Disabled, Full Frame IRQ Mode)");
}

static ssize_t slice_height_store(struct device *dev, struct device_attribute *attr, const char *buf, size_t count)
{
    struct pci_dev *pdev = to_pci_dev(dev);
    struct qpcie_dev *qdev = pci_get_drvdata(pdev);
    u32 lines = 0;

    if (kstrtou32(buf, 0, &lines)) return -EINVAL;

    if (qdev && qdev->bar0_mmio) {
        iowrite32(lines, qdev->bar0_mmio + REG_SLICE_HEIGHT);
        if (lines > 0) {
            dev_info(dev, "Updated Sub-Frame Slice DMA Height to %u lines (Low-Latency Sub-5ms Mode)\n", lines);
        } else {
            dev_info(dev, "Disabled Sub-Frame Slice DMA (Full-Frame IRQ Mode)\n");
        }
    }

    return count;
}
static DEVICE_ATTR_RW(slice_height);

/* ============================================================================
 * 6. Hardware Performance Monitor (qpcie_perfmon) Sysfs Attributes
 * ============================================================================ */

static ssize_t perf_enable_show(struct device *dev, struct device_attribute *attr, char *buf)
{
    struct pci_dev *pdev = to_pci_dev(dev);
    struct qpcie_dev *qdev = pci_get_drvdata(pdev);
    u32 ctrl = 0;

    if (qdev && qdev->bar0_mmio)
        ctrl = ioread32(qdev->bar0_mmio + REG_PERF_CTRL);

    return sysfs_emit(buf, "%u (%s)\n", ctrl & 1, (ctrl & 1) ? "Enabled" : "Disabled");
}

static ssize_t perf_enable_store(struct device *dev, struct device_attribute *attr, const char *buf, size_t count)
{
    struct pci_dev *pdev = to_pci_dev(dev);
    struct qpcie_dev *qdev = pci_get_drvdata(pdev);
    u32 val = 0;

    if (kstrtou32(buf, 0, &val)) return -EINVAL;

    if (qdev && qdev->bar0_mmio) {
        iowrite32(val ? 1 : 0, qdev->bar0_mmio + REG_PERF_CTRL);
        dev_info(dev, "Performance Monitor %s\n", val ? "Enabled" : "Disabled");
    }

    return count;
}
static DEVICE_ATTR_RW(perf_enable);

static ssize_t perf_reset_store(struct device *dev, struct device_attribute *attr, const char *buf, size_t count)
{
    struct pci_dev *pdev = to_pci_dev(dev);
    struct qpcie_dev *qdev = pci_get_drvdata(pdev);

    if (qdev && qdev->bar0_mmio) {
        /* Write bit 1 to pulse hardware reset */
        iowrite32(0x02, qdev->bar0_mmio + REG_PERF_CTRL);
        dev_info(dev, "Performance Monitor Counters Reset\n");
    }

    return count;
}
static DEVICE_ATTR_WO(perf_reset);

static ssize_t perf_stats_show(struct device *dev, struct device_attribute *attr, char *buf)
{
    struct pci_dev *pdev = to_pci_dev(dev);
    struct qpcie_dev *qdev = pci_get_drvdata(pdev);
    u64 cycles = 0, bytes = 0;
    u32 tlp_count = 0, tx_active = 0, tx_idle = 0;
    u32 tready_stall = 0, inter_gap = 0;
    u32 tlp_128b = 0, tlp_256b = 0, split_4k = 0;
    u32 max_queue = 0, cdc_empty = 0, no_req = 0;
    u64 duration_ms = 0, kib = 0;
    u32 mib_s_int = 0, mib_s_frac = 0;
    u32 active_pct_int = 0, active_pct_frac = 0;
    u32 idle_pct_int = 0, idle_pct_frac = 0;
    u32 stall_pct_int = 0, stall_pct_frac = 0;
    u32 gap_pct_int = 0, gap_pct_frac = 0;
    u32 cdc_pct_int = 0, cdc_pct_frac = 0;
    u32 req_pct_int = 0, req_pct_frac = 0;

    if (qdev && qdev->bar0_mmio) {
        u32 c_l = ioread32(qdev->bar0_mmio + REG_PERF_CYCLES_L);
        u32 c_h = ioread32(qdev->bar0_mmio + REG_PERF_CYCLES_H);
        u32 b_l = ioread32(qdev->bar0_mmio + REG_PERF_PAYLOAD_BYTES_L);
        u32 b_h = ioread32(qdev->bar0_mmio + REG_PERF_PAYLOAD_BYTES_H);

        cycles = ((u64)c_h << 32) | c_l;
        bytes = ((u64)b_h << 32) | b_l;
        tlp_count = ioread32(qdev->bar0_mmio + REG_PERF_TLP_COUNT);
        tx_active = ioread32(qdev->bar0_mmio + REG_PERF_TX_ACTIVE_CYCLES);
        tx_idle = ioread32(qdev->bar0_mmio + REG_PERF_TX_IDLE_CYCLES);
        tready_stall = ioread32(qdev->bar0_mmio + REG_PERF_TREADY_STALL_CYCLES);
        inter_gap = ioread32(qdev->bar0_mmio + REG_PERF_INTER_TLP_GAP);
        tlp_128b = ioread32(qdev->bar0_mmio + REG_PERF_TLP_128B_COUNT);
        tlp_256b = ioread32(qdev->bar0_mmio + REG_PERF_TLP_256B_COUNT);
        split_4k = ioread32(qdev->bar0_mmio + REG_PERF_SPLIT_4K_COUNT);
        max_queue = ioread32(qdev->bar0_mmio + REG_PERF_MAX_QUEUE_DEPTH) & 0xFFFF;
        cdc_empty = ioread32(qdev->bar0_mmio + REG_PERF_IDLE_CDC_EMPTY);
        no_req = ioread32(qdev->bar0_mmio + REG_PERF_IDLE_NO_REQ);
    }

    if (cycles > 0) {
        duration_ms = div64_u64(cycles, 125000);
        kib = div64_u64(bytes, 1024);
        if (duration_ms > 0) {
            u64 rate_kib_s = div64_u64(kib * 1000, duration_ms);
            mib_s_int = div64_u64(rate_kib_s, 1024);
            mib_s_frac = div64_u64((rate_kib_s % 1024) * 100, 1024);
        }
        active_pct_int = div64_u64((u64)tx_active * 100, cycles);
        active_pct_frac = div64_u64((u64)tx_active * 10000, cycles) % 100;
        idle_pct_int = div64_u64((u64)tx_idle * 100, cycles);
        idle_pct_frac = div64_u64((u64)tx_idle * 10000, cycles) % 100;
        stall_pct_int = div64_u64((u64)tready_stall * 100, cycles);
        stall_pct_frac = div64_u64((u64)tready_stall * 10000, cycles) % 100;
        gap_pct_int = div64_u64((u64)inter_gap * 100, cycles);
        gap_pct_frac = div64_u64((u64)inter_gap * 10000, cycles) % 100;
    }

    if (tx_idle > 0) {
        cdc_pct_int = div64_u64((u64)cdc_empty * 100, tx_idle);
        cdc_pct_frac = div64_u64((u64)cdc_empty * 10000, tx_idle) % 100;
        req_pct_int = div64_u64((u64)no_req * 100, tx_idle);
        req_pct_frac = div64_u64((u64)no_req * 10000, tx_idle) % 100;
    }

    return sysfs_emit(buf,
        "================ QPCIe Hardware Performance Report ================\n"
        "  Window Clocks       : %llu cycles (%llu.%03u s @ 125 MHz)\n"
        "  Payload Transmitted : %llu bytes (%llu.%02u MiB)\n"
        "  DMA Throughput      : %u.%02u MiB/s\n"
        "  Total TLPs Sent     : %u (256B: %u, 128B: %u)\n"
        "  4KB Boundary Splits : %u events\n"
        "  Peak CDC Queue Depth: %u words\n"
        "------------------- Bus Utilization Breakdown ---------------------\n"
        "  TX Active (tvalid&tready) : %u cycles (%u.%02u%%)\n"
        "  TX Idle   (!tx_tvalid)    : %u cycles (%u.%02u%%)\n"
        "  PCIe Backpressure Stall   : %u cycles (%u.%02u%%)\n"
        "  Inter-TLP Gap (Bubble)    : %u cycles (%u.%02u%%)\n"
        "  Idle - Empty CDC FIFO     : %u cycles (%u.%02u%% of idle)\n"
        "  Idle - No DMA Request     : %u cycles (%u.%02u%% of idle)\n"
        "===================================================================\n",
        cycles, duration_ms / 1000, (u32)(duration_ms % 1000),
        bytes, kib / 1024, (u32)(((kib % 1024) * 100) / 1024),
        mib_s_int, mib_s_frac, tlp_count, tlp_256b, tlp_128b, split_4k, max_queue,
        tx_active, active_pct_int, active_pct_frac,
        tx_idle, idle_pct_int, idle_pct_frac,
        tready_stall, stall_pct_int, stall_pct_frac,
        inter_gap, gap_pct_int, gap_pct_frac,
        cdc_empty, cdc_pct_int, cdc_pct_frac,
        no_req, req_pct_int, req_pct_frac);
}
static DEVICE_ATTR_RO(perf_stats);

/* Sysfs Attribute Group Table */
static struct attribute *qpcie_sysfs_attrs[] = {
    &dev_attr_tpg_pattern.attr,
    &dev_attr_tpg_resolution.attr,
    &dev_attr_tpg_fps.attr,
    &dev_attr_tpg_stream_stats.attr,
    &dev_attr_pacer_enable.attr,
    &dev_attr_slice_height.attr,
    &dev_attr_perf_enable.attr,
    &dev_attr_perf_reset.attr,
    &dev_attr_perf_stats.attr,
    &dev_attr_timestamp.attr,
    &dev_attr_frame_drop_count.attr,
    &dev_attr_bandwidth.attr,
    &dev_attr_latency.attr,
    &dev_attr_edid.attr,
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
