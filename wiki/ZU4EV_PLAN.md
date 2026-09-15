# XCZU4EV PL PCIe Video Plan

> Status: planning and architecture review only. No ZU4EV application RTL or
> project build scripts are to be implemented until the hardware pinout, PCIe
> IP configuration, and a vendor-example Tandem feasibility test pass the
> decision gates in this document.

## 1. Objective

Port the verified A50T video/audio DMA design to
`xczu4ev-fbvb900-2-e`, using the **PL UltraScale+ Integrated Block for PCI
Express** rather than the Zynq MPSoC PS PCIe controller.

Selected IP:

- Product: **UltraScale+ Devices Integrated Block for PCI Express**
- Vivado IP name: `pcie4_ultrascale_plus`
- Product guide: PG213 v1.3 or the version bundled with Vivado 2023.2
- Endpoint target: PCIe Gen3 x4
- Transaction interface: native PG213 CQ/CC/RQ/RC AXI4-Stream descriptors
- Device identification: Vendor `0x12AB`, Device `0xE380`

The first data path remains PL TPG RGB24 capture to host memory. PS PCIe is
disabled. PS DDR can be added later but is not required for the initial direct
PL-to-host DMA path.

Evidence labels used below:

- **Verified**: supported by cited AMD documentation or inspected repository source.
- **Planning default**: selected architecture, still subject to implementation proof.
- **Decision gate**: must be confirmed by schematic, generated Vivado artifacts,
  calculation, simulation, or hardware evidence before implementation proceeds.

## 2. Verified Device Resources

PG213 Tables 6, 44, and 127 list the following resources for
`XCZU4EV-FBVB900`:

| Resource | Verified value |
|---|---|
| Available PCIe hard blocks | `PCIE40E4_X0Y0`, `PCIE40E4_X0Y1` |
| Tandem/Field Update supported location | `PCIE40E4_X0Y1` |
| Gen3 x4 GT choice | `GTH_Quad_223` |
| Maximum target for this project | Gen3 x4 |

Therefore the planning default is:

```text
PCIe block : PCIE40E4_X0Y1
GT quad    : GTH_Quad_223
Link       : Gen3 x4
```

This selection is provisional until the board schematic confirms that the
four PCIe lanes and reference clock are routed to Bank/Quad 223. If the board
routes an incompatible GT quad, the PCB routing and Tandem-capable block
selection become a blocking issue.

### Signals that must be confirmed from the board schematic

- PCIe RX/TX lane package pins and physical lane order.
- Lane polarity swaps and whether lane reversal is required.
- PCIe reference-clock package pins, electrical standard, and frequency.
- Host-driven `PERST#` package pin and its I/O bank.
- QSPI type, width, maximum reliable clock, boot-mode pins, and image capacity.
- Whether the reset pin is in configuration Bank 65.

The local recovery reference project confirms the target part but does not
contain a reusable PL PCIe XDC/pinout; its PS PCIe and QSPI settings therefore
are not evidence for PL GT lanes, PL refclk, `PERST#`, or Tandem flash timing.
Those items remain schematic/example-design decision gates.

Do **not** assume that the PCIe reference clock is 250 MHz. A conventional PCIe
add-in interface normally supplies a 100 MHz reference clock, while 250 MHz can
be the generated PCIe `user_clk` for a 128-bit Gen3 x4 datapath. The final value
must come from the board schematic and generated PG213 example design. For an
add-in card using the slot clock, Phase 0 must also confirm PG213's synchronous
clock/SSC requirement and enable the PCIe Slot Clock Configuration property.

`PERST#` is an **input from the Root Port/host** for an Endpoint. The ZU4EV PMU
must not be described as driving or deasserting the host's `PERST#` signal.

## 3. Planned PL PCIe Architecture

```text
PCIe lanes/refclk/PERST#
          │
          ▼
pcie4_ultrascale_plus (PG213, Endpoint, Gen3 x4)
          │
          ├── m_axis_cq ──► CQ adapter ──► BAR0/BAR1 AXI-Lite
          ├── s_axis_cc ◄── CC encoder ◄── BAR read completion
          ├── s_axis_rq ◄── RQ encoder ◄── descriptor/H2C/C2H engines
          └── m_axis_rc ──► RC decoder ──► descriptor/H2C completion data

PL TPG ──► video capture/DMA ──► RQ Memory Writes ──► host buffers
host buffers ──► RQ Memory Reads ──► RC completion path ──► PL output
```

Initial BAR layout should remain compatible with the A50T driver and current
A50T IP configuration:

| BAR | Size | Use |
|---|---:|---|
| BAR0 | 1 MiB | DMA control/status registers |
| BAR1 | 64 KiB | AXI-Lite user-IP aperture (TPG/audio/etc.) |

BAR1 is not a 256 MiB frame buffer in the current architecture. Video payload
moves directly between the PL DMA engines and host IOVA addresses using RQ/RC
transactions.

## 4. Existing TLP Module Reuse Assessment

### 4.1 High-level conclusion

The PG213 IP exposes the same four interface families already used by
`custom_pcie_dma_top.v`:

- `m_axis_cq`
- `s_axis_cc`
- `s_axis_rq`
- `m_axis_rc`

Accordingly, ZU4EV does **not** need `pcie_7x_axi_bridge.v`. That bridge is only
needed on A50T to translate the PG054 7-series `m_axis_rx/s_axis_tx` stream into
the internal CQ/CC/RQ/RC representation.

However, matching signal names does not prove bit-level compatibility. The
existing TLP adapters cannot yet be classified as directly reusable without
modification. They must be audited against the selected PG213 width/alignment
configuration.

### 4.2 Concrete incompatibilities already identified

1. **CQ BAR ID location**
   - PG213 places BAR ID in CQ descriptor `tdata[114:112]`.
   - `cq_rx_decoder.v` currently uses `tuser[2:0]` when `DATA_WIDTH < 256`.
   - This works with the private A50T translation bridge because that bridge
     synthesizes a pseudo-CQ representation, but it is not correct for a direct
     128-bit PG213 CQ connection.

2. **128-bit CQ Memory Write payload alignment**
   - In PG213 Dword-aligned mode, the first 128-bit beat contains the complete
     16-byte CQ descriptor. Write payload starts on the following beat.
   - `cq_rx_decoder.v` currently takes write data from descriptor beat
     `[127:96]` in some paths.
   - A direct PG213 implementation needs a multi-beat CQ state machine and must
     consume `first_be`, `last_be`, `tkeep`, and `tlast` correctly.

3. **`tkeep` granularity and parameter propagation**
   - PG213 CQ/CC/RQ/RC `tkeep` is one bit per **Dword**, so a 128-bit interface
     uses four `tkeep` bits and a 256-bit interface uses eight.
   - Several shared modules default `KEEP_WIDTH = DATA_WIDTH / 8`, inherited
     from the byte-granular 7-series interface, and not every wrapper forwards
     its outer `PCIE_KEEP_WIDTH` parameter to the inner adapters.
   - All direct PG213 ports and parameters must use and propagate
     `DATA_WIDTH / 32` consistently.
   - `rq_tx_encoder.v::payload_keep` currently multiplies the valid-Dword count
     by four as if each keep bit represented a byte; this must become a
     Dword-count mask.

4. **CC descriptor is a private bridge format, not PG213 Table 52**
   - `cc_tx_encoder.v` places Requester ID at `[79:64]`, Tag at `[58:51]`, and
     Completion Status at `[46:44]`. Requester ID and Tag match the private
     extraction in `pcie_7x_axi_bridge.v`; that bridge ignores the encoded
     status and hardcodes a successful completion.
   - Direct PG213 CC requires Requester ID `[63:48]`, Tag `[71:64]`, Target
     Function `[79:72]`, Completion Status `[45:43]`, and Endpoint Completer ID
     Enable deasserted.
   - The CC descriptor must therefore be rewritten/repacked before direct
     connection to `pcie4_ultrascale_plus`.

5. **RQ byte enables and payload framing**
   - PG213 RQ `tuser[3:0]` is `first_be`, and `[7:4]` is `last_be`.
   - `rq_tx_encoder.v` currently uses values such as `62'd1`, which does not
     represent a full-Dword write (`first_be = 4'hF`).
   - Single-Dword and multi-Dword transactions require different legal
     `first_be/last_be` combinations, and the ignored `c2h_req_last` signal must
     be reconciled with Dword count and final `tkeep`.

6. **RC split-completion and tag lifetime**
   - PG213 `tlast` terminates one Completion packet; it does not necessarily
     mean the original Memory Read request is complete.
   - Tags may be recycled only when RC descriptor `Request Completed` bit 30 is
     asserted, including error termination.
   - `rc_rx_decoder.v` currently releases descriptor/SG tags on `tlast`, does
     not release H2C tags in its H2C path, and does not validate RC error,
     poison, byte-count or lower-address fields. These paths require redesign
     and split-completion tests.

7. **MSI generation**
   - The ZU4EV design should use PG213 `cfg_interrupt_msi_*` signaling.
   - The existing `irq_req` path in `rq_tx_encoder.v` must not be assumed to be
     a valid replacement for the IP's MSI interface.

8. **Tag management and flow control**
   - The design must choose core-managed or client-managed RQ tags and implement
     the associated `pcie_rq_tag*` behavior consistently. The current DMA uses
     semantic tag values, so client tag management is the likely baseline but
     remains an IP-configuration decision gate.
   - CQ non-posted credits (`pcie_cq_np_req`) must be provisioned without
     allowing reads to deadlock behind posted traffic.

9. **Remaining direct-PG213 descriptor semantics**
   - CQ address is encoded as Address `[63:2]` plus Address Type `[1:0]`; the
     adapter must not treat all 64 bits as an unqualified byte address.
   - CQ `first_be/last_be` must determine AXI-Lite strobes, lower address and CC
     byte count. Partial-Dword and multi-Dword BAR requests must be supported or
     deliberately completed with a defined error rather than silently reduced
     to one full-strobe Dword.
   - CC must return the required AT, TC, Attr, Requester ID, Tag, lower address,
     byte count and Dword count metadata from the corresponding CQ request.
   - RQ must follow Endpoint Requester Function and Requester-ID-Enable rules;
     the current fixed `REQUESTER_ID = 16'h0001` cannot be accepted without
     verifying the selected PG213 configuration.

### 4.3 Reuse classification

| Module | Planning classification |
|---|---|
| `pcie_7x_axi_bridge.v` | A50T only; omit from ZU4EV |
| `custom_pcie_dma_top.v` | Architecture reusable; PG213 widths/reset/MSI need changes |
| `cq_rx_decoder.v` | Requires PG213 CQ parser correction |
| `cc_tx_encoder.v` | Reuse FSM intent only; repack the private bridge descriptor into PG213 CC format |
| `rq_tx_encoder.v` | Reuse arbitration; correct PG213 `tuser`, tags, MSI, `tkeep` and payload framing |
| `rc_rx_decoder.v` | Reuse routing concept; redesign split-completion/error/tag lifetime and verify descriptor stripping |
| DMA/video/audio engines | Mostly reusable after interface and clock-domain validation |
| `axil_reg_space.v` | Reusable if BAR offsets and reset behavior remain stable |

Planning baseline: **128-bit, Dword-aligned, straddle disabled**. This minimizes
changes and matches a Gen3 x4 250 MHz user datapath. The generated IP example
design remains the authority for actual port widths and descriptor behavior.

## 5. PCIe 100 ms Boot Requirement

PG213 describes the requirement as:

- The host deasserts `PERST#` 100 ms after system power is good.
- The Endpoint must be ready to begin link training no later than 20 ms after
  `PERST#` deassertion.

A normal full-device PL configuration may miss this deadline. JTAG programming,
powering the board before the host, or performing a later PCI bus rescan is
useful for laboratory bring-up but does not prove compliance.

### Timing budget

Do not use an assumed `30 ms`, `50 ms`, or `80 ms` target. PG213 requires the
budget to be calculated from the actual routed stage-1 image:

```text
minimum clock = nominal configuration clock - tolerance
PROM bandwidth = minimum clock × interface width
stage-1 load time = reported stage-1 bit count / PROM bandwidth

PG213 non-ATX FPGA check:
TPOR + stage-1 load time + FPGA-power-ramp offset < 100 ms

ZU4EV system check must end at the observed PCIe-ready/LTSSM-start event:
power/TPOR + BootROM/PMUFW/FSBL pre-load latency
  + actual PCAP stage-1 transfer/overhead + post-load reset/clock stabilization
  < host PERST# deassertion + 20 ms
```

Additional time must account for regulator sequencing, TPOR, flash startup,
configuration-clock tolerance, board-specific power-good behavior, and—if the
ZynqMP PS boot chain supplies the PL image—BootROM/PMUFW/FSBL latency before
PCAP starts stage 1. Raw QSPI clock multiplied by bus width is not a proven
PCAP throughput model; use documented or measured end-to-end PCAP transfer and
startup overhead. The stage-1 bit count must be taken from the
`write_bitstream` log of the final implemented design, and compliance must be
measured through PCIe core readiness/LTSSM training rather than merely the last
configuration byte.

## 6. Tandem/DFX Options and Decision

### Option A — Tandem PROM (preferred first production candidate)

- A single Tandem image contains stage 1 and stage 2.
- Stage 1 configures PCIe-critical resources and starts link training.
- Stage 2 follows from the same local boot image while the PCIe core remains
  operational.
- No host MCAP loader or PCAP-to-MCAP ownership handoff is required.

For Zynq MPSoC, do not assume that a PL-attached flash directly clocks this
image into configuration. The normal boot chain can involve BootROM, PMUFW,
FSBL and PCAP. PG213 confirms ZU4EV Tandem support, but the exact Vivado
2023.2/Bootgen partition order and whether the board's QSPI is PS-only or also
usable by the Tandem flow must be proven with an AMD-generated example and the
schematic. The local recovery project's disabled QSPI configuration does not
answer this question.

Advantages after that feasibility gate passes:

- Simplest runtime path to proving the 100 ms rule.
- Boot does not depend on host software loading stage 2.
- Lower bring-up complexity than Tandem PCIe plus DFX.

Limitations:

- Does not support Field Updates.
- PG213 states that configuration-persist behavior prevents user logic from
  accessing the external configuration flash after Tandem PROM completes.
- Both stages consume flash space; the Tandem image is slightly larger than a
  normal full image.

### Option B — Tandem PCIe

- Stage 1 is loaded from local flash.
- Stage 2 is loaded by the host through PCIe MCAP.
- Prior to stage 2, the endpoint can enumerate, but ordinary application TLPs
  return Unsupported Request (UR).

Additional Zynq MPSoC requirement:

- PCAP owns configuration by default.
- PCAP and MCAP/ICAP are mutually exclusive.
- FSBL or JTAG must clear `PCAP_PR` in `PCAP_CTRL` (`0xFFCA3008`) before MCAP
  can load stage 2.
- No PCAP command or data may be active while ownership changes.

This mode should be selected only if host delivery of stage 2 or post-boot
flash access is required.

### Option C — Tandem PCIe with Field Updates / Tandem PCIe + DFX

Use this only if runtime replacement of the video application is an explicit
requirement.

- PCIe, GT, reset, configuration path, and link-critical clocking remain static.
- The user application occupies a reconfigurable hierarchy/Pblock.
- Its interface cannot change between revisions.
- All compatible images must be built through the same DFX flow and pass
  `PR_Verify`.
- Standard Tandem stage-2 files are not interchangeable with Field Update
  partial files.

### Decision gates

1. Confirm the production device marking and schematic-backed lane, GT,
   refclk, `PERST#`, flash and boot-mode routing.
2. Generate the official PG213 example design for
   `XCZU4EV-FBVB900`, `PCIE40E4_X0Y1`, Gen3 x4, and extract its XDC/Pblocks.
3. Use the minimal vendor PIO example to prove standard/JTAG electrical link
   operation before changing application RTL.
4. Using that same minimal example, prove the ZynqMP
   BootROM/PMUFW/FSBL/PCAP plus flash-image Tandem flow and obtain a preliminary
   cold-boot timing measurement; do not infer it from a generic FPGA PROM
   example.
5. Freeze Tandem PROM as the baseline only if this feasibility/timing gate
   passes. Otherwise stop and select Tandem PCIe or revise the boot hardware.
6. Only after gates 1–5 may the project port the PG213 transaction adapters and
   DMA application. Repeat the timing proof with the final routed stage 1 in
   Phase 4.
7. Do not add general DFX until PCIe enumeration, BAR, MSI, and DMA are stable.

## 7. Tandem Boot Behavior

### Tandem PROM sequence

```text
Power rails stable
  ├─ host independently schedules PERST# deassertion
  └─ ZynqMP boot source → BootROM/PMUFW/FSBL/PCAP (exact flow to verify)
      └─ PCIe core becomes ready and LTSSM starts by PERST# + 20 ms deadline
          └─ PCIe block/GT/reset logic link-trains
              ├─ host enumerates the endpoint
              └─ same local Tandem image supplies stage 2
                  └─ mcap_design_switch asserts
                      └─ release application reset and allow BAR/DMA
```

### Tandem PCIe sequence

```text
Local ZynqMP boot flow loads stage 1 (exact flash/PCAP sequence to verify)
  └─ PCIe endpoint enumerates; application BAR accesses return UR
      ├─ FSBL/JTAG clears PCAP_PR and grants MCAP ownership
      └─ host MCAP driver loads the matching stage-2 BIN once
          └─ mcap_design_switch asserts
              └─ release application reset and bind/start normal driver
```

The normal Linux `custom_pcie_av` driver must not assume BAR registers are
usable immediately after enumeration in **either Tandem mode** while
`mcap_design_switch` is deasserted. Either:

- arrange for stage 2 to finish before binding `custom_pcie_av`, or
- add a bounded readiness/deferred-probe mechanism coordinated with the local
  Tandem PROM sequence or MCAP loader.

Only measured platform boot ordering may justify omitting this protection.

## 8. Expected Problems and Mitigations

| Risk | Effect | Required mitigation/validation |
|---|---|---|
| Wrong PCIe block selected | Tandem generation unsupported or MCAP unavailable | Use `PCIE40E4_X0Y1`; verify generated IP/DRCs |
| Board not routed to GTH Quad 223 | Cannot place or route Gen3 x4 | Confirm schematic/package pins before project creation |
| Refclk frequency/electrical mismatch | PHY never becomes ready or unstable link | Derive from schematic; copy generated example clocking |
| Slot clock/SSC mode misconfigured | Gen3 link instability or compliance failure | Use synchronous mode for add-in slot clock and enable Slot Clock Configuration per PG213 |
| Stage 1 misses timing | Host does not enumerate at cold boot | Calculate from actual bit count and measured end-to-end configuration path; measure through LTSSM start |
| PS boot-chain latency omitted | Stage 1 starts too late even if its own load time is short | Measure BootROM/PMUFW/FSBL-to-PCAP start; minimize and document BOOT.BIN partition order |
| PS-only QSPI/Tandem image incompatibility | Generic PROM flow cannot be used on this board | Confirm flash wiring and validate the Vivado 2023.2 + Bootgen ZynqMP flow before selecting Tandem PROM |
| Reset pin far from PCIe block | Extra stage-1 frames and longer load time | Prefer Bank 65 if PCB permits; otherwise quantify added size |
| I/O shares `sys_reset` bank | Unknown/floating outputs until stage 2 | Keep safe externally or gate OBUFT with `mcap_design_switch` |
| DCI cascade crosses stage boundary | Implementation violation | Do not cascade DCI between stage-1 and stage-2 banks |
| Stage-1/stage-2 image mismatch | Configuration failure, contention, possible damage | Treat pair as one release artifact; hash/version both; use `PR_Verify` for DFX |
| Standard Tandem stage 2 loaded twice | Unsupported/unsafe behavior | Load exactly once; use Field Updates if reload is required |
| PCAP and MCAP contend | Unexpected configuration behavior | FSBL-controlled ownership switch only when PCAP idle |
| Driver binds before stage 2 | BAR accesses receive UR and probe fails | Complete local/MCAP stage 2 before bind or implement deferred readiness for both Tandem modes |
| Application reset released too early | TLP corruption or spurious DMA | Gate reset and DMA enable with synchronized `mcap_design_switch && user_lnk_up` |
| PCIe reset asserted during update | Link drops and host loses device | Keep `sys_reset`, GT, PCIe core and static clocks outside RP |
| GSR after stage 2 | User logic state uncertain | Use generated Tandem reset/handshake structure; apply explicit application reset |
| PCIe/user Pblocks overlap | DRC/route failure | Preserve generated device-specific Pblocks; DFX Pblocks must not overlap Tandem Pblocks |
| Floorplan reduces ZU4EV capacity | Video timing/resource closure fails | Estimate stage-1 Pblock cost before adding multi-channel video |
| Debug Hub/ILA/BSCAN/ICAP placement | DFX rule violations | Follow PG213/UG909 debug hierarchy; do not casually place config primitives in RP |
| MIG or configuration primitives in RP | Unsafe or illegal reconfiguration | Prefer PS DDR; isolate BSCAN/ICAP/STARTUP outside RP |
| Compression plus per-frame CRC | Bitstream-generation incompatibility | Disable compression if DFX per-frame CRC is required |
| Secure boot key mismatch | MCAP rejects stage 2 | If stage 1 encrypted, encrypt stage 2 with the same key; validate authentication flow |
| Engineering-sample silicon | Tandem bitstream generation unsupported | Require production silicon; record full device marking before Phase 1 |
| Tandem simulation assumption | Testbench appears to pass without modeling real two-stage behavior | Treat PG213 integrated-block Tandem simulation as unsupported; verify the generated hardware flow |
| Fallback assumption for stage 2 | Device remains enumerated but application absent | Fallback protects stage 1 only; define host timeout/recovery policy |
| Host warm reset behavior | Device may disappear or application state may be stale | Test cold boot, warm reboot, hot reset, PERST assertion, and PCI rescan separately |
| Existing CQ/RQ formatting defects | BAR corruption/DMA failure | Add PG213 descriptor-level simulations before hardware |
| Incorrect MSI path | Interrupt loss | Use and verify `cfg_interrupt_msi_*`; do not rely on unverified RQ message encoding |

## 9. Implementation Phases (after planning approval)

### Phase 0 — Documentation and hardware evidence

- Obtain board schematic and pinout.
- Confirm PCIe lane/refclk/PERST/QSPI routing.
- Generate the PG213 IP example design in Vivado 2023.2.
- Record exact IP properties, ports, XDC constraints, Pblocks, and stage-1 DRCs.

Exit criterion: no unresolved GT, reference-clock, reset, or configuration-mode
assumptions.

### Phase 1 — Vendor PIO electrical and Tandem feasibility baseline

- Generate rather than rewrite the `pcie4_ultrascale_plus` PIO example.
- Verify Gen1 first, then Gen3 x4 under standard/JTAG configuration.
- Verify VID/DID and configuration-space capabilities.
- On production silicon, enable the proposed Tandem mode in the vendor example
  and prove the actual ZynqMP boot-image/PCAP path.
- Measure preliminary cold-boot timing through PCIe-ready/LTSSM start.

PG213's integrated-block simulation model does not model Tandem operation, so
this gate requires generated artifacts and hardware evidence rather than a
Tandem testbench claim.

Exit criterion: repeatable Gen3 x4 link and correct enumeration after JTAG,
plus a feasible autonomous vendor-PIO Tandem cold boot within the measured
PERST#/link-training window. Failure stops application RTL porting.

### Phase 2 — PG213 transaction adapter

- Correct CQ/CC/RQ/RC widths and formats.
- Keep 128-bit, Dword-aligned, no-straddle mode initially.
- Simulate MRd/MWr, 3-Dword/4-Dword addresses, byte enables, split
  completions, backpressure, tags, CQ credits, and malformed/discontinue paths.
- Verify CQ Address/AT reconstruction, partial-Dword strobes, multi-Dword BAR
  policy, and CC lower-address/byte-count/TC/Attr response metadata.
- Verify RQ Requester Function, Requester-ID-Enable, first/last BE and final
  payload `tkeep` for every supported request length.
- Connect BAR0 1 MiB and BAR1 64 KiB.

Exit criterion: descriptor-level simulations pass for legal traffic,
backpressure, split completions and defined error cases; BAR MMIO works in the
standard/JTAG configuration.

### Phase 3 — MSI and deterministic DMA

- Implement MSI using the PG213 configuration interrupt interface.
- Validate H2C/C2H patterns and 64-bit IOVA handling.
- Validate tags, outstanding reads, split completions, ordering and 4 KiB
  boundaries.

Exit criterion: repeated MSI, H2C and C2H pattern tests pass with 64-bit IOVA,
no tag leak, lost completion, interrupt loss, or 4 KiB boundary violation.

### Phase 4 — Tandem PROM cold boot

- Enable Tandem PROM in Advanced mode.
- Migrate the generated example hierarchy, clocking, timing constraints and
  Pblocks without changing the device-dependent physical constraints.
- Calculate and measure stage-1 timing.
- Test cold boot without pre-powering the card and without PCI rescan.

Exit criterion: calculated and measured boot timing meets the host's
PERST#/link-training window over repeated true cold boots, with successful
first-pass enumeration and no link retrain during stage-2 handoff.

### Phase 5 — TPG RGB24 capture

- Add TPG, capture engine, watermark and markers.
- Validate 1080p before 4K60.
- Validate 600-frame watermark/marker continuity and no drops.

Exit criterion: 600 continuous verified frames at 1080p, followed by the
required 4K60 test with correct RGB order, markers/watermark and no unexplained
drops.

### Phase 6 — Optional Tandem PCIe/DFX

Only enter this phase if host-delivered stage 2 or field updates are required.
Add FSBL PCAP ownership handoff, host MCAP loader, static/application
partitioning, isolation, version compatibility and `PR_Verify` gates.

Exit criterion, if this optional phase is approved: compatible stage-2/update
images pass `PR_Verify`, load without link loss, reject mismatched images, and
recover cleanly from loader timeout or failure.

## 10. Required Validation Matrix

| Area | Required evidence |
|---|---|
| Hardware routing | Schematic-backed block, GT quad, refclk, lane and PERST mapping |
| PCIe | Cold-boot Gen3 x4 enumeration, stable LTSSM, correct VID/DID/BARs |
| 100 ms rule | Scope/ILA timestamps plus stage-1 size/rate calculation |
| Tandem handoff | `mcap_design_switch`, application reset, no link retrain |
| BAR | PG213 CQ descriptor tests and MMIO read/write tests |
| MSI | Repeated interrupt generation with no lost/stuck interrupt |
| D2H/H2C | 64-bit IOVA, split completion, wrap, ordering, backpressure |
| Reset | Cold boot, host warm reboot, PERST, hot reset, driver reload |
| Image safety | Matched stage hashes; `PR_Verify` if DFX is enabled |
| Video | 1080p then 4K60, marker/watermark continuity for 600 frames |

## 11. Primary References

- AMD product page — UltraScale+ Devices Integrated Block for PCI Express:
  https://www.amd.com/zh-tw/products/adaptive-socs-and-fpgas/intellectual-property/pcie4-ultrascale-plus.html
- PG213 — UltraScale+ Devices Integrated Block for PCI Express:
  https://docs.amd.com/r/en-US/pg213-pcie4-ultrascale-plus
- PG213, Tandem Configuration:
  https://docs.amd.com/r/en-US/pg213-pcie4-ultrascale-plus/Tandem-Configuration
- PG213, Using Tandem PCIe on Zynq MPSoC Devices:
  https://docs.amd.com/r/en-US/pg213-pcie4-ultrascale-plus/Using-Tandem-PCIe-on-Zynq-MPSoC-Devices
- PG213, Special Considerations for Tandem/DFX:
  https://docs.amd.com/r/en-US/pg213-pcie4-ultrascale-plus/Special-Considerations-for-Tandem-or-Dynamic-Function-eXchange-Designs
- PG213, Zynq UltraScale+ available GT quads:
  https://docs.amd.com/r/en-US/pg213-pcie4-ultrascale-plus/Zynq-UltraScale-Devices-Available-GT-Quads
- PG213, Completer Request Descriptor Formats:
  https://docs.amd.com/r/en-US/pg213-pcie4-ultrascale-plus/Completer-Request-Descriptor-Formats
- PG213, Completer Completion Descriptor Format:
  https://docs.amd.com/r/en-US/pg213-pcie4-ultrascale-plus/Completer-Completion-Descriptor-Format
- PG213, Requester Request Interface:
  https://docs.amd.com/r/en-US/pg213-pcie4-ultrascale-plus/Requester-Request-Interface
- PG213, Requester Completion Descriptor Format:
  https://docs.amd.com/r/en-US/pg213-pcie4-ultrascale-plus/Requester-Completion-Descriptor-Format
- UG909 — Vivado Dynamic Function eXchange:
  https://docs.amd.com/r/en-US/ug909-vivado-partial-reconfiguration
- AR 64761 — Stage-2 loading over PCIe/MCAP:
  https://adaptivesupport.amd.com/s/article/64761

## 12. Current Recommendation

Proceed with this order:

1. Direct PG213 `pcie4_ultrascale_plus` endpoint, not PS PCIe.
2. `PCIE40E4_X0Y1` plus `GTH_Quad_223`, subject to schematic confirmation.
3. Correct and simulate the CQ/CC/RQ/RC adapters; do not assume unmodified TLP
   reuse.
4. Prove the vendor-PIO boot feasibility, then prove final cold-boot compliance
   with **Tandem PROM**.
5. Defer Tandem PCIe with Field Updates/DFX until there is a confirmed runtime
   update requirement.

## 13. Open Implementation Blockers

These items do not prevent completion of this planning document, but they block
implementation approval and any claim of hardware feasibility:

1. Board schematic/package-pin evidence for lane mapping, `GTH_Quad_223`,
   refclk, SSC, `PERST#`, QSPI wiring and boot-mode straps is not present in
   this repository.
2. The Vivado 2023.2 ZU4EV PG213 example design, generated XCI/XDC/Pblocks and
   its Tandem DRC results have not yet been produced.
3. The physical device has not been confirmed as production rather than ES
   silicon.
4. The ZynqMP BootROM/PMUFW/FSBL/PCAP/Bootgen path for the board's local flash
   has not been demonstrated with a Tandem image.
5. Actual host power-good/PERST# timing, stage-1 bit count, PCAP throughput,
   post-load startup delay and LTSSM-start timing are not measured.

If any of these contradict the planning default, stop and revise the block/GT,
boot mode, or Tandem selection before application RTL work begins.
