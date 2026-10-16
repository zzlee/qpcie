/* SPDX-License-Identifier: Apache-2.0 */
#include "board.h"
#include "sys.h"
#include "clk.h"
#include "gpio.h"

void board_delay_ms(uint32_t ms)
{
    for (uint32_t i = 0; i < ms; i++) {
        for (volatile uint32_t j = 0; j < 12000; j++) {
            __NOP();
        }
    }
}

void board_it6663_power(bool enable)
{
    if (enable) {
        PF->DOUT |= BIT6; /* PF.6 = 1 */
    } else {
        PF->DOUT &= ~BIT6;
    }
}

void board_it6663_reset(bool assert_reset)
{
    if (assert_reset) {
        PA->DOUT &= ~BIT10; /* PA.10 = 0 (reset active) */
    } else {
        PA->DOUT |= BIT10;  /* PA.10 = 1 (reset released) */
    }
}

void board_hdmi_hpd(bool enable)
{
    if (enable) {
        PA->DOUT |= BIT11; /* PA.11 = 1 (MCU0_HPD assert) */
        PB->DOUT |= BIT5;  /* PB.5 = 1 (H0_P1TXHPD assert) */
    } else {
        PA->DOUT &= ~BIT11;
        PB->DOUT &= ~BIT5;
    }
}

bool board_hdmi_5v_detected(void)
{
    return (PB->PIN & BIT2) != 0; /* PB.2 = H0_RX_DET */
}

uint8_t board_get_status_byte(void)
{
    uint8_t st = 0;
    if (PA->DOUT & BIT10) st |= (1 << 0); /* IT6663 reset released */
    if (PB->PIN & BIT2)   st |= (1 << 1); /* HDMI 5V detected */
    if (PA->DOUT & BIT11) st |= (1 << 2); /* HPD asserted */
    if (PF->DOUT & BIT6)  st |= (1 << 3); /* +1.0V regulator enabled */
    return st;
}

void board_init(void)
{
    /* 1. Unlock protected registers */
    SYS_UnlockReg();

    /* 2. Enable HIRC (48MHz internal oscillator) */
    CLK_EnableXtalRC(CLK_PWRCTL_HIRCEN_Msk);
    CLK_WaitClockReady(CLK_STATUS_HIRCSTB_Msk);

    /* Switch HCLK to HIRC / 1 = 48MHz */
    CLK_SetHCLK(CLK_CLKSEL0_HCLKSEL_HIRC, CLK_CLKDIV0_HCLK(1));

    /* Update SystemCoreClock variable */
    SystemCoreClockUpdate();

    /* 3. Enable IP module clocks: GPIO, I2C0, I2C1 */
    CLK_EnableModuleClock(I2C0_MODULE);
    CLK_EnableModuleClock(I2C1_MODULE);

    /* 4. Configure Multi-Function Pins (MFP) */
    /* PC.0 -> I2C0_SDA (MFP 9), PC.1 -> I2C0_SCL (MFP 9) */
    SYS->GPC_MFPL = (SYS->GPC_MFPL & ~(SYS_GPC_MFPL_PC0MFP_Msk | SYS_GPC_MFPL_PC1MFP_Msk))
                  | SYS_GPC_MFPL_PC0MFP_I2C0_SDA | SYS_GPC_MFPL_PC1MFP_I2C0_SCL;

    /* PB.0 -> I2C1_SDA (MFP 9), PB.1 -> I2C1_SCL (MFP 9) */
    SYS->GPB_MFPL = (SYS->GPB_MFPL & ~(SYS_GPB_MFPL_PB0MFP_Msk | SYS_GPB_MFPL_PB1MFP_Msk))
                  | SYS_GPB_MFPL_PB0MFP_I2C1_SDA | SYS_GPB_MFPL_PB1MFP_I2C1_SCL;

    /* Enable Schmitt trigger on I2C pins */
    PC->SMTEN |= (GPIO_SMTEN_SMTEN0_Msk | GPIO_SMTEN_SMTEN1_Msk);
    PB->SMTEN |= (GPIO_SMTEN_SMTEN0_Msk | GPIO_SMTEN_SMTEN1_Msk);

    /* 5. Configure GPIO pins */
    /* PF.6: H0_RX_EN -> Output Push-Pull, default HIGH (+1.0V_H0 regulator enable) */
    GPIO_SetMode(PF, BIT6, GPIO_MODE_OUTPUT);
    board_it6663_power(true);

    /* PA.10: RSTn_MCU0 -> Output Push-Pull, default LOW (held in reset during init) */
    GPIO_SetMode(PA, BIT10, GPIO_MODE_OUTPUT);
    board_it6663_reset(true);

    /* PA.11: MCU0_HPD -> Output Push-Pull, default HIGH */
    GPIO_SetMode(PA, BIT11, GPIO_MODE_OUTPUT);

    /* PB.5: H0_P1TXHPD -> Output Push-Pull, default HIGH */
    GPIO_SetMode(PB, BIT5, GPIO_MODE_OUTPUT);
    board_hdmi_hpd(true);

    /* PB.2: H0_RX_DET -> Input Mode (HDMI 5V detection) */
    GPIO_SetMode(PB, BIT2, GPIO_MODE_INPUT);

    /* PB.6: X0_PS_SRSTb -> Input Mode (do not drive low!) */
    GPIO_SetMode(PB, BIT6, GPIO_MODE_INPUT);

    /* Lock protected registers */
    SYS_LockReg();

    /* 6. Power cycle and reset sequence matching Yuan reference:
     *    PF.6 LOW -> HIGH (power toggle)
     *    PA.10 LOW for 100ms -> HIGH (clean reset pulse)
     */
    board_it6663_power(false);
    board_delay_ms(10);
    board_it6663_power(true);
    board_delay_ms(50);

    board_it6663_reset(true);
    board_delay_ms(100);
    board_it6663_reset(false);
    board_delay_ms(50);
}
