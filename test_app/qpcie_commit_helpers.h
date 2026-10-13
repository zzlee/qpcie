/* qpcie_commit_helpers.h - testable file operations for the SC7F0 upgrade COMMIT path.
 *
 * Used by qpcie_upgrade_daemon.c (aarch64, static) and by the host-side unit
 * test tb/qpcie_commit_helpers_tb.c (x86_64). All functions operate on
 * explicit paths and return 0 on success, -1 on failure. No globals.
 */
#ifndef QPCIE_COMMIT_HELPERS_H
#define QPCIE_COMMIT_HELPERS_H

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define QCH_COPY_BUF (64u * 1024u)

/* Device mappings must not be passed to libc memcpy/fwrite: optimized
 * implementations may issue unaligned accesses forbidden by ARM Device memory.
 * Volatile byte loads preserve the access width, including arbitrary tails. */
static inline void qch_device_snapshot(unsigned char *dst,
                                const volatile unsigned char *src, size_t len) {
    for (size_t i = 0; i < len; ++i) dst[i] = src[i];
}

/* Copy src file to dst file (truncate/create 0644), fsync before close.
 * Returns 0 on full success, -1 otherwise (dst may be partial). */
static inline int qch_copy_file(const char *src, const char *dst) {
    FILE *fin = fopen(src, "rb");
    if (!fin) return -1;
    FILE *fout = fopen(dst, "wb");
    if (!fout) { fclose(fin); return -1; }
    static unsigned char buf[QCH_COPY_BUF];
    size_t n;
    int rc = 0;
    while ((n = fread(buf, 1, sizeof buf, fin)) > 0) {
        if (fwrite(buf, 1, n, fout) != n) { rc = -1; break; }
    }
    if (ferror(fin)) rc = -1;
    if (fclose(fin) != 0) rc = -1;
    if (fflush(fout) != 0) rc = -1;
    int fd = fileno(fout);
    if (fd >= 0 && fsync(fd) != 0) rc = -1;
    if (fclose(fout) != 0) rc = -1;
    return rc;
}

/* Compare two regular files byte-for-byte.
 * Returns 1 if equal, 0 if different, -1 on I/O error. */
static inline int qch_files_equal(const char *a, const char *b) {
    FILE *fa = fopen(a, "rb");
    FILE *fb = fopen(b, "rb");
    if (!fa || !fb) {
        if (fa) fclose(fa);
        if (fb) fclose(fb);
        return -1;
    }
    static unsigned char ba[QCH_COPY_BUF], bb[QCH_COPY_BUF];
    int result = 1;
    for (;;) {
        size_t na = fread(ba, 1, sizeof ba, fa);
        size_t nb = fread(bb, 1, sizeof bb, fb);
        if (na != nb || memcmp(ba, bb, na) != 0) { result = 0; break; }
        if (na == 0) break; /* both EOF together */
    }
    if (ferror(fa) || ferror(fb)) result = -1;
    fclose(fa);
    fclose(fb);
    return result;
}

/* Compare the first `len` bytes of a block device (or file) with a file.
 * Returns 1 if equal, 0 if different, -1 on I/O error. */
static inline int qch_block_prefix_equal(const char *dev, const char *file, size_t len) {
    FILE *fd = fopen(dev, "rb");
    FILE *ff = fopen(file, "rb");
    if (!fd || !ff) {
        if (fd) fclose(fd);
        if (ff) fclose(ff);
        return -1;
    }
    static unsigned char bd[QCH_COPY_BUF], bf[QCH_COPY_BUF];
    size_t left = len;
    int result = 1;
    while (left > 0) {
        size_t want = left < sizeof bd ? left : sizeof bd;
        size_t nd = fread(bd, 1, want, fd);
        size_t nf = fread(bf, 1, want, ff);
        if (nd != want || nf != want || memcmp(bd, bf, want) != 0) {
            result = (nd == want && nf == want) ? 0 : -1;
            break;
        }
        left -= want;
    }
    /* file must not be longer than len */
    if (result == 1 && fgetc(ff) != EOF) result = 0;
    if (ferror(fd) || ferror(ff)) result = -1;
    fclose(fd);
    fclose(ff);
    return result;
}

/* Copy `len` bytes from file to block device (or file) with fsync.
 * Returns 0 on full success, -1 otherwise. */
static inline int qch_block_write(const char *file, const char *dev, size_t len) {
    FILE *ff = fopen(file, "rb");
    if (!ff) return -1;
    int fd = open(dev, O_WRONLY);
    if (fd < 0) { fclose(ff); return -1; }
    static unsigned char buf[QCH_COPY_BUF];
    size_t left = len;
    int rc = 0;
    while (left > 0) {
        size_t want = left < sizeof buf ? left : sizeof buf;
        size_t nr = fread(buf, 1, want, ff);
        if (nr != want) { rc = -1; break; }
        size_t off = 0;
        while (off < want) {
            ssize_t nw = write(fd, buf + off, want - off);
            if (nw <= 0) { rc = -1; break; }
            off += (size_t)nw;
        }
        if (rc) break;
        left -= want;
    }
    if (fsync(fd) != 0) rc = -1;
    if (close(fd) != 0) rc = -1;
    if (fclose(ff) != 0) rc = -1;
    return rc;
}

/* Regular-file size in bytes, or (size_t)-1 on error. */
static inline size_t qch_file_size(const char *path) {
    struct stat st;
    if (stat(path, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size < 0)
        return (size_t)-1;
    return (size_t)st.st_size;
}

#endif /* QPCIE_COMMIT_HELPERS_H */
