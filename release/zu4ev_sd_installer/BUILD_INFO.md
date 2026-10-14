# 1401 PL / High-Speed Transactional COMMIT daemon with Safe Reset (2026-10-14)

This is a software-only update; BAR0 PL version remains `0x26101401`.
Daemon SHA256: `029625e94f8b11d01989428cade9be3c638923fc3ce5b82696cc2c53d7e8c4e3`.
Target image SHA256: `9521bfa670999fe448636f1dc2cbf69921344b19efef9b03e1ff002544002bb4`.

Features:
- High-Speed Upgrade Pipeline: direct uncompressed `.tar` streaming parser (<0.5s) eliminates 25-30s CPU gzip decompression bottleneck. Backward-compatible with `.tar.gz`.
- Cryptographic End-to-End Validation: `manifest.sha256` verifies hashes of `BOOT.BIN`, `image.ub`, and `boot.scr` before touching eMMC.
- 64-bit aligned memory snapshotting (`uint64_t`) eliminates 41.5M single-byte uncached bus stalls.
- Fast boundary canaries (<2ms) replace legacy 5-8s full BAR0 MMIO readback.
- Persistent file transaction (`qtx_apply` in `qpcie_file_transaction.h`) enabled on `/mnt/emmc_boot/.backup_upgrade`.
- Startup crash recovery (`qtx_recover`) automatically rolls back interrupted transactions.
- Raw `boot0` block writes excluded; updates target verified FAT32 partition 1 files (`BOOT.BIN`, `image.ub`, `boot.scr`).
- Host tool `qpcie_upgrade --commit` enabled with status verification.

Use `sha256sum -c SHA256SUMS` from this directory before copying to SD.

