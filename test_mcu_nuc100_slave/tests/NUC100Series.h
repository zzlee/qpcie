/* Host-only register stub; never included by ARM firmware builds. */
#ifndef MOCK_NUC100_H
#define MOCK_NUC100_H
#include <stdint.h>
typedef struct { uint32_t REGWRPROT; uint32_t IPRSTC1; } mock_sys_t;
typedef struct { uint32_t ISPCON; } mock_fmc_t;
extern mock_sys_t mock_sys;
extern mock_fmc_t mock_fmc;
#define SYS (&mock_sys)
#define FMC (&mock_fmc)
#define FMC_ISPCON_BS_Msk 2U
#define SYS_IPRSTC1_CHIP_RST_Msk 1U
#define __NOP() ((void)0)
#define __disable_irq() ((void)0)
#define __enable_irq() ((void)0)
void NVIC_SystemReset(void);
typedef struct {
    uint32_t I2CON, I2CDAT, I2CSTATUS, I2CTOC, I2CLK;
    uint32_t I2CADDR0, I2CADDR1, I2CADDR2, I2CADDR3;
    uint32_t I2CADM0, I2CADM1, I2CADM2, I2CADM3;
} I2C_T;
extern I2C_T mock_i2c0, mock_i2c1;
#define I2C0 (&mock_i2c0)
#define I2C1 (&mock_i2c1)
extern uint32_t SystemCoreClock;
void SystemCoreClockUpdate(void);
#define I2C_I2CTOC_TIF_Msk 1U
#define I2C_I2CON_ENS1_Msk 0x40U
#define I2C_I2CON_EI_Msk 0x80U
#define I2C_I2CON_AA_Msk 4U
#define I2C_I2CADDR_I2CADDR_Pos 1U
#define I2C_I2CADM_I2CADM_Pos 1U
#endif
