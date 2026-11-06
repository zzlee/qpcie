#ifndef IT6663_TX_RECOVER_H
#define IT6663_TX_RECOVER_H
#include <stdbool.h>
#include <stdint.h>
/* FPGA reconfiguration loses sink SCDC state while upstream RX stays locked.
 * A checked P1 HPD loss invalidates the cached TX setup. Never reconfigure
 * from a failed I2C read; caller also requires qualified upstream timing. */
typedef enum { IT_TX_KEEP, IT_TX_DISABLE, IT_TX_CONFIGURE } it_tx_action_t;
static inline it_tx_action_t it_tx_recover(bool configured, bool current_ratio40,
                                          bool wanted_ratio40, bool read_ok,
                                          uint8_t status)
{
    if (!read_ok)
        return IT_TX_KEEP;
    if (!(status & 1))
        return configured ? IT_TX_DISABLE : IT_TX_KEEP;
    return (!configured || current_ratio40 != wanted_ratio40)
        ? IT_TX_CONFIGURE : IT_TX_KEEP;
}
#endif
