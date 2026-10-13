// Read-only DDR content comparison through BAR0. No DMA or upgrade doorbell.
// Verifies any 16-byte-multiple file against the staging window at
// PS DDR 0x30000000 + STAGING_OFFSET, in 16-byte BAR0 readback blocks.
#define _POSIX_C_SOURCE 200809L
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define STAGING_BASE 0x30000000u
#define STAGING_SIZE (64u * 1024u * 1024u)

static void delay(void) {
    struct timespec t = {.tv_nsec = 1000000};
    nanosleep(&t, NULL);
}

int main(int argc, char **argv) {
    if (argc != 3 && argc != 4) {
        fprintf(stderr, "usage: %s RESOURCE0 FILE [STAGING_OFFSET]\n", argv[0]);
        return 2;
    }
    unsigned long base_off = 0;
    if (argc == 4) {
        char *end = NULL;
        base_off = strtoul(argv[3], &end, 0);
        if (!end || *end || (base_off & 0xf)) {
            fprintf(stderr, "STAGING_OFFSET must be a 16-byte aligned number\n");
            return 2;
        }
    }
    struct stat st;
    if (stat(argv[2], &st) || st.st_size <= 0 || (st.st_size & 0xf) ||
        (uint64_t)base_off + (uint64_t)st.st_size > STAGING_SIZE) {
        fprintf(stderr, "file must be non-empty, multiple of 16 bytes, fitting in 64MB staging\n");
        return 1;
    }
    size_t total = (size_t)st.st_size;
    unsigned char *expected = malloc(total);
    if (!expected) { perror("malloc"); return 1; }
    FILE *f = fopen(argv[2], "rb");
    if (!f) { perror("file"); free(expected); return 1; }
    size_t n = fread(expected, 1, total, f);
    int extra = fgetc(f), bad = ferror(f);
    fclose(f);
    if (n != total || extra != EOF || bad) {
        fprintf(stderr, "short read of input file\n"); free(expected); return 1;
    }
    int fd = open(argv[1], O_RDWR | O_SYNC);
    if (fd < 0) { perror("resource0"); free(expected); return 1; }
    volatile uint32_t *r = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (r == MAP_FAILED) { perror("mmap"); close(fd); free(expected); return 1; }
    int result = 1;
    if (r[0] != 0x12abe380 || (r[1] != 0x26101301 && r[1] != 0x26101302)) {
        fprintf(stderr, "requires 26101301/26101302 readback RTL, got %08x\n", r[1]); goto out;
    }
    if (r[0x780/4] & 1) { fprintf(stderr, "DMA START active; refusing\n"); goto out; }
    for (size_t off = 0; off < total; off += 16) {
        if (r[0x7c4/4] & 1) { fprintf(stderr, "readback already BUSY\n"); goto out; }
        uint32_t seq = r[0x7c8/4];
        r[0x7c0/4] = (uint32_t)(base_off + off);
        (void)r[0x7c0/4];
        r[0x7c4/4] = 1;
        (void)r[0x7c4/4];
        int done = 0;
        for (int i = 0; i < 100; ++i) {
            uint32_t now = r[0x7c8/4], status = r[0x7c4/4];
            if (now == seq + 1 && (status & 0x1c)) {
                fprintf(stderr, "readback error offset=%zx status=%x; stop, do not retry\n",
                        base_off + off, status);
                goto out;
            }
            if (now == seq + 1 && (status & 3) == 2) { done = 1; break; }
            delay();
        }
        if (!done) {
            fprintf(stderr, "readback timeout offset=%zx; stop, do not retry\n", base_off + off);
            goto out;
        }
        for (unsigned w = 0; w < 4; ++w) {
            uint32_t value = r[0x7d0/4 + w];
            for (unsigned b = 0; b < 4; ++b) {
                unsigned char got = (unsigned char)(value >> (8 * b));
                if (got != expected[off + 4 * w + b]) {
                    fprintf(stderr, "DDR mismatch at 0x%08lx: expected %02x got %02x\n",
                            (unsigned long)(STAGING_BASE + base_off + off + 4 * w + b),
                            expected[off + 4 * w + b], got);
                    goto out;
                }
            }
        }
        if (r[0x7c8/4] != seq + 1 || (r[0x7c4/4] & 0x1f) != 2) {
            fprintf(stderr, "record changed during read; exclusive access required\n"); goto out;
        }
        if ((off & 0xfffff) == 0 && off) {
            fprintf(stderr, "verify progress: %zu/%zu bytes\n", off, total);
        }
    }
    printf("DDR_VERIFY_PASS: all %zu bytes at PS DDR 0x%08lx match %s\n",
           total, (unsigned long)(STAGING_BASE + base_off), argv[2]);
    result = 0;
out:
    munmap((void *)r, 4096); close(fd); free(expected); return result;
}
