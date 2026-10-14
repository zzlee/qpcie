# MCU APROM update over PCIe (with LDROM cooperation)

Target: NUC100LE3AN (U2) on M2_710. Host path: PCIe BAR1 I2C master
(M05 MCU bus 0x5000 / M03 FRONT bus 0x3000) -> NUC100 I2C slave 0x2A.
No FPGA/driver changes needed; flashing goes through
`test_app/qpcie_mcu_scan --flash-aprom app.bin`.

## Why LDROM must cooperate

FMC rejects APROM-block writes while PC is in APROM (ISPFF). The writer
therefore runs from LDROM (`writer.c`, stack-only). No CONFIG/VECMAP
changes: boot-source switches use the ISPCON BS bit + reset (BSP pattern
`FMC_SetBootSource` + `NVIC_SystemReset`), which works under the factory
CBS=11. CONFIG stays untouched.

## Flash layout (APROM 128KB, LDROM 4KB)

| Range | Content | Update path |
|---|---|---|
| 0x0000-0x07FF | stage0 (dispatcher, CRC-checks app) | Nu-Link only |
| 0x0800+ | app image: 64B header @0x0800, code after | PCIe `--flash-aprom` |
| 0x100000+ | LDROM console + writer (magic `LD10`) | Nu-Link only |

- App header (64B @0x0800): magic `APP2`, ver, len, crc32, entry,
  i2c0h/i2c1h, sp, data/bss descriptors. `len`/`crc` patched post-link.
  CRC covers `[0x840, 0x0800+len)`; gaps are objcopy zeros, programmed
  as zero words, so both sides agree.
- `writer_program_aprom()` refuses dst < 0x0800 (stage0 immutable).
- SRAM staging at fixed `0x20001000`, 8KB max (linker `.stage` + ASSERTs;
  `.bss` must end below it). Staging survives CPU/system reset (only POR
  clears SRAM), so the LDROM side re-registers length/CRC with a fresh
  BEGIN before programming.
- Stage0 never touches clocks/GPIO (HPD floats released by SR3 until
  the app runs). I2C IRQs trampoline through the header's handler
  addresses, so any app build works without stage0 changes.

## I2C upgrade protocol (slave 0x2A, both buses)

First W byte `0xAA` escapes the transaction (offset `0x0A` must be
addressed with byte `0x0A`, never `0xAA`). Then `[CMD args...]` + STOP;
response via following Sr+R (single-shot, then cleared; a new W
discards any unread response).

| CMD | Write payload | Read response |
|---|---|---|
| 01 HELLO | — | `[PROTO=1, ROLE, FLAGS, MAXCHUNK=32]` (ROLE 0=app,1=console; FLAGS bit1=writer ready) |
| 02 BEGIN | `[LEN_L LEN_H CRC32x4]` | `[STATUS]` |
| 03 CHUNK | `[OFF_L OFF_H N DATA.. CRC8]` | `[STATUS]` (N<=32; CRC8 over OFF,N,DATA) |
| 04 COMMIT | — | `[STATUS]` (accepted work continues; then wait) |
| 05 ABORT | — | `[0]` |
| 06 PROGRESS | — | `[STATE, DONE_L, DONE_H, ERR]` |
| 07 GOTOLDROM | — | `[0]`, then LDROM boot + reset (app only) |

STATUS: 0 ok, 1 too-big, 2 busy, 3 crc-err, 4 no-session, 5 bad-offset.
CRC32 = IEEE, CRC8 poly 0x07. CHUNK retry x3 on nonzero status.

## Update flow (normal)

1. `--flash-aprom app.bin` validates header locally (magic/len/CRC).
2. HELLO (role 0 expected; role 1 also accepted = recovery reflash).
3. BEGIN, CHUNKs (progress %), COMMIT accepted.
4. App validates total CRC32, hands off (BS=LDROM + reset ~0.5s later
   so the host finishes reading the response).
5. Host re-issues BEGIN+COMMIT to the console (chunks already staged;
   CRC rechecked; NACKs during flashing are normal, keep waiting).
6. Console programs pages with IRQs off, verifies, BS=APROM + reset.
7. Host polls until MAGIC + file VER (90s budget).

Total ~15-30s at 100kHz for a 4KB image. Bus stays at 100kHz
(the FPGA master has no clock-stretch support; do not speed up).

## Recovery stories

- Corrupt app download: stage0 CRC fails -> LDROM console -> re-run
  `--flash-aprom` (same commands, role 1). No Nu-Link needed.
- Corrupt stage0/LDROM: Nu-Link only (these regions are never
  touched by `--flash-aprom`; writer range-check enforces it).
- Power loss mid-program: same as corrupt app (stage0 falls through
  to console). Vectors are programmed like any other words (no
  special-casing, so no torn-vector window beyond the page itself).

## One-time Nu-Link transition (from pre-stage0 firmware)

Current live APROM predates stage0. In ONE Nu-Link session program:
APROM <- `aprom_bundle.bin` @0x0 (stage0 padded to 0x800 + app),
LDROM <- `ldrom.bin` @0x100000. CONFIG untouched. Reset: stage0
validates the bundled app and jumps. Afterwards verify with
`--dump` (VER=04) and keep a Nu-Link backup of the previous image
for rollback. Future app updates never need Nu-Link again.
