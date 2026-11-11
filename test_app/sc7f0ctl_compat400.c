/* SPDX-License-Identifier: GPL-2.0 */
/* Diagnostic build of sc7f0ctl pinned to the legacy H2C payload aperture.
 *
 * A Card PS image loaded from the read-only rootfs may still run a debugd
 * compiled when DB_H2C_DATA was 0x400, while ../include/qpcie_debug.h moved
 * the window to 0x800 to dodge the shared VCU ring at BAR0+0x2200. Building
 * this client with the old offset proves which side of the mailbox the card
 * is actually serving; it is a probe only, never the shipping ABI.
 */
#include "qpcie_debug.h"

#undef DB_H2C_DATA
#define DB_H2C_DATA 0x400 /* legacy aperture, pre-VCU-ring-reservation */

#include "sc7f0ctl.c"
