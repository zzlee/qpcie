/* Host-only register model. Not linked into MCU firmware. */
#ifndef MCU_WRITER_FAKE_NUC1262_H
#define MCU_WRITER_FAKE_NUC1262_H
#include <stdint.h>
typedef struct { volatile uint32_t ISPCTL, ISPSTS, ISPTRG, ISPCMD, ISPADDR, ISPDAT; } fake_fmc_t;
typedef struct { volatile uint32_t AHBCLK; } fake_clk_t;
typedef struct { volatile uint32_t REGLCTL; } fake_sys_t;
typedef struct { volatile uint32_t RSTCNT; } fake_wdt_t;
typedef struct { volatile uint32_t AIRCR; } fake_scb_t;
extern fake_scb_t fake_scb;
#define SCB (&fake_scb)
extern fake_fmc_t fake_fmc;
extern fake_clk_t fake_clk;
extern fake_sys_t fake_sys;
extern fake_wdt_t fake_wdt;
#define FMC (&fake_fmc)
#define CLK (&fake_clk)
#define SYS (&fake_sys)
#define WDT (&fake_wdt)
#define FMC_ISPTRG_ISPGO_Msk 1U
#define FMC_ISPSTS_ISPFF_Msk 1U
#define FMC_ISPCTL_ISPEN_Msk 1U
#define FMC_ISPCTL_APUEN_Msk 8U
#define CLK_AHBCLK_ISPCKEN_Msk 1U
void writer_test_fmc_complete(void);
void writer_test_idle(void);
void writer_test_irq_disable(void);
_Noreturn void NVIC_SystemReset(void);
#define __ISB() writer_test_fmc_complete()
void writer_test_barrier(void);
#define __DSB() writer_test_barrier()
#define __NOP() writer_test_idle()
#define __disable_irq() writer_test_irq_disable()

/* Enough peripheral declarations to compile the ACTUAL I2C0 source in the
 * protocol harness. Unused hardware functions are discarded by --gc-sections. */
typedef struct { volatile uint32_t STATUS, DAT, TOCTL, CTL; } I2C_T;
typedef struct { volatile uint32_t PIN; } fake_gpio_t;
extern I2C_T fake_i2c0;
extern fake_gpio_t fake_pc;
#define I2C0 (&fake_i2c0)
#define PC (&fake_pc)
#define I2C0_IRQn 18
#define I2C0_RST 1
#define I2C_TOCTL_TOIF_Msk 1U
#define I2C_CTL_SI_AA 0x0cU
#define I2C_CTL_STO_SI 0x18U
#define I2C_CTL_AA 4U
#define I2C_SET_CONTROL_REG(i, value) ((i)->CTL = (value))
#define __DMB() ((void)0)
void NVIC_DisableIRQ(int irq);
void NVIC_EnableIRQ(int irq);
void SYS_UnlockReg(void);
void SYS_LockReg(void);
void SYS_ResetModule(uint32_t module);
#endif
