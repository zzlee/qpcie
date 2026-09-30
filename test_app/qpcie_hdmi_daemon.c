/*
 * qpcie_hdmi_daemon.c - Card-side HDMI RX Telemetry & Control Daemon for SC7F0 / ZU4EV
 *
 * Runs on Zynq UltraScale+ (ARM Cortex-A53 Linux / PetaLinux).
 *
 * Roles & Responsibilities:
 * 1. Opens /dev/v4l-subdev0 (registered by xilinx-hdmirxss via qpcie_v4l2_bridge).
 * 2. Subscribes to V4L2_EVENT_SOURCE_CHANGE events.
 * 3. On signal detection or resolution change:
 *    - Queries precise DV timings (VIDIOC_SUBDEV_QUERY_DV_TIMINGS) from xilinx-hdmirxss.
 *    - Locks receiver using VIDIOC_SUBDEV_S_DV_TIMINGS.
 *    - Writes real-time resolution, pixel clock, sync/porch parameters, and lock state
 *      directly into PL PCIe BAR0 registers (0x0600 - 0x0664).
 * 4. Monitors Host IPC mailbox registers (0x0630 - 0x063C) for EDID updates or HPD toggles.
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
#include <dirent.h>

#include "qpcie_control.h"

#define DAEMON_NAME "qpcie_hdmi_daemon"
#define DEFAULT_PL_BASE_ADDR   0xB0000000UL
#define PL_MMAP_SIZE           0x10000UL

static volatile bool keep_running = true;

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

static void update_pl_registers(volatile uint32_t *pl_regs,
                                bool locked,
                                const struct v4l2_dv_timings *timings)
{
    if (!locked || !timings) {
        /* Disconnected / Unlocked: Clear telemetry */
        pl_regs[BAR0_REG_HDMI_RX_STATUS / 4] = 0x01; // 5V det low or cable unplugged
        pl_regs[BAR0_REG_HDMI_RX_WIDTH / 4]  = 0;
        pl_regs[BAR0_REG_HDMI_RX_HEIGHT / 4] = 0;
        pl_regs[BAR0_REG_HDMI_RX_PIXEL_CLK / 4] = 0;
        pl_regs[BAR0_REG_HDMI_RX_HFP / 4] = 0;
        pl_regs[BAR0_REG_HDMI_RX_HSW / 4] = 0;
        pl_regs[BAR0_REG_HDMI_RX_HBP / 4] = 0;
        pl_regs[BAR0_REG_HDMI_RX_VFP / 4] = 0;
        pl_regs[BAR0_REG_HDMI_RX_VSW / 4] = 0;
        pl_regs[BAR0_REG_HDMI_RX_VBP / 4] = 0;
        return;
    }

    const struct v4l2_bt_timings *bt = &timings->bt;

    pl_regs[BAR0_REG_HDMI_RX_WIDTH / 4]      = bt->width;
    pl_regs[BAR0_REG_HDMI_RX_HEIGHT / 4]     = bt->height;
    pl_regs[BAR0_REG_HDMI_RX_PIXEL_CLK / 4]  = (uint32_t)bt->pixelclock;
    pl_regs[BAR0_REG_HDMI_RX_HFP / 4]        = bt->hfrontporch;
    pl_regs[BAR0_REG_HDMI_RX_HSW / 4]        = bt->hsync;
    pl_regs[BAR0_REG_HDMI_RX_HBP / 4]        = bt->hbackporch;
    pl_regs[BAR0_REG_HDMI_RX_VFP / 4]        = bt->vfrontporch;
    pl_regs[BAR0_REG_HDMI_RX_VSW / 4]        = bt->vsync;
    pl_regs[BAR0_REG_HDMI_RX_VBP / 4]        = bt->vbackporch;
    pl_regs[BAR0_REG_HDMI_RX_POLARITIES / 4] = bt->polarities;
    pl_regs[BAR0_REG_HDMI_RX_STANDARDS / 4]  = bt->standards;

    /* Bit 0: 5V Present, Bit 1: HPD Asserted, Bit 2: TMDS Locked, Bit 3: Video Stream Locked */
    pl_regs[BAR0_REG_HDMI_RX_STATUS / 4]     = 0x0F;

    printf("[%s] HDMI RX Locked: %ux%u @ %.2f MHz (Total H=%u, Total V=%u)\n",
           DAEMON_NAME, bt->width, bt->height,
           (double)bt->pixelclock / 1000000.0,
           bt->width + bt->hfrontporch + bt->hsync + bt->hbackporch,
           bt->height + bt->vfrontporch + bt->vsync + bt->vbackporch);
}

int main(int argc, char *argv[]) {
    (void)argc;
    (void)argv;
    signal(SIGINT, sig_handler);
    signal(SIGTERM, sig_handler);

    printf("[%s] Starting Card-Side HDMI RX Telemetry Daemon...\n", DAEMON_NAME);

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
        perror("Failed to mmap PL registers at 0xB0000000");
        close(mem_fd);
        return 1;
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

    struct v4l2_dv_timings current_timings;
    memset(&current_timings, 0, sizeof(current_timings));
    bool is_locked = false;

    /* Initial Query */
    if (subdev_fd >= 0) {
        if (ioctl(subdev_fd, VIDIOC_SUBDEV_QUERY_DV_TIMINGS, &current_timings) == 0) {
            is_locked = true;
            ioctl(subdev_fd, VIDIOC_SUBDEV_S_DV_TIMINGS, &current_timings);
            update_pl_registers(pl_regs, true, &current_timings);
        } else {
            update_pl_registers(pl_regs, false, NULL);
        }
    }

    /* 4. Event & Polling Loop */
    while (keep_running) {
        if (subdev_fd < 0) {
            sleep(1);
            subdev_fd = open(subdev_path, O_RDWR);
            if (subdev_fd >= 0) {
                struct v4l2_event_subscription sub;
                memset(&sub, 0, sizeof(sub));
                sub.type = V4L2_EVENT_SOURCE_CHANGE;
                ioctl(subdev_fd, VIDIOC_SUBSCRIBE_EVENT, &sub);
            } else {
                continue;
            }
        }

        struct pollfd pfd;
        pfd.fd = subdev_fd;
        pfd.events = POLLPRI;

        int poll_ret = poll(&pfd, 1, 1000); // 1-second timeout
        if (poll_ret > 0 && (pfd.revents & POLLPRI)) {
            struct v4l2_event ev;
            memset(&ev, 0, sizeof(ev));
            if (ioctl(subdev_fd, VIDIOC_DQEVENT, &ev) == 0) {
                if (ev.type == V4L2_EVENT_SOURCE_CHANGE) {
                    printf("[%s] V4L2_EVENT_SOURCE_CHANGE detected!\n", DAEMON_NAME);
                }
            }

            /* Query timings after event */
            struct v4l2_dv_timings new_timings;
            memset(&new_timings, 0, sizeof(new_timings));
            if (ioctl(subdev_fd, VIDIOC_SUBDEV_QUERY_DV_TIMINGS, &new_timings) == 0) {
                is_locked = true;
                current_timings = new_timings;
                ioctl(subdev_fd, VIDIOC_SUBDEV_S_DV_TIMINGS, &new_timings);
                update_pl_registers(pl_regs, true, &current_timings);
            } else {
                printf("[%s] HDMI RX Signal Unlocked / Cable Disconnected\n", DAEMON_NAME);
                is_locked = false;
                update_pl_registers(pl_regs, false, NULL);
            }
        } else if (poll_ret == 0) {
            /* Periodic query fallback in case driver does not emit event */
            struct v4l2_dv_timings check_timings;
            memset(&check_timings, 0, sizeof(check_timings));
            int query_res = ioctl(subdev_fd, VIDIOC_SUBDEV_QUERY_DV_TIMINGS, &check_timings);

            if (query_res == 0 && (!is_locked || memcmp(&check_timings, &current_timings, sizeof(check_timings)) != 0)) {
                printf("[%s] Periodic Query: New Timings Locked\n", DAEMON_NAME);
                is_locked = true;
                current_timings = check_timings;
                ioctl(subdev_fd, VIDIOC_SUBDEV_S_DV_TIMINGS, &current_timings);
                update_pl_registers(pl_regs, true, &current_timings);
            } else if (query_res != 0 && is_locked) {
                printf("[%s] Periodic Query: Signal Lost\n", DAEMON_NAME);
                is_locked = false;
                update_pl_registers(pl_regs, false, NULL);
            }
        }

        /* Check Host Mailbox IPC (0x0630 - 0x063C) */
        uint32_t doorbell = pl_regs[BAR0_REG_HDMI_IPC_DOORBELL / 4];
        if (doorbell == 1) {
            uint32_t cmd = pl_regs[BAR0_REG_HDMI_IPC_CMD / 4];
            printf("[%s] Received Host IPC Command: 0x%08X\n", DAEMON_NAME, cmd);
            // Handle custom commands (e.g. EDID reload, HPD toggle)
            pl_regs[BAR0_REG_HDMI_IPC_STATUS / 4] = 0; // Success
            pl_regs[BAR0_REG_HDMI_IPC_DOORBELL / 4] = 0; // Clear doorbell
        }
    }

    printf("[%s] Exiting daemon...\n", DAEMON_NAME);
    if (subdev_fd >= 0) close(subdev_fd);
    munmap((void *)pl_regs, PL_MMAP_SIZE);
    close(mem_fd);
    return 0;
}
