# SC7F0 debug-first profile, CSR CDC and release gates

Status: candidate `0x26101504`, ABI 1. **Not yet board-validated or released.**
The user's priority is a working PCIe → PS Linux command/debug path, not HDMI
bring-up. The user now explicitly permits PCIe flash-image upgrades and a board
reboot if needed, AFTER design/clock/timing/integrity validation. Never reboot
the Host as part of this workflow. No hardware mutation has yet been performed.

## Scope

`scripts/build_zu4ev.tcl` defaults to `SC7F0_PROFILE=debug`. It defines
`SC7F0_DEBUG_ONLY`, excludes external HDMI/DDC/300 MHz ports and the HDMI
PHY/RX/TX/CDC/EDID hardware, and does not generate the corresponding HDMI IP.
`constraints/zu4ev_debug_pinout.xdc` contains only the V11 PCIe/LED pin subset.
Only external asynchronous PERST# and human-visible LEDs have I/O exceptions;
no asynchronous clock groups or custom blanket CDC false paths are added.

The PS hard block, independent 100 MHz CSR, shared 8 KiB mailbox, PCIe Gen3 x4,
upgrade H2C/PS DDR writer and DDR readback remain. Existing internal PCIe-clock
TPG/DMA/loopback plumbing is retained for diagnostics; this is not new AV work.
The hardware capability word is `0x80000010`: debug-profile bit31, canonical-map
bit4, **zero advertised video/audio channels**. Matching host-driver probe
creates only mailbox + upgrade interfaces and skips V4L2/ALSA/I2C/SPI/sysfs AV
initialization; an unrelated peripheral cannot prevent creation of debug node.
HDMI status is zero and no external HDMI operation is claimed.

The previous full AV source is preserved behind `SC7F0_PROFILE=full` for future
work, but is NOT a verified image/profile. Adding HDMI or I2C master later needs
new hardware revision, real PHY control/init, legal clocks and fresh validation.

## Baseline and rejected experiment

The `26101501` complete design failed WNS -1.399 ns, TNS -5524.436 ns, WHS
+0.010 ns, although mailbox timing passed. Inventory under
`build/cdc-timing/baseline/` found 11,653 failing PS→PCIe endpoints and 32 in the
reverse direction, plus 16,124 no-clock pins and 44,831 unconstrained internal
endpoints in uninitialized HDMI/NI-DRU logic.

The `26101502` HDMI GT-output primary-clock experiment reduced those last two
counts to zero but caused **nine TIMING-3 invalid primary clock warnings**.
Baseline CPLLREFCLKSEL was tied to `000` and PHY AXI control was unconnected.
Thus those clocks were NOT a legal hardware model, regardless of intermediate
positive WNS. The hook was removed. The experimental script is archived only
at `build/cdc-timing/constrain-hdmi-clocks-experiment.tcl`; it is not production
source. The user-stopped build was later cancelled (exit143), never exported
as the new XSA, never deployed. Its logs/checkpoints are historical diagnostics.

The debug-first `26101503` placed design had no HDMI cells, only four PCIe
GTHE4 channels, zero no-clock pins/unconstrained internal endpoints, and no
invalid clock methodology. Review caught three CDC-11 reset fan-outs: one PS
reset independently synchronized for controls, telemetry and xrun counters.
That build was cancelled before XSA export or deployment. Candidate04 shares
ONE peer-reset synchronizer per domain across those consumers, preventing
one-cycle deassertion/reconvergence differences. Historical03 reports and the
placed checkpoint are preserved under `build/debug-first/attempt03/`.

## Actual CDC repair

The authoritative CSR and AXI responses stay on independent PS `pl_clk0`.
Never relocate BAR0 to PCIe: Linux must retain access without host/slot clock.

* `qpcie_csr_cdc`: ordered XPM FIFO snapshots, 1851 control + 82 event bits.
  Each commit reserves a snapshot; the next source edge captures the updated
  bank. Backpressure prevents accepted live events from being merged/lost.
  Events last one destination cycle. Offline PS writes stay local and do not
  wait; recovery sends current levels, never replays old reset/W1C events.
* A registered heartbeat watchdog handles stopped PCIe clocks with stale
  link/reset: about 2.55 µs + synchronizer latency at 100/125 MHz. Pending DMA
  cannot be resumed transparently across clock/link loss.
* `qpcie_status_cdc`: coherent 1615-bit telemetry snapshots back to PS. Samples
  can be skipped; commands never use this path. Fresh-valid/online qualification
  prevents stale status. Separate software MMIO reads are NOT multiword atomic.
* Audio xrun pulses become a source counter, qualified by reset/online/fresh
  status to avoid phantom recovery events. Sticky clear uses actual commit.
* Upgrade START/SIZE/HOST_ADDR use ordered snapshots rather than raw buses.
  PS DDR writer, readback, HDMI IPC register bank and debug BRAM remain PS local.
* Foreign reset is synchronized BEFORE combining with the receiving domain's
  local reset. PCIe-online crossing uses a source-clock registered level, not
  a combinational core reset/link expression. Assertions remain asynchronous;
  deassertion is synchronized in the destination. Each domain reuses ONE
  synchronized peer-reset level for control bank, status FIFO and counters;
  duplicate reset synchronizers are forbidden (CDC-11).
* Existing diagnostic sticky bits are independent monotonic flags, not coherent
  payload: XPM array-single crosses their levels; XPM single crosses clear and
  ACK, with one additional ACK stage for sticky-clear settling.
* `generate_sc7f0_csr_cdc.py` generates the width-checked wrapper; `--check` is
  mandatory after interface edits and is invoked before every main build.
* Host debug allowlist is explicit `26101501/02/04` (unreleased failed03 is
  omitted); the newly built PS daemon requires exact current `26101504`
  before probing the new aperture.

## Validation / gates

Native debug RPC and UBSan regressions plus rootfs opt-in/installer guards pass.
Host driver/apps compile. CSR CDC regression passes after per-domain reset
repair: no PCIe clock, full FIFO/backpressure, ordered config/START, 80 reset +
80 W1C events, coherent telemetry, xrun/clear, stale-link clock stop, bounded
write release, recovery without replay/phantom xrun, PCIe reset and PS reset.
Upgrade sticky-clear/ACK, PS AXI ID protocol, diagnostic CSR, upgrade START
CDC, DDR readback and production mailbox crossbar integration also pass.
The debug CSR test verifies version04 and capability `0x80000010` while PCIe
clock is absent. Artifacts are under `build/debug-first/`. Full implementation
and on-board acceptance are still pending, not claimed passes.

`check_sc7f0_timing.py` fails closed before XSA export on negative whole-design
setup/hold/pulse-width/skew, incomplete clock coverage, unconstrained internal
endpoints, unknown/critical CDC, invalid clock methodology, or overridden
CDC max-delay constraints. Unit regression `tb/sc7f0_timing_gate_tb.py` tests
negative/missing/malformed reports, not just the pass case. The build also
records detailed CDC, check_timing, clock-interaction and methodology reports.
Remaining vendor XPM FIFO CE/LUTRAM/reset warnings require source-level review;
a passing automated gate is necessary, not sufficient, for release.

Only after final reports and integration tests pass: import the matching XSA,
rebuild PetaLinux/patched FSBL/matching BOOT.BIN, explicitly opt the LAB image
into root shell execution, record SHA-256 manifest (integrity, NOT signature),
then use established PCIe VERIFY/COMMIT upgrade with old image/driver preserved.
Accept on the board: byte-accurate loopback, Bash exec, stdout/stderr, exit7,
timeout124, cancellation, exclusivity, reconnect/restart and no new PCIe errors.
Do not call the channel complete until these are observed on real hardware.
