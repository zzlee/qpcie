// SPDX-License-Identifier: GPL-2.0
#define _GNU_SOURCE
#include "sc7f0_health.h"
#include <stdbool.h>
#include <limits.h>
#include <signal.h>
#include <glob.h>
#include <sys/ioctl.h>
#include <sys/utsname.h>
#include <linux/watchdog.h>

#define HEALTH_DIR "/run/sc7f0-health"
#define HW_TIMEOUT 60
#define BOOT_GRACE_MS 120000ULL
struct health { uint64_t time, critical; long pid; };

static bool read_health(const char *dir, const char *name, const char *boot,
                        uint64_t now, uint64_t age, struct health *h)
{
    char path[512], got_boot[37], extra;
    struct stat st;
    if (snprintf(path, sizeof(path), "%s/%s", dir, name) >= (int)sizeof(path))
        return false;
    int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0) return false;
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_uid != geteuid() ||
        (st.st_mode & 0022) || st.st_size > 160) { close(fd); return false; }
    FILE *f = fdopen(fd, "r");
    if (!f) { close(fd); return false; }
    int n = fscanf(f, "SC7F0H1 %36s %ld %" SCNu64 " %" SCNu64 " %c",
                   got_boot, &h->pid, &h->time, &h->critical, &extra);
    fclose(f);
    return n == 4 && !strcmp(got_boot, boot) && h->pid > 1 &&
           /* A dead/replaced PID is NOT an immediate escalation: systemd
            * needs its abort/restart grace. The last real main-loop progress
            * remains acceptable only until the existing bounded age expires.
            */
           h->pid <= INT_MAX && h->time <= now && now - h->time <= age &&
           (!h->critical || (h->critical >= h->time &&
            h->critical - h->time <= SC7F0_CRITICAL_MAX_MS));
}
static bool all_healthy(const char *dir, const char *boot, uint64_t now)
{
    struct stat st;
    struct health h;
    if (lstat(dir, &st) || !S_ISDIR(st.st_mode) ||
        st.st_uid != geteuid() || (st.st_mode & 0022)) return false;
    /* Upgrade is always mandatory, even during COMMIT. */
    if (!read_health(dir, "upgrade", boot, now, 240000, &h)) return false;
    if (h.critical > now) return true;
    return read_health(dir, "debug", boot, now, 45000, &h) &&
           read_health(dir, "hdmi", boot, now, 45000, &h);
}
/* Latch survives guardian restarts within the SAME Linux boot. */
static bool latch_present(const char *boot)
{
    int fd = open(HEALTH_DIR "/watchdog-latched", O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return errno != ENOENT;
    char got[37] = {0};
    ssize_t n = read(fd, got, 36);
    close(fd);
    if (n != 36 || !strcmp(got, boot)) return true;
    return unlink(HEALTH_DIR "/watchdog-latched") != 0;
}
static void persist_latch(const char *boot)
{
    /* Parent is a private, root-owned directory created by the daemons. */
    struct stat st;
    if (lstat(HEALTH_DIR, &st) || !S_ISDIR(st.st_mode) ||
        st.st_uid != geteuid() || (st.st_mode & 0022)) return;
    int fd = open(HEALTH_DIR "/watchdog-latched",
                  O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0) return;
    if (write(fd, boot, 36) != 36)
        fprintf(stderr, "Failed to persist watchdog latch\n");
    close(fd);
}
static bool policy_feed(bool *latched, uint64_t now, bool healthy)
{
    if (!now || (now >= BOOT_GRACE_MS && !healthy)) *latched = true;
    return !*latched;
}
static int read_number(const char *path)
{
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    int n = -1;
    if (fscanf(f, "%d", &n) != 1) n = -1;
    fclose(f);
    return n;
}
static int find_watchdog(char device[64])
{
    struct utsname u;
    if (uname(&u) || strcmp(u.machine, "aarch64")) {
        fprintf(stderr, "Refusing hardware watchdog on non-aarch64 host\n");
        return -1;
    }
    glob_t g;
    if (glob("/sys/class/watchdog/watchdog*/device", 0, NULL, &g)) return -1;
    int found = 0;
    for (size_t i = 0; i < g.gl_pathc; ++i) {
        char resolved[PATH_MAX], classpath[PATH_MAX], attr[PATH_MAX + 32];
        if (!realpath(g.gl_pathv[i], resolved) ||
            !strstr(resolved, "/fd4d0000.watchdog")) continue;
        snprintf(classpath, sizeof(classpath), "%s", g.gl_pathv[i]);
        *strrchr(classpath, '/') = 0;
        snprintf(attr, sizeof(attr), "%s/nowayout", classpath);
        if (read_number(attr) != 1) continue;
        const char *name = strrchr(classpath, '/') + 1;
        snprintf(device, 64, "/dev/%s", name);
        ++found;
    }
    globfree(&g);
    if (found != 1) {
        fprintf(stderr, "Need exactly one FPD fd4d0000 watchdog with nowayout=1\n");
        return -1;
    }
    return 0;
}
int main(int argc, char **argv)
{
    char boot[37], device[64];
    if (sc7f0_boot_id(boot)) return 2;
    if (argc == 3 && !strcmp(argv[1], "--check-health")) {
        bool ok = all_healthy(argv[2], boot, sc7f0_mono_ms());
        printf("PS boot_id=%s health=%s (no watchdog device opened)\n",
               boot, ok ? "healthy" : "stale/missing");
        return ok ? 0 : 1;
    }
    if (argc != 2 || strcmp(argv[1], "--run")) {
        fprintf(stderr, "Usage: %s --check-health DIR | --run\n", argv[0]);
        return 2;
    }
    if (find_watchdog(device)) return 2;
    /* This is the sole hardware-WDT owner. PID1 RuntimeWatchdogSec must be 0.
     * No magic-close, SETOPTIONS(DISABLE), or disarm-on-signal code exists.
     */
    int fd = open(device, O_WRONLY | O_CLOEXEC);
    if (fd < 0) { perror(device); return 1; }
    int timeout = HW_TIMEOUT;
    struct watchdog_info info;
    if (ioctl(fd, WDIOC_GETSUPPORT, &info) ||
        strncmp((char *)info.identity, "cdns_wdt", 8) ||
        ioctl(fd, WDIOC_SETTIMEOUT, &timeout) || timeout != HW_TIMEOUT) {
        fprintf(stderr, "Watchdog configuration failed AFTER open; not feeding\n");
        for (;;) pause();
    }
    fprintf(stderr, "ARMED %s timeout=%ds PS boot_id=%s; progress-gated\n",
            device, timeout, boot);
    bool latched = latch_present(boot);
    for (;;) {
        uint64_t now = sc7f0_mono_ms();
        bool previous = latched;
        (void)policy_feed(&latched, now, all_healthy(HEALTH_DIR, boot, now));
        if (latched && !previous) {
            persist_latch(boot);
            fprintf(stderr, "LATCHED unhealthy PS services at %" PRIu64
                    "ms; no more pings, awaiting hardware system reset\n", now);
            latched = true;
        }
        if (!latched && ioctl(fd, WDIOC_KEEPALIVE, 0)) {
            perror("WDIOC_KEEPALIVE");
            latched = true;
            persist_latch(boot);
        }
        sleep(1);
    }
}
