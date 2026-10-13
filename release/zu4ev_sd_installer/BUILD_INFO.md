# 1401 PL / Transactional COMMIT daemon (2026-10-13)

This is a software-only update; BAR0 PL version remains `0x26101401`.
Daemon SHA256: `c06a3c99b72cd6404d4e1eb2d186b707218f640dfe64dd5d1e0eb0979ad2074d`.
Target image SHA256: `c988d1f615c5397a7a634758f57f9ea9a2fea9cbe4f5631fec5657977c99d7ff`.

Features:
- Includes Device DDR byte-snapshot volatile loads fix and strict ustar three-file parser.
- Persistent file transaction (`qtx_apply` in `qpcie_file_transaction.h`) enabled on `/mnt/emmc_boot/.backup_upgrade`.
- Startup crash recovery (`qtx_recover`) automatically rolls back interrupted transactions.
- Raw `boot0` block writes excluded; updates target verified FAT32 partition 1 files (`BOOT.BIN`, `image.ub`, `boot.scr`).
- Host tool `qpcie_upgrade --commit` enabled with status verification.

Use `sha256sum -c SHA256SUMS` from this directory before copying to SD.
