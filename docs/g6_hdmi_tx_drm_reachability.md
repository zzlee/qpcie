
## G8 resolved: why the VTC half of the TX aperture was dead, and the 26111602 fix

Deployed 26111601 published `v_hdmi_tx_ss_rgb` as **one 17-bit crossbar slice**
(`0xB0020000 + 128 KiB`), which is the textbook-correct shape (the subsystem keeps
its VTC at `+0x10000`, and `xhdmi_drm_compute_subcore_AbsAddr()` in the KMS driver
derives `VTC = base + 0x10000` from a single `reg`).  On hardware it did not work:

| address | result |
|---|---|
| `0xB0020000..0xB002FF7F` | returns the TX SS ID `0x22000100` (aliases every ~2 KiB) |
| `0xB002FF80`, `0xB0030000`, `0xB003007C`, `0xB0030150`, `0xB003C000` | `SIGBUS` (synchronous external abort = AXI DECERR) |

Evidence and the elimination order, all reproducible:

1. **IP/BD configuration was correct.** `report_addr_table` on the deployed
   `v_hdmi_tx_ss_rgb.bd`: `S_AXI_CPU_IN` = `0xB0020000` size `0x20000`,
   `Reg[0]` = `0xB0020000 +0x10000`, `Reg[1]` = `0xB0030000 +0x10000` (the VTC
   segment is present), and the subsystem's own control port is
   `S_AXI_CPU_IN_araddr[16:0]` (17 bits).
2. **Gate-level simulation of both deployed crossbars decodes correctly.**
   `tb/tb_sc7f0_hdmi_xbar_addr_map.v` + `scripts/sim_sc7f0_hdmi_xbar_addr_map.sh`
   run the *post-synthesis netlists*: outer `0xB0030000 -> M02` with the full
   address and `OKAY`, `0xB00B0000 -> DECERR`; inner `0x10000 -> M01` (VTC) with
   `OKAY`.  So neither crossbar's decode table is the fault.
3. **The routed design proves the read path is wired and the write path is not.**
   Pin/net probe of `impl_1/zu4ev_pcie_card_top_routed.dcp` and
   `v_hdmi_tx_ss_rgb.dcp` (`build/g6g8-20261116T110140Z/netlist-probe/`):
   * `u_hdmi_control/m_axi_araddr[80] -> u_hdmi_tx_ss/S_AXI_CPU_IN_araddr[16]`
     `-> inst/axi_crossbar/s_axi_araddr[16]`, and the inner crossbar's M01 field
     bit 0 lands on `inst/v_tc/s_axi_araddr[0]` (slice arithmetic exact);
   * `u_hdmi_control/m_axi_awaddr[80]` and `u_hdmi_tx_ss/S_AXI_CPU_IN_awaddr[16]`
     **have no net at all** — the write-channel bit 16 does not exist at the
     subsystem boundary, so no VTC write could ever have selected the VTC segment.
     A driver modeset would have aliased onto the TX core instead.

**Fix (26111602).**  Stop asking a crossbar slice to carry bit 16:

* `scripts/create_sc7f0_hdmi_crossbar.tcl` decodes **two 64 KiB slices** —
  `M02 = 0xB0020000` and `M10 = 0xB0030000` — the window class proven good on this
  card (RX SS, frame tap, frmbuf, overlay).  `build_zu4ev.tcl` now requests
  `create_sc7f0_hdmi_crossbar 3` for the RGB profile; the legacy personalities keep
  the original single 128 KiB slice.
* `rtl/sc7f0_axil_merge_2to1.v` re-merges the two slices onto the subsystem's single
  control port and **drives subsystem address bit 16 from the slice index** in
  fabric.  Nothing else in the address changes, so the PS still sees one contiguous
  `0xB0020000..0xB003FFFF` aperture and the driver/device-tree contract is untouched.
* This new module instead of reusing `rtl/axil_arbiter_2to1.v` because the latter
  forwards `arvalid/awvalid` to the slave *before* its grant state is entered
  (`m_axil_arvalid = arvalid && (state != IDLE || arvalid)` is just `arvalid`), so
  the slave accepts the request, answers before `arready` can ever rise, and a
  spec-compliant master that must hold `arvalid` until `arready` never completes.
  Measured in the DBG trace; the existing BAR0/HPM0 user is left untouched.

Simulation result (`build/g6g8-20261116T110140Z/g8-txss-ctl-merge-sim.txt`):

```
SC7F0_TXSS_CTL_MERGE_PASS lower=core(bit16=0) upper=vtc(bit16=1) rw+isolation ok
```

14/14 checks, including `0xB0030150` arriving as subsystem address `0x10150`
(write and read back) and no cross-talk when the two halves are interleaved.
`rtl/zu4ev_pcie_card_top.v` analyses clean with the real RGB define set
(`-d SC7F0_TX_VIDEO_PRESENT=1 -d SC7F0_RGB_COMPOSITOR=1`), same as HEAD.

Not yet proven: on-card `devmem 0xB0030000` after the next flash.  Until then this
is a validated fix in simulation plus a proven defect in the deployed netlist, not
a board result.

## 2026-11-16 follow-up: the address-map simulator could not have seen the new slice

`scripts/sim_sc7f0_hdmi_xbar_addr_map.sh` was run against **round 26111602's own**
post-synthesis netlists before this round's XSA, and two things came out of it that
change what the section above is worth.

1. **The script never ran on 2023.2.** `xvlog -pragmas ignore` is not a valid option
   ("unrecognised option '--pragmas'" printed to *stdout*, which the script sent to
   `/dev/null`), and the tool writes no `.log` when it fails to start,
   `xsim -tclon` is not one either.  It exited non-zero leaving an empty directory -
   the "the `inner` variant failed at `xvlog` with no log" note in the round's
   PROGRESS.md.  Compiler output now goes to a file that survives the failure.
2. **`tb_hdmi_xbar_outer` was still modelling ten master ports.** 26111601's crossbar
   had ten, so `localparam NS = 10` and a 320-bit `m_axi_*` vector matched it.  With
   G8's eleventh master the deployed netlist is `m_axi_araddr[351:0]` /
   `m_axi_awvalid[10:0]` (straight out of `axi_crossbar_hdmi_stub.v`), so the probe
   truncated every vector, connected no responder to port 10, and printed
   `0xB0030000 -> none` - which is indistinguishable, in that table, from the DECERR
   it is not.  `NS` is now 11, `portname()` reaches M10, the banner is this round's
   real map, the write probe reports `aw_port` (it printed `hit_port`, the *read*
   monitor, so the write path said nothing about the write path), and the rows are
   assertions with a `SC7F0_XBAR_MAP_OUTER_PASS/FAIL` verdict instead of a table for
   a human to squint at.

Re-run on this round's netlists (`$BR/g8-xbar-addr-map-26111602.txt`):

```
  b002fffc |  OKAY   |     M02 | b002fffc     lower slice ends at +0xFFFF
  b0030000 |  OKAY   |     M10 | b0030000     26111601: DECERR
  b0030100 |  OKAY   |     M10 | b0030100     no 2 KiB / 4 KiB alias up there
  b003fffc |  OKAY   |     M10 | b003fffc     upper slice really spans 64 KiB
  b0040000 |  OKAY   |     M03 | b0040000     the other windows did not shift
  b00b0000 |  DECERR |    none | xxxxxxxx     nothing was widened
  write 0xB0030004 ->     M10 addr=b0030004 bresp=0
SC7F0_XBAR_MAP_OUTER_PASS slices=11 upper=0xB0030000->M10 rw+full-address ok
```

and the inner crossbar inside `v_hdmi_tx_ss_rgb` answers `0x10000 -> M01` (the VTC)
with the full 17-bit address.  So both halves of the G8 path are now measured on
netlists that belong to the round being flashed.

One more hole this exposed, and it is the kind that matters: **no gate had ever
checked the two slices**.  `scripts/check_sc7f0_hdmi_dt.py` asserted `NUM_MI == 11`
and the M04..M09 windows, but never `M02_A00_ADDR_WIDTH` or `M10_A00_BASE_ADDR`, so a
build that kept 26111601's single 128 KiB `M02` would have passed the device-tree
gate unchanged.  Both slices are asserted now, for both personalities (64 KiB under
RGB, 128 KiB legacy).

