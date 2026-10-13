/* Strict three-file ustar reader. Input is already decompressed by gzip.
 * Reject links, directories, extensions, duplicate members and path traversal.
 * Destination must be a newly created private directory. No shell extraction. */
#ifndef QPCIE_ARCHIVE_VERIFY_H
#define QPCIE_ARCHIVE_VERIFY_H
#include <sys/wait.h>
#include "qpcie_file_transaction.h"
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
    unsigned char h[512], buffer[4096];
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
            return seen == 7 && !ferror(input) ? 0 : -1;
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
        for (unsigned i = 0; i < 3; ++i) {
            size_t len = strlen(qtx_names[i]);
            if (!memcmp(h, qtx_names[i], len) && qav_zero(h + len, 100 - len)) member = (int)i;
        }
        if (member < 0 || (seen & (1u << member))) return -1;
        seen |= 1u << member; total += size;
        char path[512];
        if (qtx_path(path, sizeof path, destination, qtx_names[member])) return -1;
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
#endif
