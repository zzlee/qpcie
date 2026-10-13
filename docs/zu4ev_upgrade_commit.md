# SC7F0 PCIe firmware update: two-stage protocol (26101401)

Stage 1 (`qpcie_upgrade --package`) pushes the tarball to staging DDR,
verifies it through BAR0 readback, then asks the board only to VERIFY.
Stage 2 (`qpcie_upgrade --commit`) flashes eMMC from the VERIFIED bundle.
eMMC is written ONLY by an explicit COMMIT; a VERIFY never writes.

**Latest VERIFY-only build rejects COMMIT on both host and daemon.**
PL remains 1401 because this is software-only. HELLO `0x10` returns status
`0x06` before host uploads anything; PL version alone is not a daemon
generation check. The snapshot fix and strict extraction described below
are included in the new installer (see `BUILD_INFO.md` and `SHA256SUMS`).

**COMMIT hardware testing is NOT authorized or safety-qualified yet.**
The current backup is in volatile `/tmp`, so it cannot provide power-loss
recovery. Restoration is best-effort, not an atomic update. The boot0 path
can proceed without a verified backup and has not been validated against
the actual eMMC capacity/boot layout. Archive extraction also still needs
strict member/type/size validation. Do not interpret VERIFIED as permission
to flash, or the helper tests as a complete transaction/rollback test.

## VERIFY diagnostic result (1401)

The 41,489,105-byte gzip bundle was completely DMA-transferred and host
readback-verified, but the board VERIFY returned to IDLE after acknowledging
the doorbell. A 50,532-byte legal test archive reproduced that behavior.
The SAME small archive padded to 53,248 bytes reached VERIFIED; the real
archive padded to 41,492,480 bytes likewise reached VERIFIED in 45.4s.
No COMMIT or reboot was performed during these controlled tests.

This strongly suggests an unaligned bulk access to `/dev/mem` Device memory
(for example `fwrite`), not necessarily memory exhaustion; without PS logs,
the precise fault/signal remains unconfirmed. The source now copies staging
through volatile byte loads into ordinary RAM before CRC and libc I/O.
That candidate compiled on host/aarch64 and is packaged in the VERIFY-only
installer, but has NOT been board validated. Original installed 1401 still
requires the aligned-bundle workaround until the SD update.

## Offline safety work, not yet enabled for eMMC

`qpcie_file_transaction.h` creates unique persistent same-filesystem backups,
verifies them before writing PREPARED/APPLYING/COMMITTED markers, and supports
checked, idempotent restoration. Process-death checkpoint tests pass; they
are not physical power-loss tests. Corrupt journals and incomplete backups
fail closed. No claim of an atomic boot-file switch or boot-failure rollback.

`qpcie_archive_verify.h` replaces shell tar extraction with a bounded ustar
reader fed by gzip. Only exactly three nonempty regular named members are
allowed; links, traversal, directories, duplicate/extra files and truncated
streams are rejected. Tests cover these cases. The package still needs a
trusted manifest/signature policy before use beyond controlled diagnostics.

## Why two stages

The old single-doorbell design let the daemon act on START&&DONE, which
fires spuriously while the host streams consecutive 4K chunks (observed
as `STATUS=0xe1` on 26101302 hardware). The new daemon ignores START&&DONE
entirely and latches work only from explicit doorbell values. The old
`cp ... || true` flash path (failures silently ignored) is replaced by
checked copies plus readback verification and backup restore.

## BAR0 protocol (existing registers, new values)

- `0x780 CTRL`: bit3 REBOOT (unchanged). START/DONE remain the DMA
  transport handshake owned by the host driver; the daemon never acts on them.
- `0x784 SIZE`, `0x788 CRC32`: latched by the daemon when a doorbell arrives.
- `0x79C DOORBELL`: `0x01` VERIFY, `0x02` COMMIT. The daemon acknowledges
  by writing `0x00` immediately after latching SIZE/CRC. Anything else
  nonzero is acknowledged and reported as `ERR_STATE`.
- `0x794 STATUS`: `0x00` IDLE, `0x02` VERIFYING, `0x05` VERIFIED (new),
  `0x03` FLASHING, `0x04` SUCCESS, `0xE1` CRC, `0xE2` FLASH, `0xE4` STATE
  (new: COMMIT without a matching VERIFIED, or unknown doorbell).

VERIFY (no eMMC access at all): bounds check, CRC32 over staging DDR,
write staging tar (checked), extract, require non-empty
BOOT.BIN/image.ub/boot.scr. Success latches SIZE/CRC and reports VERIFIED.

COMMIT (exactly one per VERIFY): requires `STATUS==VERIFIED` with SIZE/CRC
still matching the latch, then consumes it. Mounts eMMC p1, backs up the
current files, copies the new files (every copy return-checked), `sync`,
compares each file back against staging, then handles boot0 (backup,
write, compare). Any failure restores the backups and reports `ERR_FLASH`;
only fully verified writes report SUCCESS.

## Host requirements

- Board RTL `>= 0x26101401` (gates the new daemon generation; older boards
  still run the single-doorbell daemon and are refused for --package/--commit).
- `--package` refuses a busy board (VERIFYING/FLASHING) and oversized input.
- `--commit` refuses unless the board reports VERIFIED.

## What rollback does and does not cover

Backup/restore covers write-time failures (bad copy, readback mismatch):
the previous eMMC files and boot0 bytes are put back and `ERR_FLASH` is
reported. It does NOT cover a successfully written image that fails to
boot; that case still needs physical SD-card recovery. A fallback that
boots the backup automatically does not exist.
