# Direct-pull page flip ABI v1 (stage-1 candidate)

Probe BAR0+0x4000+0x88 for `0x44500101`; do not infer support from the board
version. This note reserves the interface for driver work; it is not a signoff
or evidence of a deployed image. All offsets below are relative to 0x4000.
One owner serializes MMIO; no other BAR/PS writer may operate the plane.

| Offset | Access | Meaning |
|---|---|---|
| 88 | R | Capability/signature above |
| 8c | RW | bit 0 selects direct-pull v1; bit 1 enables output-frame IRQ (source 9). Enter/leave with legacy CTRL.enable/go clear and DMA drained. |
| 90 | W | SUBMIT: full-word nonzero cookie. Snapshot legacy staging address (04/08), bytes (0c), MRd limit (10). |
| 94 | R | Last admitted cookie; read back after posted SUBMIT. Rejected writes change no descriptor. |
| 98 | R | Pending cookie: stays occupied from admission through presentation; no overwrite even if fetch already started. |
| 9c | R | Active cookie: changes only at confirmed presentation, zero when disabled and drained. |
| a0 | R | Retired cookie: old active on replacement. |
| a4 | R | Output SOF handshake count, modulo 2^32, including base-only, independent of submit/IRQ enable. |
| a8 | R | bit 0 DMA drained after disable (all accepted buffers safe); bit 1 fault. |

Use strictly increasing 32-bit cookies across disable/re-enable; no reuse within
a device epoch. Fixed RGBA 3840x2160, contiguous 32-byte-aligned IOVA,
33177600 bytes, request cap 0 (default) or a multiple of 32. Enable v1 while
legacy engine is idle, configure compositor blend/base, then submit. Pending
launches on the next eligible base end-of-frame; late submits wait for a later
frame. Replay fetches the selected source each eligible frame without further
submits. Active means the tagged, paired and blend-enabled SOF beat handshook
at the blender output to the TX FIFO; it does not mean physical HDMI scanout.
Polling active and pending is sufficient. No base/output acceptance means no
presentation; timeout does not release memory. Retirement requires cessation
of issue for the old IOVA and completed/quiescent old reads.

Clear mode to disable issue, keep CTRL.enable/go clear and wait for DMA drained;
this cancels pending and releases both mappings, not a presentation event. This
is a host memory fence, not proof that already buffered pixels left TX. Disable
blend separately for immediate base-only operation. Disable first inhibits new
MRds while maintaining the ingress GO level until a previously presented
RQ header has been accepted and every outstanding MRd has completed. Only then
is the arm withdrawn. An unexpected abort or soft reset during v1 operation
latches FAULT and suppresses DRAINED until PL reconfiguration;
retain mappings and use coordinated device teardown, never a soft reset to
reclaim them. Disappearing status or IRQ is not a release fence.

The cookie namespace restarts only on full PL reconfiguration (also clears the
video queues). `ADMITTED` is an FPGA INIT=0 register with no PCIe/DMA/video
reset. Scheduler working state uses `pcie_user_lnk_up && !pcie_user_reset`.
After **any** admission, even after a successful disable, a PCIe reset clears
the scheduler epoch-ready latch but **not** ADMITTED. On the first live clock
this forces FAULT=1, DRAINED=0, rejects *all* cookies (even newer ones) and
ignores delayed output acknowledgements until PL reconfiguration. During reset
STATUS can read zero; it is not DRAINED. A driver reload/close without reset may
resume from ADMITTED+1 only after verifying normal disabled/drained idle.
Do not wrap at `0xffffffff`. A failed disable must retain mappings until the
driver has independently established physical device teardown and bus-master
quiescence. Reconfiguration alone is not a software DMA-unmap fence.
Frame counter deltas across reset are
invalid. The counter measures output SOFs, not a generated 60-Hz timebase.

Implementation: the accepted descriptor, next fetch selection and DMA ownership
live in `pcie_user_clk`. The source cookie is sampled on ingress `arm_ok`;
payload BRAM carries it alongside the SOF through the existing Gray-pointer
crossing. On the 300-MHz side a four-entry metadata FIFO pushes on each accepted
SOF into the URAM stream and pops on accepted overlay SOF out of the unpacker;
when full it backpressures the next SOF. The 16K-deep URAM payload stays 129
bits wide. The overlay queue and all three elastic blend stages carry identity;
base-only or blend-disabled tokens produce cookie zero. An XPM handshake holds
the new nonzero cookie until transfer back to PCIe; software cannot admit the
next one before that acknowledgement. A separate XPM pulse crosses frame
boundaries; the 32-bit frame counter itself never crosses a clock. XPM scoped
constraints and the existing 3.333-ns ingress pointer max-delay/skew constraints
must be measured on the routed design before this is a deployable ABI.
