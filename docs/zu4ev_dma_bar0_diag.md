# SC7F0 H2C upgrade: BAR0-only stage tracing (1205 diagnostic)

Host can read these counters *after* the 3-second sysfs canary times out;
no JTAG access is needed. The host tool accepts `0x26101205`,
`0x26101206`, `0x26101301`, `0x26101302` and `0x26101401` only. Version 1206 changes PCIe IP tag and RC straddle modes;
it is **not** proof that the upgrade is fixed, and this tool never writes eMMC.

## Registers in the existing PS/host-shared BAR0 CSR aperture

| BAR0 offset | PS physical | Meaning |
| --- | --- | --- |
| `0x07B0` | `0xA00007B0` | Sticky PCIe-domain events, synchronized to PL |
| `0x07B4` | `0xA00007B4` | Sticky 100 MHz PS writer events |
| `0x07B8` | `0xA00007B8` | Bit 0 clear-request toggle, bit 1 PCIe clear ACK; write bit 0 = 1 to toggle |

`0x07B0` bits: 0 synchronized START edge; 1 descriptor pending;
2 descriptor accepted; 3 H2C MRd valid; 4 H2C MRd ack;
5 RQ handshake with tag 2..17; 6 RC handshake (any RC while upgrade active);
7 H2C completion data routed (tag 2..17); 8 loopback valid;
9 loopback accepted; 10 SG H2C busy; 11 SG H2C bytes nonzero;
12 CDC input ready.

`0x07B4` bits: 0 START observed in PL; 1 CDC output valid;
2 CDC output accepted; 3 HP0 AW valid; 4 HP0 AW handshake;
5 HP0 W valid; 6 HP0 W handshake; 7 HP0 WLAST handshake;
8 HP0 B valid; 9 HP0 B handshake; 10 non-OK B response;
11 writer done; 12 writer byte count nonzero; 13 PL reset released.

Bits are set where the event occurs. PCIe-domain sticky *levels*, not
one-cycle pulses or asynchronous counters, pass through two flip-flops into
`pl_clk0`. Sticky values survive host driver's 3-second wait; they are
cleared only by reset or an explicit clear/ACK handshake. No extra BRAM or
JTAG ILA is required. Bit 6 indicates RC activity, **not proof of a matching
completion**; inspect bits 5/7 together. For meaningful traces, keep other
video/DMA traffic idle during the test.

## One canary per clear

1. Update the card through the SD-to-eMMC installer **only after** the 1205
   bitstream, XSA, FSBL, image and installer are verified. Boot it on the
   PCIe host and confirm the intended BAR0 version before writing anything.
2. Read `sudo qpcie_dma_diag RESOURCE0 --clear`. This refuses START in
   progress, waits for the PCIe clear ACK and checks that both event records
   are clear (PL-reset bit 13 may immediately become 1). If it fails, **do
   not run the canary**. Host BAR0 read only uses
   `sudo qpcie_dma_diag RESOURCE0`.
3. Write **exactly 4096 bytes** once to
   `/sys/bus/pci/devices/0000:03:00.0/firmware_upgrade`, no upgrade
   doorbell and no eMMC flash. It is expected that the 1204 bug may still
   time out. Immediately read the diagnostic tool, driver dmesg, and PS
   `0xA00007B0/0xA00007B4` if a verified safe PS reader is available.
4. Follow the first missing event: no bit 2 ⇒ descriptor/trigger;
   bit 4 but not bit 5 ⇒ RQ transmit; bit 5 but no bit 7 ⇒ completion
   path/RC routing; bit 7 but no bit 8 ⇒ reorder/retirement;
   bit 9 but no writer bit 1 ⇒ AXIS CDC; writer bit 2 but no AW/B ⇒
   HP0 writer/PS. A B handshake without writer done/driver success still
   needs byte-count and CPU-side validation.

This does not replace a full PCIe host model or hardware validation. For
each rerun, clear and confirm ACK again; do not mistake old sticky bits for
new canary progress.
