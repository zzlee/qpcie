/* LDROM recovery console + APROM writer (boots via BS=LDROM + reset).
 * Serves the same upgrade protocol as the app (HELLO role=recovery).
 * Flow: app stages image in SRAM, COMMITs (validates), reboots here;
 * host re-issues BEGIN+COMMIT (chunks already staged, CRC rechecked),
 * console programs APROM, verifies, boots APROM, resets.
 * Brick recovery (stage0 CRC-fail lands here with empty staging):
 * host pushes full image, same commands.
 */
#include "NUC100Series.h"
#include "i2c.h"
#include "i2c_slave.h"
#include "upg.h"
#include "writer.h"

static i2c_ch_t g_c0, g_c1;

void ProcessHardFault(void)
{
    while (1) {
    }
}

void I2C0_IRQHandler(void)
{
    i2c_slave_isr(I2C0, &g_c0);
}

void I2C1_IRQHandler(void)
{
    i2c_slave_isr(I2C1, &g_c1);
}

/* LDROM-strong upgrade hooks. */
uint8_t upg_role(void) { return UPG_ROLE_CONSOLE; }

int main(void)
{
    /* If booted from an in-SRAM upgrade handshake, flash APROM directly and reboot into APROM. */
    volatile uint32_t *hs = (volatile uint32_t *)UPG_HANDSHAKE_ADDR;
    if (hs[0] == UPG_HANDSHAKE_MAGIC) {
        uint32_t len = hs[1];
        uint32_t crc = hs[2];
        hs[0] = 0UL; /* Clear magic immediately so failure doesn't loop */
        if (len >= UPG_APP_HDR_LEN && len <= UPG_STAGE_MAX && (len & 3UL) == 0UL) {
            if (upg_crc32(upg_image_ptr(), len) == crc) {
                uint32_t nwords = (len + 3UL) / 4UL;
                int rc = writer_program_aprom(UPG_APP_BASE, (const uint32_t *)upg_image_ptr(), nwords);
                if (rc == 0) {
                    SYS->REGWRPROT = 0x59UL;
                    SYS->REGWRPROT = 0x16UL;
                    SYS->REGWRPROT = 0x88UL;
                    CLK->AHBCLK |= CLK_AHBCLK_ISP_EN_Msk;
                    FMC->ISPCON |= FMC_ISPCON_ISPEN_Msk;
                    FMC->ISPCON &= ~FMC_ISPCON_BS_Msk; /* boot APROM next */
                    SYS->IPRSTC1 = SYS_IPRSTC1_CHIP_RST_Msk; /* Whole-chip reset */
                    while (1) {
                    }
                }
                upg_set_error((uint8_t)(0 - rc));
            } else {
                upg_set_error(UPG_ST_CRCERR);
            }
        } else {
            upg_set_error(UPG_ST_BADOFF);
        }
    }

    /* Minimal recovery init (no HXT/CLKO, no regfile): HIRC default clock,
     * PB.10 LOW (HPD released), PB.15 HIGH, I2C slaves on both buses. */
    SYS->REGWRPROT = 0x59UL;
    SYS->REGWRPROT = 0x16UL;
    SYS->REGWRPROT = 0x88UL;

    CLK->AHBCLK |= CLK_AHBCLK_ISP_EN_Msk;
    FMC->ISPCON |= FMC_ISPCON_ISPEN_Msk;

    PA->PMD &= ~((0x3UL << (12 * 2)) | (0x3UL << (13 * 2)));
    PB->DOUT &= ~(1UL << 10);
    PB->DOUT |= (1UL << 15);
    PB->PMD = (PB->PMD & ~((0x3UL << (10 * 2)) | (0x3UL << (15 * 2))))
            | ((0x1UL << (10 * 2)) | (0x1UL << (15 * 2)));
    SYS->ALT_MFP &= ~(1UL << 11);
    SYS->GPA_MFP |= (1UL << 8) | (1UL << 9) | (1UL << 10) | (1UL << 11);
    SYS->IPRSTC2 |= SYS_IPRSTC2_I2C0_RST_Msk | SYS_IPRSTC2_I2C1_RST_Msk;
    SYS->IPRSTC2 &= ~(SYS_IPRSTC2_I2C0_RST_Msk | SYS_IPRSTC2_I2C1_RST_Msk);
    CLK->APBCLK |= CLK_APBCLK_I2C0_EN_Msk | CLK_APBCLK_I2C1_EN_Msk;
    i2c_slave_ch_init(I2C0, &g_c0, 0x2AU);
    i2c_slave_ch_init(I2C1, &g_c1, 0x2AU);
    NVIC_EnableIRQ(I2C0_IRQn);
    NVIC_EnableIRQ(I2C1_IRQn);
    SYS->REGWRPROT = 0x00UL;

    for (;;) {
        upg_poll();
        __WFI();
    }
}
