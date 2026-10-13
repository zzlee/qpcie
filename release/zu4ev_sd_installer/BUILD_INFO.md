# 1401 PL / Transactional COMMIT daemon with Safe Reset (2026-10-13)

This is a software-only update; BAR0 PL version remains `0x26101401`.
Daemon SHA256: `3518171b7ae1dc96a35caa4477efd35e30ca2f5903eba922d52d235ed3e836f0`.
Target image SHA256: `f21fb48a4b5dca798fc1e082039ff265a114aaa3fb2e56244b5ddd5143da95c4`.

Features:
- Includes Device DDR byte-snapshot volatile loads fix and strict ustar three-file parser.
- Persistent file transaction (`qtx_apply` in `qpcie_file_transaction.h`) enabled on `/mnt/emmc_boot/.backup_upgrade`.
- Startup crash recovery (`qtx_recover`) automatically rolls back interrupted transactions.
- Raw `boot0` block writes excluded; updates target verified FAT32 partition 1 files (`BOOT.BIN`, `image.ub`, `boot.scr`).
- Host tool `qpcie_upgrade --commit` enabled with status verification.

Use `sha256sum -c SHA256SUMS` from this directory before copying to SD.
