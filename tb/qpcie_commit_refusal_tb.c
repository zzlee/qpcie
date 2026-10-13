#define main qpcie_daemon_main
#include "../test_app/qpcie_upgrade_daemon.c"
#undef main
int main(void) {
    uint32_t regs[PL_MMAP_SIZE / 4] = {0};
    uint32_t size = 4096, crc = 0x12345678;
    bool verified = true;
    regs[REG_DMA_UPG_STATUS / 4] = STATUS_UPG_VERIFIED;
    regs[REG_DMA_UPG_SIZE / 4] = size;
    regs[REG_DMA_UPG_CRC32 / 4] = crc;
    do_commit(regs, &size, &crc, &verified);
    if (verified || regs[REG_DMA_UPG_STATUS / 4] != STATUS_UPG_ERR_STATE ||
        regs[REG_DMA_UPG_CTRL / 4] != 0) return 1;
    puts("TB_PASS: even matching VERIFIED session cannot enable COMMIT in safe build");
    return 0;
}
