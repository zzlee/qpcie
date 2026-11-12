/* Generation-retaining backup policy for the SC7F0 COMMIT path.
 *
 * Why this exists (measured, not theoretical)
 * -------------------------------------------
 * The card was found on 2026-11-11 with /run/media/BOOT-mmcblk0p1/.backup_upgrade
 * holding BOOT.BIN / image.ub / boot.scr whose SHA-256 values were *identical to
 * the live files*, and no .backup_cli_* directory at all. That is what the old
 * policy produces by construction:
 *
 *     rm -rf .backup_upgrade            <- deletes the previous generation
 *     qtx_apply(mount, staging, .backup_upgrade)
 *
 * The backup is therefore "whatever was on the card a moment ago", so a retry of
 * the same package, or a second COMMIT in the same session, overwrites the only
 * prior-generation image with the current one. Worse, if the previous transaction
 * was interrupted (state APPLYING), the rm -rf destroys the unique recovery set
 * before anything could be restored from it. AGENTS.md's "rollback is available"
 * claim is only true while exactly one COMMIT has ever run.
 *
 * The policy implemented here:
 *
 *   .backup_upgrade/                 retention root, never deleted as a whole
 *     txn-<epoch>-<n>/               one fresh transaction directory per COMMIT
 *       BOOT.BIN image.ub boot.scr   pre-COMMIT bytes (qtx_apply writes these)
 *       state                        PREPARED -> APPLYING -> COMMITTED
 *     gen-<epoch>-<n>/               a finished transaction, renamed, never
 *                                    rewritten in place
 *
 *   * an interrupted transaction (state missing, PREPARED or APPLYING) is
 *     recovered before anything else and is never removed; if recovery fails the
 *     COMMIT is refused, because the alternative is destroying the only set of
 *     bytes the card can boot from;
 *   * a retry of the same package cannot overwrite a generation: it creates a new
 *     transaction directory whose content happens to be identical, and the older
 *     generation survives retention;
 *   * retention keeps QBR_MAX_GENERATIONS newest generations, and prunes nothing
 *     while any transaction is unfinished; when a reference generation is supplied
 *     (the daemon always supplies the newest one), a generation whose BOOT.BIN is
 *     not provably identical to it is never the one removed - so a same-version
 *     retry can evict its own duplicate, but never the older image that differs;
 *   * the pre-existing single-directory layout (state file directly inside
 *     .backup_upgrade) is adopted, not deleted, so the first COMMIT after this
 *     daemon boots still cannot lose data.
 *
 * Bootstrap caveat, stated where the code is: the FIRST upgrade of a card that
 * still runs the previous daemon is executed by that previous daemon, with the
 * destructive rm -rf. Fixing this file cannot protect that attempt, so the host
 * side must snapshot the live trio (and keep the matching release tar) before it.
 *
 * Host-testable: no mount(), no /dev/mem, no PL. The caller passes a directory it
 * owns exclusively, exactly like qpcie_file_transaction.h.
 */
#ifndef QPCIE_BACKUP_RETENTION_H
#define QPCIE_BACKUP_RETENTION_H

#include "qpcie_commit_helpers.h"
#include "qpcie_file_transaction.h"

#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <time.h>
#include <unistd.h>

#define QBR_ROOT_NAME       ".backup_upgrade"
#define QBR_TXN_PREFIX      "txn-"
#define QBR_GEN_PREFIX      "gen-"
#define QBR_MAX_GENERATIONS 2u
#define QBR_MAX_ENTRIES     128
/* The BOOT partition is vfat, which reserves nothing for anyone. A COMMIT that
 * runs the partition out of space while copying the old image into a new backup
 * generation leaves a truncated BOOT.BIN behind - and the daemon cannot journal
 * its way out of that. This is the free space that must still be available after
 * the backup copies are made (BOOT.BIN + image.ub + boot.scr is ~50 MB today,
 * so 64 MB keeps room for the journal and for the next attempt). */
#define QBR_MIN_FREE_BYTES  ((unsigned long long)64u << 20)
/* Never drop the newest generation for space; below this many generations the
 * retention simply stops pruning and lets qbr_room() refuse the COMMIT instead. */
#define QBR_MIN_GENERATIONS 1u

/* State of one transaction directory. */
enum qbr_state {
    QBR_ABSENT = 0,     /* no state file at all                    */
    QBR_PREPARED,       /* backups durable, new bytes not written  */
    QBR_APPLYING,       /* mid-write: recovery must restore        */
    QBR_COMMITTED,      /* finished successfully                   */
    QBR_ROLLED_BACK,    /* finished by recovery                    */
    QBR_UNKNOWN         /* unreadable or unrecognised: needs review */
};

static inline enum qbr_state qbr_read_state(const char *dir) {
    char path[600];
    int n0 = snprintf(path, sizeof path, "%s/state", dir);
    if (n0 < 0 || (size_t)n0 >= sizeof path) return QBR_UNKNOWN;
    int fd = open(path, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return QBR_ABSENT;
    char buf[32] = {0};
    ssize_t n = read(fd, buf, sizeof buf - 1);
    close(fd);
    if (n <= 0) return QBR_ABSENT;
    if (!strcmp(buf, "COMMITTED\n"))   return QBR_COMMITTED;
    if (!strcmp(buf, "ROLLED_BACK\n")) return QBR_ROLLED_BACK;
    if (!strcmp(buf, "APPLYING\n"))    return QBR_APPLYING;
    if (!strcmp(buf, "PREPARED\n"))    return QBR_PREPARED;
    return QBR_UNKNOWN;
}

static inline int qbr_is_dir(const char *path) {
    struct stat st;
    return lstat(path, &st) == 0 && S_ISDIR(st.st_mode);
}

/* Directories whose name starts with prefix, oldest-name-first. Names are
 * zero-padded epoch seconds, so lexicographic order is chronological. */
static unsigned qbr_list(const char *root, const char *prefix,
                         char out[QBR_MAX_ENTRIES][300]) {
    DIR *d = opendir(root);
    if (!d) return 0;
    unsigned n = 0;
    size_t plen = strlen(prefix);
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (strlen(e->d_name) <= plen || strncmp(e->d_name, prefix, plen) != 0) continue;
        char full[600];
        if (snprintf(full, sizeof full, "%s/%s", root, e->d_name) >= (int)sizeof full) continue;
        if (!qbr_is_dir(full)) continue;
        if (n < QBR_MAX_ENTRIES) {
            snprintf(out[n], 300, "%s", e->d_name);
            n++;
        }
    }
    closedir(d);
    for (unsigned i = 1; i < n; i++) {           /* insertion sort by name */
        char tmp[300];
        int j = (int)i - 1;
        snprintf(tmp, sizeof tmp, "%s", out[i]);
        while (j >= 0 && strcmp(out[j], tmp) > 0) {
            snprintf(out[j + 1], 300, "%s", out[j]);
            j--;
        }
        snprintf(out[j + 1], 300, "%s", tmp);
    }
    return n;
}

/* A transaction is in flight when its journal says PREPARED/APPLYING, when the
 * journal is missing but backups already exist (crash between the first copy and
 * the first mark), or when the journal cannot be parsed. All three must be
 * recovered, none may be deleted. */
static inline int qbr_txn_in_flight(const char *dir) {
    enum qbr_state s = qbr_read_state(dir);
    if (s == QBR_PREPARED || s == QBR_APPLYING || s == QBR_UNKNOWN) return 1;
    if (s == QBR_ABSENT) {
        char p[600];
        if (snprintf(p, sizeof p, "%s/BOOT.BIN", dir) >= (int)sizeof p) return 1;
        return access(p, F_OK) == 0;
    }
    return 0;
}

/* Bytes held by the three boot components inside one directory. */
static unsigned long long qbr_payload_bytes(const char *dir) {
    static const char *names[3] = { "BOOT.BIN", "image.ub", "boot.scr" };
    unsigned long long total = 0;
    for (int i = 0; i < 3; i++) {
        char p[600];
        struct stat st;
        if (snprintf(p, sizeof p, "%s/%s", dir, names[i]) >= (int)sizeof p) continue;
        if (stat(p, &st) == 0 && S_ISREG(st.st_mode)) total += (unsigned long long)st.st_size;
    }
    return total;
}

/* What one COMMIT actually has to fit on the BOOT partition.
 *
 * The copy being made is the *current* trio on the card, not the incoming one:
 * qtx_apply() reads mount_dir and writes the backup. Asking only about
 * STAGING_DIR therefore estimated the wrong thing, and estimated it optimistically
 * exactly when it mattered - a card whose live BOOT.BIN/image.ub are bigger than
 * the package being installed (which is what happens when a smaller image follows
 * a bigger one) looked like it had room, started copying, and could run out of
 * space halfway through a BOOT.BIN. The worst case is the maximum of the two. */
static unsigned long long qbr_commit_need_bytes(const char *staging_dir,
                                               const char *mount_dir) {
    unsigned long long new_bytes = qbr_payload_bytes(staging_dir);
    unsigned long long live_bytes = qbr_payload_bytes(mount_dir);
    return new_bytes > live_bytes ? new_bytes : live_bytes;
}

/* Free bytes available to the daemon on the mounted BOOT partition. */
static unsigned long long qbr_free_bytes(const char *mount_dir) {
    struct statvfs sv;
    if (statvfs(mount_dir, &sv) != 0) return 0;      /* unknown == no room */
    return (unsigned long long)sv.f_bavail * (unsigned long long)sv.f_frsize;
}

/* Refuse early rather than half-copy: `need` bytes must still be free AFTER the
 * copy, so the check is free >= need + QBR_MIN_FREE_BYTES. Returns 0 when there is
 * room, -1 (with a reason) when a COMMIT must not start. */
static int qbr_room(const char *mount_dir, unsigned long long need, char *why, size_t cap) {
    unsigned long long free_now = qbr_free_bytes(mount_dir);
    if (free_now >= need + QBR_MIN_FREE_BYTES) return 0;
    snprintf(why, cap ? cap : 1, "%s has %llu bytes free; a backup generation of %llu "
                 "bytes plus %llu bytes of reserve does not fit. Nothing was staged; "
                 "delete nothing by hand - free the BOOT partition or lower retention.",
             mount_dir, free_now, need, (unsigned long long)QBR_MIN_FREE_BYTES);
    return -1;
}

/* Deterministic core of every retention decision: keep the newest `keep`
 * finished generations and delete older ones, never a transaction that is still
 * in flight, never a generation that has not been marked finished. */
static int qbr_prune_oldest(const char *root, unsigned keep) {
    char all[QBR_MAX_ENTRIES][300];
    unsigned n = qbr_list(root, QBR_GEN_PREFIX, all);
    if (keep < QBR_MIN_GENERATIONS) keep = QBR_MIN_GENERATIONS;
    /* Only generations with a finished journal count towards retention, and only
     * they may be removed. A directory that has bytes but no verdict is not a
     * recovery set yet, so it must not consume a retention slot and push a good
     * generation out; nor may it ever be deleted, because its bytes may be the
     * only copy of what the card had before the interrupted COMMIT. */
    char finished[QBR_MAX_ENTRIES][300];
    unsigned f = 0;
    for (unsigned i = 0; i < n; i++) {
        char full[600];
        if (snprintf(full, sizeof full, "%s/%s", root, all[i]) >= (int)sizeof full) break;
        if (!qbr_txn_in_flight(full)) {
            if (f < QBR_MAX_ENTRIES) snprintf(finished[f++], sizeof finished[0], "%s", all[i]);
        }
    }
    char txn[QBR_MAX_ENTRIES][300];
    unsigned t = qbr_list(root, QBR_TXN_PREFIX, txn);
    for (unsigned i = 0; i < t; i++) {
        char full[600];
        if (snprintf(full, sizeof full, "%s/%s", root, txn[i]) >= (int)sizeof full) return 0;
        if (qbr_txn_in_flight(full)) return 0;   /* unfinished bytes are untouchable */
    }
    unsigned removed = 0;
    for (unsigned i = 0; i + keep < f; i++) {
        char full[600], cmd[700];
        if (snprintf(full, sizeof full, "%s/%s", root, finished[i]) >= (int)sizeof full) break;
        if (qbr_txn_in_flight(full)) continue;
        if (snprintf(cmd, sizeof cmd, "rm -rf '%s'", full) >= (int)sizeof cmd) break;
        if (system(cmd) != 0) break;
        removed++;
    }
    return (int)removed;
}

/* Space-driven pruning: shrink the kept-generation count until the partition has
 * QBR_MIN_FREE_BYTES free again, stopping at QBR_MIN_GENERATIONS. Called after a
 * promotion, when the new generation is already on disk. */
static int qbr_prune_for_space(const char *root, const char *mount_dir) {
    for (unsigned keep = QBR_MAX_GENERATIONS;;) {
        if (qbr_free_bytes(mount_dir) >= QBR_MIN_FREE_BYTES) return 0;
        int removed = qbr_prune_oldest(root, keep);
        if (keep <= QBR_MIN_GENERATIONS || removed <= 0) break;
        keep--;
    }
    return qbr_free_bytes(mount_dir) >= QBR_MIN_FREE_BYTES ? 0 : -1;
}

/* Name of the newest finished generation directory, if any. Generations are
 * named gen-<zero-padded epoch>-<n>, so the lexicographically last one that is not
 * in flight is the newest. Used as the retention reference below. */
static int qbr_newest_generation(const char *root, char *out, size_t cap);

/* How many generation names exist at all (in-flight included). Cheap, allocates
 * nothing, and exists for one reason: the COMMIT log must say out loud when a
 * COMMIT is the first backup this card ever had, because "rollback is available"
 * is only true from the second one onward. */
static unsigned qbr_generation_count(const char *root) {
    DIR *d = opendir(root);
    if (!d) return 0;
    unsigned n = 0;
    size_t plen = strlen(QBR_GEN_PREFIX);
    struct dirent *e;
    while ((e = readdir(d)) != NULL)
        if (strncmp(e->d_name, QBR_GEN_PREFIX, plen) == 0) n++;
    closedir(d);
    return n;
}

static int qbr_newest_generation(const char *root, char *out, size_t cap) {
    char names[QBR_MAX_ENTRIES][300];
    unsigned n = qbr_list(root, QBR_GEN_PREFIX, names);
    for (unsigned i = n; i-- > 0;) {
        char full[600];
        if (snprintf(full, sizeof full, "%s/%s", root, names[i]) >= (int)sizeof full) return -1;
        if (qbr_txn_in_flight(full)) continue;
        if (snprintf(out, cap, "%s", full) >= (int)cap) return -1;
        return 0;
    }
    return -1;
}

/* Retention with a preference. Removes superseded generations beyond
 * QBR_MAX_GENERATIONS, oldest first, with one extra rule when `keep_reference`
 * (the newest generation) is supplied: a generation whose BOOT.BIN is not provably
 * byte-identical to the reference is never removed, because it is a distinct
 * recovery image and the only one of its kind. With nullptr the call degrades to
 * "keep the newest N", which is why the daemon always passes the reference. */
static int qbr_prune(const char *root, const char *keep_reference) {
    char names[QBR_MAX_ENTRIES][300];
    unsigned n = qbr_list(root, QBR_GEN_PREFIX, names);
    if (n <= QBR_MAX_GENERATIONS) return 0;
    /* Never prune while a transaction is unfinished: the bytes it holds may be
     * the only recoverable set on the card. */
    char txn[QBR_MAX_ENTRIES][300];
    if (qbr_list(root, QBR_TXN_PREFIX, txn) > 0) {
        for (unsigned i = 0; i < qbr_list(root, QBR_TXN_PREFIX, txn); i++) {
            char full[600];
            if (snprintf(full, sizeof full, "%s/%s", root, txn[i]) >= (int)sizeof full) continue;
            if (qbr_txn_in_flight(full)) return 0;
        }
    }
    unsigned removed = 0;
    for (unsigned i = 0; i + QBR_MAX_GENERATIONS < n; i++) {
        char full[600];
        if (snprintf(full, sizeof full, "%s/%s", root, names[i]) >= (int)sizeof full) break;
        if (keep_reference) {
            char cand[600], ref[600];
            if (snprintf(cand, sizeof cand, "%s/BOOT.BIN", full) >= (int)sizeof cand) break;
            if (snprintf(ref, sizeof ref, "%s/BOOT.BIN", keep_reference) >= (int)sizeof ref) break;
            struct stat a, b;
            /* PROTECTED, not droppable: this generation's BOOT.BIN is not the bytes
             * the reference generation holds, so it is the only copy of something.
             * Anything that cannot be *proven* identical (unreadable, different
             * size) is protected too - failing closed costs a disk block, failing
             * open costs the last rollback image. Generations that are byte-identical
             * to the reference are the duplicates, and only they are removed here. */
            int identical = 0;
            if (stat(cand, &a) == 0 && stat(ref, &b) == 0 && a.st_size == b.st_size &&
                qch_files_equal(cand, ref))
                identical = 1;
            if (!identical) continue;
        }
        /* Only directories that finished are ever removed. */
        if (qbr_txn_in_flight(full)) continue;
        char cmd[700];
        if (snprintf(cmd, sizeof cmd, "rm -rf '%s'", full) >= (int)sizeof cmd) break;
        if (system(cmd) != 0) break;
        removed++;
    }
    return (int)removed;
}

/* Adopt the pre-existing single-directory layout: before this policy the journal
 * and the three backups sat directly inside .backup_upgrade, which is now the
 * retention root. The root cannot be renamed into itself, so its payload files are
 * moved down into a generation directory instead and the root stays a root.
 * Returns 0 nothing to do, 1 adopted, -1 recovery of an interrupted legacy
 * transaction failed (the caller must then refuse to flash anything). */
static int qbr_adopt_legacy(const char *mount_dir, const char *root, char *why, size_t cap) {
    char state[600];
    if (snprintf(state, sizeof state, "%s/state", root) >= (int)sizeof state) return -1;
    struct stat st;
    if (lstat(state, &st) != 0 || !S_ISREG(st.st_mode)) return 0;
    enum qbr_state s = qbr_read_state(root);
    if (s == QBR_PREPARED || s == QBR_APPLYING || s == QBR_UNKNOWN) {
        int rc = qtx_recover(mount_dir, root);
        if (rc != 0) {
            snprintf(why, cap, "legacy %s transaction is in state %d and qtx_recover "
                               "returned %d; refusing to touch the retention root",
                     root, (int)s, rc);
            return -1;
        }
    }
    char dst[600];
    snprintf(dst, sizeof dst, "%s/gen-0000000000-legacy", root);
    if (access(dst, F_OK) != 0 && mkdir(dst, 0700) != 0 && errno != EEXIST) {
        snprintf(why, cap, "cannot create adopted generation %s: %s", dst, strerror(errno));
        return -1;
    }
    /* Move every regular file of the legacy transaction into the generation
     * directory. Nothing is copied-and-deleted: rename(2) on the same vfat
     * filesystem is atomic, so a power cut cannot lose a byte mid-adoption. */
    DIR *d = opendir(root);
    if (!d) {
        snprintf(why, cap, "cannot read %s: %s", root, strerror(errno));
        return -1;
    }
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        char src[600], to[600];
        if (snprintf(src, sizeof src, "%s/%s", root, e->d_name) >= (int)sizeof src) continue;
        if (lstat(src, &st) != 0 || !S_ISREG(st.st_mode)) continue;
        if (snprintf(to, sizeof to, "%s/%s", dst, e->d_name) >= (int)sizeof to) continue;
        if (rename(src, to) != 0) {
            closedir(d);
            snprintf(why, cap, "could not adopt legacy file %s into %s: %s",
                     src, dst, strerror(errno));
            return -1;
        }
    }
    closedir(d);
    return 1;
}

/* Create one fresh transaction directory. Fails rather than reusing a name, so a
 * transaction can never write into an existing recovery set. */
static int qbr_begin(const char *mount_dir, const char *root, char *out, size_t cap,
                     char *why, size_t wcap) {
    (void)mount_dir;
    if (mkdir(root, 0700) != 0 && errno != EEXIST) {
        snprintf(why, wcap, "cannot create %s: %s", root, strerror(errno));
        return -1;
    }
    time_t now = time(NULL);
    for (unsigned n = 0; n < 1024; n++) {
        char cand[600], would_be_gen[600];
        if (snprintf(cand, sizeof cand, "%s/%s%010ld-%u", root, QBR_TXN_PREFIX,
                     (long)now, n) >= (int)sizeof cand) return -1;
        /* Two COMMITs inside the same clock second are normal (a retry after a
         * rejected VERIFY). The promoted name must be free too, otherwise the
         * transaction would be created under a name whose generation already
         * exists and the promote step would have to overwrite history. */
        if (snprintf(would_be_gen, sizeof would_be_gen, "%s/%s%010ld-%u", root,
                     QBR_GEN_PREFIX, (long)now, n) >= (int)sizeof would_be_gen) return -1;
        if (access(would_be_gen, F_OK) == 0) continue;
        if (mkdir(cand, 0700) == 0) {
            if (snprintf(out, cap, "%s", cand) >= (int)cap) return -1;
            return 0;
        }
        if (errno != EEXIST) {
            snprintf(why, wcap, "cannot create %s: %s", cand, strerror(errno));
            return -1;
        }
    }
    snprintf(why, wcap, "no free transaction directory name under %s", root);
    return -1;
}

/* Turn a finished transaction into a generation. rename() on the same filesystem
 * is atomic, so there is no window in which the bytes have no name. */
static int qbr_promote(const char *root, const char *txn, char *why, size_t wcap) {
    const char *base = strrchr(txn, '/');
    base = base ? base + 1 : txn;
    if (strncmp(base, QBR_TXN_PREFIX, strlen(QBR_TXN_PREFIX)) != 0) {
        snprintf(why, wcap, "%s is not a transaction directory", txn);
        return -1;
    }
    char dst[600];
    snprintf(dst, sizeof dst, "%s/%s%s", root, QBR_GEN_PREFIX,
             base + strlen(QBR_TXN_PREFIX));
    if (access(dst, F_OK) == 0) {
        snprintf(why, wcap, "refusing to overwrite existing generation %s", dst);
        return -1;
    }
    if (rename(txn, dst) != 0) {
        snprintf(why, wcap, "rename %s -> %s failed: %s", txn, dst, strerror(errno));
        return -1;
    }
    return 0;
}

/* Startup / pre-COMMIT recovery. Recovers the newest in-flight transaction and
 * adopts a legacy directory. Returns 0 when the retention root is safe to use,
 * -1 when an operator must look at it (the caller must then refuse to flash). */
static int qbr_recover_all(const char *mount_dir, const char *root, char *why, size_t cap) {
    if (!qbr_is_dir(root)) return 0;
    int rc = qbr_adopt_legacy(mount_dir, root, why, cap);
    if (rc < 0) return -1;
    char names[QBR_MAX_ENTRIES][300];
    unsigned n = qbr_list(root, QBR_TXN_PREFIX, names);
    for (unsigned i = 0; i < n; i++) {
        char full[600];
        if (snprintf(full, sizeof full, "%s/%s", root, names[i]) >= (int)sizeof full) continue;
        enum qbr_state s = qbr_read_state(full);
        if (s == QBR_COMMITTED || s == QBR_ROLLED_BACK) {
            /* A finished transaction that was never promoted (crash between
             * qtx_apply and promote) becomes a generation, not garbage. */
            char w[300];
            if (qbr_promote(root, full, w, sizeof w) != 0) return -1;
            continue;
        }
        if (!qbr_txn_in_flight(full)) continue;
        int r = qtx_recover(mount_dir, full);
        if (r != 0) {
            snprintf(why, cap, "transaction %s is in state %d and qtx_recover returned "
                               "%d; the card must not be reflashed until this is reviewed",
                     full, (int)s, r);
            return -1;
        }
        char w[300];
        if (qbr_promote(root, full, w, sizeof w) != 0) return -1;
    }
    return 0;
}
#endif /* QPCIE_BACKUP_RETENTION_H */
