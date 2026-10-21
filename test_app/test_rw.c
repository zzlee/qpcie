#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>

int main(void) {
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open"); return 1; }
    volatile uint32_t *p = mmap(NULL, 0x1000, PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0xB0000000);
    if (p == MAP_FAILED) { perror("mmap"); return 1; }

    uint32_t test_offsets[] = {
        0x00C, 0x010, 0x014, 0x01C, 0x024, 0x02C, 0x030, 0x038, 
        0x068, 0x06C, 0x070, 0x074, 0x07C, 0x080, 0x100, 0x108,
        0x10C, 0x110, 0x114, 0x120, 0x134, 0x140, 0x154, 
        0x200, 0x208, 0x214, 0x218, 0x300, 0x308, 0x30C
    };
    int n = sizeof(test_offsets)/sizeof(test_offsets[0]);

    printf("Testing writes to Video PHY registers (0xB0000000):\n");
    for (int i = 0; i < n; i++) {
        uint32_t off = test_offsets[i];
        uint32_t orig = p[off/4];
        uint32_t test_val = (off == 0x208) ? 0x5F5E1000 : 0xA5A5A5A5;
        p[off/4] = test_val;
        uint32_t rb = p[off/4];
        // Restore orig if safe
        if (off != 0x014 && off != 0x024) p[off/4] = orig;
        printf("  [0x%03X] orig=0x%08X wrote=0x%08X rb=0x%08X %s\n",
               off, orig, test_val, rb, (rb != orig) ? "--> WRITABLE" : "(same)");
    }

    munmap((void*)p, 0x1000);
    close(fd);
    return 0;
}
