# 1401 PL / VERIFY-only daemon (2026-10-13)

This is a software-only update; BAR0 PL version remains `0x26101401`.
Daemon SHA256: `3a7482eae89ad0471b6ede66e22037f4e465e2cf2873f706a18daac6a109c254`.
HELLO doorbell `0x10` acknowledges with status `0x06` (VERIFY-only).
COMMIT is disabled in BOTH the new host tool and this daemon.

Includes Device DDR byte-snapshot fix and strict three-file ustar validation.
Persistent file transaction/recovery helpers are offline-tested ONLY and
not connected to eMMC. No boot0 writing or board power-cut test is enabled.
The old PL cross-domain timing violations remain; this is a diagnostic release.

Use `sha256sum -c SHA256SUMS` from this directory before copying to SD.
Do not mix `image.ub`/`target_emmc/image.ub` from the original 1401 release.
