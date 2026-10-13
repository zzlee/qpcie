/*
 * qpcie_upgrade_daemon.c - On-Board Firmware Upgrade Daemon for QPCIe SC7F0
 *
 * Target Hardware: AMD/Xilinx Zynq UltraScale+ XCZU4EV (SC7F0 N1 HDMI2 V11)
 * Architecture   : aarch64 (ARM Cortex-A53 Linux / PetaLinux)
 *
 * Description:
 *   Runs as a background service on the SC7F0 card. Coordinates with the
 *   Host PC's qpcie_upgrade tool via PL CSR registers. Receives the upgrade
 *   bundle (upgrade.tar.gz) directly in DDR4 memory, validates CRC32/SHA256,
 *   performs atomic replacement on eMMC (/dev/mmcblk0p1 and mmcblk0boot0),
 *   and triggers PMU chip-level POR reset for zero-host-reboot reloading.
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
#include <sys/stat.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <errno.h>
#include <signal.h>
#include <setjmp.h>
#include <syslog.h>

#include "qpcie_commit_helpers.h"
#include "qpcie_archive_verify.h"
#include "qpcie_file_transaction.h"

#define DAEMON_NAME "qpcie_upgrade_daemon"

/* Base Address of PL CSR space mapped into PS (M_AXI_HPM0_FPD).
 * Verified 2026-10-08 from built BD: SEG_M_AXI_HPM0_FPD_Reg @0xA0000000/64KB.
 * NOTE: 0xB0000000 is NOT mapped (reads wedge the NoC with no abort).
 * NEVER probe unmapped addresses. */
#define DEFAULT_PL_BASE_ADDR   0xA0000000UL
#define PL_MMAP_SIZE           0x10000UL     /* 64KB */

/* SC7F0 PCIe H2C DMA Fast-Push Upgrade Registers (BAR0 0x0780 - 0x079C) */
#define REG_DMA_UPG_CTRL       0x0780
#define REG_DMA_UPG_SIZE       0x0784
#define REG_DMA_UPG_CRC32      0x0788
#define REG_DMA_UPG_PS_ADDR_L  0x078C
#define REG_DMA_UPG_PS_ADDR_H  0x0790
#define REG_DMA_UPG_STATUS     0x0794
#define REG_DMA_UPG_PROGRESS   0x0798
#define REG_DMA_UPG_DOORBELL   0x079C

/* DMA Upgrade Commands (REG_DMA_UPG_CTRL) */
#define DMA_UPG_CMD_NONE       0x00
#define DMA_UPG_CMD_START      0x01
#define DMA_UPG_CMD_DMA_DONE   0x02
#define DMA_UPG_CMD_ABORT      0x04
#define DMA_UPG_CMD_REBOOT     0x08

/* DMA Upgrade Status (REG_DMA_UPG_STATUS) */
#define STATUS_UPG_IDLE        0x00
#define STATUS_UPG_RECEIVING   0x01
#define STATUS_UPG_VERIFYING   0x02
#define STATUS_UPG_FLASHING    0x03
#define STATUS_UPG_SUCCESS     0x04
#define STATUS_UPG_VERIFIED    0x05
#define STATUS_UPG_ERR_CRC     0xE1
#define STATUS_UPG_ERR_FLASH   0xE2
#define STATUS_UPG_ERR_TIMEOUT 0xE3
#define STATUS_UPG_ERR_STATE   0xE4

/* Doorbell commands (REG_DMA_UPG_DOORBELL). The daemon NEVER acts on
 * START&&DONE; only an explicit doorbell value triggers work. VERIFY stages
 * and checks the package without touching eMMC; COMMIT flashes eMMC and
 * requires a preceding VERIFIED state with matching SIZE/CRC. */
#define DOORBELL_VERIFY        0x01
#define DOORBELL_COMMIT        0x02
#define DOORBELL_HELLO         0x10
#define STATUS_VERIFY_ONLY    0x06

/* Dedicated DDR4 DMA Staging Physical Address (dau_fpga reserved memory) */
#define DEFAULT_DDR4_DMA_PHYS  0x30000000UL
#define DDR4_DMA_BUF_SIZE      (64 * 1024 * 1024) /* 64 MB */

#ifndef EMMC_BOOT_PART
#define EMMC_BOOT_PART         "/dev/mmcblk0p1"
#endif
#ifndef EMMC_MOUNT_DIR
#define EMMC_MOUNT_DIR         "/mnt/emmc_boot"
#endif
#define STAGING_DIR            staging_dir
static char staging_dir[128];
#define BACKUP_DIR             "/tmp/upgrade_backup"
#define STAGING_TAR            "/tmp/upgrade.tar.gz"

static const char *const kPkgFiles[] = { "BOOT.BIN", "image.ub", "boot.scr" };
#define N_PKG_FILES 3

static volatile bool g_running = true;

static void sig_handler(int sig) {
    (void)sig;
    g_running = false;
}

/* Standalone-safe PL liveness probe.
 * Without PCIe/host (no pcie_user_clk), the PS->PL AXI path may never answer.
 * Touching it unconditionally wedges boot, so the FIRST magic read of every
 * attempt is guarded by alarm(2)+SIGBUS/SIGSEGV. On fault/timeout we abandon
 * the mapping and idle-retry WITHOUT touching PL again until it answers.
 * Production (PCIe present) behavior is unchanged: first probe succeeds. */
#define PL_PROBE_MAGIC   0x12ABE380u
#define PL_PROBE_TIMEOUT 2   /* seconds */
#define PL_RETRY_SECS    30

static sigjmp_buf probe_env;

static void probe_handler(int sig) {
    (void)sig;
    siglongjmp(probe_env, 1);
}

static bool pl_magic_ok(volatile uint32_t *map) {
    struct sigaction sa, old_alrm, old_bus, old_segv;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = probe_handler;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGALRM, &sa, &old_alrm);
    sigaction(SIGBUS, &sa, &old_bus);
    sigaction(SIGSEGV, &sa, &old_segv);
    bool ok = false;
    if (sigsetjmp(probe_env, 1) == 0) {
        alarm(PL_PROBE_TIMEOUT);
        uint32_t v = map[0];
        alarm(0);
        ok = (v == PL_PROBE_MAGIC);
    } else {
        ok = false; /* alarm fired or bus fault: PL not answering */
    }
    alarm(0);
    sigaction(SIGALRM, &old_alrm, NULL);
    sigaction(SIGBUS, &old_bus, NULL);
    sigaction(SIGSEGV, &old_segv, NULL);
    return ok;
}

/* Block until PL CSR answers with magic. Returns live mapping; never returns
 * a dead one. Sleeps between attempts so standalone (power-only) boot always
 * reaches login; daemon springs to life once PL is accessible. */
static volatile uint32_t *pl_wait_ready(int fd_mem) {
    uint64_t candidate_bases[] = {0xA0000000UL};
    unsigned attempt = 0;
    for (;;) {
        for (size_t i = 0; i < sizeof(candidate_bases)/sizeof(candidate_bases[0]); i++) {
            volatile uint32_t *map = (volatile uint32_t *)mmap(NULL, PL_MMAP_SIZE,
                                                               PROT_READ | PROT_WRITE,
                                                               MAP_SHARED, fd_mem, candidate_bases[i]);
            if (map == MAP_FAILED)
                continue;
            if (pl_magic_ok(map)) {
                syslog(LOG_NOTICE, "Discovered SC7F0 PL CSR at physical base 0x%08lX (Magic: 0x12ABE380)",
                       candidate_bases[i]);
                return map;
            }
            munmap((void *)map, PL_MMAP_SIZE);
        }
        if ((attempt++ % 10) == 0)
            syslog(LOG_WARNING, "PL CSR not answering (standalone power-only boot?). Retrying every %ds...",
                   PL_RETRY_SECS);
        for (int s = 0; s < PL_RETRY_SECS && g_running; s++)
            sleep(1);
        if (!g_running)
            return MAP_FAILED;
    }
}

/* CRC32 Lookup Table & Calculation */
static uint32_t crc32_table[256];
static bool crc_tab_init = false;

static void init_crc32(void) {
    if (crc_tab_init) return;
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t c = i;
        for (int j = 0; j < 8; j++) {
            c = (c & 1) ? (0xEDB88320L ^ (c >> 1)) : (c >> 1);
        }
        crc32_table[i] = c;
    }
    crc_tab_init = true;
}

static uint32_t calculate_crc32(const uint8_t *buf, size_t len) {
    init_crc32();
    uint32_t crc = 0xFFFFFFFF;
    for (size_t i = 0; i < len; i++) {
        crc = crc32_table[(crc ^ buf[i]) & 0xFF] ^ (crc >> 8);
    }
    return crc ^ 0xFFFFFFFF;
}

/* Trigger ZU4EV PMU Chip-Level Power-On Reset (POR) */
static void trigger_pmu_por(void) {
    syslog(LOG_NOTICE, "Triggering ZU4EV chip-level Power-On Reset (POR)...");
    sync();

    // 1. Attempt writing PMU_GLOBAL.GLOBAL_RESET (0xFFD80030 = 0x1) via /dev/mem
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd >= 0) {
        void *pmu = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0xFFD80000);
        if (pmu != MAP_FAILED) {
            volatile uint32_t *global_reset = (volatile uint32_t *)((uint8_t *)pmu + 0x30);
            *global_reset = 0x00000001; // Chip-level POR
            msync((void *)global_reset, 4, MS_SYNC);
        }
        close(fd);
    }

    // 2. Fallback: sysrq trigger 'b'
    FILE *sysrq = fopen("/proc/sysrq-trigger", "w");
    if (sysrq) {
        fputs("b\n", sysrq);
        fclose(sysrq);
    }

    // 3. Fallback: Linux reboot syscall
    reboot(RB_AUTOBOOT);
}

/* ---- Two-stage upgrade protocol (VERIFY then COMMIT) ----
 * The daemon NEVER treats streaming-DMA START&&DONE as a trigger: that
 * condition fires spuriously while the host pushes consecutive chunks.
 * Only an explicit doorbell value latches work. VERIFY checks the staged
 * bundle and stops; COMMIT flashes eMMC exactly once per VERIFY and
 * requires the latched SIZE/CRC to still match. */

static void finish_cmd(volatile uint32_t *pl_regs, uint32_t status) {
    pl_regs[REG_DMA_UPG_STATUS / 4] = status;
    pl_regs[REG_DMA_UPG_CTRL / 4]   = DMA_UPG_CMD_NONE;
}

/* Best-effort shell helper (e.g. force_ro toggles that may not exist).
 * Return value is logged, never fatal. */
static inline void run_best_effort(const char *cmd) {
    int rc = system(cmd);
    if (rc != 0)
        syslog(LOG_WARNING, "best-effort command rc=%d: %s", rc, cmd);
}

static int stage_path(char *dst, size_t cap, const char *dir, const char *name) {
    size_t dl = strlen(dir), nl = strlen(name);
    if (dl + 1 + nl + 1 > cap) return -1;
    memcpy(dst, dir, dl);
    dst[dl] = '/';
    memcpy(dst + dl + 1, name, nl + 1);
    return 0;
}

/* VERIFY: CRC-check staging DDR, extract tar, validate package contents.
 * Touches eMMC in NO way. Sets *verified on success. */
static void do_verify_ram(volatile uint32_t *pl_regs, const uint8_t *dma_buf,
                      uint32_t req_size, uint32_t req_crc,
                      uint32_t *verified_size, uint32_t *verified_crc,
                      bool *verified) {
    *verified = false;
    pl_regs[REG_DMA_UPG_STATUS / 4]   = STATUS_UPG_VERIFYING;
    pl_regs[REG_DMA_UPG_PROGRESS / 4] = 30;

    if (req_size == 0 || req_size > DDR4_DMA_BUF_SIZE) {
        syslog(LOG_ERR, "VERIFY: invalid package size %u", req_size);
        finish_cmd(pl_regs, STATUS_UPG_ERR_CRC);
        return;
    }
    uint32_t calc_crc = calculate_crc32(dma_buf, req_size);
    if (calc_crc != req_crc) {
        syslog(LOG_ERR, "VERIFY: CRC32 mismatch expected=0x%08X got=0x%08X", req_crc, calc_crc);
        finish_cmd(pl_regs, STATUS_UPG_ERR_CRC);
        return;
    }
    syslog(LOG_NOTICE, "VERIFY: CRC32 OK (0x%08X, %u bytes); staging tarball", calc_crc, req_size);

    FILE *f_tar = fopen(STAGING_TAR, "wb");
    if (!f_tar) {
        syslog(LOG_ERR, "VERIFY: cannot write %s: %s", STAGING_TAR, strerror(errno));
        finish_cmd(pl_regs, STATUS_UPG_ERR_FLASH);
        return;
    }
    bool wr_ok = (fwrite(dma_buf, 1, req_size, f_tar) == req_size);
    bool cl_ok = (fclose(f_tar) == 0);
    if (!wr_ok || !cl_ok) {
        syslog(LOG_ERR, "VERIFY: short write to staging tar");
        finish_cmd(pl_regs, STATUS_UPG_ERR_FLASH);
        return;
    }

    pl_regs[REG_DMA_UPG_PROGRESS / 4] = 50;
    /* Delete only our own three known files from the previous private dir. */
    if (staging_dir[0]) {
        for (int i = 0; i < N_PKG_FILES; ++i) {
            char path[512];
            if (!stage_path(path, sizeof path, staging_dir, kPkgFiles[i])) unlink(path);
        }
        rmdir(staging_dir);
    }
    strcpy(staging_dir, "/tmp/qpcie_verified_XXXXXX");
    if (!mkdtemp(staging_dir)) {
        staging_dir[0] = 0;
        syslog(LOG_ERR, "VERIFY: cannot create private staging dir");
        finish_cmd(pl_regs, STATUS_UPG_ERR_FLASH);
        return;
    }
    if (qav_gzip(STAGING_TAR, STAGING_DIR)) {
        syslog(LOG_ERR, "VERIFY: invalid archive (only three regular bounded ustar files allowed)");
        finish_cmd(pl_regs, STATUS_UPG_ERR_CRC);
        return;
    }
    for (int i = 0; i < N_PKG_FILES; i++) {
        char p[512];
        if (stage_path(p, sizeof(p), STAGING_DIR, kPkgFiles[i]) != 0 ||
            qch_file_size(p) == (size_t)-1 || qch_file_size(p) == 0) {
            syslog(LOG_ERR, "VERIFY: package file %s missing or empty", kPkgFiles[i]);
            finish_cmd(pl_regs, STATUS_UPG_ERR_CRC);
            return;
        }
    }
    *verified_size = req_size;
    *verified_crc  = req_crc;
    *verified       = true;
    pl_regs[REG_DMA_UPG_PROGRESS / 4] = 60;
    syslog(LOG_NOTICE, "VERIFY: package complete (BOOT.BIN/image.ub/boot.scr present)");
    finish_cmd(pl_regs, STATUS_UPG_VERIFIED);
}

/* Snapshot the Device-mapped DDR before using any libc bulk operation.
 * The host must stop DMA and hold the session exclusive throughout VERIFY. */
static void do_verify(volatile uint32_t *pl_regs, const uint8_t *dma_buf,
                      uint32_t req_size, uint32_t req_crc,
                      uint32_t *verified_size, uint32_t *verified_crc,
                      bool *verified) {
    *verified = false;
    if (!req_size || req_size > DDR4_DMA_BUF_SIZE ||
        (pl_regs[REG_DMA_UPG_CTRL / 4] & DMA_UPG_CMD_START)) {
        finish_cmd(pl_regs, STATUS_UPG_ERR_STATE);
        return;
    }
    uint8_t *snapshot = malloc(req_size);
    if (!snapshot) {
        syslog(LOG_ERR, "VERIFY: cannot allocate %u-byte RAM snapshot", req_size);
        finish_cmd(pl_regs, STATUS_UPG_ERR_FLASH);
        return;
    }
    pl_regs[REG_DMA_UPG_STATUS / 4] = STATUS_UPG_VERIFYING;
    pl_regs[REG_DMA_UPG_PROGRESS / 4] = 25;
    qch_device_snapshot(snapshot, dma_buf, req_size);
    do_verify_ram(pl_regs, snapshot, req_size, req_crc,
                  verified_size, verified_crc, verified);
    free(snapshot);
}

/* COMMIT: flash eMMC from the VERIFIED staging dir using persistent file transaction
 * with automatic rollback. Exactly one COMMIT is consumed per VERIFY. */
static void do_commit(volatile uint32_t *pl_regs,
                      uint32_t *verified_size, uint32_t *verified_crc,
                      bool *verified) {
    uint32_t req_size = pl_regs[REG_DMA_UPG_SIZE / 4];
    uint32_t req_crc  = pl_regs[REG_DMA_UPG_CRC32 / 4];
    if (!*verified || pl_regs[REG_DMA_UPG_STATUS / 4] != STATUS_UPG_VERIFIED ||
        req_size != *verified_size || req_crc != *verified_crc || !staging_dir[0]) {
        syslog(LOG_ERR, "COMMIT: rejected (no matching VERIFIED state)");
        *verified = false;
        finish_cmd(pl_regs, STATUS_UPG_ERR_STATE);
        return;
    }
    *verified = false; /* consume: one COMMIT per VERIFY */
    pl_regs[REG_DMA_UPG_STATUS / 4]   = STATUS_UPG_FLASHING;
    pl_regs[REG_DMA_UPG_PROGRESS / 4] = 70;
    syslog(LOG_NOTICE, "COMMIT: flashing eMMC (%u bytes, crc 0x%08X)", req_size, req_crc);

    char cmd[2048];
    snprintf(cmd, sizeof(cmd), "mkdir -p %s", EMMC_MOUNT_DIR);
    if (system(cmd) != 0) {
        finish_cmd(pl_regs, STATUS_UPG_ERR_FLASH);
        return;
    }
    umount(EMMC_MOUNT_DIR);
    if (mount(EMMC_BOOT_PART, EMMC_MOUNT_DIR, "vfat", 0, NULL) != 0) {
        syslog(LOG_ERR, "COMMIT: mount %s failed: %s", EMMC_BOOT_PART, strerror(errno));
        finish_cmd(pl_regs, STATUS_UPG_ERR_FLASH);
        return;
    }

    char backup_dir[1024];
    if (qtx_path(backup_dir, sizeof(backup_dir), EMMC_MOUNT_DIR, ".backup_upgrade") != 0) {
        umount(EMMC_MOUNT_DIR);
        finish_cmd(pl_regs, STATUS_UPG_ERR_FLASH);
        return;
    }
    /* Clean up any old completed backup before creating new one */
    char rm_cmd[2048];
    snprintf(rm_cmd, sizeof(rm_cmd), "rm -rf %s", backup_dir);
    run_best_effort(rm_cmd);

    pl_regs[REG_DMA_UPG_PROGRESS / 4] = 80;
    int rc = qtx_apply(EMMC_MOUNT_DIR, STAGING_DIR, backup_dir, NULL, NULL);
    if (rc != 0) {
        syslog(LOG_ERR, "COMMIT: qtx_apply failed (rc=%d); attempting rollback", rc);
        int rec = qtx_recover(EMMC_MOUNT_DIR, backup_dir);
        syslog(LOG_NOTICE, "COMMIT: rollback result: %d", rec);
        sync();
        umount(EMMC_MOUNT_DIR);
        finish_cmd(pl_regs, STATUS_UPG_ERR_FLASH);
        return;
    }

    pl_regs[REG_DMA_UPG_PROGRESS / 4] = 95;
    sync();
    if (umount(EMMC_MOUNT_DIR) != 0) {
        syslog(LOG_WARNING, "COMMIT: umount %s failed; check manually", EMMC_MOUNT_DIR);
    }
    syslog(LOG_NOTICE, "COMMIT: eMMC upgrade committed and verified");
    pl_regs[REG_DMA_UPG_PROGRESS / 4] = 100;
    finish_cmd(pl_regs, STATUS_UPG_SUCCESS);
}

int main(int argc, char **argv) {
    (void)argc; (void)argv;
    openlog(DAEMON_NAME, LOG_PID | LOG_CONS, LOG_DAEMON);
    syslog(LOG_NOTICE, "QPCIe SC7F0 Firmware Upgrade Daemon starting...");

    signal(SIGINT, sig_handler);
    signal(SIGTERM, sig_handler);

    int fd_mem = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd_mem < 0) {
        syslog(LOG_ERR, "Failed to open /dev/mem: %s", strerror(errno));
        return EXIT_FAILURE;
    }

    // Wait for PL CSR to answer (standalone-safe: never touch PL until
    // the magic probe succeeds, so power-only boot always reaches login).
    // ONLY probe the BD-mapped window (0xA0000000/64KB). Unmapped addresses
    // wedge the NoC with no error response and must never be touched.
    volatile uint32_t *pl_regs = pl_wait_ready(fd_mem);
    if (pl_regs == MAP_FAILED || !g_running) {
        close(fd_mem);
        closelog();
        return EXIT_SUCCESS;
    }

    // Map DDR4 DMA receive window
    uint8_t *dma_buf = (uint8_t *)mmap(NULL, DDR4_DMA_BUF_SIZE,
                                      PROT_READ | PROT_WRITE,
                                      MAP_SHARED, fd_mem, DEFAULT_DDR4_DMA_PHYS);
    if (dma_buf == MAP_FAILED) {
        syslog(LOG_ERR, "Failed to mmap DDR4 DMA buffer at 0x%08lX: %s", DEFAULT_DDR4_DMA_PHYS, strerror(errno));
        munmap((void *)pl_regs, PL_MMAP_SIZE);
        close(fd_mem);
        return EXIT_FAILURE;
    }

    // Publish DDR4 physical address to Host via CSR
    pl_regs[REG_DMA_UPG_PS_ADDR_L / 4] = (uint32_t)(DEFAULT_DDR4_DMA_PHYS & 0xFFFFFFFF);
    pl_regs[REG_DMA_UPG_PS_ADDR_H / 4] = (uint32_t)((DEFAULT_DDR4_DMA_PHYS >> 32) & 0xFFFFFFFF);
    pl_regs[REG_DMA_UPG_STATUS / 4]    = STATUS_UPG_IDLE;
    pl_regs[REG_DMA_UPG_PROGRESS / 4]  = 0;
    pl_regs[REG_DMA_UPG_CTRL / 4]      = DMA_UPG_CMD_NONE;

    syslog(LOG_NOTICE, "Daemon initialized. Ready for Host PCIe DMA (Buffer @ 0x%08lX)", DEFAULT_DDR4_DMA_PHYS);

    // Startup recovery check: if previous update was interrupted, recover from backup
    {
        char mnt_cmd[2048];
        snprintf(mnt_cmd, sizeof(mnt_cmd), "mkdir -p %s", EMMC_MOUNT_DIR);
        run_best_effort(mnt_cmd);
        umount(EMMC_MOUNT_DIR);
        if (mount(EMMC_BOOT_PART, EMMC_MOUNT_DIR, "vfat", 0, NULL) == 0) {
            char backup_dir[1024];
            if (qtx_path(backup_dir, sizeof(backup_dir), EMMC_MOUNT_DIR, ".backup_upgrade") == 0 &&
                access(backup_dir, F_OK) == 0) {
                int rec = qtx_recover(EMMC_MOUNT_DIR, backup_dir);
                if (rec == 0) {
                    syslog(LOG_NOTICE, "Startup recovery check completed successfully");
                } else {
                    syslog(LOG_WARNING, "Startup recovery returned %d", rec);
                }
                sync();
            }
            umount(EMMC_MOUNT_DIR);
        }
    }

    uint32_t verified_size = 0, verified_crc = 0;
    bool verified_valid = false;

    while (g_running) {
        uint32_t ctrl     = pl_regs[REG_DMA_UPG_CTRL / 4];
        uint32_t doorbell = pl_regs[REG_DMA_UPG_DOORBELL / 4];

        // Check for Warm Reboot request
        if (ctrl & DMA_UPG_CMD_REBOOT) {
            trigger_pmu_por();
            break;
        }

        // Only explicit doorbell commands latch work. Streaming-DMA
        // START&&DONE is deliberately NOT a trigger (fires spuriously
        // while the host pushes consecutive chunks).
        if (doorbell == DOORBELL_HELLO) {
            verified_valid = false;
            pl_regs[REG_DMA_UPG_STATUS / 4] = STATUS_VERIFY_ONLY;
            pl_regs[REG_DMA_UPG_DOORBELL / 4] = 0;
        } else if (doorbell == DOORBELL_VERIFY || doorbell == DOORBELL_COMMIT) {
            uint32_t cmd = doorbell;
            uint32_t req_size = pl_regs[REG_DMA_UPG_SIZE / 4];
            uint32_t req_crc  = pl_regs[REG_DMA_UPG_CRC32 / 4];
            pl_regs[REG_DMA_UPG_DOORBELL / 4] = 0x00; // latch + acknowledge
            if (cmd == DOORBELL_VERIFY) {
                syslog(LOG_NOTICE, "VERIFY request: size=%u crc=0x%08X", req_size, req_crc);
                do_verify(pl_regs, dma_buf, req_size, req_crc,
                          &verified_size, &verified_crc, &verified_valid);
            } else {
                syslog(LOG_NOTICE, "COMMIT request: size=%u crc=0x%08X", req_size, req_crc);
                do_commit(pl_regs, &verified_size, &verified_crc, &verified_valid);
            }
        } else if (doorbell != 0) {
            pl_regs[REG_DMA_UPG_DOORBELL / 4] = 0x00;
            verified_valid = false;
            syslog(LOG_ERR, "Unknown doorbell 0x%08X; ignored", doorbell);
            finish_cmd(pl_regs, STATUS_UPG_ERR_STATE);
        }

        usleep(100000); // 100ms poll interval (firmware upgrade is not latency-sensitive)
    }

    munmap((void *)dma_buf, DDR4_DMA_BUF_SIZE);
    munmap((void *)pl_regs, PL_MMAP_SIZE);
    close(fd_mem);
    closelog();
    return EXIT_SUCCESS;
}
