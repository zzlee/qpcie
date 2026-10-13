// Host-only staged push through the firmware_upgrade sysfs channel.
// The kernel caps each bin_attribute write at 4096 bytes, so this tool
// loops 4K blocks with lseek positioning and per-block retry. It never
// rings the doorbell and never touches eMMC; completion is verified
// separately with qpcie_ddr_verify.
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define STAGING_SIZE (64u * 1024u * 1024u)
#define BLOCK 4096
#define MAX_RETRY 5

static double now_sec(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

int main(int argc, char **argv) {
    if (argc != 4) {
        fprintf(stderr, "usage: %s SYSFS_FIRMWARE_UPGRADE FILE STAGING_OFFSET\n", argv[0]);
        return 2;
    }
    char *end = NULL;
    unsigned long base_off = strtoul(argv[3], &end, 0);
    if (!end || *end || (base_off & (BLOCK - 1))) {
        fprintf(stderr, "STAGING_OFFSET must be 4096-byte aligned\n");
        return 2;
    }
    struct stat st;
    if (stat(argv[2], &st) || st.st_size <= 0 || (st.st_size & (BLOCK - 1)) ||
        (uint64_t)base_off + (uint64_t)st.st_size > STAGING_SIZE) {
        fprintf(stderr, "file must be non-empty, multiple of 4096, fitting in 64MB staging\n");
        return 1;
    }
    size_t total = (size_t)st.st_size;
    FILE *f = fopen(argv[2], "rb");
    if (!f) { perror("file"); return 1; }
    unsigned char *data = malloc(total);
    if (!data) { perror("malloc"); fclose(f); return 1; }
    if (fread(data, 1, total, f) != total) { perror("read"); fclose(f); free(data); return 1; }
    fclose(f);

    int fd = open(argv[1], O_WRONLY);
    if (fd < 0) { perror("sysfs"); free(data); return 1; }
    double t0 = now_sec();
    unsigned retries = 0, blocks = 0;
    for (size_t off = 0; off < total; off += BLOCK) {
        int ok = 0;
        for (int attempt = 0; attempt < MAX_RETRY && !ok; ++attempt) {
            if (lseek(fd, (off_t)(base_off + off), SEEK_SET) < 0) { perror("lseek"); continue; }
            ssize_t n = write(fd, data + off, BLOCK);
            if (n == BLOCK) {
                ok = 1;
            } else {
                ++retries;
                fprintf(stderr, "block %zu: attempt %d failed (%zd, errno=%d); retrying\n",
                        base_off + off, attempt, n, errno);
            }
        }
        if (!ok) {
            fprintf(stderr, "block %zu: FAILED after %d attempts; stop\n", base_off + off, MAX_RETRY);
            close(fd); free(data); return 1;
        }
        ++blocks;
        if ((off & 0xfffff) == 0 && off) {
            double el = now_sec() - t0;
            fprintf(stderr, "push progress: %zu/%zu bytes (%.1f MB/s, retries=%u)\n",
                    off, total, off / 1048576.0 / (el > 0 ? el : 1), retries);
        }
    }
    double el = now_sec() - t0;
    printf("PUSH_PASS: %zu bytes in %.2fs (%.1f MB/s), %u blocks, %u retries\n",
           total, el, total / 1048576.0 / (el > 0 ? el : 1), blocks, retries);
    close(fd); free(data);
    return 0;
}
