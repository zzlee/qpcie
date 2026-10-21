#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>

int main(void) {
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open"); return 1; }
    volatile uint32_t *p = mmap(NULL, 0x1000, PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0xB0010000);
    if (p == MAP_FAILED) { perror("mmap"); return 1; }

    printf("=== Testing HDMI RX Subsystem (0xB0010000) ===\n");
    for (uint32_t off = 0; off < 0x100; off += 4) {
        uint32_t val = p[off/4];
        if (val != 0 || off == 0x00 || off == 0x40 || off == 0x44 || off == 0x54 || off == 0x80 || off == 0xC0) {
            printf("  [0x%03X] = 0x%08X\n", off, val);
        }
    }

    printf("\n=== Writing to PIO and VTD ===\n");
    printf("Before: PIO_CTRL(0x44)=0x%08X, PIO_OUT(0x54)=0x%08X, VTD_CTRL(0xC4)=0x%08X\n",
           p[0x44/4], p[0x54/4], p[0xC4/4]);

    p[0x48/4] = 0x1;       // PIO CTRL SET: RUN=1
    p[0x58/4] = 0x8000E;   // PIO OUT SET: LnkEn, VidEn, HPD, AxisEn
    p[0xC8/4] = 0x1;       // VTD CTRL SET: RUN=1

    printf("After:  PIO_CTRL(0x44)=0x%08X, PIO_OUT(0x54)=0x%08X, VTD_CTRL(0xC4)=0x%08X\n",
           p[0x44/4], p[0x54/4], p[0xC4/4]);

    munmap((void*)p, 0x1000);
    close(fd);
    return 0;
}
