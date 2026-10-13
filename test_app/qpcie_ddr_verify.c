// Read-only DDR content comparison through BAR0. No DMA or upgrade doorbell.
#define _POSIX_C_SOURCE 200809L
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
static void delay(void) {
    struct timespec t = {.tv_nsec = 1000000};
    nanosleep(&t, NULL);
}
int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s RESOURCE0 EXACT_4096_BYTE_CANARY\n", argv[0]);
        return 2;
    }
    unsigned char expected[4096], actual[4096];
    FILE *f = fopen(argv[2], "rb");
    if (!f) { perror("canary"); return 1; }
    size_t n = fread(expected, 1, sizeof expected, f);
    int extra = fgetc(f), bad = ferror(f);
    fclose(f);
    if (n != sizeof expected || extra != EOF || bad) {
        fprintf(stderr, "canary must contain exactly 4096 bytes\n"); return 1;
    }
    int fd = open(argv[1], O_RDWR | O_SYNC);
    if (fd < 0) { perror("resource0"); return 1; }
    volatile uint32_t *r = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (r == MAP_FAILED) { perror("mmap"); close(fd); return 1; }
    int result = 1;
    if (r[0] != 0x12abe380 || r[1] != 0x26101301) {
        fprintf(stderr, "requires 26101301 readback RTL, got %08x\n", r[1]); goto out;
    }
    if (r[0x780/4] & 1) { fprintf(stderr, "DMA START active; refusing\n"); goto out; }
    for (unsigned off = 0; off < 4096; off += 16) {
        if (r[0x7c4/4] & 1) { fprintf(stderr, "readback already BUSY\n"); goto out; }
        uint32_t seq = r[0x7c8/4];
        r[0x7c0/4] = off;
        (void)r[0x7c0/4];
        r[0x7c4/4] = 1;
        (void)r[0x7c4/4];
        int done = 0;
        for (int i = 0; i < 100; ++i) {
            uint32_t now = r[0x7c8/4], status = r[0x7c4/4];
            if (now == seq + 1 && (status & 0x1c)) {
                fprintf(stderr, "readback error offset=%x status=%x; stop, do not retry\n", off, status);
                goto out;
            }
            if (now == seq + 1 && (status & 3) == 2) { done = 1; break; }
            delay();
        }
        if (!done) { fprintf(stderr, "readback timeout offset=%x; stop, do not retry\n", off); goto out; }
        for (unsigned w = 0; w < 4; ++w) {
            uint32_t value = r[0x7d0/4 + w];
            for (unsigned b = 0; b < 4; ++b) actual[off + 4*w + b] = value >> (8*b);
        }
        if (r[0x7c8/4] != seq + 1 || (r[0x7c4/4] & 0x1f) != 2) {
            fprintf(stderr, "record changed during read; exclusive access required\n"); goto out;
        }
    }
    for (unsigned i = 0; i < 4096; ++i) {
        if (actual[i] != expected[i]) {
            fprintf(stderr, "DDR mismatch at 0x%08x: expected %02x got %02x\n",
                    0x30000000 + i, expected[i], actual[i]); goto out;
        }
    }
    puts("DDR_VERIFY_PASS: all 4096 bytes at PS DDR 0x30000000 match canary");
    result = 0;
out:
    munmap((void *)r, 4096); close(fd); return result;
}
