#include <stdio.h>
#include <stdint.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>

int main(void) {
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open"); return 1; }

    volatile uint32_t *vphy = (volatile uint32_t *)mmap(NULL, 0x1000, PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0xB0000000);
    volatile uint32_t *rx   = (volatile uint32_t *)mmap(NULL, 0x1000, PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0xB0010000);
    volatile uint32_t *csr  = (volatile uint32_t *)mmap(NULL, 0x1000, PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0xA0000000);

    printf("=== Video PHY (0xB0000000) ===\n");
    for (int i = 0; i < 16; i++) {
        printf("  [0x%03X] = 0x%08X\n", i * 4, vphy[i]);
    }
    printf("  [0x200] Clock Det Ctrl = 0x%08X\n", vphy[0x200/4]);
    printf("  [0x208] Clock Det Tmr  = 0x%08X\n", vphy[0x208/4]);
    printf("  [0x210] Clock Det Freq = 0x%08X\n", vphy[0x210/4]);

    printf("\n=== HDMI RX Subsystem (0xB0010000) Subcore IDs ===\n");
    for (int base = 0; base <= 0x200; base += 0x40) {
        printf("  Base 0x%03X: ID=0x%08X, Reg1=0x%08X, Reg2=0x%08X, Reg3=0x%08X\n",
               base, rx[base/4], rx[(base+4)/4], rx[(base+8)/4], rx[(base+12)/4]);
    }

    printf("\n=== PL BAR0 CSR (0xA0000000) ===\n");
    printf("  Magic: 0x%08X, Version: 0x%08X\n", csr[0], csr[1]);

    return 0;
}
