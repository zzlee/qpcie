# SC7F0 PCIe PS command channel (ABI 1 / debug-first PL 26101504)

Current scope/build/CDC status: [sc7f0_cdc_timing.md](sc7f0_cdc_timing.md).
The `26101504` candidate disables external HDMI and skips host AV/I2C/SPI
initialization. Its board acceptance is pending; the historical `26101501`
artifacts below failed whole-design timing and must NOT be deployed.

## Goal and boundaries

Execute one non-interactive shell command on the card's A53 Linux from the
PCIe host, with separate stdout/stderr, exit status, cancellation and timeout.
No Ethernet/UART, DMA, DDR staging region, firmware-upgrade doorbell or eMMC
access is needed for **debug transport**. The command itself can of course have
side effects: this is an explicitly enabled **root debug shell**, not a sandbox.
Do not enable it in untrusted/production deployments. Host permissions are
0600 and only one client may open a card at a time.

This is NOT a kernel console, panic dumper, R5 console, interactive TTY, XVC,
or an out-of-band recovery path. PS Linux and the daemon must be alive. PL
power/clock/reset and the PCIe link must work. Panic retention, terminal PTYs
and early boot logging are separate future work.

## Design

```
SSH to host (rd@sc7f0-test.local)
  sc7f0ctl -> existing qpcie.ko misc node -> PCIe BAR0
             100 MHz shared AXI-Lite crossbar -> 8 KiB BRAM
             PS HPM0_FPD -> /dev/mem -> qpcie_debugd -> shell -c
```

Existing BAR0 CSR `0x0000..0x0fff`, environment `0x1000..0x1fff`, video,
audio and upgrade protocol remain unchanged. A third crossbar target is added
at BAR0 `0x2000..0x3fff`, PS physical `0xA0002000..0xA0003fff`. The PS base
is stripped to a **20-bit** BAR offset, replacing the old 13-bit truncation
that would alias this new window to the DMA CSR. The slave uses `pl_clk0` /
`sys_100m_rst_n`, not PCIe link or DMA soft reset. The existing PCIe AXI clock
converter remains responsible for CDC. No new clock domain is introduced.

The mailbox infers block RAM with synchronous reads. AW and W are latched
independently, and B/R stay valid under backpressure. Invalid alignment,
partial writes and writes to immutable hardware magic/ABI return SLVERR.
The crossbar responds DECERR outside all windows. Control words reset to
zero; payload memory is not reset or trusted until a frame is published.

### Why framed slots rather than full rings / virtual TTY

ABI 1 uses two one-slot producer/consumer queues (capacity one frame each).
They are simpler to validate, and sufficient for diagnostic shell throughput.
Output streams are chunked under backpressure, not truncated to one buffer.
This avoids premature TTY drivers, prompt parsing, echo loops and per-byte
PCIe MMIO. No throughput comparable to DMA is claimed.

`include/qpcie_debug.h` is the authoritative register/protocol definition:

| Relative offset | Writer | Meaning |
| --- | --- | --- |
| `0x00 / 0x04` | hardware | immutable magic `0x53434442`, ABI 1 |
| `0x08 / 0x0c` | card | READY, random daemon epoch |
| `0x10 / 0x14` | host / card | random session epoch, drain/attach ACK |
| `0x18 / 0x4c` | card / host | monotonic millisecond heartbeats |
| `0x1c / 0x20` | host / card | request sequence / consumption ACK |
| `0x24..0x2c` | host | request type, ID, byte length |
| `0x30 / 0x34` | card / host | response sequence / consumption ACK |
| `0x38..0x44` | card | response type, ID, byte length, exit code |
| `0x48` | host | execution budget in milliseconds (1..300000) |
| `0x400..0xfff` | host | request payload, max 3072 bytes |
| `0x1000..0x1bff` | card | response payload, max 3072 bytes |

All MMIO is aligned **32-bit little endian**, including padded final payload
words. The CQ decoder currently ignores PCIe byte enables and emits full
WSTRB, so byte stores are NOT safe. The misc node enforces alignment, bounds
and host-owned write offsets. It does not expose mmap or other BAR0 registers.
It shares the existing PCI function/driver; it is NOT another PCI driver.

Producer: write payload + metadata, publish SEQ last. Consumer: read SEQ,
metadata + payload, then ACK only what was consumed. Slots use sequence
equality, including u32 wrap. Host kernel uses ioread32/iowrite32 and a safe
same-endpoint readback to flush posted writes; an SMP barrier alone is not
sufficient. PS maps Device memory with /dev/mem O_SYNC and uses `dmb sy`.

Before accessing the aperture, the host driver checks the explicit hardware
allowlist `26101501/26101502/26101504` (failed03 was never deployed); the current PS daemon checks its exact
build version `26101504` on the established CSR page. Neither accepts an open
version range or probes unknown old firmware. Mailbox ABI remains 1.

### Sessions and execution

- Host chooses a fresh random nonce per open; daemon kills old work, drains
  stale slots, and acknowledges this nonce before any new request is sent.
- Daemon chooses a new random epoch on start. Host observes epoch, READY,
  nonce ACK and changing heartbeat; stale READY is not proof of liveness.
- EXEC invokes configured `/bin/sh -c` or `/bin/bash -c`, with stdin from
  `/dev/null`, separate stdout/stderr pipes, and a dedicated process group.
  Environment/cwd are those of the daemon; `cd`/exports do not persist across
  invocations. Command length is 1..3071 bytes, no embedded NUL.
- Stdout/stderr preserve per-stream bytes, not their cross-stream ordering.
  On success the CLI exits with the remote shell status (0..255).
- Status 124: budget exceeded; 125: cancellation/transport/internal error;
  126: execution disabled; 127: shell exec failed. Shell commands can also
  independently return these same codes. Ctrl-C/TERM CLI exits 128+signal.
- CANCEL and timeout SIGKILL the process group. A disconnected client or
  non-consuming client stops heartbeats; after ~3 seconds the daemon kills
  the group and abandons the session. A blocked local stdout consumer can
  trigger this protection. A stopped/dead daemon makes the host fail closed.
- PID is not reaped until output drains and group cleanup completes, avoiding
  a PID/PGID reuse race. systemd KillMode=control-group cleans all service
  children on restart. Commands deliberately using setsid/daemonization can
  escape the process-group timeout; this is NOT a general remote job service.
- **No automatic retries of submitted commands**, even after ambiguous
  disconnect. A transport failure may mean the command already had effects.
- Payloads and metadata are not authenticated against hostile PCIe actors.
  Root-only access is a local permission boundary, not cryptographic security.

## Build and test

From repository root:

```bash
iverilog -g2012 -s qpcie_debug_mailbox_tb -o /tmp/debug.vvp \
  rtl/qpcie_debug_mailbox.v tb/qpcie_debug_mailbox_tb.sv
vvp /tmp/debug.vvp
python3 tb/qpcie_debug_tb.py
bash tb/qpcie_debug_rootfs_tb.sh
source /opt/Xilinx/Vivado/2023.2/settings64.sh
vivado -mode batch -source scripts/sim_qpcie_debug.tcl
vivado -mode batch -source scripts/sim_zu4ev_ps_axi_protocol.tcl
# After implementation, review new paths AND the whole-design timing report:
vivado -mode batch -source scripts/report_sc7f0_debug_timing.tcl
make -C driver clean && make -C driver
make -C test_app clean && make -C test_app all qpcie_debugd
```

Require TB_PASS, not just simulator exit 0. Native RPC tests run real daemon
and client against an explicitly selected temporary mmap file, with no root
or hardware: 10 MiB random loopback, binary streams, nonzero exit, timeout,
cancel, concurrent-open rejection, client death, daemon restart, no duplicate
execution, corrupt lengths, sequence wrap, execution opt-in, stale readiness.
The focused crossbar test uses the same production IP configuration and tests
both masters concurrently, old aperture isolation and unmapped DECERR. The
PS protocol test covers nonzero AXI4 IDs separately. Neither is a full PCIe
host or Zynq PS hard-block simulation.

### Production rootfs

The Yocto `qpcie-debugd` recipe installs the service and Bash. Recipe/config
changes persist across PetaLinux builds; service defaults to **echo only**.
To enable shell execution on the card, explicitly install root-owned mode
0600 `/etc/default/qpcie-debugd` containing:

```ini
DEBUG_EXEC_ARGS=--allow-exec
DEBUG_SHELL=/bin/bash
```

Then restart `qpcie-debugd.service`. Remove/clear DEBUG_EXEC_ARGS to disable
execution. An image without Bash can use `/bin/sh` (not Bash syntax).

The existing production image injection flow can also include this service:

```bash
# Point copies at an isolated candidate directory, NOT the published installer.
mkdir -p build/debug-first/candidate
REL_TARGET_DIR="$PWD/build/debug-first/candidate" \
  INCLUDE_DEBUG_DAEMON=1 ENABLE_DEBUG_EXEC=1 \
  bash scripts/inject_upgrade_daemon_to_image_ub.sh
```

This explicit lab-only flag installs an execution-enabled config (selects
Bash if present). Without ENABLE_DEBUG_EXEC, the rootfs helper explicitly
clears execution even on a reused rootfs. **Never inject the debug/upgrade
services into the standalone SD installer RAMDisk.**

Hardware changes require C_VERSION, regenerated targets/XSA, PetaLinux
hardware-description import, image/BOOT.BIN rebuild and release hashes. Do
not combine a new daemon with an old PL and claim functional validation.
The user explicitly authorizes PCIe flash-image update and necessary board
reboot after validation. Preserve the old image/driver, require upgrade VERIFY
before COMMIT, and never reboot the Host. Timing/CDC gates still apply.

## Hardware acceptance after installing the matching image

SSH reaches the **host**, not PS. Test host `rd@sc7f0-test.local` uses dynamic
IP; PCI BDF is currently `0000:03:00.0`. Host reboot need not power-cycle the
board; use the established PCIe flash-image upgrade/reboot workflow.

1. Verify BAR0 magic/version using existing safe tools, PCIe Gen3 x4 and no
   concurrent upgrades/video stress. Load the rebuilt host driver only after
   the validated PL 26101504 is confirmed. Preserve old driver/artifacts.
2. Node `/dev/qpcie-debug-0000:03:00.0` should exist, mode 0600.
3. Run these **proposed acceptance commands**, not evidence of completed tests:

```bash
sudo ./test_app/sc7f0ctl status
sudo ./test_app/sc7f0ctl loopback 10485760
sudo ./test_app/sc7f0ctl exec 'uname -a'
sudo ./test_app/sc7f0ctl exec 'printf OUT; printf ERR >&2; exit 7'; echo $?
sudo ./test_app/sc7f0ctl exec 'dmesg | tail -n 100'
sudo ./test_app/sc7f0ctl --timeout 1 exec 'sleep 10'; echo $?
# Ctrl-C should cancel this, without destabilizing PCIe or PS:
sudo ./test_app/sc7f0ctl exec 'sleep 30'
```

4. Require byte-accurate loopback, exit 7, timeout 124, successful subsequent
   commands and no new PCIe AER errors. Test simultaneous-open rejection and
   client/daemon restart. Do not use panic, devmem of unverified addresses,
   eMMC writes, firmware COMMIT or board POR as first acceptance commands.

## Implementation files

- `rtl/qpcie_debug_mailbox.v`, `rtl/custom_pcie_dma_top.v`
- `scripts/create_bar0_crossbar.tcl`, `scripts/build_zu4ev.tcl`
- `include/qpcie_debug.h`, `driver/qpcie_debug.c`
- `test_app/sc7f0ctl.c`, `test_app/qpcie_debugd.c`, `test_app/qpcie_debug_io.h`
- `petalinux/.../recipes-apps/qpcie-debugd/`, `scripts/install_debug_rootfs.sh`
- `scripts/strip_sc7f0_mmio_services.sh` (standalone installer only)
- `tb/qpcie_debug_*`, `scripts/sim_qpcie_debug.tcl`

## Historical 26101501 validation record (2026-10-15; not a release)

- SSH/sudo: PASS; host kernel `7.0.0-38-generic`, `03:00.0` Gen3 x4,
  running driver `qpcie-dma`, existing PL `26101401`, upgrade IDLE. No live
  driver reload, board reboot, firmware COMMIT or eMMC write was performed.
- Native RPC suite: PASS repeatedly, including 10 MiB random loopback,
  Bash arrays, closed stdio and inherited SIGCHLD handling; also PASS under
  UBSan. GCC `-fanalyzer` found no remaining diagnostics.
- Mailbox AXI regression, production-crossbar regression: TB_PASS.
- Existing PS AXI ID protocol, client-tag/RC, DDR readback, upgrade CSR and
  START CDC regressions: all TB_PASS.
- Host driver and all host tools: compile PASS locally. Driver source also
  compiled on the SSH test host without being loaded. Old firmware correctly
  has no debug node; CLI refuses with 125 instead of probing new registers.
- Static ARM64 daemon and Yocto `qpcie-debugd` recipe: compile/package PASS.
- Rootfs install/enable/disable, standalone installer removal of both MMIO
  services/binaries/presets, and host-root guards: TB_PASS.
- ZU4EV bitstream/XSA generation: completed, mailbox inferred as block RAM.
  **Whole-design timing FAILS**: WNS -1.399 ns, TNS -5524.436 ns, WHS
  +0.010 ns. clk_pl_0 intra-clock WNS +1.271 ns; pcie_user_clk +1.185 ns.
  Mailbox register paths (1084 registers, both from/to): minimum reported
  setup +3.596 ns and hold +0.030 ns. These positive paths do NOT waive the
  inter-clock failures or 44831 unconstrained internal endpoints / 16124
  no-clock pins reported for the full design. Historical `build_zu4ev.log`
  already records global WNS -1.728 ns; non-closure predates this feature,
  but that is not proof this candidate is safe to deploy.
- New XSA imported into PetaLinux; both tracked XSA copies have identical
  SHA-256. Full PetaLinux build, patched FSBL and BOOT.BIN packaging completed.
  Rootfs archive contains Bash, debug daemon and enabled service; execution
  remains disabled by default. Production upgrade-daemon injection and
  execution-enabled installer publication were **intentionally blocked** by
  the timing gate. Existing `release/zu4ev_sd_installer` was not overwritten.
  The images/linux outputs are intermediate candidates, NOT installable
  release artifacts. Logs: `build/debug-channel/{vivado,release}.log`;
  exit markers are 0 (Vivado generation) and 2 (release withheld for timing).
- Required A50T build was attempted separately and fails on missing
  `ila_ps_axi_0` in its build IP list; that unconditional instantiation already
  exists in baseline `bdda0a3`. This unrelated A50T build gap was not fixed.
  Previous A50T build directory was preserved/restored; failure log is
  `build/debug-channel/a50t.log`.
- **No on-board command-channel acceptance has been performed.** Timing/CDC
  review and passing release gates are required before producing an installable
  image. The later user authorization permits PCIe update after those gates;
  it does not waive them or approve this failed 26101501 candidate.

Intermediate artifact SHA-256 (not a release manifest):

```text
bit  44c4679c9d2924c2917420b51511ed63cf38d30305348411bb829fa08f29c559
XSA  dc1a72d10397977655bd9b45a24065c565c40cc0cc0b803c19a074c82598a585
BOOT 72342867e8896b0c53018161d184e922c4fe7e91695181d3f130a019eb7f15db
FIT  68e439a287357049460db39aa569a6a30196ee8ebd6427f7d3f08d8b144d12ff
```

Bitstream embeds the build-start base Git ID `bdda0a3`; source was committed
following tests/build, so use this record plus the XSA/bit hashes rather than
claiming the embedded ID alone identifies the full feature changes.
