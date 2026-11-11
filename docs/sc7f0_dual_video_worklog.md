# SC7F0 dual-video Vivado implementation worklog

## Latest: R6 full-profile hardware accepted; matching PS build active

R6 `26102804` completed synthesis/route/bit: WNS+0.671ns/WHS+0.010ns, LUT70010/87840, BRAM89.5/128, URAM0. Its original debug-profile gate remains rejected (`build.exit=1`); separate exact full C2H/capture review accepted all5116 CDC paths,25 reset cones/276 truth cases, physical I/O roles, pinned DRC detail/vendor configurations and positive STA.49 positive/mutation/native tests and fresh actual-XPM/official-CSC/framebuffer safety simulations pass. The latter also asserts IRQ follows outstanding AXI B retirement. New ABI1.1 ordered stop token replaces sampled status as teardown proof; kernel retries reuse a pending fence, preserving ownership on permanent faults.

Accepted XSA: `build/r6-reviewed-acceptance.tQ3I92jj/hardware.xsa`, SHA `3a39c1faf5d2e14c1fb5d68aa171030fc65bbba58511f64b406e0e9d880b3075`; embedded bit byte-matches actual R6 bit, SHA `f70a2cb61c42ff3175c2191203a8cdae5c636b1f627377a4202d6a384ee06d3e`. This is hardware scope only, not zero warnings or deployment readiness. Review: `docs/sc7f0_full_profile_r6_review.md`; five-stage ledger: `docs/sc7f0_continuous_todo.md`.

Matching PS build has imported that XSA into this worktree, with private TMPDIR and shared downloads/sstate only. Launcher PID3063083; logs `build/ps-matching-r6.8cps4WtZ-launch.log`. Full kernel/rootfs/boot/package acceptance and card tests remain pending; no full-card build remains running. No MCU operation, flash, PS reboot or host reboot. VCU hardware/executable daemon remain unimplemented. Permanent DMA/IRQ/clock failure may deliberately block close; no reset/reclamation workaround is approved.

## Previous: test host ONLINE; deployment/testing authorized after gates

Operator reports the test machine online again and requests direct flashing/testing once the build is ready. Read-only SSH succeeded: host kernel7.0.0-38-generic, bootID `c7915db6-0a6d-4917-93bc-7e8045d54270`, qpcie driver bound, deployed FPGA still `26102702`. No board/host reboot, firmware write, client quiesce or MCU operation was performed. Prior offline restrictions below are historical; no MCU update or host reboot is authorized.

R5 `26102803` is FINISHED, exit1, not running. Synthesis/route/bit generation and setup/hold pass: WNS+0.698ns, WHS+0.010ns, TNS/THS0; LUT69810/87840, BRAM89.5/128, URAM0. Gray checks pass before opt and after route. Strict CDC/methodology gate REJECTED: CDC10Critical29/CDC12Critical10, unreviewed warnings2628, I/O coverage/methodology findings. No XSA/hardware.ok or matching PS package. Result: `build/dual-video-26102803-r5-logs/result.json`. Do not flash that rejected bit.

An exact-path CDC inventory against frozen deployed26102702 has been generated:5084 current paths,3438 exact clock/path matches,1206 removed baseline paths. All39 Critical rows are catalogued as32 asynchronous-reset synchronizer entry paths and7 probe-level diagnostic paths. Those categories are NOT approvals: reset cone/release, diagnostic source/use, FIFO ownership and collision evidence still require review. `scripts/audit_sc7f0_cdc_delta.py` verifies complete summary/detail counts and preserves exact identities/multiplicity;5 tests PASS. Evidence: `build/.r5-cdc-review-latest` points to complete `paths.csv`/`review.json` and read-only host status. No gate was weakened or new waiver added.

Next: close exact CDC/I/O/methodology findings, build matching XSA/kernel/rootfs/package, then quiesce clients → VERIFY → backup → single COMMIT → independent eMMC SHA readback → PS reboot/boot-ID proof → scoped capture/raw/audio/packet acceptance. VCU/PS daemon is authorized but not yet implemented; it remains the subsequent integration task, not a claimed feature of R5.




## 2026-10-28: offline test host; VCU is next authorized phase

Operator reports the SC7F0 test machine OFFLINE. No SSH/probing, deployment, PS/host reboot or MCU operation while unavailable. After this hardware-build stage, prioritize VCU and PS apps/daemon; previous VCU deferral is superseded. See `docs/sc7f0_vcu_daemon_plan.md` for implementation sequence, DMA ownership/PTS/host-credit/service safety and pending runtime gates.

R4 has finished, REJECTED: linked-cell pruning PASS; placed LUT69814/87840, BRAM89.5/128, URAM0; bit generated, but setup WNS−2.020ns/TNS−193.700ns/128 endpoints, hold+0.001ns. No XSA/hardware.ok/package. Failure was diagnosed: `if/foreach` in capture Gray XDC ignored by Vivado, so intended max-delay/skew did not apply. R4 logs/result.json preserve failure. Unrolled XDC plus full-Tcl exact128-path/effective6ns checks are now implemented. Read-only corrected-constraint R4 DCP diagnostic passes all128 direct paths: WNS+0.959ns/WHS+0.001ns, TNS/THS0; this is NOT a rebuilt/released bit. CDC/methodology remains unreviewed (including reset/FIFO structures), no blanket waiver.

R5 `26102803` fresh build launched PID1608583, `build/dual-video-26102803-r5` with sibling logs, prescribed license2101. Pre-opt/post-route checks included. New constraint-hook tests plus C2H/caps/CSR checks:7methods PASS, covering six negative missing/overridden/unsafe mappings. No hardware input edits during R5. VCU preparation has identified local official IP/recipes/OMX DMA-buffer extensions, but no VCU instance or executable daemon is claimed yet. Physical capture/encoding/zero-copy/three-route concurrency remain pending until test environment restored.


> Current status (2026-10-28): R3 rejected before placement for LUT overuse. Operator narrows production to raw video + encoded packets + raw audio C2H and authorizes unused IP removal. R4 `26102802` is building with TX/TPG/auxiliary streams excluded; raw capture engine is unchanged. Linux capture integration and matching host personality changes are implemented, not hardware-accepted. See the current-status section in `docs/sc7f0_ps_v4l2_capture_plan.md`; older entries below are chronological evidence, not current readiness claims.

## Scope / isolation

- Operator requests Vivado paths first: retain HDMI→PCIe→host; add HDMI→PS DDR; add PS DDR→PCIe→host variable packet DMA with timestamps. VCU encoding/software deferred.
- Worktree `/home/zzlee/vibecoding/sc7f0-dual-video`, branch `feat/sc7f0-dual-video-vivado`, base `2bce1d8`.
- Original `/home/zzlee/qpcie` MCU WIP and frozen26102702 artifacts are untouched. No MCU operations or live deployment.

## Completed: ILA source removal

- Removed PS AXI ILA and probe-only status logic from `rtl/custom_pcie_dma_top.v`.
- Removed ILA IP generation from `scripts/build_zu4ev.tcl`.
- Guarded LTX export in main/existing implementation scripts when no debug cores exist.
- Kept the independent debug mailbox, PS control and DMA interfaces intact.
- Source checks, Tcl completeness and `git diff --check` pass. No new synthesis/routed utilization yet.
- Prior routed design attributed19.5 equivalent BRAM36 to ILA. That is the potential reclaimed amount, not a newly synthesized result.

## PPC discussion (not a change request yet)

- Existing HDMI RX/TPG/CSC/pack paths are primarily4PPC; HDMI4K60 video clock148.5MHz, capture domain150MHz. PCIe256-bit and DDR128-bit bus widths are not PPC settings.
- 4PPC×150MHz and2PPC×300MHz both sustain600Mpixel/s.2PPC may lower arithmetic parallelism, but retaining the same buffered pixel count requires twice as many FIFO words, so BRAM does not automatically halve.
- SG table/PCIe/ILA memories are not reduced by PPC.300MHz requires new pipeline/timing analysis, not just swapping clock/width parameters.
- Recommendation: retain validated4PPC raw path for this implementation; consider a4→2 gearbox only on the new DDR branch if a measured resource/timing comparison justifies it. Do not silently change the whole design to2PPC.

## Original next steps (RTL/BD now implemented; physical signoff still running)

- PS HP1 memory interface and additional AXI-Lite control window (proposed PS0xb0040000; existing TX aperture covers0xb0020000–0xb003ffff).
- Independent frame-aware DDR tap, NV12 packing/frame writer and geometry/error/ownership handling.
- Variable-length PS DDR reader, packet/timestamp/completion descriptors, packet CDC and PCIe C2H arbitration/byte-enable support.
- Targeted simulations, raw/audio regressions, fresh Vivado synthesis/implementation and matched XSA. Do not call dual paths complete until these exist and pass.

## Implementation progress

- Added PS HP1 at150MHz, PS AXI-Lite0xb0040000, level IRQ0[3], RGB8→NV12 independent DDR writer, command/completion CDC queues and variable packet DDR reader/C2H.
- Added separate64-byte host completion records with PTS/DTS/frame/sequence/timebase, true tail byte enables and variable-DWORD RQ packing. Core arbiter preserves SG/audio priority, nonpreemptive ownership and raw/packet fairness.
- Official-XPM full4K NV12 plus parallel65537-byte packet simulation PASS; all13 packet sizes, tail guards and PTS checked. Small stride-padding capture PASS.
- Existing20 fast video cases,128/256 RQ regression,PCM/audio/trace and actual core-arbiter focused test PASS. No MCU tests.
- Source and build-script SHA snapshots: build/dual-video-26102703-r1-logs/.
- Full top synthesis PASS; hierarchy112 RAMB36+15 RAMB18 =119.5/128 equivalents. No ILA, no VCU.
- R1 implementation STOPPED exit1; wrapper PID541308 no longer running. WNS−0.228ns/TNS−41.492ns/568 endpoints; WHS+0.010ns. R1 placed BRAM119.5/128.
- Exact reported setup issue: raw PCIe link state reaches CSR-domain packet completion FIFO CE. Fixed sc7f0_dp_fifo with separate rclk reset synchronization (no waiver). Added independent-clock off-edge reset/flush/reuse checker; full4K/13-size simulation repeated PASS in build/dualpath-reset-r2.ZQRNCowY. Revised source has NOT been re-synthesized/routed. Original R1 inputs preserved and SHA-verified under logs/source-r1.
- R1 HDMI RX/TX IP license denied bitstream. Initial old2101@192.168.200.97 was unreachable. User identified192.168.200.112, started service and updated development-host/etc/hosts. Name now resolves; lmgrd/xilinxd reportUP and v_hdmi/v_hdmi1 features are listed (not by itself a Vivado checkout/bitstream PASS).
- User explicitly specifies XILINXD_LICENSE_FILE=2101@192.168.200.112. R2 starts with that exact environment, not the manager diagnostic port2100. No global license or DNS settings changed by agent.
- R2 FINISHED exit1: bit generated; WNS+0.653ns/WHS+0.010ns, LUT81451/87840, BRAM119.5/128, URAM0. Strict CDC/methodology gate rejected CDC-10 Critical34/CDC-12 Critical8 and other findings; no XSA/hardware.ok/package/upgrade. LauncherPID785255 ended; logs/result.json preserve evidence and source snapshots. No blanket waivers.
- User authorizes continuation with REQUIRED official PS V4L2 capture. Two official4PPC IP probes (framebuffer+VPSS CSC) synth PASS; actual paired64x64 RGB→NV12 simulation with stride padding and DDR stalls PASS. Standard PS capture app, recipe and inactive kernel fragment added; ARM64 -Werror/API-model tests PASS. Whole-card integration, DT graph, source SOF metadata, kernel image and hardware capture remain pending. Current requirements/evidence: docs/sc7f0_ps_v4l2_capture_plan.md and docs/sc7f0_ps_capture_app.md. R2 stays a baseline, not automatic deployment candidate.
- USER AUTHORIZATION: upgrade card once complete validated SC7F0 package exists. Existing updater consumes upgrade-VERSION.tar with exactly BOOT.BIN/image.ub/boot.scr/manifest, not a standalone upgrade.bin. Quiesce capture, VERIFY→backup→COMMIT once→independent eMMC SHA→PS reboot+boot ID→scoped acceptance. No MCU update or x86 reboot. No live operations performed yet.
- Existing check_sc7f0_timing.py is the strict debug-era checker, whereas frozen HDMI26102702 has scoped reviewed CDC advisories. If it rejects the new report, preserve the failure and review exact baseline/new paths; do not blanket waive or bypass the gate.
