#include <assert.h>
#include <stdio.h>
#include "it6663_tx_recover.h"
int main(void)
{
    assert(it_tx_recover(true,true,true,true,0x9f)==IT_TX_KEEP);
    assert(it_tx_recover(true,true,true,true,0x9e)==IT_TX_DISABLE);
    assert(it_tx_recover(false,true,true,true,0x9e)==IT_TX_KEEP);
    assert(it_tx_recover(false,true,true,true,0x9f)==IT_TX_CONFIGURE);
    assert(it_tx_recover(true,false,true,true,0x9f)==IT_TX_CONFIGURE);
    assert(it_tx_recover(true,true,false,true,0x9f)==IT_TX_CONFIGURE);
    for(int configured=0;configured<2;configured++)
        for(int value=0;value<256;value++)
            assert(it_tx_recover(configured,false,true,false,(uint8_t)value)==IT_TX_KEEP);
    /* Existing upstream remains locked across the FPGA HPD cycle. */
    bool configured=true;
    assert(it_tx_recover(configured,true,true,true,0x9e)==IT_TX_DISABLE);
    configured=false;
    assert(it_tx_recover(configured,true,true,true,0x9f)==IT_TX_CONFIGURE);
    configured=true;
    assert(it_tx_recover(configured,true,true,true,0x9f)==IT_TX_KEEP);
    puts("IT6663_TX_RECOVER_POLICY_PASS: HPD loss/rise, stable/mode-change, failed-read hold");
    return 0;
}
