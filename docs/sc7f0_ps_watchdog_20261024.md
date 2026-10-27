# SC7F0 PS watchdog / warm-reset scope (2026-10-24)

> **2026-10-27：R1 已被板端故障測試發現 PID 替換寬限缺陷，勿再新部署 R1。**
> systemd 能重啟 daemon，但 R1 guardian 因舊 PID 消失而過早 latch，額外觸發 system reset。
> 正在以 R2 修正並重驗；以後續部署／驗收紀錄為準。本文其餘內容保留 R1 離線歷史。

## Status and boundary

**Offline-built candidate, not flashed and not card-hardware accepted.**
No new hardware probes, x86/card resets, MCU flashing, or power cycling were
performed. The only fault injection so far was SIGSTOP of an explicitly verified
local development-user `qpcie_debugd --sim <regular-file>` process.

PS release: `sc7f0-ps-watchdog-20261024-r1`.
The PL is the **unchanged frozen 0x26102206** from
`build/sc7f0-audio-26102206-r5`; no Vivado run or new audio acceptance is claimed.
The current video commit and audio/MCU WIP remain separate/uncommitted.
The bundle contains NO MCU firmware and performs NO automatic MCU reset/update.

## What the updater's “warm reboot” actually does

The previous tool text “PMU chip-level POR” / “100% active” was incorrect.
Current code path:

```text
host qpcie_upgrade --reboot
  -> shared CSR DMA_UPG_CMD_REBOOT
  -> live PS qpcie_upgrade_daemon clears request
  -> sync(); SysRq b; fallback reboot(RB_AUTOBOOT)
  -> Linux PSCI SYSTEM_RESET
  -> ATF zynqmp_system_reset()
     pm_system_shutdown(RESET, pm_get_shutdown_scope())
  -> default scope SYSTEM (not PMU's PS_ONLY/subsystem scope)
  -> PMU PmSystemShutdown -> XPfw_ResetSystem()
     -> PmExtReset() [empty without EXT_RESET_MIO_PIN configuration]
     -> CRL_APB.RESET_CTRL.SOFT_RESET
  -> boot flow / FSBL / BOOT.BIN PL partition / U-Boot / image.ub / Linux
```

The ATF default scope can be changed by a separate SETSCOPE request; no such
override is configured by this updater. A request to a dead PS daemon does
nothing. Host PCI remove/rescan is **not** an independent PS-reset mechanism.

| Part / state | Effect of a SUCCESSFULLY EXECUTED current warm-system-reset path |
|---|---|
| PS A53 / Linux / daemons | System restart and fresh Linux processes, not merely restarting one service |
| PS peripherals / DDR controller | Re-established by reset/boot software; not a claim that every stuck interconnect is recoverable |
| DDR memory chips | Not power-cycled or securely erased; warm-reset retention details are distinct from Linux restart |
| PL, HDMI RX/VPHY, PCIe endpoint, DMA state | BOOT.BIN includes PL; normal reboot reloads/reinitializes PL and interrupts capture/link. Do not infer all external reset-net waveforms from this |
| Independent NUC1262 MCU | No reset is requested through its external RESETn chain; it normally continues with existing software state |
| IT6663 | No guaranteed direct assertion of its external RESETn from PS soft reset; any later MCU recovery is a separate action |
| Si5341 | FSBL reprograms its configuration table (including any IC-specific soft-reset commands); not a board-level power cycle or proof of external RESETn assertion |
| eMMC | PS controller/boot access is re-established; stored files persist. No claim of an eMMC external RESETn pulse without measurement |
| x86 host / card power rails | No host reboot and no board power cycle |
| PMU/always-on/persistent state | Not equivalent to a complete cold POR; do not assume every retained register is cleared |

V11 schematic direction matters:

```text
external PS POR X0_PS_PORb -> PS_POR_B
                         -> SR17 -> MCU RESETn -> MCU/AND logic -> IT6663 RESETn

host PERST# AND X0_PS_PORb -> endpoint reset only
```

An internal soft-reset request does not drive those PS input nets low.
Likewise, pressing the SRST button is not automatically equivalent to POR:
SRST/POR are distinct, and R62/R116 are NC in the schematic.
This is why MCU/IT6663 state may survive a firmware update reboot, and why
warm-host-reboot failed to recover the currently unresponsive PS.

**Evidence:** actual `test_app/qpcie_upgrade{,_daemon}.c`; local cached ATF
`plat/xilinx/zynqmp/plat_psci.c` and `pm_service/zynqmp_pm_api_sys.c`;
embeddedsw c9a0ee31b2 `pm_core.c`, `xpfw_resets.c`;
V11 pages 10/11/13/36. See
[reset/recovery review](sc7f0_reset_recovery_review.md).
AMD references:
[UG1087 RESET_CTRL](https://docs.amd.com/r/en-US/ug1087-zynq-ultrascale-registers/RESET_CTRL-CRL_APB-Register),
[RESET_REASON](https://docs.amd.com/r/en-US/ug1087-zynq-ultrascale-registers/RESET_REASON-CRL_APB-Register).
These are source/topology conclusions, not measured waveforms.

## Implemented watchdog layers

### 1. Restart a stalled daemon

`test_app/sc7f0_health.h` is called by the **actual main loop** of debug,
HDMI and upgrade daemons. It emits READY/WATCHDOG Unix datagrams to systemd and
atomically publishes a root-owned progress record in `/run/sc7f0-health`:

- actual PS kernel boot_id;
- main PID;
- monotonic progress timestamp;
- optional fixed-duration COMMIT lease.

No independent feeding thread. A blocked MMIO/I/O main loop cannot keep
asserting health. Child processes cannot publish as the parent's main loop.

| Service | systemd watchdog | start limit | restart delay |
|---|---:|---:|---:|
| debug | 20 s | 30 s | 2 s |
| HDMI | 20 s | 30 s | 2 s |
| upgrade | 180 s | 120 s | 2 s |

Stop/abort grace is 5 s. Lack of input video or host connection is not itself a
hang: a responsive idle/no-signal loop remains healthy.

### 2. Reset PS/system if service recovery cannot succeed

`test_app/sc7f0_ps_watchdog.c` is the **sole** FPD hardware-watchdog owner.

- Verifies aarch64 and the kernel device path `fd4d0000.watchdog`, with
  `nowayout=1`; no guessed MMIO or arbitrary device override.
- Opens the Cadence watchdog through its kernel driver, verifies identity,
  and requests a 60-second hardware timeout.
- 120-second grace measured from **Linux monotonic boot**, not renewed every
  guardian restart.
- Then requires fresh debug/HDMI progress <=45 s and upgrade <=240 s.
- A fault latches and stops all further pings. The latch contains the boot_id
  and survives guardian restart within that boot.
- Guardian has `Restart=no`: crashing it must expire the hardware watchdog,
  not create an endless re-arm cycle. Manual stop is refused.
- PID1 RuntimeWatchdogSec and RebootWatchdogSec are 0: never two owners.
- Kernel enables WATCHDOG_SYSFS, WATCHDOG_NOWAYOUT and CADENCE_WATCHDOG.
- PMU firmware enables its Error Manager. FPD SWDT action remains
  **EM_ACTION_SRST**, programming PMU ERROR_SRST_EN directly.
  **ENABLE_RECOVERY remains disabled**: this does not use the graceful
  APU/ATF recovery handshake and its subsystem-restart fallback.

A kernel-wide scheduling hang stops guardian pings and should expire in ~60 s.
A partial hang may first wait for the relevant progress budget, then the
hardware timeout. These are intended timings; actual reset coverage is pending
bench acceptance. FPD watchdog still depends on its own clock/power/reset
logic. It is NOT independent external POR and cannot guarantee every SoC fault.

### Upgrade protection and boot limits

COMMIT publishes one non-renewing lease, maximum 300 s. While valid, debug/HDMI
faults do not interrupt an otherwise progressing upgrade. Upgrade's OWN
freshness requirement, systemd watchdog and hardware watchdog remain active.
A kernel hang during COMMIT still cannot be made power-fail-safe by a watchdog;
preserve backups and do not perform fault injection during writes or DMA.

FSBL Si5341 BUSY waits are bounded (~100 ms each); complete clock-table
programming retries have a ~45 s budget with controller reset/page-cache
invalidation. The SDK polled-send FIFO loop is also bounded. This permits a
separately running MCU watchdog to release a shared bus before boot gives up.
Linux watchdog ownership starts later; it does not cover all BootROM/early-FSBL
failures. No software timeout can rescue every permanently unacknowledged MMIO.

## Build / audit / files

```sh
cd /home/zzlee/qpcie
bash scripts/sc7f0_ps_watchdog_build.sh --out build/<FRESH_PS_ONLY_DIRECTORY>
```

The script refuses overwrite, checks the frozen base hashes and matching XSA,
builds PetaLinux and ARM daemons, audits FIT binaries/units/kernel/DT/PMU EM,
runs the actual C archive verifier, packages both candidate and rev06 rollback,
and saves source snapshot/manifests. It does not contact hardware.

Candidate directory:
`build/sc7f0-ps-watchdog-20261024-r1-release/`

- `upgrade-ps-watchdog-20261024-r1.tar`: strict four-member PS/PL boot bundle.
- `rollback-26102206.tar`: strict four-member original rev06 bundle.
- `images/`: new PS boot components, kernel config, unchanged PL input.
- `fpga/`: frozen bit/XSA, NOT newly synthesized.
- `RELEASE.sha256`, `release.json`, `SOURCE.sha256`, `source-snapshot.tar.gz`.
- `logs/`: build, tests, PMU patch/nm, FIT audit and C archive verification.
- `build.ok/package.ok` use PS-only markers; do not forge the generic FPGA
  build gate or use a changed PL version as proof of this PS-only upgrade.

An intermediate build exposed a real recipe issue: meta-xilinx-tools replaces
SRC_URI with EMBEDDEDSW_SRCURI. The PMU patch was corrected to append the latter
and PMU was rebuilt. Final audit requires both applied patch log and compiled
`EmCfgInit` symbol, not merely patch-file presence.

## AFTER operator cold reboot: controlled deployment / acceptance

**Not executed yet. No unattended flashing or automatic host power-off.**

1. Verify genuine recovery: fresh PS kernel boot_id, advancing heartbeat,
   responsive debug and upgrade daemons. Cached READY or endpoint enumeration
   is not enough. Preserve the host kernel boot_id too.
2. On development machine, check `sha256sum -c RELEASE.sha256` from the
   candidate directory. Transfer the strict bundle plus host tool sources;
   compile the corrected qpcie_upgrade tool on x86.
3. Quiesce video/audio DMA. Back up all three current boot files and verify
   hashes. Existing rev04 and rev06 rollback artifacts must remain intact.
4. Use existing VERIFY -> COMMIT protocol; never retry an ambiguous COMMIT.
   Example on x86: `sudo ./qpcie_upgrade --package <candidate.tar>` (VERIFY),
   then `sudo ./qpcie_upgrade --commit`. Check eMMC file hashes through a
   separate fresh PS debug command before any reboot.
5. Record PS boot_id; request `sudo ./qpcie_upgrade --reboot`. This is a
   PS-dependent warm reset, not an out-of-band recovery command.
6. Require changed PS kernel boot_id, exact `/etc/sc7f0-recovery-release`,
   advancing debug/HDMI heartbeat, and all four services active. PL version
   correctly remains `0x26102206`.
7. Inspect guardian journal for ARMED, sysfs identity/state/nowayout/timeout,
   and `sc7f0_ps_watchdog --check-health /run/sc7f0-health`.
   **Do not run wdctl or open /dev/watchdog merely to inspect it.**
8. Separately validate real HDMI frames/TPG/restart and normal upgrade VERIFY.
   MCU/IT6663 may still need their separate, previously proven runtime
   reconnect; do not mistake this PS watchdog for MCU/whole-board recovery.
9. Only with explicit authorization and no flash/DMA activity: SIGSTOP one
   daemon and verify systemd restart; separately SIGSTOP the guardian and
   verify actual hardware reset/fresh boot_id. Never inject disabled MMIO.
10. Roll back via the preserved rev06 bundle if necessary while PS is healthy;
    if boot/control is unavailable, use an operator-assisted boot/JTAG/eMMC
    recovery path. A backup directory alone is not a bootable automatic A/B
    fallback.

Do not intentionally stop required services or the guardian for ordinary
maintenance: with nowayout, persistent loss of progress leads to reset.
Actual audio payload/rate and audible A/V acceptance remain unfinished.
