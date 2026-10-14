/* Strict ustar reader and manifest verifier.
 * Supports both uncompressed (.tar) and gzip-compressed (.tar.gz).
 * Rejects links, directories, extensions, duplicate members and path traversal.
 * Destination must be a newly created private directory. No shell extraction. */
#ifndef QPCIE_ARCHIVE_VERIFY_H
#define QPCIE_ARCHIVE_VERIFY_H

#include <sys/wait.h>
#include <strings.h>
#include "qpcie_file_transaction.h"
#include "qpcie_sha256.h"

#define QAV_MANIFEST_NAME "manifest.sha256"

static int qav_octal(const unsigned char *p, size_t n, size_t *value) {
    size_t v = 0, i = 0;
    while (i < n && p[i] == ' ') ++i;
    int digits = 0;
    for (; i < n && p[i] >= '0' && p[i] <= '7'; ++i) {
        if (v > (SIZE_MAX - 7) / 8) return -1;
        v = v * 8 + p[i] - '0'; digits = 1;
    }
    for (; i < n; ++i) if (p[i] != 0 && p[i] != ' ') return -1;
    if (!digits) return -1;
    *value = v; return 0;
}

static int qav_zero(const unsigned char *p, size_t n) {
    for (size_t i = 0; i < n; ++i) if (p[i]) return 0;
    return 1;
}

static int qav_tar(FILE *input, const char *destination) {
    unsigned char h[512], buffer[65536];
    unsigned seen = 0;
    size_t total = 0;
    for (;;) {
        if (fread(h, 1, sizeof h, input) != sizeof h) return -1;
        if (qav_zero(h, sizeof h)) {
            if (fread(h, 1, sizeof h, input) != sizeof h || !qav_zero(h, sizeof h)) return -1;
            size_t tail = 0, n;
            while ((n = fread(buffer, 1, sizeof buffer, input))) {
                tail += n;
                if (tail > 1024 * 1024 || !qav_zero(buffer, n)) return -1;
            }
            return ((seen & 7) == 7) && !ferror(input) ? 0 : -1;
        }
        size_t checksum, size;
        if (qav_octal(h + 148, 8, &checksum) || qav_octal(h + 124, 12, &size)) return -1;
        size_t actual = 0;
        for (size_t i = 0; i < sizeof h; ++i) actual += i >= 148 && i < 156 ? ' ' : h[i];
        if (actual != checksum || (h[156] != 0 && h[156] != '0') ||
            !qav_zero(h + 157, 100) || !qav_zero(h + 345, 155) ||
            memcmp(h + 257, "ustar", 5) ||
            !size || size > 64u * 1024u * 1024u || total > 64u * 1024u * 1024u - size) return -1;
        int member = -1;
        const char *member_name = NULL;
        for (unsigned i = 0; i < 3; ++i) {
            size_t len = strlen(qtx_names[i]);
            if (!memcmp(h, qtx_names[i], len) && qav_zero(h + len, 100 - len)) {
                member = (int)i;
                member_name = qtx_names[i];
                break;
            }
        }
        if (member < 0) {
            size_t len = strlen(QAV_MANIFEST_NAME);
            if (!memcmp(h, QAV_MANIFEST_NAME, len) && qav_zero(h + len, 100 - len)) {
                member = 3;
                member_name = QAV_MANIFEST_NAME;
            }
        }
        if (member < 0 || (seen & (1u << member))) return -1;
        seen |= 1u << member; total += size;
        char path[512];
        if (qtx_path(path, sizeof path, destination, member_name)) return -1;
        int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
        if (fd < 0) return -1;
        size_t left = size;
        int rc = 0;
        while (left) {
            size_t want = left < sizeof buffer ? left : sizeof buffer;
            if (fread(buffer, 1, want, input) != want) { rc = -1; break; }
            size_t done = 0;
            while (done < want) {
                ssize_t n = write(fd, buffer + done, want - done);
                if (n < 0 && errno == EINTR) continue;
                if (n <= 0) { rc = -1; break; }
                done += (size_t)n;
            }
            if (rc) break;
            left -= want;
        }
        if (close(fd)) rc = -1;
        if (rc) return -1;
        size_t padding = (512 - size % 512) % 512;
        if (fread(buffer, 1, padding, input) != padding || !qav_zero(buffer, padding)) return -1;
    }
}

static int qav_gzip(const char *archive, const char *destination) {
    int p[2];
    if (pipe(p)) return -1;
    pid_t pid = fork();
    if (pid < 0) { close(p[0]); close(p[1]); return -1; }
    if (!pid) {
        close(p[0]);
        if (dup2(p[1], STDOUT_FILENO) < 0) _exit(127);
        close(p[1]);
        execlp("gzip", "gzip", "-dc", "--", archive, (char *)NULL);
        _exit(127);
    }
    close(p[1]);
    FILE *f = fdopen(p[0], "rb");
    int rc = f ? qav_tar(f, destination) : -1;
    if (f) fclose(f); else close(p[0]);
    int status;
    pid_t result;
    do { result = waitpid(pid, &status, 0); } while (result < 0 && errno == EINTR);
    return rc == 0 && result == pid && WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : -1;
}

/* Auto-detecting extractor: reads directly if uncompressed tar; pipes through gzip if compressed. */
static inline int qav_extract(const char *archive, const char *destination) {
    FILE *f_check = fopen(archive, "rb");
    if (!f_check) return -1;
    unsigned char magic[2] = {0};
    size_t nr = fread(magic, 1, 2, f_check);
    fclose(f_check);
    if (nr < 2) return -1;

    /* Gzip magic: 0x1F, 0x8B */
    if (magic[0] == 0x1F && magic[1] == 0x8B) {
        return qav_gzip(archive, destination);
    }

    /* Uncompressed USTAR archive: read directly (instant, zero-fork) */
    FILE *f = fopen(archive, "rb");
    if (!f) return -1;
    int rc = qav_tar(f, destination);
    fclose(f);
    return rc;
}

/* Verifies all payload files in destination against destination/manifest.sha256.
 * Returns:
 *   0: Manifest valid and all hashes match (or no manifest present for legacy compatibility)
 *  -1: I/O error or missing required file
 *  -2: Cryptographic SHA-256 hash mismatch!
 */
static inline int qav_verify_manifest(const char *destination) {
    char manifest_path[512];
    if (qtx_path(manifest_path, sizeof(manifest_path), destination, QAV_MANIFEST_NAME))
        return -1;

    /* If manifest is not present, allow legacy packages */
    if (access(manifest_path, F_OK) != 0)
        return 0;

    FILE *mf = fopen(manifest_path, "r");
    if (!mf) return -1;

    char line[256];
    int verified_mask = 0;
    while (fgets(line, sizeof(line), mf)) {
        char exp_sha[65] = {0};
        char filename[128] = {0};
        if (sscanf(line, "%64s %127s", exp_sha, filename) != 2)
            continue;

        /* Strip optional leading './' */
        char *f_ptr = filename;
        if (f_ptr[0] == '.' && f_ptr[1] == '/')
            f_ptr += 2;

        int member_idx = -1;
        for (int i = 0; i < 3; i++) {
            if (strcmp(f_ptr, qtx_names[i]) == 0) {
                member_idx = i;
                break;
            }
        }
        if (member_idx < 0) continue;

        char file_path[512];
        if (qtx_path(file_path, sizeof(file_path), destination, f_ptr)) {
            fclose(mf);
            return -1;
        }

        char act_sha[65] = {0};
        if (qpcie_sha256_file(file_path, act_sha) != 0) {
            fclose(mf);
            return -1;
        }

        if (strcasecmp(exp_sha, act_sha) != 0) {
            fclose(mf);
            return -2; /* Hash mismatch */
        }
        verified_mask |= (1 << member_idx);
    }
    fclose(mf);

    /* All 3 mandatory files (BOOT.BIN, image.ub, boot.scr) must have been verified */
    return ((verified_mask & 7) == 7) ? 0 : -1;
}

#endif /* QPCIE_ARCHIVE_VERIFY_H */
