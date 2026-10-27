/*
 * qpcie_hdmi_daemon.c - Card-side HDMI RX Telemetry & Control Daemon for SC7F0 / ZU4EV
 *
 * Runs on Zynq UltraScale+ (ARM Cortex-A53 Linux / PetaLinux).
 *
 * Roles & Responsibilities:
 * 1. Opens the official HDMI 2.0 RX subdevice via qpcie_v4l2_bridge.
 * 2. Subscribes to V4L2_EVENT_SOURCE_CHANGE events.
 * 3. Publishes real timings/format into BAR0 using the versioned telemetry ABI:
 *      - 0x0604..0x0664: payload (timings, colorimetry, media-bus code)
 *      - 0x0668: ABI_VERSION (read-only RTL constant)
 *      - 0x066C: TELEMETRY_SEQ (odd = update in progress, even = complete)
 *      - 0x0670: TELEMETRY_FLAGS (timing/color valid, interlaced, query error)
 *      - 0x0674: HEARTBEAT (advances at least once per second while alive)
 *      - 0x0678: MBUS_CODE (exact V4L2 media-bus format from the RX subdevice)
 *      - 0x067C: PIXELCLOCK_HI (paired with 0x060C)
 *    0x0600 is hardware-owned (cable/HPD); this daemon never writes it and
 *    never invents TMDS/video lock state that the driver did not report.
 * 4. Monitors Host IPC mailbox registers (0x0630 - 0x063C) and returns a real
 *    error (not a fabricated success) for commands that are not implemented.
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <poll.h>
#include <errno.h>
#include <signal.h>
#include <linux/videodev2.h>
#include <linux/v4l2-subdev.h>
#include <linux/media-bus-format.h>
#include <dirent.h>

#include "qpcie_control.h"
#include "qpcie_hdmi_audio.h"
#include "sc7f0_health.h"

#define DAEMON_NAME "qpcie_hdmi_daemon"
#define DEFAULT_PL_BASE_ADDR   0xA0000000UL /* BD-mapped HPM0 window (was wrong 0xB000) */
#define PL_MMAP_SIZE           0x10000UL

static volatile sig_atomic_t keep_running = 1;

struct rx_state {
    bool timing_valid;
    bool color_valid;
    bool interlaced;
    bool query_error;
    uint32_t audio_fmt;
    struct v4l2_dv_timings timings;
    struct v4l2_mbus_framefmt fmt;
};

static void sig_handler(int sig) {
    (void)sig;
    keep_running = false;
}

/* Locate the HDMI RX v4l-subdev node */
static int find_hdmi_rx_subdev(char *out_path, size_t max_len) {
    DIR *dir = opendir("/sys/class/video4linux");
    if (!dir) return -1;

    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (strncmp(entry->d_name, "v4l-subdev", 10) != 0) continue;

        char path[512], name[256];
        snprintf(path, sizeof(path), "/sys/class/video4linux/%s/name", entry->d_name);
        FILE *f = fopen(path, "r");
        if (!f) continue;
        if (fgets(name, sizeof(name), f)) {
            fclose(f);
            /* The RX SS may expose more than one v4l-subdev (video/audio).
             * MAILBOX queries only work on the video subdevice, so never pick
             * an audio node just because it matched first. */
            if (strstr(name, "audio"))
                continue;
            if (strstr(name, "hdmi") || strstr(name, "v_hdmi_rx_ss") || strstr(name, "rx")) {
                snprintf(out_path, max_len, "/dev/%s", entry->d_name);
                closedir(dir);
                return 0;
            }
        } else {
            fclose(f);
        }
    }
    closedir(dir);

    /* Default fallback */
    snprintf(out_path, max_len, "/dev/v4l-subdev0");
    return 0;
}

static inline void mmio_wmb(volatile uint32_t *reg)
{
    /* Read back the written register so the posted AXI write has reached the
     * PL before the next publication step becomes visible to the host. */
    (void)*reg;
    __sync_synchronize();
}

static void classify_mbus(uint32_t code, uint32_t *encoding, uint32_t *depth)
{
    *encoding = HDMI_COLOR_ENC_RGB;
    *depth = 8;

    switch (code) {
#ifdef MEDIA_BUS_FMT_RBG888_1X24
    case MEDIA_BUS_FMT_RBG888_1X24:      *encoding = HDMI_COLOR_ENC_RGB;     *depth = 8;  return;
#endif
#ifdef MEDIA_BUS_FMT_RBG101010_1X30
    case MEDIA_BUS_FMT_RBG101010_1X30:   *encoding = HDMI_COLOR_ENC_RGB;     *depth = 10; return;
#endif
#ifdef MEDIA_BUS_FMT_RBG121212_1X36
    case MEDIA_BUS_FMT_RBG121212_1X36:   *encoding = HDMI_COLOR_ENC_RGB;     *depth = 12; return;
#endif
#ifdef MEDIA_BUS_FMT_VUY8_1X24
    case MEDIA_BUS_FMT_VUY8_1X24:        *encoding = HDMI_COLOR_ENC_YUV444;  *depth = 8;  return;
#endif
#ifdef MEDIA_BUS_FMT_VUY10_1X30
    case MEDIA_BUS_FMT_VUY10_1X30:       *encoding = HDMI_COLOR_ENC_YUV444;  *depth = 10; return;
#endif
#ifdef MEDIA_BUS_FMT_UYVY8_1X16
    case MEDIA_BUS_FMT_UYVY8_1X16:       *encoding = HDMI_COLOR_ENC_YUV422;  *depth = 8;  return;
#endif
#ifdef MEDIA_BUS_FMT_UYVY10_1X20
    case MEDIA_BUS_FMT_UYVY10_1X20:      *encoding = HDMI_COLOR_ENC_YUV422;  *depth = 10; return;
#endif
#ifdef MEDIA_BUS_FMT_VYYUYY8_1X24
    case MEDIA_BUS_FMT_VYYUYY8_1X24:     *encoding = HDMI_COLOR_ENC_YUV420;  *depth = 8;  return;
#endif
#ifdef MEDIA_BUS_FMT_VYYUYY10_4X20
    case MEDIA_BUS_FMT_VYYUYY10_4X20:    *encoding = HDMI_COLOR_ENC_YUV420;  *depth = 10; return;
#endif
    default:
        /* Unknown code: publish the code itself but not a guessed encoding. */
        *encoding = 0;
        *depth = 0;
        return;
    }
}

static void clear_payload(volatile uint32_t *r)
{
    r[BAR0_REG_HDMI_RX_WIDTH / 4]       = 0;
    r[BAR0_REG_HDMI_RX_HEIGHT / 4]      = 0;
    r[BAR0_REG_HDMI_RX_PIXEL_CLK / 4]   = 0;
    r[BAR0_REG_HDMI_TLM_PIXELCLK_HI / 4] = 0;
    r[BAR0_REG_HDMI_RX_HFP / 4]         = 0;
    r[BAR0_REG_HDMI_RX_HSW / 4]         = 0;
    r[BAR0_REG_HDMI_RX_HBP / 4]         = 0;
    r[BAR0_REG_HDMI_RX_VFP / 4]         = 0;
    r[BAR0_REG_HDMI_RX_VSW / 4]         = 0;
    r[BAR0_REG_HDMI_RX_VBP / 4]         = 0;
    r[BAR0_REG_HDMI_RX_POLARITIES / 4]  = 0;
    r[BAR0_REG_HDMI_RX_STANDARDS / 4]   = 0;
    r[BAR0_REG_HDMI_RX_COLOR_FMT / 4]   = 0;
    r[BAR0_REG_HDMI_RX_AUDIO_FMT / 4]   = 0;
    r[BAR0_REG_HDMI_TLM_MBUS_CODE / 4]  = 0;
}

/*
 * Publish one coherent snapshot:
 *   even -> odd SEQ, payload, FLAGS/HEARTBEAT, odd -> even SEQ.
 * The host rejects any snapshot whose SEQ is odd or changed while reading.
 * start()/stop() brackets guarantee even SEQ even after an abnormal exit.
 */
static void publish_snapshot(volatile uint32_t *r, const struct rx_state *s,
                             uint32_t *heartbeat)
{
    static bool printed_valid;
    static uint32_t printed_w, printed_h;
    static uint64_t printed_pclk;
    static bool printed_interlaced;
    bool changed;
    uint32_t seq = r[BAR0_REG_HDMI_TLM_SEQ / 4];

    if (seq & 1U)
        seq++; /* recover from a publisher that died mid-update */
    __sync_synchronize();

    r[BAR0_REG_HDMI_TLM_SEQ / 4] = seq + 1; /* odd: update in progress */
    mmio_wmb(&r[BAR0_REG_HDMI_TLM_SEQ / 4]);

    clear_payload(r);

    if (s->timing_valid) {
        const struct v4l2_bt_timings *bt = &s->timings.bt;

        r[BAR0_REG_HDMI_RX_WIDTH / 4]        = bt->width;
        r[BAR0_REG_HDMI_RX_HEIGHT / 4]       = bt->height;
        r[BAR0_REG_HDMI_RX_PIXEL_CLK / 4]    = (uint32_t)bt->pixelclock;
        r[BAR0_REG_HDMI_TLM_PIXELCLK_HI / 4] = (uint32_t)(bt->pixelclock >> 32);
        r[BAR0_REG_HDMI_RX_HFP / 4]          = bt->hfrontporch;
        r[BAR0_REG_HDMI_RX_HSW / 4]          = bt->hsync;
        r[BAR0_REG_HDMI_RX_HBP / 4]          = bt->hbackporch;
        r[BAR0_REG_HDMI_RX_VFP / 4]          = bt->vfrontporch;
        r[BAR0_REG_HDMI_RX_VSW / 4]          = bt->vsync;
        r[BAR0_REG_HDMI_RX_VBP / 4]          = bt->vbackporch;
        r[BAR0_REG_HDMI_RX_POLARITIES / 4]   = bt->polarities;
        r[BAR0_REG_HDMI_RX_STANDARDS / 4]    = bt->standards;
    }

    if (s->color_valid) {
        uint32_t encoding, depth;

        classify_mbus(s->fmt.code, &encoding, &depth);
        r[BAR0_REG_HDMI_RX_COLOR_FMT / 4] =
            (s->fmt.colorspace & 0xffU) |
            ((s->fmt.quantization & 0xfU) << 8) |
            ((s->fmt.ycbcr_enc & 0xfU) << 12) |
            ((s->fmt.xfer_func & 0xfU) << 16) |
            ((depth & 0xfU) << 20) |
            ((encoding & 0xfU) << 24);
        r[BAR0_REG_HDMI_TLM_MBUS_CODE / 4] = s->fmt.code;
    }

    r[BAR0_REG_HDMI_RX_AUDIO_FMT / 4] = s->audio_fmt;

    r[BAR0_REG_HDMI_TLM_FLAGS / 4] =
        (s->timing_valid ? HDMI_TLM_F_TIMING_VALID : 0) |
        (s->color_valid ? HDMI_TLM_F_COLOR_VALID : 0) |
        (s->interlaced ? HDMI_TLM_F_INTERLACED : 0) |
        (s->query_error ? HDMI_TLM_F_QUERY_ERROR : 0);

    r[BAR0_REG_HDMI_TLM_HEARTBEAT / 4] = ++(*heartbeat);
    mmio_wmb(&r[BAR0_REG_HDMI_TLM_HEARTBEAT / 4]);

    r[BAR0_REG_HDMI_TLM_SEQ / 4] = seq + 2; /* even: snapshot complete */
    mmio_wmb(&r[BAR0_REG_HDMI_TLM_SEQ / 4]);

    if (s->timing_valid) {
        const struct v4l2_bt_timings *bt = &s->timings.bt;

        changed = !printed_valid || printed_w != bt->width ||
                  printed_h != bt->height || printed_pclk != bt->pixelclock ||
                  printed_interlaced != !!bt->interlaced;
        if (changed) {
            /* Change-only logging: a once-per-second line on the serial
             * console and journal would be pure noise and eMMC wear. */
            printf("[%s] HDMI RX: %ux%u%s @ %.2f MHz\n", DAEMON_NAME,
                   bt->width, bt->height, s->interlaced ? "i" : "p",
                   (double)bt->pixelclock / 1000000.0);
            if (s->color_valid)
                printf("[%s]   color: colorspace=%u quant=%u ycbcr=%u xfer=%u mbus=0x%04x\n",
                       DAEMON_NAME, s->fmt.colorspace, s->fmt.quantization,
                       s->fmt.ycbcr_enc, s->fmt.xfer_func, s->fmt.code);
            fflush(stdout);
            printed_valid = true;
            printed_w = bt->width;
            printed_h = bt->height;
            printed_pclk = bt->pixelclock;
            printed_interlaced = !!bt->interlaced;
        }
    } else if (printed_valid) {
        printf("[%s] HDMI RX: no locked timing\n", DAEMON_NAME);
        fflush(stdout);
        printed_valid = false;
    }
}

static int read_rx_state(int subdev_fd, struct rx_state *s)
{
    memset(s, 0, sizeof(*s));

    if (subdev_fd < 0)
        return -ENODEV;

    if (ioctl(subdev_fd, VIDIOC_SUBDEV_QUERY_DV_TIMINGS, &s->timings) < 0) {
        int err = errno;

        /* ENOLINK/ENODATA are normal "no signal" results, not daemon errors. */
        s->query_error = (err != ENOLINK && err != ENODATA && err != ENODEV);
        return -err;
    }

    s->timing_valid = true;
    s->interlaced = !!s->timings.bt.interlaced;

    struct v4l2_subdev_format fmt;
    memset(&fmt, 0, sizeof(fmt));
    fmt.which = V4L2_SUBDEV_FORMAT_ACTIVE;
    fmt.pad = 0;
    if (ioctl(subdev_fd, VIDIOC_SUBDEV_G_FMT, &fmt) == 0 && fmt.format.code) {
        s->fmt = fmt.format;
        s->color_valid = true;
    }
    /* The official PS RX driver owns these measurements. No fabricated audio
     * codec/formatter is registered on PS: samples go directly PL -> host. */
    uint32_t encoding, depth;
    classify_mbus(s->fmt.code, &encoding, &depth);
    if (s->color_valid && depth == 8 &&
        (encoding == HDMI_COLOR_ENC_RGB || encoding == HDMI_COLOR_ENC_YUV444)) {
        FILE *f = fopen("/sys/bus/platform/devices/b0010000.hdmi-rx/hdmi_info","r");
        if (f) {
            char info[8192];
            size_t n = fread(info,1,sizeof(info)-1,f);
            info[n] = 0;
            fclose(f);
            s->audio_fmt = qpcie_parse_hdmi_audio(info,s->timings.bt.pixelclock);
        }
    }
    return 0;
}

int main(int argc, char *argv[]) {
    (void)argc;
    (void)argv;
    signal(SIGINT, sig_handler);
    signal(SIGTERM, sig_handler);

    printf("[%s] Starting Card-Side HDMI RX Telemetry Daemon...\n", DAEMON_NAME);

    sc7f0_health_init("hdmi");
    /* 1. Map PL Registers via /dev/mem */
    int mem_fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (mem_fd < 0) {
        perror("Failed to open /dev/mem (run as root)");
        return 1;
    }

    volatile uint32_t *pl_regs = (volatile uint32_t *)mmap(
        NULL, PL_MMAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED,
        mem_fd, DEFAULT_PL_BASE_ADDR
    );

    if (pl_regs == MAP_FAILED) {
        perror("Failed to mmap PL registers at 0xA0000000");
        close(mem_fd);
        return 1;
    }

    uint32_t abi = pl_regs[BAR0_REG_HDMI_TLM_ABI_VERSION / 4];
    if (abi != HDMI_TLM_ABI_EXPECTED) {
        fprintf(stderr,
                "[%s] ERROR: telemetry ABI 0x%08x, expected 0x%08x. "
                "This daemon/build does not match the FPGA image.\n",
                DAEMON_NAME, abi, HDMI_TLM_ABI_EXPECTED);
        munmap((void *)pl_regs, PL_MMAP_SIZE);
        close(mem_fd);
        return 2;
    }

    /* 2. Find and open HDMI RX Subdev Node */
    char subdev_path[512] = {0};
    find_hdmi_rx_subdev(subdev_path, sizeof(subdev_path));
    printf("[%s] Using V4L2 Subdevice: %s\n", DAEMON_NAME, subdev_path);

    int subdev_fd = open(subdev_path, O_RDWR);
    if (subdev_fd < 0) {
        fprintf(stderr, "[%s] Warning: Could not open %s (%s). Will retry in loop.\n",
                DAEMON_NAME, subdev_path, strerror(errno));
    }

    /* 3. Subscribe to V4L2 Source Change Event */
    if (subdev_fd >= 0) {
        struct v4l2_event_subscription sub;
        memset(&sub, 0, sizeof(sub));
        sub.type = V4L2_EVENT_SOURCE_CHANGE;
        if (ioctl(subdev_fd, VIDIOC_SUBSCRIBE_EVENT, &sub) < 0) {
            fprintf(stderr, "[%s] VIDIOC_SUBSCRIBE_EVENT warning: %s\n",
                    DAEMON_NAME, strerror(errno));
        }
    }

    struct rx_state state;
    uint32_t heartbeat = 0;
    bool was_valid = false;

    /* Publish "no timing" first: a restarted daemon must not leave stale values
     * from a previous run visible as valid to the host. */
    read_rx_state(subdev_fd, &state);
    publish_snapshot(pl_regs, &state, &heartbeat);
    was_valid = state.timing_valid;

    /* 4. Event & Polling Loop */
    sc7f0_health_ready();
    while (keep_running) {
        sc7f0_health_progress();
        if (subdev_fd < 0) {
            sleep(1);
            /* Nodes may appear after the bridge/media probe, and the numbering
             * is not guaranteed; re-scan instead of reopening a stale path. */
            find_hdmi_rx_subdev(subdev_path, sizeof(subdev_path));
            subdev_fd = open(subdev_path, O_RDWR);
            if (subdev_fd >= 0) {
                struct v4l2_event_subscription sub;
                memset(&sub, 0, sizeof(sub));
                sub.type = V4L2_EVENT_SOURCE_CHANGE;
                ioctl(subdev_fd, VIDIOC_SUBSCRIBE_EVENT, &sub);
            } else {
                /* Keep the heartbeat alive so the host can distinguish
                 * "publisher alive but no RX node" from "publisher dead". */
                memset(&state, 0, sizeof(state));
                state.query_error = true;
                publish_snapshot(pl_regs, &state, &heartbeat);
                continue;
            }
        }

        struct pollfd pfd;
        pfd.fd = subdev_fd;
        pfd.events = POLLPRI;

        int poll_ret = poll(&pfd, 1, 1000); // 1-second timeout
        if (poll_ret > 0 && (pfd.revents & (POLLERR | POLLHUP | POLLNVAL))) {
            close(subdev_fd);
            subdev_fd = -1;
            continue;
        }
        if (poll_ret > 0 && (pfd.revents & POLLPRI)) {
            struct v4l2_event ev;
            memset(&ev, 0, sizeof(ev));
            if (ioctl(subdev_fd, VIDIOC_DQEVENT, &ev) == 0 &&
                ev.type == V4L2_EVENT_SOURCE_CHANGE) {
                printf("[%s] V4L2_EVENT_SOURCE_CHANGE detected!\n", DAEMON_NAME);
            }
        } else if (poll_ret < 0 && errno != EINTR) {
            fprintf(stderr, "[%s] poll failed: %s\n", DAEMON_NAME, strerror(errno));
            close(subdev_fd);
            subdev_fd = -1;
            continue;
        }

        /* Re-read on events and periodically as a fallback for drivers that do
         * not emit SOURCE_CHANGE. Real state always comes from the subdevice. */
        struct rx_state fresh;
        bool new_valid;
        int ret = read_rx_state(subdev_fd, &fresh);

        if (ret < 0 && ret != -ENOLINK && ret != -ENODATA && ret != -ENODEV)
            fprintf(stderr, "[%s] timing query failed: %s\n",
                    DAEMON_NAME, strerror(-ret));

        if (ret == -ENODEV) {
            /* The subdevice disappeared (driver unbind / media teardown).
             * Drop the fd so the next iteration re-scans the node list. */
            close(subdev_fd);
            subdev_fd = -1;
        }

        new_valid = (ret == 0);
        if (new_valid != was_valid)
            printf("[%s] HDMI RX %s\n", DAEMON_NAME,
                   new_valid ? "signal locked" : "signal lost / no timings");
        state = fresh;
        was_valid = new_valid;
        /* Publish every loop: payload changes and the liveness heartbeat are
         * both carried inside the same even-SEQ transaction. */
        publish_snapshot(pl_regs, &state, &heartbeat);

        /* Check Host Mailbox IPC (0x0630 - 0x063C) */
        uint32_t doorbell = pl_regs[BAR0_REG_HDMI_IPC_DOORBELL / 4];
        if (doorbell == 1) {
            uint32_t cmd = pl_regs[BAR0_REG_HDMI_IPC_CMD / 4];
            printf("[%s] Received Host IPC Command: 0x%08X\n", DAEMON_NAME, cmd);
            /* No commands implemented yet: never acknowledge a no-op as success.
             * Status is a signed Linux errno encoded in a 32-bit register. */
            pl_regs[BAR0_REG_HDMI_IPC_STATUS / 4] = (uint32_t)-EOPNOTSUPP;
            pl_regs[BAR0_REG_HDMI_IPC_DOORBELL / 4] = 0; // Clear doorbell
        }
    }

    printf("[%s] Exiting daemon...\n", DAEMON_NAME);

    /* Clear the payload and publish FLAGS=0 through a complete even-SEQ
     * transaction, including the abnormal-exit recovery path in
     * publish_snapshot(). */
    memset(&state, 0, sizeof(state));
    publish_snapshot(pl_regs, &state, &heartbeat);

    if (subdev_fd >= 0) close(subdev_fd);
    munmap((void *)pl_regs, PL_MMAP_SIZE);
    close(mem_fd);
    return 0;
}
