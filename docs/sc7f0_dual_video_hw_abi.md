# SC7F0 dual-video hardware ABI — packet transport and historical capture

> Current source: R5 `26102803`, C2H-only production personality. The capture-descriptor/CSR writer below is **historical and disabled** (`LEGACY_CAPTURE=0`); production PS capture uses official V4L2/VIPP at framebuffer `0xb0050000`, CSC `0xb0060000`, tap/GPIO `0xb0070000`. The separate DPV1 packet ABI at `0xb0040000` remains relevant. R4 fits resources but failed timing; R5 is rebuilding. Test host offline: no MMIO/SSH/deployment. Next authorized phase is VCU + PS daemon, no longer deferred; see `docs/sc7f0_vcu_daemon_plan.md`. Older readiness/deferral statements below are historical, not current signoff.

**Hardware source and simulation implemented. R1 synthesis passed, but implementation failed timing and HDMI licensing; no bit/XSA/package. FIFO reset source was corrected and simulation repeated; revised RTL has not been re-synthesized/routed. Not deployed or hardware-accepted.**
Worktree `/home/zzlee/vibecoding/sc7f0-dual-video`, branch `feat/sc7f0-dual-video-vivado`, base2bce1d8.
No MCU modifications, VCU codec implementation, host compressed V4L2 driver or PetaLinux deployment in this phase.

## Paths

- A: existing4PPC HDMI/TPG → raw RGB/NV12/NV16 capture → PCIe/host. Existing audio unchanged.
- B: independent observer of accepted HDMI RX AXIS → dedicated RGB8 pack/BT.709 CSC → async video FIFO →4PPC NV12 packer → AXI128 HP1 →PS DDR.
- C: PS DDR → AXI burst reader → full-TLP CDC → shared PCIe RQ encoder →host payload and separate64-byte completion record.
- No VCU instance yet. C accepts any binary payload; codec software will produce/submit AU segments later.
- ILA removed from RTL/IP generation. Management mailbox retained.

B never drives HDMI RX READY, so a full DDR queue cannot backpressure A. Ordinary raw STREAMOFF continues draining RX.
A and B still share the physical RX; a forced raw pipeline sub-reset/exceptional raw input backpressure can temporarily interrupt the accepted RX stream.
B detects malformed/incomplete frames rather than publishing them as successful. This is not a claim of fault isolation across arbitrary RX/reset failures.
The300MHz-derived capture clock now resets from PS, not host link; B memory reset is independent of raw engine sub-reset.
Capture's ordinary clock is150MHz; PCIe125MHz; control clock is PS~100MHz.

## PS memory/control interfaces

- Existing HP0 upgrade/readback unchanged.
- New `S_AXI_HP1_FPD`:128-bit, nominal150MHz `dp_mem_clk`; bursts bounded to4KiB, up to16 beats.
- Supported DMA addresses below2^40, zero extended into PS49-bit address ports.
- PS HPM1 control crossbar MI3: **0xb0040000–0xb0040fff**. Existing TX aperture0xb0020000–0xb003ffff is not overlapped.
- New PL IRQ0[3] is level-high while either completion queue is nonempty (GIC SPI92 under existing IRQ mapping).
- CSR exists on the PS control clock and returns errors for unsupported accesses; it does not wait on an absent video clock.
- **Do not probe the new address on the deployed26102702 image.** A matching bit/XSA/PS init and software allocation must precede hardware use.

Control is PS-only in this revision. Future host/PS software must validate and exchange host DMA credits; no host virtual pointer is a DMA address.
No Linux driver or buffer reservation is installed by these RTL changes. DMA-coherent allocation / cache synchronization and reserved-memory non-overlap remain software integration work.
Quiesce both DMAs before changing clocks/resetting PS; arbitrary mid-TLP independent reset recovery is outside this first-phase acceptance.

## CSR ABI DPV1

32-bit little-endian registers; independent AXI-Lite AW/W handling; staging writes support WSTRB.
Doorbells atomically snapshot staging words into16-entry ordered command queues.
Completion FIFO heads remain stable until explicit POP, allowing coherent multiword reads.

| Offset | Access | Meaning |
|---|---|---|
|000|RO|magic0x44505631 (DPV1)|
|004|RO|ABI0x00010000|
|008|RO|bit0 frame-submit-ready,1 packet-submit-ready,2 frame-done-valid,3 packet-done-valid,4 frame-owned,5 packet-busy|
|00c|W1|submit capture descriptor (bit0)|
|010|W1|pop capture completion|
|014|W1|submit packet descriptor|
|018|W1|pop packet completion|
|01c|RO|capture ticks/sec150000000|
|020|RO|unowned/dropped input SOF count|
|024|RO|capability7: RGB8→NV12, packet DMA, host completion record|
|040–05f|RW|8 capture staging words|
|080–0df|RW|24 packet staging words|
|200–21f|RO|8 capture completion words|
|240–27f|RO|16 packet completion words|

Unsupported address/alignment: DECERR. Full command queue / empty completion POP/read: SLVERR.
No software reset doorbell that might abort outstanding AXI transactions is exposed.

### Capture descriptor (8 words)

0/1 Y base64;2/3 UV base64;4 `{height16,width16}`;5 stride;6 cookie;7 reserved=0.

First implementation: RGB8 HDMI only, converted to8-bit NV12 with2×2 rounded chroma average.
Width16..4096 and multiple16; height2..2160 and even; stride>=width, <=65520 and multiple16.
Both bases16-byte aligned; planes must not overlap and their strided extents must fit40-bit address space.
Bad config emits an error completion without issuing memory writes. Full Y/UV queues invalidate this frame, never backpressure RX.
Only one owned frame executes at a time; subsequent descriptors are queued. Submission does not guarantee capture of the immediately following SOF if it arrives before descriptor CDC/prefetch.

Capture completion:0/1 PTS ticks64;2/3 source-frame counter64;4 cookie;5 status;6 payload bytes;7 reserved.
Status bits:0 invalid config;1 invalid/incomplete raster;2 queue overflow;3 AXI B error;4 total-byte mismatch.
Success requires all accepted writes and B responses drained, plus exact width×height×1.5 payload count; row padding is not counted as payload.
PTS is latched at the accepted SOF in the150MHz memory/capture domain, not DMA completion time.
This is not yet a common hardware timestamp exported on the old host raw node; precise A/B/audio clock correlation is later software/interface work.

### Packet descriptor (24 words)

| Word | Meaning |
|---|---|
|0/1|PS source DMA address64|
|2/3|host destination DMA address64|
|4|effective payload byte length|
|5|host destination capacity|
|6/7|host completion DMA address64|
|8/9|PTS64|
|10/11|DTS64|
|12/13|packet sequence64|
|14/15|source frame ID64|
|16|flags|
|17|stream epoch|
|18|cookie|
|19|timebase numerator|
|20|timebase denominator|
|21..23|reserved|

Flags:0 AU_START,1 AU_END,2 keyframe,3 codec-config,4 PTS_VALID,5 DTS_VALID,6 EOS,7 discontinuity.
Metadata is preserved; hardware only interprets EOS to permit a zero-length payload.
Starts are16-byte aligned. Payload length is arbitrary0..8MiB and <=capacity; zero length requires EOS.
Source backing allocation must cover the16-byte-rounded AXI read tail. PCIe byte enables prevent rounded data from overwriting the host payload tail.
Invalid pointers/config produce only a PS-side error completion, never an attempted write through an invalid host completion address.

A job is one **contiguous segment**, not a hardware-fetched arbitrary host SGL. Software can submit page/SG segments with common frame/sequence/PTS and AU boundaries.
Host SGL ownership/credit exchange is not implemented in this phase; do not claim a complete compressed V4L2 product interface.
AXI reads and PCIe TLPs independently split at4KiB and256-byte limits. First/last byte enables and variable RQ TKEEP handle non-DWORD lengths.
The256-bit RQ encoder now supports arbitrary1..64-DWORD payloads; old32/64-DWORD video and128-bit requester regression still pass.

### Host completion record (64 bytes, separate from payload)

0 magic0x44504331 (DPC1);4 status;8 sequence64;16 frame-ID64;24 PTS64;32 DTS64;
40 transferred bytes;44 flags;48 epoch;52 cookie;56 timebase numerator;60 denominator.

Status:0 success;bit0 invalid job;bit1 AXI R error;bit2 RLAST/length error.
After a partial error, transferred bytes counts only fully submitted payload chunks, not untransmitted read data.
A record is submitted only after all preceding payload TLPs have been acknowledged by the local RQ encoder. All writes retain default ordered attributes.
PS completion FIFO returns the same record after the host record's RQ transaction finishes; source ownership is not released early.
There is no new packet-specific host MSI in this revision; host memory completion polling is the initial integration interface. PS queue IRQ is available.
Do not interpret local RQ acknowledgement as a remote host application having consumed the buffer.

## Packet arbitration

Existing SG and low-bandwidth audio priority preserved. Raw-video and packet DMA alternate at packet boundaries when both are waiting.
An owner is never preempted inside a TLP. Packet metadata/byte enables stay associated with that owner.
Actual arbiter RTL unit test checks ownership,ack routing,fairness and SG/audio priority; unrelated IPs are explicitly unresolved in this focused test.

## Evidence so far

- `build/dualpath-sim-logs/final.log`: official XPM simulation, independent clocks and AXI/RQ backpressure.
  NV12 pixel-exact64×8 stride80 and full3840×2160; concurrent65537-byte packet during4K capture.
- Packet lengths1,3,4,15,16,17,255,256,257,4095,4096,4097,65537 checked byte-for-byte, including tail guards and host-record PTS.
- Initial simulation failures preserved in attempt logs: implicit forward net caused unknown header pop; generic RQ tail had fixed-four-DWORD assumption;
  repeated capture retained row state. Fixed rather than waiving checks. Exact byte-count guard added.
- Sim Tcl explicitly checks the final test_pass bit; Vivado's process exit0 alone is not a pass.
- Existing20 fast video/packing/doorbell cases,128/256-bit RQ tests,PCM/audio/trace simulations pass.
- `build/dual-video-26102703-r1-logs/`: source SHA snapshots, fresh IP/BD logs, full-build PID, synthesis/implementation logs.
  Source mismatch, timing/CDC gate failure or missing final marker prevents build.ok/XSA acceptance.

Top synthesis completed successfully (0 errors /0 critical warnings; ordinary vendor/source warnings remain). Fully resolved hierarchical synthesis counts112 RAMB36+15 RAMB18 = **119.5 equivalent BRAM36/128**, URAM0. This includes all OOC IPs; the bare synthesis resource table alone excludes black boxes and must not be used as the full count.
R1 placement confirmed119.5/128 equivalent BRAM36. Route failed setup: WNS−0.228ns, TNS−41.492ns/568 endpoints, WHS+0.010ns. Reported failing paths originate PCIe link state and reach packet completion FIFO CSR-domain read CE. Fixed by separate async-assert/sync-release read-domain reset in sc7f0_dp_fifo, not a timing waiver. Official-XPM reset/flush/reuse checker plus full4K/13-size packet simulation repeated PASS in build/dualpath-reset-r2.ZQRNCowY.
R1 bitstream generation also denied HDMI RX/TX encrypted IP licensing. The documented server2101@192.168.200.97 is unreachable (lmutil−15); current environment has no license server configured. Requires valid server access and IP output regeneration. R1 exact original RTL/build inputs preserved and SHA-verified in build/dual-video-26102703-r1-logs/source-r1/.
Revised-source synthesis/route, setup/hold/skew/CDC and matching bit/XSA remain **not yet passed**. No hardware validation or deployment performed. User now authorizes upgrade after the complete validated package is ready; this does not authorize MCU updates or host reboot.
