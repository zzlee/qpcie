#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>

int main(int argc, char **argv) {
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open /dev/mem"); return 1; }

    volatile uint32_t *vphy = mmap(NULL, 0x1000, PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0xB0000000);
    if (vphy == MAP_FAILED) { perror("mmap vphy"); return 1; }

    volatile uint32_t *hdmi = mmap(NULL, 0x1000, PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0xB0010000);
    if (hdmi == MAP_FAILED) { perror("mmap hdmi"); return 1; }

    printf("=== Initial State ===\n");
    printf("VPHY 0x010 (RefClkSel): 0x%08X\n", vphy[0x010/4]);
    printf("VPHY 0x018 (PllLock):   0x%08X\n", vphy[0x018/4]);
    printf("VPHY 0x020 (TxStatus):  0x%08X\n", vphy[0x020/4]);
    printf("VPHY 0x028 (RxStatus):  0x%08X\n", vphy[0x028/4]);
    printf("VPHY 0x200 (ClkDetCtrl):0x%08X\n", vphy[0x200/4]);
    printf("VPHY 0x204 (ClkDetStat):0x%08X\n", vphy[0x204/4]);
    printf("VPHY 0x208 (FreqTmout): 0x%08X\n", vphy[0x208/4]);
    printf("VPHY 0x210 (RxFreq):    0x%08X (%u Hz)\n", vphy[0x210/4], vphy[0x210/4]);
    printf("HDMI 0x040 (PIO ID):    0x%08X\n", hdmi[0x040/4]);
    printf("HDMI 0x064 (PIO IN):    0x%08X\n", hdmi[0x064/4]);
    printf("HDMI 0x0C0 (VTD ID):    0x%08X\n", hdmi[0x0C0/4]);
    printf("HDMI 0x0D0 (VTD STA):   0x%08X\n", hdmi[0x0D0/4]);
    printf("HDMI 0x0D8 (VTD W):     0x%08X\n", hdmi[0x0D8/4]);
    printf("HDMI 0x0E0 (VTD H):     0x%08X\n", hdmi[0x0E0/4]);

    printf("\n=== Configuring Video PHY Clock Detector ===\n");
    // 1. Configure Freq Timeout to 100MHz (0x05F5E100)
    vphy[0x208/4] = 100000000;
    // 2. Select GTREFCLK1 (0x20) for CPLL RefClk
    vphy[0x010/4] = 0x00000020;
    // 3. Clear CEB on GTREFCLK1 ( slv_reg_0x2C[1] = 0 )
    vphy[0x02C/4] = 0x00000000;
    // 4. Start Clock Detector: Run=1, Threshold=40, Acc=8, delta=0
    vphy[0x200/4] = 0x00010501;

    usleep(50000); // 50ms for clock detector to measure
    printf("VPHY 0x204 (ClkDetStat): 0x%08X\n", vphy[0x204/4]);
    printf("VPHY 0x210 (RxFreq):     0x%08X (%u Hz)\n", vphy[0x210/4], vphy[0x210/4]);

    printf("\n=== Resetting CPLL & GTHE4 RX ===\n");
    // Pulse CPLL Reset: 0x014 bit 0
    vphy[0x014/4] = 0x00000001;
    usleep(10000);
    vphy[0x014/4] = 0x00000000;
    usleep(20000);

    // Pulse RX PLL GT Reset & GTRXRESET: 0x024 bits [7,0], [15,8], [23,16] = 0x818181
    vphy[0x024/4] = 0x00818181;
    usleep(20000);
    vphy[0x024/4] = 0x00000000;
    usleep(20000);

    // Assert RXUSERRDY: bits [6], [14], [22] = 0x404040
    vphy[0x024/4] = 0x00404040;
    usleep(50000);

    printf("VPHY 0x018 (PllLock):    0x%08X\n", vphy[0x018/4]);
    printf("VPHY 0x020 (TxStatus):   0x%08X\n", vphy[0x020/4]);
    printf("VPHY 0x028 (RxStatus):   0x%08X\n", vphy[0x028/4]);
    printf("VPHY 0x104 (RxStatus2):  0x%08X\n", vphy[0x104/4]);
    printf("VPHY 0x204 (ClkDetStat): 0x%08X\n", vphy[0x204/4]);
    printf("VPHY 0x210 (RxFreq):     0x%08X (%u Hz)\n", vphy[0x210/4], vphy[0x210/4]);

    printf("\n=== Configuring HDMI RX Subsystem ===\n");
    // Start PIO & set HPD, LNK_EN, VID_EN, AXIS_EN
    hdmi[0x048/4] = 0x00000001; // PIO CTRL SET: RUN=1
    // PIO OUT SET: bit 1 (LNK_EN), bit 2 (VID_EN), bit 3 (HPD), bit 19 (AXIS_EN) -> 0x0008000E
    hdmi[0x058/4] = 0x0008000E;
    // Start VTD: RUN=1
    hdmi[0x0C8/4] = 0x00000001;
    usleep(50000);

    printf("HDMI 0x050 (PIO STA):    0x%08X\n", hdmi[0x050/4]);
    printf("HDMI 0x054 (PIO OUT):    0x%08X\n", hdmi[0x054/4]);
    printf("HDMI 0x064 (PIO IN):     0x%08X\n", hdmi[0x064/4]);
    printf("HDMI 0x0D0 (VTD STA):    0x%08X\n", hdmi[0x0D0/4]);
    printf("HDMI 0x0D4 (VTD TotPix): 0x%08X (%u)\n", hdmi[0x0D4/4], hdmi[0x0D4/4]);
    printf("HDMI 0x0D8 (VTD ActPix): 0x%08X (%u)\n", hdmi[0x0D8/4], hdmi[0x0D8/4]);
    printf("HDMI 0x0DC (VTD TotLin): 0x%08X (%u)\n", hdmi[0x0DC/4], hdmi[0x0DC/4]);
    printf("HDMI 0x0E0 (VTD ActLin): 0x%08X (%u)\n", hdmi[0x0E0/4], hdmi[0x0E0/4]);

    munmap((void*)hdmi, 0x1000);
    munmap((void*)vphy, 0x1000);
    close(fd);
    return 0;
}
