# SC7F0 Phase 1 / Todo 1.1 + 1.2 — encoder-only VCU in `zu4ev_ps_bd`

Date: 2026-10-29. Scope: Block Design integration, independent BD validation and
out-of-context resource measurement only. No bitstream, XSA, device tree,
PetaLinux, driver or hardware work was performed, and no existing project
directory was modified.

## What was built

`scripts/create_zu4ev_ps_bd.tcl` gained an optional second argument:

| call | result |
| --- | --- |
| `create_zu4ev_ps_bd` / `create_zu4ev_ps_bd 0` | debug profile, unchanged (1-bit `pl_ps_irq0`) |
| `create_zu4ev_ps_bd 1` | R7 full profile, unchanged (VCU off) |
| `create_zu4ev_ps_bd 1 1` | full profile **+ encoder-only VCU** |

`scripts/build_zu4ev.tcl` still calls `create_zu4ev_ps_bd [expr {!$debug_profile}]`,
so the shipped debug/full hardware builds are bit-for-bit the same BD; the VCU
is opt-in until a hardware revision is scheduled for it.

Validation command:

```bash
source /opt/Xilinx/Vivado/2023.2/settings64.sh
vivado -mode batch -notrace -source scripts/check_sc7f0_vcu_bd.tcl   # VCU_BD_PASS
vivado -mode batch -notrace -source scripts/check_sc7f0_hdmi_bd.tcl  # HDMI_BD_PASS
vivado -mode batch -notrace -source scripts/check_sc7f0_hdmi_bd.tcl -tclargs debug  # DEBUG_BD_PASS
```

## Integration topology

Everything the VCU needs stays **inside** the BD, so the generated wrapper keeps
exactly the ports the R7 top level already connects
(`dp_mem_clk`, `pl_clk0`, `pl_resetn0`, `pl_ps_irq0[4:0]`,
`M_AXI_HPM0_FPD`, `M_AXI_HPM1_FPD`, `S_AXI_HP0_FPD`, `S_AXI_HP1_FPD`) — asserted
by `check_sc7f0_vcu_bd.tcl`, so the existing RTL needs no port edits when the
VCU revision is scheduled.

| VCU | through | PS | clock |
| --- | --- | --- | --- |
| `M_AXI_ENC0` (128 b, 44 b addr) | `smc_vcu_enc/S00_AXI` | | |
| `M_AXI_ENC1` (128 b, 44 b addr) | `smc_vcu_enc/S01_AXI` → `M00_AXI` | `S_AXI_HP2_FPD` (128 b, `PSU__USE__S_AXI_GP4=1`) | `dp_mem_clk` 150 MHz |
| `M_AXI_MCU` (32 b) | `smc_vcu_mcu/S00_AXI` → `M00_AXI` (32→128 conversion) | `S_AXI_HP3_FPD` (128 b, `PSU__USE__S_AXI_GP5=1`) | `dp_mem_clk` 150 MHz |
| `S_AXI_LITE` (32 b, 20 b addr) | `axil_vcu` (AXI4 → AXI4-Lite) ← `M_AXI_HPM0_LPD` (`PSU__USE__M_AXI_GP2=1`, kept internal) | — | `pl_clk0` 99.99 MHz |
| `pll_ref_clk` | PS `pl_clk1` (`PSU__PL_CLK1_BUF=TRUE`, internal net, not exported) | — | 33.33 MHz |
| `vcu_resetn` | `pl_resetn0` | — | — |
| `vcu_host_interrupt` | `vcu_irq_cat` (xlconcat, `IN0_WIDTH=5`) → `pl_ps_irq0` | `pl_ps_irq0[5]` | — |

> Todo 1.2b replaced the two SmartConnects in this table: `smc_vcu_enc` is now
> `xbar_vcu_enc` (`axi_crossbar` 2.1, `NUM_SI=2 NUM_MI=1`) and `smc_vcu_mcu` is
> now `dwc_vcu_mcu` (`axi_dwidth_converter` 2.1, 32→128). The PS ports, widths,
> clocks, address map and the `S00/S01 → M00` merge onto HP2 are unchanged.

IP configuration: `ENABLE_ENCODER=true`, `ENABLE_DECODER=false`,
`PLL_BYPASS=0`, `PLL_CLK=33.333333`, `CORE_CLK=667`, `AXI_ENC_CLK=AXI_MCU_CLK=150`
(reporting parameters, matched to the real fabric clock instead of the 333 MHz
default), `ENC_FRAME_SIZE=4` (3840×2160), `ENC_FPS=3` (60),
`ENC_COLOR_FORMAT=0` (4:2:0) and `ENC_COLOR_DEPTH=0` (8 bit) to match the
verified NV12 capture path, `ENC_BUFFER_EN=false`.

Reset: `vcu_rst_mem` (150 MHz) and `vcu_rst_lite` (100 MHz) are `proc_sys_reset`
5.0 instances with `aux_reset_in = pl_resetn0` (active low,
`C_AUX_RESET_HIGH=0`) and `ext_reset_in` tied inactive by a shared `xlconstant`,
so the interconnect resets are synchronous releases. The VCU releases into
reset *after* its slaves (`peripheral_aresetn` path), which is the safe order.

Interrupt mapping: ZynqMP `pl_ps_irq0[n]` → GIC SPI `89+n`. Bit 5 is therefore
**SPI 94** (INTID 126) for the encoder; bits 0…4 keep the existing upgrade /
HDMI-PHY / HDMI-RX / DP-DMA / capture sources, and the wrapper still sees a
5-bit vector.

## Address map after the change

| master (PS `Data` space) | offset | range | note |
| --- | --- | --- | --- |
| `M_AXI_HPM0_FPD/Reg` (BAR0 CSR) | `0x0A000_0000` | 64 KiB | unchanged |
| `M_AXI_HPM1_FPD/Reg` (HDMI CSR: DPV1/Frmbuf/VPSS/Frame-Tap) | `0x0B000_0000` | 1 MiB | unchanged |
| `vcu_0/S_AXI_LITE/Reg` | **`0x08008_0000`** | 1 MiB | new (encoder +0, slcr +0x40000, logicore +0x41000) |

VCU masters → DDR (`assign_bd_address`, per-port apertures, no overlap):

| VCU address space | segments |
| --- | --- |
| `vcu_0/EncData0`, `vcu_0/EncData1` | `HP2_DDR_LOW` 0x0+2 GiB, `HP2_DDR_HIGH` 0x8_0000_0000+…, `HP2_LPS_OCM` 0xFF00_0000+16 MiB |
| `vcu_0/Code` (MCU) | `HP3_DDR_LOW` 0x0+2 GiB, `HP3_DDR_HIGH` 0x8_0000_0000+…, `HP3_LPS_OCM` 0xFF00_0000+16 MiB |

## Deviations from the task text, with evidence

1. **AXI-Lite base `0x8008_0000`, not `0xB008_0000`.** All three FPD GP masters
   that could reach `0xB00x_xxxx` are already exported to RTL (`M_AXI_HPM0_FPD`
   → BAR0 crossbar, `M_AXI_HPM1_FPD` → HDMI crossbar), so only
   `M_AXI_HPM0_LPD` can be used inside the BD. `validate_bd_design` rejects the
   requested address for it:
   `ERROR: [BD 41-1075] … must fit an available aperture through master
   interface '/zynq_ultra_ps_e_0/M_AXI_HPM0_LPD'. Valid apertures are
   {<0x8000_0000 [ 512M ]>}` — the LPD GP master decodes
   `0x8000_0000…0x9FFF_FFFF` only. `0x8008_0000` sits in that aperture, is not
   DDR (low bank ends at 0x7FFF_FFFF with the PMU-reserved 0x7FF0_0000 tail,
   high bank starts at 0x8_0000_0000) and does not touch `0xA000_0000` or
   `0xB000_0000…0xB00F_FFFF`. Using the LPD port also gives DTGen a real base
   address (`reg` for the `xlnx,vcu` / `al,al5e` nodes) instead of a manual DT
   `reg`, and it keeps the existing HDMI window at its full 1 MiB.
2. **Reference clock is 33.330002 MHz, not exactly 33.333333 MHz.** `pl_clk1` is
   derived from the PS RPLL, which the frozen clock configuration runs at
   999.90005 MHz, so `/30` = 33.330002 MHz (−0.01 %). Changing RPLL would move
   `pl_clk0` (99.99 MHz) that the whole validated card runs on, so it was left
   alone. `CONFIG.PLL_CLK` keeps the nominal 33.333333; the IP's own
   `IP_Flow 19-4684` long-conversion warnings for `HDL_PLL_CLK_HI/LO` are
   benign (those model parameters are unused in the shipped HDL).
3. **HP2/HP3 are BD-internal**, not new wrapper AXI ports, because both masters
   are inside the BD. Same for `pl_clk1`. This is what keeps the top level
   unchanged.
4. **`ENC_COLOR_FORMAT=0` / `ENC_COLOR_DEPTH=0`** (IP defaults are 4:2:2 / 10 bit)
   to match the verified NV12 (4:2:0 8-bit) capture path. Must be re-checked
   against the pinned OMX/allegro input layout in the daemon phase.
5. **Pre-existing stale check repaired:** `check_sc7f0_hdmi_bd.tcl` still
   expected a 3-bit `pl_ps_irq0`, while the working-tree BD and RTL already use
   5 bits (`{capture_irq,dp_irq,hdmi_rx_irq,hdmi_phy_irq,ps_irq_pulse_w}`). The
   expectation is now 5, so the gate actually passes again.

## Validation results (all in in-memory projects)

| run | result |
| --- | --- |
| `check_sc7f0_vcu_bd.tcl` (`create_zu4ev_ps_bd 1 1`) | `validate_bd_design` → `SUCCESS: zu4ev_ps_bd created & validated successfully!`, 75/75 assertions ok, **`VCU_BD_PASS`**, Vivado exit 0, **0 CRITICAL WARNING** |
| `check_sc7f0_hdmi_bd.tcl` (full, VCU off) | `SUCCESS … validated` + `HDMI_BD_PASS`, exit 0 |
| `check_sc7f0_hdmi_bd.tcl -tclargs debug` | `SUCCESS … validated` + `DEBUG_BD_PASS` (1-bit IRQ preserved), exit 0 |

Remaining warnings in the VCU run are informational or already present in the
shipped design: `[PSU-1]` isolation note (6×), the two benign
`IP_Flow 19-4684` PLL_CLK conversions, `[BD 41-702]` propagation refusing to
overwrite USER-strength `PLL_CLK`/`AXI_ENC_CLK`, and `BD 41-237`
`AWUSER/ARUSER_WIDTH` mismatches — the identical warning already exists for
`S_AXI_HP0_FPD` in R7.

Evidence copies (gitignored): `build/sc7f0-vcu-bd-check/`.

# Todo 1.2 (2026-10-29) — measured out-of-context synthesis

Todo 1.1's "not run here" item 5 is now measured: `zu4ev_ps_bd` was elaborated
with `create_zu4ev_ps_bd 1 1` and synthesised `-mode out_of_context` in a
throw-away project. Nothing outside `/tmp/opencode/sc7f0-vcu/` and the
gitignored `build/sc7f0-vcu-ooc/` evidence directory was written; `rtl/`,
`constraints/` and both production projects are untouched and
`scripts/build_zu4ev.tcl` still calls `create_zu4ev_ps_bd` without the VCU
argument.

## How it was run

New script `scripts/synth_sc7f0_vcu_bd_ooc.tcl` (scratch project, `generate_target
all`, `make_wrapper`, top `zu4ev_ps_bd_wrapper`, `STEPS.SYNTH_DESIGN.ARGS.MORE
OPTIONS = -mode out_of_context`, `launch_runs synth_1` so the 7 per-IP OOC runs
come up as dependencies, `config_ip_cache -disable_cache` like the production
build):

```bash
source /opt/Xilinx/Vivado/2023.2/settings64.sh
vivado -mode batch -notrace -source scripts/synth_sc7f0_vcu_bd_ooc.tcl 1 vcu sweep
vivado -mode batch -notrace -source scripts/synth_sc7f0_vcu_bd_ooc.tcl 0 control sweep
vivado -mode batch -notrace -source scripts/synth_sc7f0_vcu_bd_ooc.tcl 1 vcuxdc sweep xdc
```

| variant | BD | extra clock | Vivado exit | synth_1 | ERROR / CRITICAL WARNING | wall |
| --- | --- | --- | --- | --- | --- | --- |
| `vcu` | `create_zu4ev_ps_bd 1 1` | — | **0** | `100% synth_design Complete!` | **0 / 0** | ~6 min |
| `control` | `create_zu4ev_ps_bd 1 0` | — | **0** | `100% … Complete!` | **0 / 0** | ~4 min |
| `vcuxdc` | `create_zu4ev_ps_bd 1 1` | `create_clock -period 6.666 dp_mem_clk` | **0** | `100% … Complete!` | **0 / 0** | ~5 min |

Validity checks that the numbers are not stubs: every dependent run reports
`synth_design Complete!`, `runme.log` contains exactly one
`synth_design … -mode out_of_context` line, section 9 *Black Boxes* of
`report_utilization` is empty, and `control` (VCU off) reproduces the BD that the
shipped R7 card contains (`zu4ev_ps_bd_zynq_ultra_ps_e_0_0`, 359 LUT — the same
359 LUT the R7 synth-hierarchical report shows inside `zu4ev_ps_bd_i`). Because
both variants are measured in the same flow, the delta is BD-vs-BD and does not
double-count the 137 LUT the wrapper contributes at card level in R7.

## Measured `zu4ev_ps_bd` cost (`report_utilization`, Design State: Synthesized)

| account | part capacity | VCU on | VCU off (control) | **VCU delta** |
| --- | --- | --- | --- | --- |
| CLB LUTs | 87,840 | **8,373** (9.53 %) | 359 (0.41 %) | **+8,014** |
| — LUT as Logic | 87,840 | 6,520 | 359 | +6,161 |
| — LUT as Memory | 57,600 | 1,853 | 0 | +1,853 (1,538 dist-RAM + 315 SRL) |
| CLB Registers (all FF) | 175,680 | **12,845** (7.31 %) | 0 | **+12,845** |
| Block RAM Tile / RAMB36 / RAMB18 | 128 / 128 / 256 | **0 / 0 / 0** | 0 | **0** |
| URAM | 48 | **0** | 0 | **0** |
| DSP48 | 728 | **0** | 0 | **0** |
| CARRY8 / MUXF7 / MUXF8 | — | 0 / 4 / 0 | 0 / 0 / 0 | 0 / +4 / 0 |
| BUFG_PS (global clock buffer) | 96 | 1 | 0 | +1 (the `pl_clk1` VCU reference) |
| PLL / MMCM | 8 / 4 | 0 / 0 | 0 / 0 | **0** |
| **VCU (ADVANCED section)** | 1 | **1 = 100 %** | 0 | **+1 hard block** |

### Where the 8,014 LUTs actually go (`report_utilization -hierarchical`)

| BD cell | clock | LUT (logic + distRAM + SRL) | FF |
| --- | --- | --- | --- |
| `smc_vcu_enc` (SmartConnect, EncData0+EncData1 → `S_AXI_HP2_FPD`) | 150 MHz | 4,166 (3,185 + 916 + 65) | 6,914 |
| `smc_vcu_mcu` (SmartConnect, MCU 32→128 bit → `S_AXI_HP3_FPD`) | 150 MHz | 3,219 (2,426 + 622 + 171) | 5,028 |
| `axil_vcu` (AXI4 → AXI4-Lite) | 100 MHz | 475 (398 + 0 + 77) | 656 |
| `vcu_0` (VCU IP fabric wrapper + hard macro) | mixed | **116** | 167 |
| `vcu_rst_mem` + `vcu_rst_lite` (`proc_sys_reset`) | 150 / 100 MHz | 19 + 19 | 40 + 40 |
| `vcu_irq_cat` (`xlconcat`) | — | 0 | 0 |
| **sum** | | **8,014** | **12,845** |

**92 % of the cost is the two SmartConnect interconnects (7,385 LUT /
11,942 FF), not the encoder.** Both came up in *High-performance Mode*
(`INFO [xilinx.com:ip:smartconnect:1.0-1]` in the run log). ~12.0 k of the added
FF are in the 150 MHz `dp_mem_clk` domain, ~0.7 k in the 100 MHz control domain.

## The encoder itself is a Dedicated Hard Macro (answer to the Todo question)

```
primitive VCU = 1
  vcu_cell=zu4ev_ps_bd_i/vcu_0/inst/VCU_i ref=VCU group=ADVANCED subgroup=VIDEO
6. ADVANCED  | VCU | 1 | 0 | 0 | 1 | 100.00 |          (part property VCU = 1)
```

`report_utilization` books it in the *ADVANCED* section, not in CLB/BLOCKRAM,
and the encoder-cores-for-4K60 count is irrelevant to fabric: `CORE_CLK=667` with
4 encoder cores costs 0 LUT / 0 FF / 0 BRAM / 0 URAM because the cores live in
the hard block. It consumes the only VCU on `xczu4ev-fbvb900-2-e` (1/1), so
nothing else in the design can ever use it. `vcu_0`'s 116 LUT / 167 FF are just
the IP's AXI-Lite/slcR/logicore glue.

## Post-synthesis timing

A BD has no XDC of its own, so the bare `vcu` run only sees the two clocks the PS
IP declares; the third variant adds the card's real 150 MHz period
(`constraints/zu4ev_pcie_pinout.xdc` makes `capture_clk_150m` = 300.030 MHz ÷ 2
= 6.666 ns) as a scratch-file constraint so `dp_mem_clk` — the clock of
`smc_vcu_enc`, `smc_vcu_mcu`, HP2/HP3 and the VCU AXI side — is actually timed:

| variant | clocks seen | setup WNS | endpoints | `check_timing` | methodology |
| --- | --- | --- | --- | --- | --- |
| `vcu` | `clk_pl_0` 10.000 ns, `clk_pl_1` 30.002 ns | +7.007 ns, TNS 0, 0 failing | 1,910 | `no_clock` 15,318, `unconstrained_internal_endpoints` 49,279 | TIMING-17 ×1000 (cap), TIMING-18 ×1000 |
| `vcuxdc` | + `dp_mem_clk` 6.666 ns (150.015 MHz) | **+4.976 ns**, TNS 0, **0 failing**, "All user specified timing constraints are met" | **50,693** (dp_mem_clk 48,783 @ +4.976, clk_pl_0 1,910 @ +7.007, WPWS +1.833) | `no_clock` 8, `unconstrained_internal_endpoints` **0** | TIMING-18 ×1000 (missing I/O delay on the exported BD AXI ports — meaningless in OOC), CKLD-1 ×1 |
| `control` | `clk_pl_0`, `clk_pl_1` | no constrained paths (0 FF outside the hard macro) | 0 | — | — |

The 150 MHz logic the VCU adds therefore has 74.6 % of its period as slack at
synthesis, the 100 MHz control path 70 %, `clk_pl_1` carries only one pulse-width
endpoint (it is the VCU PLL reference; the 667 MHz core clock never becomes a
fabric clock), and `report_clock_interaction` shows no fabric 100↔150 MHz
requirement (the single `clk_pl_0 → dp_mem_clk` path is `Ignored / False Path`).
Resource counts are identical between `vcu` and `vcuxdc` (8,373 / 12,845), so the
constraint did not perturb the netlist.

## Whole-card projection against the shipped R7 card

Baseline is the **R7 (`26102901`) placed report**
`build/dual-video-26102901-r7/qpcie_zu4ev_card.runs/impl_1/zu4ev_pcie_card_top_utilization_placed.rpt`
and its synth-hierarchical twin — see "deviations" for why the task text's
69,810 / 89.5 / 48 numbers are R5's, not R7's. Two projections are given because
synthesis counts are pre-opt: (A) synth-consistent — the R7 synth delta
(76,897 LUT → 70,806 routed, ratio 0.9208) applied to the BD delta; (B)
route-anchored — the raw synth delta added to the routed baseline, which is the
pessimistic bound.

| account | capacity | R7 placed | projected with VCU | projected util | headroom left |
| --- | --- | --- | --- | --- | --- |
| CLB LUTs | 87,840 | 70,806 (80.61 %) | **78,185 (A) … 78,820 (B)** | **89.0 % … 89.7 %** | **9,655 … 9,020 = 11.0 % … 10.3 %** |
| LUT as Logic | 87,840 | 61,134 (69.60 %) | 67,295 | 76.6 % | 20,545 |
| LUT as Memory | 57,600 | 9,672 (16.79 %) | 11,525 | 20.0 % | 46,075 |
| CLB Registers | 175,680 | 112,615 (64.10 %) | 124,499 (A) … 125,460 (B) | 70.9 % … 71.4 % | ~51 k |
| Block RAM Tile | 128 | 95.5 (74.61 %) | 95.5 | 74.6 % | 32.5 tiles |
| URAM | 48 | 0 | 0 (`ENC_BUFFER_EN=false`) | 0 % | 48 |
| DSP48 | 728 | 87 (11.95 %) | 87 | 12.0 % | 641 |
| BUFG_PS | 96 | 1 | 2 (expected: `+1` for `pl_clk1`) | 2.1 % | 94 |
| PLL / MMCM | 8 / 4 | 0 / 2 | 0 / 2 (VCU PLL is inside the hard block) | 0 % / 50 % | 8 / 2 |
| **VCU** | 1 | 0 | **1** | **100 %** | 0 |
| CLB *sites* | 14,640 | **14,640 (100.00 %)** | 14,640 (cannot exceed 100 %) | 100 % | 0 sites |

R7 closes at WNS +0.923 ns / WHS +0.010 ns (`clk_pl_0` +0.923 over 132,388
endpoints, `capture_clk_150m` +1.308 over 114,508 endpoints). The VCU adds ~48.8 k
new 150 MHz endpoints (+43 % to that domain) and 1.9 k to `clk_pl_0`.

## Verdict for Todo 1.3

**Not safe to merge as-is; conditional GO after the interconnect is re-sized.**

> **Update (Todo 1.2b, same day):** that re-size is done and measured — the two
> SmartConnects are replaced by `axi_crossbar` (2 SI / 1 MI) plus
> `axi_dwidth_converter` (32→128), the BD delta fell from +8,014 to **+2,699 LUT
> / +3,265 FF**, and the whole-card projection is **83.44 … 83.68 %**. Status is
> now **GO for Todo 1.3**; see "Todo 1.2b" at the end of this document.

1. BRAM, URAM, DSP, PLL/MMCM are untouched and VCU=1 is available, so there is no
   blocker of the "hard resource is gone" kind, and the encoder's own fabric cost
   is negligible (116 LUT / 167 FF + 1 hard block).
2. LUT is the blocker: 89–90 % projected against the ≤85 % planning guideline
   (an 85 % budget of 74,664 LUT leaves only 3,858 LUT for the VCU, vs. 8,014
   measured — 2.1×), on a card whose CLB *sites* are already 100 % placed and
   that uses 6,810 F7 + 2,564 F8 muxes. 1,538 of the added LUTs are distributed
   RAM, which needs RAM-capable slices. Extra endpoints land on the 150 MHz
   domain that currently holds +1.308 ns.
3. The fix is targeted, not general: 7,385 of the 8,014 LUT are the two
   high-performance SmartConnects. `smc_vcu_mcu` is a 1-master→1-slave 32→128-bit
   width conversion and `smc_vcu_enc` only merges two 128-bit encoder streams onto
   one HP2 port, so plain `axi_interconnect`/`axi_crossbar` instances with reduced
   per-channel `AXI_PIPELINING` (or a narrower ENC1/`M_AXI_MCU` path) should
   recover most of it. That is an *estimate*, not a measurement — Todo 1.3 must
   re-run this script after the change and require ≤85 % before P&R.
4. Acceptance gate for the first whole-card attempt: re-run
   `check_sc7f0_vcu_bd.tcl` + this OOC script, then a synth-only full-card build
   (no bitstream) with `report_utilization` ≤85 % LUT, positive WNS/WHS, and the
   existing CDC/methodology gate; anything else needs an encoder-profile or
   capture-logic reduction decision first, and 4K60 4-core vs 4K30 2-core does not
   change the fabric answer (it changes VCU-internal throughput and DDR bandwidth).
   *(First half done in Todo 1.2b: both scripts re-run and green for the slim
   interconnect; the synth-only full-card build is still Todo 1.3.)*

## Deviations from the task text, with evidence (Todo 1.2)

1. **The quoted baseline is R5, not R7.** 69,810 LUT / 89.5 BRAM is the
   `26102803` (R5) placed report (`…/dual-video-26102803-r5/…/zu4ev_pcie_card_top_utilization_placed.rpt`:
   `CLB LUTs 69810 / 87840 = 79.47 %`, `Block RAM Tile 89.5 / 128`). The shipped
   R7 `26102901` is **70,806 LUT / 95.5 BRAM tile / 112,615 FF / 0 URAM**.
   Projections above use R7; the R5 numbers would understate LUT by 1,000 and
   BRAM by 6 tiles.
2. **"0 URAM / 48" mixes up URAM capacity with DSP use.** The part has 48 URAM
   (all free); DSP48 use is **87 of 728** in both R5 and R7, not 48.
3. **`report_timing_summary` needs a clock to mean anything.** A BD-only project
   has no XDC, so `dp_mem_clk` is a plain input and 49,279 endpoints were
   unconstrained; a scratch-only `ooc_clocks.xdc` (written inside the scratch
   tree, never into `constraints/`) was added for the third variant to time the
   150 MHz domain. `USED_IN_SYNTHESIS` was left on, and utilization is unchanged
   with and without it.
4. **The OOC flow needs `launch_runs`, not a bare `synth_design`**, because a run
   object has no `STEPS.SYNTH_DESIGN.ARGS.MODE` property; `-mode out_of_context`
   is passed via `STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS` and verified from
   `runme.log`. The 7 per-IP OOC runs (`vcu_0`, `smc_vcu_enc`, `smc_vcu_mcu`,
   `axil_vcu`, `vcu_rst_mem`, `vcu_rst_lite`, `zynq_ultra_ps_e_0`) come up as
   dependencies, which is what keeps the numbers free of black boxes.
5. **Disk hygiene**: scratch stayed in `/tmp/opencode/sc7f0-vcu/ooc-<tag>` with
   `sweep` (DCPs deleted after reporting, 16 MB per run) and the project trees,
   `.Xil` and backup logs were removed afterwards (~223 MiB back); the gitignored
   evidence in `build/sc7f0-vcu-ooc/` is 460 KB of reports and logs only.

Evidence (gitignored): `build/sc7f0-vcu-ooc/` — `*-utilization_synth.rpt`,
`*-utilization_synth_hier.rpt`, `vcu-hard_macro.txt`, `*-ooc-summary.txt`,
`*-timing_summary.rpt`, `*-check_timing.rpt`, `vcuxdc-clock_interaction.rpt`,
`*-markers.txt` (run status + exit codes) and the three full console logs.

## Open items before this can become hardware (carried into Todo 1.3)

1. **Fit — measured in Todo 1.2, still the blocker.** The VCU IP's core-count
   formula yields **4 encoder cores** for 3840×2160@60 at `CORE_CLK=667` (2 for
   4K30, 1 for ~1080p60 — confirmed with `CONFIG.ENCODERNUMCORES`), but those
   cores are inside the Dedicated Hard Macro, so they cost **0 fabric**; the
   measured whole-BD cost is 8,373 LUT / 12,845 FF / 0 BRAM / 0 URAM / 0 DSP,
   i.e. **+8,014 LUT over the shipped BD**, and 92 % of that is the two
   SmartConnects. Whole-card projection is 89–90 % LUT — see "Verdict for Todo
   1.3" for the sizing change that is required before P&R.
   **Resolved in Todo 1.2b:** with the crossbar/width-converter interconnect the
   whole-BD cost is 3,058 LUT / 3,265 FF (**+2,699 LUT**), 83.4–83.7 % projected.
2. **DDR bandwidth.** At the specified 150 MHz × 128-bit HP2, one port carries
   ~1.92 GB/s. The IP's `encoder_bw_calc` for 4K60 NV12 with `ENC_BUFFER_EN=false`
   asks ~0.75 GB/s source + ~2.6 GB/s reference ≈ 3.4 GB/s. Enabling the on-chip
   encoder buffer (`ENC_BUFFER_EN`, URAM type — 48 URAM currently unused) or a
   faster/lower-resolution profile is required; this is an estimate from the IP
   formula, not a measurement.
3. QoS for HP2/HP3 is still the default (empty `PSU__DDR_QOS_HP2/HP3_*QOS`), so
   the encoder has no DDR priority guarantee against capture.
4. CMA/reserved-memory sizing, `vcu.dtsi` (its `vcu_refclk` fixed-clock no longer
   matches the design — the reference is now PS `pl_clk1` and DTGen should bind
   the PS clock), encoder/firmware/rootfs package selection, and the DT interrupt
   (`<0 94 4>`) are follow-up todos.
5. ~~`generate_target` and OOC synthesis were intentionally not run here.~~
   **Done in Todo 1.2** (`scripts/synth_sc7f0_vcu_bd_ooc.tcl`, three variants,
   all exit 0 / 0 errors / 0 critical warnings). Whole-card implementation,
   CDC/methodology gates and bitstream generation are still not run — that is
   Todo 1.3 and it is gated on the interconnect re-size above.
   *(The gate is cleared: see Todo 1.2b.)*


# Todo 1.2b (2026-10-29) — interconnect slimming (measured)

Todo 1.2's verdict was "conditional GO after the interconnect is re-sized": the
encoder itself costs 116 LUT / 167 FF + 1 hard macro, while the two default
SmartConnects cost 7,385 LUT / 11,942 FF. This phase replaces them, re-measures
with the same flow, and re-projects the card. Scope: no R7 RTL, no
`constraints/`, no production project and no `scripts/build_zu4ev.tcl` change
(`create_zu4ev_ps_bd [expr {!$debug_profile}]`, no VCU argument, byte-identical
behaviour); the repository changes are the three VCU scripts, two read-only
`probe_sc7f0_*` helpers, the new `scripts/run_vcu_ooc.sh` wrapper and this
document, plus reports in the gitignored `build/sc7f0-vcu-ooc/`. All synthesis
ran in throw-away projects under `/tmp/opencode/sc7f0-vcu/`.

## What replaced what

`create_zu4ev_ps_bd` gained a third argument, the VCU memory-interconnect style;
the default is now the slim one and `sc` reproduces the Todo 1.1 netlist:

| call | memory interconnect |
| --- | --- |
| `create_zu4ev_ps_bd 1 1` | **`xbar`** (default): `axi_crossbar` + `axi_dwidth_converter` |
| `create_zu4ev_ps_bd 1 1 xbar8` | as `xbar`, crossbar acceptance/issuing depth pinned to 8 (measured reserve lever) |
| `create_zu4ev_ps_bd 1 1 sc` | the Todo 1.1 SmartConnect baseline |

| path | before (Todo 1.1/1.2) | after (Todo 1.2b, default) |
| --- | --- | --- |
| `M_AXI_ENC0` + `M_AXI_ENC1` (2 × 128 b) → `S_AXI_HP2_FPD` | `smc_vcu_enc`, smartconnect 1.0, "High-performance Mode" | **`xbar_vcu_enc`**, `xilinx.com:ip:axi_crossbar:2.1`, `NUM_SI=2 NUM_MI=1`, `PROTOCOL=AXI4`, `DATA_WIDTH=128`, `ADDR_WIDTH=44`, `ID_WIDTH=5`, `ADDR_RANGES=3` (auto-raised for DDR_LOW / LPS_OCM / DDR_HIGH), acceptance/issuing left at the propagated 16 |
| `M_AXI_MCU` (32 b) → `S_AXI_HP3_FPD` | `smc_vcu_mcu`, smartconnect 1.0 | **`dwc_vcu_mcu`**, `xilinx.com:ip:axi_dwidth_converter:2.1`, `SI_DATA_WIDTH=32 MI_DATA_WIDTH=128`, `ADDR_WIDTH=44`, `SI_ID_WIDTH=3`, `ACLK_ASYNC=0`, `FIFO_MODE=0`, `PACKING_LEVEL=1` |
| `M_AXI_HPM0_LPD` → `S_AXI_LITE` | `axil_vcu`, axi_protocol_converter 2.1 | unchanged (475 LUT / 656 FF in both) |

Clocks (`dp_mem_clk` 150 MHz on both new cells, `pl_clk0` on `axil_vcu`), the
`vcu_rst_mem` / `vcu_rst_lite` synchronous releases, the address map
(`EncData0/1` → HP2, `Code` → HP3, registers @ `0x8008_0000`) and the interrupt
(bit 5 → SPI 94) are unchanged, and so is the wrapper port set.

Two design points worth keeping:

1. **`ID_WIDTH=5`, not 4.** `axi_crossbar` routes B/R with the ID bits sitting at
   the per-SI `S01_BASE_ID` position — with a 4-bit ID that base ID is `0x8`, so
   it would eat the VCU's own ID MSB. With 5 bits the base ID is `0x10` and all
   16 encoder IDs pass through untouched. The generated netlist proves the
   wiring, and also that this is *no worse* than the SmartConnect it replaces:

   | | Todo 1.1 (smartconnect) | Todo 1.2b (crossbar) |
   | --- | --- | --- |
   | PS `saxigp4_awid/arid` (HP2, video) | `{1'b0,1'b0,1'b0,1'b0,1'b0,1'b0}` — every VCU ID discarded | `{1'b0, xbar_vcu_enc_M00_AXI_AWID[4:0]}` — real 5-bit ID |
   | crossbar SI view | — | `s_axi_awid = {1'b0, ENC1_AWID[3:0], 1'b0, ENC0_AWID[3:0]}` |
   | PS `saxigp5_awid/arid` (HP3, MCU) | tied to 0 | tied to 0 (identical; `SI_ID_WIDTH=3` is still returned to the VCU) |
   | `vcu_0/M_AXI_ENC*/BID,RID` pin width | 5 bit | 5 bit (the IP's response ID is one bit wider than its request ID in both) |

2. **A "one HP port per VCU master, no PL logic at all" variant is impossible on
   this part.** The 2023.2 `zynq_ultra_ps_e` elaborates only
   `S_AXI_HP0_FPD…S_AXI_HP3_FPD` (`PSU__USE__S_AXI_GP2…GP5`) plus `S_AXI_LPD`;
   `PSU__USE__S_AXI_GP6` creates `saxigp6_*` pins with **no** `S_AXI_HP4_FPD`
   interface and no `saxihp4_fpd_aclk` (`connect_bd_net` then fails with
   `BD 41-701`), and HP0/HP1 carry the capture path. The 2:1 merge on HP2 is
   therefore mandatory, which is what the task asked for.

## Validation

```bash
source /opt/Xilinx/Vivado/2023.2/settings64.sh
vivado -mode batch -notrace -source scripts/check_sc7f0_vcu_bd.tcl            # xbar (default)
vivado -mode batch -notrace -source scripts/check_sc7f0_vcu_bd.tcl -tclargs xbar8
vivado -mode batch -notrace -source scripts/check_sc7f0_vcu_bd.tcl -tclargs sc
vivado -mode batch -notrace -source scripts/check_sc7f0_hdmi_bd.tcl            # full profile, VCU off
vivado -mode batch -notrace -source scripts/check_sc7f0_hdmi_bd.tcl -tclargs debug
```

| run | `validate_bd_design` | assertions | CRITICAL WARNING | exit |
| --- | --- | --- | --- | --- |
| `check_sc7f0_vcu_bd.tcl` (xbar, shipped tree) | `SUCCESS … validated successfully!` | **86 ok / 0 fail** | **0** | **0** |
| `… -tclargs xbar8` | SUCCESS | 86 ok / 0 fail | **0** | **0** |
| `… -tclargs sc` (baseline regression) | SUCCESS | 77 ok / 0 fail | **0** | **0** |
| `check_sc7f0_hdmi_bd.tcl` (full) | SUCCESS | `HDMI_BD_PASS` | 0 | 0 |
| `check_sc7f0_hdmi_bd.tcl -tclargs debug` | SUCCESS | `DEBUG_BD_PASS` | 0 | 0 |

The checker now resolves the interconnect cells from the style, asserts that
**no `smartconnect` cell is left** in the slim build, that the crossbar MI ID
width is strictly wider than the VCU's and still ≤ HP2's 6, that the MCU cell is
a plain 32→128 upsizer with `ACLK_ASYNC=0`, and that everything previously
asserted (wrapper ports, HP2/HP3 internal, address map, reset order, IRQ bit 5,
HP0/HP1/HPM regression) still holds. Remaining warnings are the same
informational set as before (`[PSU-1]` ×6, `IP_Flow 19-4684` PLL rounding,
`BD 41-702` propagation, `BD 41-237` `AWUSER/ARUSER_WIDTH`, the latter already
present for `S_AXI_HP0_FPD` in R7).

## OOC resource comparison

`scripts/synth_sc7f0_vcu_bd_ooc.tcl` (args travel in `-tclargs`; the Todo 1.2
command lines in this file omitted it — bare trailing words are *not* read as
`argv`, which is why `scripts/run_vcu_ooc.sh` now wraps the calls):

| account | part capacity | VCU off (control) | **before** `sc` | **after** `xbar` | delta before | delta after | saved |
| --- | --- | --- | --- | --- | --- | --- | --- |
| CLB LUTs | 87,840 | 359 (0.41 %) | **8,373** (9.53 %) | **3,058** (3.48 %) | +8,014 | **+2,699** | **−5,315 (−66 %)** |
| — LUT as Logic | 87,840 | 359 | 6,520 | 2,903 | +6,161 | +2,544 | −3,617 |
| — LUT as Memory | 57,600 | 0 | 1,853 (1,538 LUTRAM + 315 SRL) | 155 (0 + 155 SRL) | +1,853 | **+155** | −1,698 |
| CLB Registers (all FF) | 175,680 | 0 | **12,845** (7.31 %) | **3,265** (1.86 %) | +12,845 | **+3,265** | **−9,580 (−75 %)** |
| Block RAM Tile / RAMB36 / RAMB18 | 128 / 128 / 256 | 0 | 0 | 0 | 0 | 0 | 0 |
| URAM | 48 | 0 | 0 | 0 | 0 | 0 | 0 |
| DSP48 | 728 | 0 | 0 | 0 | 0 | 0 | 0 |
| BUFG_PS / PLL / MMCM | 96 / 8 / 4 | 0 | 1 / 0 / 0 | 1 / 0 / 0 | +1 BUFG_PS | +1 BUFG_PS | 0 |
| CARRY8 / MUXF7 | — | 0 | 0 / 4 | 2 / 35 | 0 / +4 | +2 / +35 | — |
| **VCU (ADVANCED)** | 1 | 0 | 1 = 100 % | 1 = 100 % | +1 hard macro | +1 hard macro | 0 |

Per-BD-cell (`report_utilization -hierarchical`), all three styles:

| BD cell | `sc` LUT / FF | **`xbar` LUT / FF** | `xbar8` LUT / FF |
| --- | --- | --- | --- |
| video merge: `smc_vcu_enc` → `xbar_vcu_enc` | 4,166 / 6,914 | **1,356 / 1,375** | 960 / 947 |
| MCU upsizer: `smc_vcu_mcu` → `dwc_vcu_mcu` | 3,219 / 5,028 | **714 / 987** | 714 / 987 |
| `axil_vcu` | 475 / 656 | 475 / 656 | 475 / 656 |
| `vcu_0` | 116 / 167 | 116 / 167 | 116 / 167 |
| `vcu_rst_mem` + `vcu_rst_lite` | 38 / 80 | 38 / 80 | 38 / 80 |
| `zynq_ultra_ps_e_0` | 359 / 0 | 359 / 0 | 359 / 0 |
| **BD total** | **8,373 / 12,845** | **3,058 / 3,265** | **2,662 / 2,837** |

`scbase` (the refactored script, `1 1 sc`) reproduces Todo 1.2's `vcu` run
cell-for-cell — the 8,373 / 12,845 above are not a different measurement, and the
`xbar` numbers are therefore comparable to them. `final-*` re-runs the shipped
tree one last time after the script clean-up and returns the same 3,058 LUT /
3,265 FF and the same per-cell split, with 0 ERROR / 0 CRITICAL WARNING /
`black_box_instances = 0`.

Post-synthesis timing of the same build, with the scratch 150 MHz constraint
(`xbarxdc`, `create_clock -period 6.666 dp_mem_clk`, written inside the scratch
project only):

| | before (`vcuxdc`) | **after (`xbarxdc`)** |
| --- | --- | --- |
| setup WNS / TNS / failing | +4.976 ns / 0 / 0 | **+3.833 ns / 0 / 0** ("All user specified timing constraints are met") |
| constrained endpoints | 50,693 (dp_mem_clk 48,783) | **9,305 (dp_mem_clk 7,395)** |
| `clk_pl_0` | +7.007 ns, 1,910 ep | +7.007 ns, 1,910 ep |
| pulse-width WNS | +1.833 | +1.833 |
| methodology | TIMING-18, CKLD-1 | TIMING-18, CKLD-1 (OOC I/O delays only) |

The 150 MHz domain that R7 closes at +1.308 ns now gains **41,388 fewer
endpoints (−85 %)**; its own WNS is 3.833 ns of a 6.666 ns period (57 %).
Utilization is identical with and without that constraint (`xbar` = `xbarxdc`),
as in Todo 1.2.

## Whole-card projection and margin

Baseline is the shipped R7 (`26102901`) placed report. Projections follow the
same two conventions as Todo 1.2: (A) synth-consistent (R7's own
synth→route ratio 70,806 / 76,897 = 0.9208 applied to the BD delta) and
(B) route-anchored (raw synth delta added to the routed baseline = pessimistic).

| account | capacity | R7 placed | projected A … B (with VCU + slim IC) | util A … B | headroom to **85 %** |
| --- | --- | --- | --- | --- | --- |
| **CLB LUTs** | 87,840 | 70,806 (80.61 %) | **73,291 … 73,505** | **83.44 % … 83.68 %** | **1,373 … 1,159 LUT = 1.56 … 1.32 pt** |
| LUT as Logic | 87,840 | 61,134 (69.60 %) | 63,477 … 63,678 | 72.27 % … 72.50 % | 24,162 … 24,362 |
| LUT as Memory | 57,600 | 9,672 (16.79 %) | 9,815 … 9,827 | 17.04 % … 17.06 % | 47,773 |
| CLB Registers | 175,680 | 112,615 (64.10 %) | 115,621 … 115,880 | 65.82 % … 65.96 % | ~60 k |
| Block RAM Tile | 128 | 95.5 (74.61 %) | 95.5 | 74.61 % | 32.5 tiles |
| URAM | 48 | 0 | 0 (`ENC_BUFFER_EN=false`) | 0 % | 48 |
| DSP48 | 728 | 87 (11.95 %) | 87 | 11.95 % | 641 |
| BUFG_PS | 96 | 1 | 2 (`pl_clk1`) | 2.08 % | 94 |
| PLL / MMCM | 8 / 4 | 0 / 2 | 0 / 2 | 0 % / 50 % | 8 / 2 |
| **VCU** | 1 | 0 | **1** | 100 % | 0 (only one on this part) |
| CLB *sites* | 14,640 | 14,640 (100 %) | 14,640 (cannot exceed 100 %) | 100 % | see below |

The *sites* line needs the caveat Todo 1.2 implied: a CLB site holds 6 LUT, so
R7's 70,806 LUT already occupy every site while still leaving
**17,034 LUT slots** free inside them. What matters is how much of that remainder
the VCU eats:

| | before (`sc`) | **after (`xbar`)** |
| --- | --- | --- |
| free LUT slots consumed (route-anchored) | 8,014 / 17,034 = **47.0 %** | 2,699 / 17,034 = **15.8 %** |
| free FF consumed | 12,845 / 63,065 = 20.4 % | 3,265 / 63,065 = **5.2 %** |
| added LUT-as-Memory (needs RAM-capable slices) | 1,853 | **155** |
| added 150 MHz endpoints | 48,783 | **7,395** |

## Gate results, and one honest miss

| gate | target | measured | verdict |
| --- | --- | --- | --- |
| `validate_bd_design` + check script | SUCCESS, 0 critical warning | SUCCESS, 0 critical warning, exit 0 (xbar / xbar8 / sc) | **PASS** |
| Whole-card projected LUT | ≤ 85 % | 83.44 % … 83.68 % | **PASS** (1,159 … 1,373 LUT margin) |
| BD LUT delta | ≤ 2,500 | **2,699** | **MISS by 199 (8 %)** |

The 199 LUT were deliberately *not* chased, because the measured levers all cost
something the encoder still needs:

* `xbar8` (crossbar acceptance/issuing 16 → 8) is measured: **2,662 LUT /
  2,837 FF**, i.e. only −396 LUT, and it still misses 2,500. It halves the
  outstanding-burst budget on the video merge, which is the path
  `encoder_bw_calc` already flags as tight (~3.4 GB/s asked vs 1.92 GB/s per
  150 MHz × 128-bit port). Depth 8 keeps 8 × 4 KiB = 32 KiB in flight, which is
  ample for a ~120 ns DDR latency, so this lever is safe to hold in reserve —
  it is implemented and gated (`create_zu4ev_ps_bd 1 1 xbar8`, asserted by the
  check script) — but it does not close the gate.
* Getting under 2,500 by other means would mean `ID_WIDTH=4` (sacrificing the
  VCU's ID MSB), cutting `axil_vcu` (fixed by the PS's 16-bit GP ID), or
  dropping the LPS_OCM segment (≈45 LUT). None is a good trade for <200 LUT on
  a card that clears the real ≤85 % gate with 1.3 points to spare.

**Verdict: GO for Todo 1.3 (whole-card synth/P&R attempt).** BRAM, URAM, DSP,
PLL/MMCM are untouched, the 48 URAM are still free for the
`ENC_BUFFER_EN` bandwidth decision, the LUT projection sits 1.3–1.6 points below
the 85 % planning line, the 150 MHz domain gains 85 % fewer endpoints, and the
ID/response semantics are no weaker than the SmartConnect they replace (measured,
`build/sc7f0-vcu-ooc/xbar-*/scbase-*`). Still open before hardware: DDR
bandwidth / `ENC_BUFFER_EN`, HP2/HP3 QoS, CMA + `vcu.dtsi` (its `vcu_refclk` must
bind PS `pl_clk1`), DT interrupt `<0 94 4>`, and a real 4K60 encoder run.

## Disk hygiene

Scratch projects lived in `/tmp/opencode/sc7f0-vcu/ooc-<tag>` with `sweep`, so
the run DCPs were deleted right after the reports (16.0 MB freed in the
SmartConnect run, 4.7 MB in each slim run). The remaining project trees plus the
probe/quick/tune directories (450 MB) were deleted at the end of the phase, and
`/` reported 20 GB available both before the first run and after the cleanup.
`build/sc7f0-vcu-ooc/` (gitignored) grew from 460 KB to 3.5 MB of reports,
hierarchical utilization, timing/methodology reports and console logs — no DCPs,
no project files.
