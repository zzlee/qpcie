#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>

int main(void) {
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open"); return 1; }
    volatile uint32_t *vphy = mmap(NULL, 0x1000, PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0xB0000000);
    if (vphy == MAP_FAILED) { perror("mmap vphy"); return 1; }

    printf("--- Video PHY Registers (0xB0000000) ---\n");
    for (uint32_t off = 0x000; off <= 0x230; off += 4) {
        uint32_t val = vphy[off / 4];
        if (val != 0 || off == 0x010 || off == 0x018 || off == 0x020 || off == 0x028 || off == 0x200 || off == 0x204 || off == 0x210) {
            printf("  [0x%03X] = 0x%08X\n", off, val);
        }
    }

    volatile uint32_t *hdmi = mmap(NULL, 0x1000, PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0xB0010000);
    if (hdmi != MAP_FAILED) {
        printf("\n--- HDMI RX SS Registers (0xB0010000) ---\n");
        for (uint32_t off = 0x000; off <= 0x100; off += 4) {
            uint32_t val = hdmi[off / 4];
            if (val != 0 || off == 0x000 || off == 0x050 || off == 0x064 || off == 0x0D0 || off == 0x0D8 || off == 0x0E0) {
                printf("  [0x%03X] = 0x%08X\n", off, val);
            }
        }
        munmap((void*)hdmi, 0x1000);
    }

    munmap((void*)vphy, 0x1000);
    close(fd);
    return 0;
}
