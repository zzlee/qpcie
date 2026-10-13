/* File-only persistent rollback transaction. Not a boot0 updater or an
 * atomic multi-file boot switch. A power cut can still require SD recovery
 * before Linux can run this recovery routine. Caller owns an exclusive mount. */
#ifndef QPCIE_FILE_TRANSACTION_H
#define QPCIE_FILE_TRANSACTION_H
#include <stdlib.h>
#include "qpcie_commit_helpers.h"

static const char *const qtx_names[] = { "BOOT.BIN", "image.ub", "boot.scr" };
typedef int (*qtx_checkpoint)(unsigned step, void *context);

static inline int qtx_path(char *dst, size_t cap, const char *dir, const char *name) {
    int n = snprintf(dst, cap, "%s/%s", dir, name);
    return n < 0 || (size_t)n >= cap ? -1 : 0;
}
static inline int qtx_sync_dir(const char *dir) {
    int fd = open(dir, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    if (fd < 0) return -1;
    int rc = fsync(fd);
    if (close(fd) != 0) rc = -1;
    return rc;
}
static inline int qtx_regular(const char *p) {
    struct stat st;
    return lstat(p, &st) == 0 && S_ISREG(st.st_mode) && st.st_size > 0;
}
static inline int qtx_mark(const char *backup, const char *state) {
    char path[512];
    if (qtx_path(path, sizeof path, backup, "state") != 0) return -1;
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0600);
    if (fd < 0) return -1;
    size_t len = strlen(state);
    int rc = write(fd, state, len) == (ssize_t)len ? 0 : -1;
    if (fsync(fd) != 0) rc = -1;
    if (close(fd) != 0) rc = -1;
    if (qtx_sync_dir(backup) != 0) rc = -1;
    return rc;
}
/* Recovery is idempotent and never deletes the backups. A partial/invalid
 * marker fails closed: caller needs operator review, not a blind new update. */
static inline int qtx_recover(const char *mount_dir, const char *backup) {
    char path[512], state[32] = {0};
    if (qtx_path(path, sizeof path, backup, "state") != 0) return -1;
    int fd = open(path, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return -1;
    ssize_t n = read(fd, state, sizeof state - 1);
    close(fd);
    if (n <= 0) return -1;
    if (!strcmp(state, "COMMITTED\n") || !strcmp(state, "ROLLED_BACK\n")) return 0;
    if (strcmp(state, "APPLYING\n") && strcmp(state, "PREPARED\n")) return -1;
    /* Require every backup before overwriting anything. */
    for (unsigned i = 0; i < 3; ++i) {
        if (qtx_path(path, sizeof path, backup, qtx_names[i]) || !qtx_regular(path)) return -1;
    }
    for (unsigned i = 0; i < 3; ++i) {
        char dst[512];
        if (qtx_path(path, sizeof path, backup, qtx_names[i]) ||
            qtx_path(dst, sizeof dst, mount_dir, qtx_names[i])) return -1;
        if (qch_copy_file(path, dst) || qch_files_equal(path, dst) != 1) return -1;
    }
    if (qtx_sync_dir(mount_dir)) return -1;
    return qtx_mark(backup, "ROLLED_BACK\n");
}
/* Unique backup directory MUST be on the same persistent filesystem as
 * mount_dir, never /tmp. Caller verifies device identity/free capacity first.
 * checkpoints permit fault injection or a simulated process termination. */
static inline int qtx_apply(const char *mount_dir, const char *staging,
                     const char *backup, qtx_checkpoint checkpoint, void *context) {
    char src[512], dst[512];
    struct stat m, b;
    if (mkdir(backup, 0700) || stat(mount_dir, &m) || stat(backup, &b) || m.st_dev != b.st_dev)
        return -1;
    if (qtx_sync_dir(mount_dir)) return -1;
    for (unsigned i = 0; i < 3; ++i) {
        if (qtx_path(src, sizeof src, mount_dir, qtx_names[i]) || !qtx_regular(src) ||
            qtx_path(dst, sizeof dst, staging, qtx_names[i]) || !qtx_regular(dst)) return -1;
    }
    /* All backups must be durable and byte-identical before PREPARED. */
    for (unsigned i = 0; i < 3; ++i) {
        if (qtx_path(src, sizeof src, mount_dir, qtx_names[i]) ||
            qtx_path(dst, sizeof dst, backup, qtx_names[i]) ||
            qch_copy_file(src, dst) || qch_files_equal(src, dst) != 1) return -1;
    }
    if (qtx_mark(backup, "PREPARED\n")) return -1;
    if (checkpoint && checkpoint(0, context)) return -1;
    if (qtx_mark(backup, "APPLYING\n")) return -1;
    for (unsigned i = 0; i < 3; ++i) {
        if (qtx_path(src, sizeof src, staging, qtx_names[i]) ||
            qtx_path(dst, sizeof dst, mount_dir, qtx_names[i]) ||
            qch_copy_file(src, dst) || qch_files_equal(src, dst) != 1) {
            /* Preserve APPLYING for recovery; do not claim rollback succeeded. */
            return -1;
        }
        if (checkpoint && checkpoint(i + 1, context)) return -1;
    }
    if (qtx_sync_dir(mount_dir)) return -1;
    return qtx_mark(backup, "COMMITTED\n");
}
#endif
