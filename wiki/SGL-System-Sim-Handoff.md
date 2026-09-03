# Handoff: End-to-End SGL Loopback System Simulation (in progress)

> Written 2026-09-03 by the previous coding agent, mid-debugging. Read fully before
> touching anything. All findings below were verified against RTL source and xsim runs.

---

## 1. Mission

Validate the **host SGL fetch linked-page path** (FPGA issues tag-1 MRds to read host
SGL tables) end-to-end. The production validation plan lives in
[wiki/Host-SGL-Validation-Plan.md](file:///home/zzlee/qpcie/wiki/Host-SGL-Validation-Plan.md).

Current status:
- Direct-DMA loopback baseline PASSES on the Jetson board (`force_sgl_fetch=0`, ~934 MiB/s).
- Forced-SGL mode (`force_sgl_fetch=1`) **hangs on real hardware** — zero completions in
  both directions, at every resolution, across two bitstreams.
- A full-system SGL loopback simulation (`tb/tb_sgl_loopback_system.v`) is being built to
  reproduce/hunt the hang. It is NOT passing yet — see §6.

## 2. Git state

```
272c1ce fpga: decouple SGL table fetch from consumer backpressure   <- newest, flashed
2995109 fix(v4l2): publish H2C loopback descriptor before C2H ...
4a9006d feat(qpcie): add force_sgl_fetch knob ...
2ea1bb5 docs: ... SGL validation plan
```

Working tree: only `tb/tb_sgl_loopback_system.v` is untracked/new (the sim under debug).

History of fixes so far (in order):
1. `4a9006d` driver: `force_sgl_fetch=1` module param; 4 KiB-split SGL table builder with
   explicit error propagation; rejects buffers on build failure. Log line
   "host SGL fetch enabled (force=1)". → Hardware still deadlocked.
2. `2995109` driver: publish H2C descriptor before its C2H partner (ring order). Theory was
   a serial-dispatch deadlock (desc_fetch blocks in WAIT_SGL_FETCH). → Hardware still deadlocked.
3. `272c1ce` RTL: rewrote `rtl/sg_host_fetch_engine.v` to buffer each direction's full SGL
   table on-chip (BRAM FIFOs: Y 2048 x 16B, UV 1024 x 16B) and drain to the consumer in the
   background, decoupling fetch completion from consumer backpressure. New demux outputs
   `sgl_y_channel`/`sgl_uv_channel` in `rtl/custom_pcie_dma_top.v`. 26/26 sims pass incl. a
   deadlock test. Timing closed WNS=+0.044ns. **Flashed and re-tested — hardware still
   hangs with the identical symptom.**

Conclusion from the identical hardware symptom across bitstreams: the standalone fetch
engine + unit TBs were fine; the failure lives in a path the sims never exercised — the
**integration** (tag-1 MRd/CplD flow through the bridge ↔ desc_fetch ↔ walker ↔ H2C engine
↔ loopback ↔ ch1 NV12 capture engine ↔ C2H MWr). That is what the new system TB must cover.

## 3. Hardware symptom (authoritative)

Jetson Orin NX, loopback_test_app 1080p & 4K forced-SGL:
```
TX: 7 / RX: 0        (7 = buffers queued pre-STREAMON; RX: 0 = ZERO completions)
NV12M STREAMOFF: drained=1 head=0 tail=0 video_errors=0   (head never advanced)
```
Driver-side SGL tables are CORRECT per dmesg (Y 507 entries/1 chain, UV 254,
ctrl=0x69/0x6B, addresses sane). `dmesg` shows no SMMU/IOMMU faults. The FPGA never
completes even the first descriptor (`head=0` forever in direct reads).

Note: BAR0[0x34] exposes the git hash of the HEAD the bitstream was built from. Board log
showed `0x2EA1BB55` (= `2ea1bb5`, parent of the RTL change) on the FIRST test round. The
newest flashed bitstream was built at `2995109` HEAD (RTL identical to `272c1ce` since the
commit only touched the TB+docs afterwards — verify: no RTL change between 2995109 and
272c1ce other than what was already in the build). **Always re-confirm the flashed hash via
`dmesg | grep 'Git Commit Hash'` after a reflash.**

## 4. Byte-order & AXI-stream conventions (PAINSTAKINGLY VERIFIED)

These are THE critical facts. Do not "fix" them. Source of truth: `rtl/pcie_7x_axi_bridge.v`
and the passing `tb/tb_pcie_7x_axi_bridge.v`.

**Native 7-series RX/TX header DWs are RAW (NOT byte-swapped) on the 128-bit bus:**
- DW0 (fmt/type/length) at `tdata[31:0]`. `0x60000001` = 4-DW MWr len 1 (fmt=2'b11 @[30:29],
  type 0). `0x4A000010` = CplD (fmt=2'b10, type 01010, 16 data DWs). `0x01000000|len` = 4-DW
  MRd (fmt=01) etc. The bridge decodes `rx_data = m_axis_rx_tdata` RAW for headers.
- DW1 at [63:32] (CplD: byte count in DW1[11:0]; MRd/MWr: ReqID[31:16], tag[15:8], BE[7:0]).
- DW2 at [95:64] (addr hi for 4-DW TLPs; CplD: ReqID/tag/lower-addr).
- DW3 at [127:96] (addr lo for 4-DW TLPs).
- `m_axis_rx_tuser[2]` = BAR0 hit on RX requests (bridge maps tuser[3..7]→BAR1..5, else BAR0).

**Payload DWs ARE byte-swapped per 32-bit lane** (`host_dw` = `payload_bswap32`): on the wire,
byte 0 sits at AXI [31:24], so a lane holding host value V carries `host_dw(V)`.

**4-DW MWr into the bridge (host MMIO write):**
- Beat 0 (tlast=0, keep=FFFF): `{addrLo@[127:96], addrHi@[95:64], {reqID,0xF,0xF}@[63:32], 0x60000001@[31:0]}`. Bridge latches addr/reqid/tag and moves to RX_MWR4_BEAT1 — does NOT emit a CQ beat for beat 0.
- Beat 1 (tlast=1, keep=000F): payload at native `[31:0]` = `host_dw(data)`. Bridge emits the single CQ beat with the write data at `cq[127:96]`, 64-bit addr at `cq[63:0]`.
- Back-to-back writes work; handshake on `m_axis_rx_tready` between beats (bridge may hold beat 1 while the CQ decoder is busy with a previous write).

**CplD response (host read completion) — 5-beat example for 64 B (16 DWs):**
- Beat 0: `{host_dw(payloadDW0)@[127:96], {reqID, tag, 0}@[95:64] (DW2 RAW), (len*4)@[63:32] (byte count RAW), 0x4A000000|len@[31:0]}`.
- Beats 1..N: up to 4 payload DWs per beat, each lane `host_dw()`, DW i in lane `((i-1)%4)*32`, partial final beat keep 1→000F / 2→00FF / 3→0FFF, tlast on the final beat. Beat0 carries DW0; beats then carry DW1.., so 128-DW reads = 1 + 31×4 + 3 = 33 beats.

**rc_rx_decoder assembly (desc CplD):**
```
beat0 -> desc_cpl_data[31:0]  = rc_tdata[127:96]        (DW0)
beat1 -> desc_cpl_data[159:32] = rc_tdata[127:0]        (DW1..DW4, lane order)
beat2 -> desc_cpl_data[287:160]
beat3 -> desc_cpl_data[415:288]
beat4 -> desc_cpl_data[511:416] = rc_tdata[95:0]        (DW13..15)
```

**Descriptor wire format** (`driver/qpcie_driver.h`, `struct qpcie_dma_desc_64b`, 16 DWs):
DW0-1 plane0_src, DW2-3 plane0_dst, DW4-5 plane1_src, DW6-7 plane1_dst, DW8-9 plane2_src,
DW10-11 plane2_dst, DW12 = {line_count[31:16], line_width[15:0]}, DW13 = {dst_stride,
src_stride}, DW14 = {plane12_count, plane12_width}, **DW15 = {reserved[31:16],
control[15:8], plane_count[7:4], format[3:0]}**. For ch1 H2C SGL: control=0x69 → DW15 =
0x0000_6922. C2H: 0x0000_6B22. RTL reads control from `desc_cpl_data[495:488]`.

**SGL entry (16 B)**: DW0-1 phys addr, DW2 len, DW3 flags (bit0 CHAIN_PTR, bit1 LAST_SEG).
Slot = 4 KiB = 256 entries; index 255 reserved for the chain pointer.

## 5. What was learned debugging the TB (two real bugs, both fixed)

1. **Uninitialized queue pointers**: `mmio_wr` reg declared but never reset → stayed `x` →
   FSM never saw queued writes. Init both `mmio_wr`/`mmio_rd` at start of the main block.
2. **Stale-tvalid idle cycle between beats (THE big one)**: a task pattern
   `@(posedge clk); drive beat N; @(posedge clk); while(!tready) @(posedge clk);` followed by
   another leading `@(posedge clk)` before driving beat N+1 leaves `tvalid=1` with the OLD
   beat data on the bus for one extra cycle. The bridge samples the same beat TWICE → a 5-beat
   CplD became 8 RC beats → `desc_cpl_data` assembled shifted/garbled. FIX RULE: **the moment a
   beat's handshake completes, assign the next beat's data in the SAME timestep** (no leading
   `@(posedge clk)` at the top of the next-beat block). This matches the bridge TB's driving.

## 6. Current sim state & the remaining bug

`tb/tb_sgl_loopback_system.v` (untracked) — full-system SGL loopback, 2048x512 NV12M
(Y = 256 SGL entries, 2-slot chained Y table + Y→UV switch; both H2C and C2H descriptors;
host memory models; procedural BFM). Run harness:

```bash
cd /home/zzlee/qpcie
rm -rf work_sim/run-sglsys && mkdir -p work_sim/run-sglsys
export XILINX_VIVADO="/opt/Xilinx/Vivado/2023.2"; export PATH="$XILINX_VIVADO/bin:$PATH"
cd work_sim/run-sglsys
xvlog --sv /opt/Xilinx/Vivado/2023.2/data/ip/xpm/xpm_cdc/hdl/xpm_cdc.sv \
           /opt/Xilinx/Vivado/2023.2/data/ip/xpm/xpm_fifo/hdl/xpm_fifo.sv \
           /opt/Xilinx/Vivado/2023.2/data/ip/xpm/xpm_memory/hdl/xpm_memory.sv
xvlog /home/zzlee/qpcie/rtl/*.v /home/zzlee/qpcie/tb/tb_sgl_loopback_system.v
xvlog /opt/Xilinx/Vivado/2023.2/data/verilog/src/glbl.v
xelab tb_sgl_loopback_system work.glbl -s sglsys_sim
timeout 120 xsim sglsys_sim -runall 2>&1 | grep -E 'RC[0-9]|MRD|PASS|FAIL|Fatal'
```

Latest run (after the beat-timing fix):
```
[PASS] MMIO config landed
[MRD] tag=0 reqid=0408 addr=ffffe000 len=16 DW        <- descriptor fetch
[RC0] tag=0 len=16 data=00000000_00002000_00000010_00400000
[RC1] data=20002000_0000...                            <- CORRECT (carries DW4=0x20002000)
[RC2] data=0...
[RC3] data=02000800_0000...
Fatal: timeout ... desc=1 sgl=0 h2c=0 head=1 tail=1 fetch_busy=0
```

Decoded: RC0 metadata is right (tag=0 @[71:64], dword count=16 @[42:32], byte count=64 in
[28:16]) but **RC0[127:96] (payload DW0) = 0 instead of 0x20000000** and **req_id [87:72] =
0x0020 instead of 0x0408**. RC1..RC4 (payload DW1..15) are correct. So the corruption is
isolated to the FIRST native beat → the bridge's RX_IDLE CplD handling of beat 0, or the
beat 0 the bridge actually saw differs from what `respond_cpld` assigned.

An `[RCn] ... | nat=... nat_valid=... rx_state=...` probe (already added, prints the native
beat + `u_bridge.rx_state` at each RC beat) was added to the TB right before this handoff —
**re-run and read it; it prints the exact native beat the bridge consumed for beat 0.** That
should immediately reveal whether the native beat 0 lanes were what `respond_cpld` assigned.

Things to check next (in order):
1. Re-run with the `| nat=... rx_state=...` probe and compare beat-0 lanes against the
   assignment `{host_dw(mem_dw(mr_addr)) @[127:96], (0x0408<<16)|0 @[95:64], 64 @[63:32],
   0x4A000010 @[31:0]}`. (mem_dw(RING_BASE+0) = ring_mem[0] = 0x20000000, so [127:96] should
   be `host_dw(0x20000000) = 0x00000020`.)
2. Verify no leftover state from the last MMIO write (bridge `rx_state` should be RX_IDLE
   well before the descriptor MRd response; if RX_MWR4_BEAT1/RC-related states linger, the
   ordering of `mmio_write_bar0`'s final deassert vs. the MRd response matters).
3. Check the descriptor fetch path end-to-end: once RC0 is fixed the SGL fetch (tag 1 MRds,
   64 B each) should start (`sgl` counter), followed by H2C payload MRds (512 B = len 128,
   tags 2..17), then Phase B C2H.
4. The 512 B H2C payload CplDs must ALSO be beat-accurate (33 beats) — the same
   immediate-next-beat rule applies (respond_cpld's data loop already follows it).
5. Phase B is triggered inside the single dispatcher process (no fork/join — a fork would
   double-drive m_axis_rx). Keep it that way.

## 7. What the TB does / design notes

- DUT = `pcie_7x_axi_bridge` + `custom_pcie_dma_top` on one 125 MHz clock (video_clk = clk;
  note the real design has a 150 MHz video clock, but SGL fetch/H2C/C2H live on the 125 MHz
  PCIe side — single-clock keeps the CDC FIFOs out of the way for this test).
- Memory map: ring 0xFFFFE000, H2C payload 0x1000_0000 (Y) / 0x1100_0000 (UV), H2C SGL slots
  0x2000_0000.., C2H SGL slots 0x3000_0000.., C2H dst 0x4000_0000 (Y) / 0x4100_0000 (UV).
  `mem_dw()` routes read addresses; anything unexpected returns 0xDEAD_BEEF so corruption is loud.
- Descriptor 0 = H2C NV12M ch1 SGL (plane0_src = H2C Y slot, plane1_src = H2C UV slot,
  DW15 = 0x00006922). Descriptor 1 = C2H (plane0/1_dst = C2H slots, DW15 = 0x00006B22).
- H2C payload data = stream index (Y: 0..Y_DWS-1, UV: Y_DWS..). Loopback is 1:1 so captured
  C2H data must equal the index; `check_captured()` compares all 393,216 DWs.
- Phase A publishes only the H2C descriptor (tail=1) and asserts the SGL fetch completes and
  desc head advances even though H2C stalls once the 1 KB loopback FIFO fills. Phase B
  (tail=2) is published from within the dispatcher when head==1 && ≥4 H2C MRds observed.
- Fatal on: MMIO config not landing, no descriptor MRd, no SGL MRd, desc head != 2 at end,
  data mismatch, global 6e6-cycle timeout.

## 8. Repro/verification commands (full suite + build)

```bash
./sim/run_sim.sh                          # full sim suite (26 TBs) — must stay green
make -C driver clean && make -C driver    # driver must compile
./scripts/build_a50t.sh                   # bitstream; timing: WNS>=0, TNS=0
```

Board procedure (after the sim reproduces & the fix is found & flashed):
```bash
cd ~/qpcie && git pull --ff-only
make -C driver clean && make -C driver
./scripts/flash_a50t.sh
sudo rmmod custom_pcie_av 2>/dev/null
sudo insmod driver/custom_pcie_av.ko force_sgl_fetch=1
sudo dmesg -C
./test_app/loopback_test_app -o /dev/video1 -d /dev/video2 -w 1920 -h 1080 -b
./test_app/loopback_test_app -o /dev/video1 -d /dev/video2 -w 3840 -h 2160 -b
sudo dmesg | grep -E 'SGL ch|DMA ch|SG fetch|NV12M STREAMOFF'
sudo dmesg | grep -Ei 'smmu|iommu|context fault|decode error|protocol error'
```
Then restore baseline `force_sgl_fetch=0` and confirm direct mode still passes. Acceptance
criteria: log shows `host SGL fetch enabled (force=1)`, Y 2025/UV 1013 entries with nonzero
chains at 4K, `100% BIT-EXACT MATCH PASS`, STREAMOFF `drained=1 head==tail
video_errors=0`, no new IOMMU faults. Do NOT relax timing; do NOT disable the Tegra SMMU;
do NOT let forced-SGL throughput be compared against the direct-DMA baseline.

## 9. Pitfalls / constraints

- NEVER drive `m_axis_rx_*` from two procedural processes (races — see §5/§6 note 5).
- All FPGA MRds on this design are 4-DW (64-bit address), fmt=2'b01, tag byte at native
  [47:40], req id at [63:48], addr = {tdata[95:64], tdata[127:96]}. C2H MWrs are fmt=2'b11.
- Host CplD req_id must echo the MRd's requester id (0x0408 observed = bus 4/dev 0/func 8 —
  the PCIe core's own completer id from cfg inputs).
- SGL table addresses must be 4 KiB aligned (slots are 4 KiB), entries 16 B.
- The 7-series core uses tuser for EOF; the bridge accepts `tlast` as a fallback
  (`rx_eof = tuser[21] | tlast`), and with tlast the bridge honors the driven `tkeep` for
  partial final beats. tuser=0 with tlast=1 works.

---

## 10. Continuation update (2026-09-03)

The system TB now passes end-to-end after finding two integration RTL bugs and several TB BFM issues.

RTL fixes:
1. `rtl/custom_pcie_dma_top.v`: `sg_host_fetch_engine.fetch_start` used the dangling/unassigned `h2c_desc_ready` wire for H2C descriptors. It now uses the actual SG DMA ready signal, `sg_h2c_desc_ready`. This explains the hardware symptom of zero tag-1 SGL MRds in forced-H2C SGL mode.
2. `rtl/sg_host_fetch_engine.v`: the UV plane slot address was read from the live muxed `plane1_slot_addr` input during `S_NEXT_BURST`/`S_SWITCH_UV`, after `h2c_desc_valid` had already dropped. For H2C this mux fell away from `h2c_plane1_src`, so only Y was fetched. The engine now latches `curr_plane1_slot_addr` at `fetch_start` and uses the latched value for UV switching.

TB fixes in `tb/tb_sgl_loopback_system.v`:
- Sized the CplD beat-0 concatenation fields exactly to 32-bit lanes; an accidental 129-bit concatenation shifted the native CplD header/payload.
- Reworked FPGA->host TX handling into an always-on monitor/queue so MRd headers and C2H MWr payloads are captured while the BFM is concurrently driving RX CplDs. This avoids losing requester TLPs on the full-duplex PCIe link.
- Phase-B publication now polls while waiting for queued MRDs, so it fires even after Phase A quiesces with H2C stalled on the loopback FIFO.

Verification:
```text
SGL loopback system TB:
  [PASS] Phase A: SGL fetch complete while H2C stalled
  [PASS] H2C frame completed, desc head=2 (desc=2 sgl=194 h2c=3072)
  [PASS] C2H captured 393216 DWs in 6144 MWr bursts
  [PASS] 393216 C2H payload DWs match the H2C stream exactly
  SUCCESS: SGL loopback system verified end-to-end (host SGL fetch)

./sim/run_sim.sh: 26 Passed, 0 Failed
make -C driver clean && make -C driver: PASS (expected compiler/pahole/vmlinux warnings only)
```

Next required step: build timing (`./scripts/build_a50t.sh`), flash (`./scripts/flash_a50t.sh`), confirm BAR0 git hash in `dmesg`, then rerun forced-SGL hardware loopback at 1080p and 4K.
