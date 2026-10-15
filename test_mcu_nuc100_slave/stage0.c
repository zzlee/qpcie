/* APROM stage0 (immutable dispatcher @0x0, runs from BSP startup).
 * Validates the app image header @0x0800, inits app .data/.bss, sets MSP,
 * jumps to app entry. I2C IRQs trampoline through cached app handler
 * addresses, so any app build works without stage0 changes. Touches no
 * clocks/GPIO (HPD floats released by SR3). On any failure: LDROM console
 * if valid, else WFI (Nu-Link recovery only).
 */
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Warray-bounds"

#include "NUC100Series.h"
#include "upg.h"

#define APP_HDR_BASE 0x0800UL

typedef struct {
    uint32_t magic, ver, len, crc;
    void (*entry)(void);
    void (*i2c0h)(void);
    void (*i2c1h)(void);
    uint32_t sp;
    uint32_t data_lma, data_vma, data_end;
    uint32_t bss_vma, bss_end;
    uint32_t resv[3];
} app_hdr_t;

/* App initialization owns low SRAM, including stage0's former BSS.
 * IRQ targets must therefore live in flash, not cached stage0 globals. */

void ProcessHardFault(void)
{
    while (1) {
    }
}

/* Trampolines: forward through the validated flash header. */
void I2C0_IRQHandler(void)
{
    volatile app_hdr_t *hdr = (volatile app_hdr_t *)APP_HDR_BASE;
    void (*handler)(void) = hdr->i2c0h;
    if (handler)
        handler();
}

void I2C1_IRQHandler(void)
{
    volatile app_hdr_t *hdr = (volatile app_hdr_t *)APP_HDR_BASE;
    void (*handler)(void) = hdr->i2c1h;
    if (handler)
        handler();
}

/* No C stack access is legal after replacing MSP. Tail-branch to main;
 * it never returns. r0/r1 are the incoming ABI arguments. */
__attribute__((naked, noreturn)) static void app_enter(uint32_t, void (*)(void))
{
    __asm volatile("msr msp, r0\n\tbx r1");
}

static uint32_t crc32_step(uint32_t crc, uint8_t b)
{
    uint32_t j;
    crc ^= b;
    for (j = 0; j < 8; j++)
        crc = (crc & 1UL) ? (crc >> 1) ^ 0xEDB88320UL : (crc >> 1);
    return crc;
}

static int app_valid(volatile app_hdr_t *hdr)
{
    uint32_t crc = 0xFFFFFFFFUL;
    uint32_t i, end;

    if (hdr->magic != UPG_APP_MAGIC)
        return 0;
    if (hdr->len < 64UL || hdr->len > (UPG_FLASH_END - UPG_APP_BASE))
        return 0;
    {
        uint32_t entry = (uint32_t)hdr->entry;
        if (entry < UPG_APP_BASE || entry >= UPG_FLASH_END ||
            (entry & 1UL) == 0UL)
            return 0;
    }
    end = UPG_APP_BASE + hdr->len;
    for (i = UPG_APP_BASE + UPG_APP_HDR_LEN; i < end; i++)
        crc = crc32_step(crc, *((volatile uint8_t *)i));
    crc = ~crc;
    if (crc != hdr->crc)
        return 0;
    /* Sanity: data/bss windows inside SRAM, entry Thumb code. */
    if (hdr->data_vma < 0x20000000UL || hdr->bss_vma < 0x20000000UL)
        return 0;
    return 1;
}

static void boot_ldrom(void)
{
    SYS->REGWRPROT = 0x59UL;
    SYS->REGWRPROT = 0x16UL;
    SYS->REGWRPROT = 0x88UL;
    FMC->ISPCON |= FMC_ISPCON_BS_Msk; /* boot LDROM after reset */
    NVIC_SystemReset();
    while (1) {
    }
}

int main(void)
{
    volatile app_hdr_t *hdr = (volatile app_hdr_t *)APP_HDR_BASE;
    uint32_t *src, *dst, n;

    if (!app_valid(hdr))
        boot_ldrom();

    if (!hdr->i2c0h || !hdr->i2c1h)
        boot_ldrom();

    /* Init app .data/.bss (app startup is bypassed; we jump to main). */
    if (hdr->data_end < hdr->data_vma || hdr->bss_end < hdr->bss_vma ||
        hdr->data_end - hdr->data_vma > 0x4000UL ||
        hdr->bss_end - hdr->bss_vma > 0x4000UL)
        boot_ldrom();
    src = (uint32_t *)hdr->data_lma;
    dst = (uint32_t *)hdr->data_vma;
    for (n = 0; n < (hdr->data_end - hdr->data_vma) / 4UL; n++)
        dst[n] = src[n];
    dst = (uint32_t *)hdr->bss_vma;
    for (n = 0; n < (hdr->bss_end - hdr->bss_vma) / 4UL; n++)
        dst[n] = 0UL;

    app_enter((uint32_t)hdr->sp, (void (*)(void))hdr->entry);
}

#pragma GCC diagnostic pop

#pragma GCC diagnostic pop
