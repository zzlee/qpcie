/* SPDX-License-Identifier: GPL-2.0
 * Main-thread progress only. No timer/thread can conceal blocked MMIO or I/O.
 * Opt-in health files; systemd notifications require no libsystemd.
 */
#ifndef SC7F0_HEALTH_H
#define SC7F0_HEALTH_H
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <inttypes.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <time.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <stddef.h>

#define SC7F0_CRITICAL_MAX_MS 300000ULL
static const char *sc7f0_health_name;
static uint64_t sc7f0_health_next, sc7f0_critical_until;
static pid_t sc7f0_health_owner;
static char sc7f0_health_boot[37];

static inline uint64_t sc7f0_mono_ms(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts)) return 0;
    return (uint64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}
static inline int sc7f0_boot_id(char out[37])
{
    FILE *f = fopen("/proc/sys/kernel/random/boot_id", "r");
    if (!f) return -1;
    int n = fscanf(f, "%36s", out);
    fclose(f);
    return n == 1 && strlen(out) == 36 ? 0 : -1;
}
static inline void sc7f0_notify(const char *msg)
{
    const char *path = getenv("NOTIFY_SOCKET");
    struct sockaddr_un sa = {.sun_family = AF_UNIX};
    if (!path || !*path || strlen(path) >= sizeof(sa.sun_path) ||
        (path[0] != '/' && path[0] != '@')) return;
    memcpy(sa.sun_path, path, strlen(path) + 1);
    socklen_t len = offsetof(struct sockaddr_un, sun_path) + strlen(path) + 1;
    if (path[0] == '@') { sa.sun_path[0] = 0; --len; }
    int fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    if (fd < 0) return;
    (void)sendto(fd, msg, strlen(msg), MSG_NOSIGNAL,
                 (struct sockaddr *)&sa, len);
    close(fd);
}
static inline void sc7f0_health_init(const char *name)
{
    sc7f0_health_name = name;
    sc7f0_health_owner = getpid();
    (void)sc7f0_boot_id(sc7f0_health_boot);
}
static inline void sc7f0_health_progress(void)
{
    if (!sc7f0_health_name || getpid() != sc7f0_health_owner) return;
    uint64_t now = sc7f0_mono_ms();
    if (!now || now < sc7f0_health_next) return;
    sc7f0_health_next = now + 1000;
    sc7f0_notify("WATCHDOG=1");
    const char *dir = getenv("SC7F0_HEALTH_DIR");
    if (!dir || !*dir || !sc7f0_health_boot[0]) return;
    struct stat st;
    if ((mkdir(dir, 0700) && errno != EEXIST) ||
        lstat(dir, &st) || !S_ISDIR(st.st_mode) ||
        st.st_uid != geteuid() || (st.st_mode & 0022)) return;
    char path[512], tmp[512], buf[160];
    int n = snprintf(path, sizeof(path), "%s/%s", dir, sc7f0_health_name);
    int t = snprintf(tmp, sizeof(tmp), "%s/.%s.%ld.tmp",
                     dir, sc7f0_health_name, (long)getpid());
    if (n < 0 || n >= (int)sizeof(path) || t < 0 || t >= (int)sizeof(tmp)) return;
    int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0) return;
    n = snprintf(buf, sizeof(buf), "SC7F0H1 %s %ld %" PRIu64 " %" PRIu64 "\n",
                 sc7f0_health_boot, (long)getpid(), now, sc7f0_critical_until);
    int good = !fstat(fd, &st) && S_ISREG(st.st_mode) && st.st_nlink == 1 &&
               st.st_uid == geteuid() && n > 0 && n < (int)sizeof(buf) &&
               write(fd, buf, n) == n;
    close(fd);
    if (good) (void)rename(tmp, path);
    else (void)unlink(tmp);
}
static inline void sc7f0_health_ready(void)
{
    sc7f0_notify("READY=1");
    sc7f0_health_next = 0;
    sc7f0_health_progress();
}
/* A fixed, non-renewing COMMIT lease only defers OTHER daemon failures.
 * It never bypasses the upgrade daemon's own progress or kernel/hardware WDT.
 */
static inline void sc7f0_health_critical(int active)
{
    sc7f0_critical_until = active ? sc7f0_mono_ms() + SC7F0_CRITICAL_MAX_MS : 0;
    sc7f0_health_next = 0;
    sc7f0_health_progress();
}
#endif
