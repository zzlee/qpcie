/* SPDX-License-Identifier: Apache-2.0 */
#include "board.h"
#include "it6663.h"
#include "i2c0_slave.h"
#include "writer.h"
#include "NUC1262.h"

it6663_info_t g_info;

/* Minimal HardFault and Semihost stubs required by BSP startup code */
void ProcessHardFault(void)
{
    while (1) {
        __NOP();
    }
}

void SH_Return(void) {}

void exit(int status)
{
    (void)status;
    while (1) {
        __NOP();
    }
}

int main(void)
{
    /* 1. Initialize clocks, pin muxing, and GPIOs */
    board_init();

    /* 2. Initialize IT6663 / I2C1 Master */
    it6663_init(&g_info);

    /* 3. Initialize I2C0 Slave */
    i2c0_slave_init(&g_info);

    uint32_t loop_count = 0;

    while (1) {
        board_delay_ms(10);
        loop_count++;

        /* Periodic status check (~100ms) */
        if (loop_count >= 10) {
            loop_count = 0;

            /* If IT6663 wasn't detected at power-up, try initializing again */
            if (!g_info.it6663_present) {
                it6663_init(&g_info);
            } else {
                it6663_poll_status(&g_info);
            }

            i2c0_update_status(&g_info);
        }

        /* Check for EDID update request from host */
        if (g_i2c0.edid_update_requested) {
            g_i2c0.edid_update_requested = false;
            it6663_update_edid(g_active_edid);
        }

        /* Check for software reboot command */
        if (g_i2c0.reboot_requested) {
            board_delay_ms(50);
            NVIC_SystemReset();
        }

        /* Check for in-system flash request over PCIe */
        if (g_upg_flash_pending) {
            board_delay_ms(100); /* Allow host to finish reading COMMIT response */
            __disable_irq();
            uint32_t nwords = (g_upg_flash_len + 3UL) / 4UL;
            int rc = writer_program_aprom(0x0000, (const uint32_t *)0x20001000UL, nwords);
            if (rc == 0) {
                NVIC_SystemReset();
                while (1) {
                    __NOP();
                }
            }
            __enable_irq();
            g_upg_flash_pending = false;
        }
    }
}
