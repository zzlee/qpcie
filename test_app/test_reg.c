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
    
    printf("Before write: 0x208 = 0x%08X\n", p[0x208/4]);
    p[0x208/4] = 0x12345678;
    printf("After write:  0x208 = 0x%08X\n", p[0x208/4]);

    printf("Before write: 0x200 = 0x%08X\n", p[0x200/4]);
    p[0x200/4] = 0x10501;
    printf("After write:  0x200 = 0x%08X\n", p[0x200/4]);
    
    munmap((void*)p, 0x1000);
    close(fd);
    return 0;
}
