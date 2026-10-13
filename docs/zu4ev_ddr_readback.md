# Host-only DDR verification (26101301 and later)

This diagnostic adds a read-only AXI HP0 path to PS DDR. No UART, JTAG,
PS daemon, C2H DMA, extra BRAM, DDR writes or eMMC commands are required.
Since 26101302 it covers the whole 64MB staging window at physical
`0x30000000 + offset` (16-byte aligned); the older 4KiB canary-only range
applied to 26101301. The existing 1206 client-tag/non-straddled RC fix is
retained.

## BAR0 map (shared PS/host CSR clock domain)

| Offset | Meaning |
| --- | --- |
| `0x7c0` | Staging offset, RW; must be 16-byte aligned, at most `size-16` (64MB window since 26101302) |
| `0x7c4` | Write bit0=1 to request; read status below |
| `0x7c8` | Accepted-request sequence; increments even for a rejected address |
| `0x7d0..0x7dc` | Four little-endian words from the completed 128-bit read |

Status: bit0 BUSY, bit1 DONE, bit2 ERROR (RRESP/RID/RLAST or rejected
command), bit3 TIMEOUT, bit4 REJECTED. A new accepted command clears old
status/data. A command while BUSY is ignored (sequence unchanged).
The hardware rejects requests during DMA START or outside the canary range.
ARID=0, ARLEN=0, ARSIZE=4 (16 bytes), ARBURST=INCR. Address and ARVALID
are held until handshake; data stays latched until the next request.

The default timeout is 1,000,000 PL cycles (10ms at 100MHz). It does NOT
cancel an outstanding AXI read: BUSY and the request remain until the late
response is drained. Nonzero RID, non-OK RRESP or missing RLAST are errors;
missing RLAST keeps the reader draining until RLAST arrives. A timed-out
transaction never becomes a successful result even if it returns later.
Stop on any error/timeout; do not retry or reset only this reader while
there is an outstanding PS transaction.

## Hardware handoff

Only use a verified installer matching the expected version, through the
existing SD-to-eMMC workflow. Whole-design cross-domain timing still
requires review; a built bitstream is not proof of reliable operation.

### Transport ladder (host-only, no eMMC writes)
1. Confirm BAR0 version and PCIe link, load the driver.
2. `qpcie_dma_diag RESOURCE0 --clear`; require clear ACK before each stage.
3. Push 64KiB random file with `qpcie_stage_push SYSFS FILE 0`, then
   `sudo qpcie_ddr_verify RESOURCE0 FILE 0`; require `DDR_VERIFY_PASS`.
4. Push 2MiB random file the same way (proves multi-chunk sequencing),
   then verify as above.
5. Push 8MiB random file the same way (2048 sequential 4K blocks),
   then verify as above.
6. If any stage fails, preserve diag/AER output and stop; do not proceed
   to larger sizes or any COMMIT work.

Two transport facts established on 26101302 hardware:
- The kernel caps each `firmware_upgrade` sysfs write at 4096 bytes
  (a single 1MB `write()` returns 4096), so the driver's 2MB coherent
  chunk path is unreachable; transfers proceed as sequential 4K DMAs at
  ~23-24MB/s, not 3.2GB/s. `qpcie_stage_push` loops 4K blocks with
  `lseek` positioning and per-block retry for this reason.
- The board daemon spuriously triggers on START&&DONE during multi-chunk
  pushes (`STATUS=0xe1` latched, CRC mismatch on a partial SIZE). It is
  harmless for transport but proves the single-doorbell design unsafe;
  COMMIT must become a separate explicit step (see next section).

1. Confirm 26101301 BAR0 version and PCIe link, load the driver.
2. `qpcie_dma_diag RESOURCE0 --clear`; require clear ACK before one fresh
   4096-byte canary. Keep the original canary file; do not send doorbell.
3. Run `sudo qpcie_ddr_verify RESOURCE0 CANARY_FILE`. It reads all 256
   aligned blocks and compares all 4096 bytes. Require `DDR_VERIFY_PASS`.
4. If it fails, preserve the output and stop. No eMMC commit is authorized.

Use exclusive access: no other host/PS tool may write these registers or
launch DMA concurrently. The host tool requires an exact 4096-byte input
and version 26101301, checks sequence/status and stops on a failed read.
Even success validates only the small H2C canary, not larger transfers,
repeated-start behavior, Linux cache coherence or safe firmware updates.
