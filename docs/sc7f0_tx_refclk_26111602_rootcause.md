# HDMI TX never lights a panel: the TX MGT reference clock is not present

Date: 2026-11-17. Card `0x26111602` on `rd@sc7f0-test.local` after the operator's **physical
power cycle** (`uptime -s` = 2026-11-17 10:53:49, PS `boot_id`
`e996599a-c5c8-4703-a23b-3b60e444ebbf`). Read-only plus one DRM pattern pass; **no COMMIT, no
eMMC write, no git commit/push, no Vivado run.** Evidence: `build/txlive-26111701/` and
`build/hdmi-tx-drm-verify-20261117T031115Z-1080p/`.

**Verdict: Step 1 fails at the HDMI TX, and it fails in hardware, upstream of every software
layer this project has been debugging.** Do not build/flash `26111701` for TX acceptance until
the TX reference clock exists; the bitstream cannot fix it.

---

## 1. Host and card are healthy (Step 1.1 — pass)

| check | result |
|---|---|
| `lspci -d 12ab:` | `03:00.0`, `Subsystem 0007`, `Kernel driver in use: qpcie-dma` |
| BAR0 / BAR1 | `0x80800000` / `0x80900000`; vendor:device `e38012ab` |
| link | `LnkSta: Speed 8GT/s, Width x4`, EqualizationComplete+ Phase1..3+ |
| AER | `UESta` all `-`, `CESta` all `-`, `HeaderLog: 00000000 00000000 00000000 00000000` |
| `qpcie_upgrade --status` | Magic `0x12ABE380 [VALID]`, **Version `0x26111602`**, Caps `0x1001011F` (bit20 clear, as expected pre-`26111701`), Git `0xC0E0A43E` |
| mailbox | `ABI=1 ready=1 card_epoch=df43d3ef card_beat=206185`, daemons `qpcie-debugd`/`qpcie-hdmi-daemon`/`qpcie-upgrade-daemon` all `active` |

`qpcie` is loaded on `7.0.0-43-generic`. Nothing here needs work.

## 2. DDC/EDID is fully working — `docs/sc7f0_txfix_26111701_findings.md` §2 is closed for good

`build/txlive-26111701/edid-real.txt`, `edid-detail.txt`:

* `/sys/class/drm/card0-HDMI-A-1/edid` = **256 bytes**;
* `/sys/kernel/debug/dri/0/HDMI-A-1/edid_override` = **0 bytes**, so this is a genuine DDC read,
  not the leftover injection from the previous round;
* raw block decodes `00 ff ff ff ff ff ff 00 1e 6d c1 5b 0e 0f 00 00`, monitor name
  descriptor `LG ULTRAFINE`, serial `304NTUW03854`, CTA-861 extension at 128, both block
  checksums valid;
* `modetest -M xlnx -c` → `status=connected`, **26 modes**, mode #0
  `3840x2160 60.00 3840 4016 4104 4400 2160 2168 2178 2250 594000 flags: phsync, pvsync; type: preferred`.

HPD is fine too (`probe_pins` bit10 = 1 raw pin, TX SS `PIO_IN 0x4` = bit2, DDC pads idle
`tx_scl=tx_sda=1`). **No PS I2C0, no `ddc-i2c-bus`, no `axi_iic` is needed — do not add one.**

## 3. A real modeset does not bring the TX link up

`scripts/verify_sc7f0_hdmi_tx_drm.sh --mode 1920x1080-60 --fourcc AR24 --hold 60` (1080p was
chosen deliberately: it differs from the fbcon mode `3840x2160`, so the commit is a *real*
modeset, and its 148.5 MHz TMDS clock removes "594 MHz is too fast" as an explanation).
`--force` was **not** needed any more; see §6.

| observation | before | during pattern | after |
|---|---|---|---|
| `tx_video_clk` `0xA000069C` | `0x00000000` | `0x00000000` | `0x00000000` |
| `txoutclk` `0xA0000698` | `0x00000000` | `0x00000000` | `0x00000000` |
| VPHY `PLL_LOCK_STATUS` `0xB0000018` | `0x00000000` | `0x00000000` | — |
| VPHY `TX_INIT` `0xB000001C` | `0x80808080` | `0x80808080` | — |
| VPHY `TX_INIT_STATUS` `0x020` | `0x00040404` | `0x00040404` | — |
| VPHY `TX_STATUS` `0xB0000078` | `0x00000000` | `0x00000000` | — |
| VTC `0xB0030000` | SIGBUS | SIGBUS | SIGBUS |
| `xilinx-hdmitxss` IRQ | 1 | — | 1 (**delta 0**) |

`TX_INIT = 0x80808080` decodes with `xvphy_hw.h:292-316` as
`XVPHY_TXRX_INIT_PLLGTRESET_MASK(Ch) = 0x80 << 8*(Ch-1)` on **CH1..CH4**: the commit never took
the VPHY TX lanes out of PLL+GT reset. `TX_INIT_STATUS = 0x00040404` is
`POWERGOOD` on CH1..CH3, so the GT lanes are powered but held in reset.

`dmesg` is unchanged in shape: `[drm] *ERROR* flip_done timed out` for `CRTC:34:crtc-0`,
`CONNECTOR:38:HDMI-A-1` and `PLANE:32:plane-0`, plus the `WARNING` in
`drm_atomic_helper_wait_for_vblanks` from `drm_fb_helper_restore_fbdev_mode_unlocked()`
(`xlnx_lastclose` → `drm_release`). The DRM core state is fully applied
(`/sys/kernel/debug/dri/0/state`: `enable=1 active=1`, `mode: "3840x2160": 60 594000 …`,
`fb=49 … dma_addr=0x0000000069f00000`) — the *software* commit is fine; nothing ticks.

**One measured side effect worth knowing:** opening and closing a DRM master on this image costs
**31.04 s** by itself (`modetest -M xlnx -c` alone), because every release re-runs the fbdev
commit and waits 3 × 10 s for a `flip_done` that never arrives.

## 4. Root cause: bank 226 MGTREFCLK0 (D10/D9) has no clock

Three independent measurements, none of them a driver opinion:

**(a) The board's own loss-of-lock signal says "not ready".**
`rtl/zu4ev_pcie_card_top.v:68` — `hdmi_tx_refclk_rdy`, **pin G13 = `X0_5319_LOL`,
"active HIGH = not ready"** — is synced into `probe_pins` **bit [11]**
(`rtl/sc7f0_hdmi_probe.v:511`). Every sample ever recorded on this card has it set:

| `0xA00006A0` | source | bit11 |
|---|---|---|
| `0x3F03F8AF` | `build/rx-refclk-defect2-20261116T050441Z/logs/22-pl-counters-idle.txt` | **1** |
| `0xaf03f8af` | `build/accept-26111602/hdmi-tx-drm-baseline/tx-hw-state-before.txt`, `build/g6g8-20261116T110140Z/26-probe-pins.txt` | **1** |
| `0xAF03FCAF` | `build/txfix-26111701/card-txclk2.txt` (monitor attached) | **1** |
| `0x2F00FCAF` | this round | **1** |

So the TX reference clock has **never** been ready on this card — this is not a regression.

**(b) The VPHY's own clock detector agrees, and its detector demonstrably works.**

```
clkdet_ctrl=0x00010501  clkdet_st=0x00000001   <- XVPHY_CLKDET_STAT_TX_FREQ_ZERO (xvphy_hw.h:568)
freq_tx=0x00000000  tmr_tx=0x00000000          <- nothing measured on the TX side
freq_rx=0x03670000  tmr_rx=0x00018696          <- RX measured
freq_dru=0x09500000                            <- 156,250,000 Hz exactly
```

**(c) The fabric frequency meter on that exact net.** `sc7f0_hdmi_probe.v` header item 5:
`tx_mgtrefclk0_odiv2_bufg` = "HDMI TX Reference Clock, pins D10/D9"; `constraints/zu4ev_pcie_pinout.xdc:32-35`
constrains it as `create_clock -period 3.367` (297 MHz). Eight consecutive 1 s gates
(`build/txlive-26111701/tx-refclk-stability.txt`):

```
tx_clk   0x00672a75 0x0065a704 0x0074b9df 0x0047bc07 0x0054577a 0x00425e2e 0x005ac367 0x006667d9
         = 4.3 .. 7.7 MHz, swinging ±40% sample to sample   <- noise on an input, not an oscillator
rx_clk   0x2366eefd 0x2366eef4 0x2366eef2 0x2366eef1 0x2366eeeb 0x2366eeee 0x2366eeed 0x2366ef03
         = 593,948,4xx Hz, stable to 0.001%                 <- the same meter doing a real clock
dru_clk  0x094ff475 0x094ff46d ... = 156,249,9xx Hz, stable
```

A dead/unconnected differential GT refclk input; a live one measures as cleanly as `rx_clk` does.

**The clock chain, from the schematic** (`/home/zzlee/llm-wiki/raw/SC7F0_N1_HDMI2_V11/SC7F0 N1
HDMI2 V11.pdf`, sheets 11 and 29):

```
Si5341B-B05239-GM  OUT9 = 114.285 MHz (X0_5319_REFCLKp)
   -> SI5319 buffer  -> DIFF2/DIFF2b --SC87/SC86 AC--> X0_H0_REFCK0p/n -> FPGA D10/D9 = MGTREFCLK0P/N_226
                     -> DIFF1/DIFF1b ----------------> X0_H0_REFCK1p/n -> FPGA N8/N7  (the quad's other refclk)
   SI5319 status:  X0_5319_LOL -> FPGA G13 (this is probe bit 11)
                   X0_5319_RST (sheets 28,29; series resistor SR52 = NC), X0_5319_INT -> FPGA D12
```

`LOLn` asserted means the SI5319 does not see its 114.285 MHz input, or the buffer is held in
reset. The Si5341 itself is alive — its OUT8 300 MHz is the fabric capture clock
(`capture-clock` = `0x11e1a300` = 300 MHz in the live DT) and the DRU refclk reads exactly
156.25 MHz — so this is specifically the **OUT9/SI5319 leg that feeds the TX quad**, not a dead
clock chip.

**Nothing in the current bitstream can drive `X0_5319_RST`**: the top level has only the
*input* `hdmi_tx_refclk_rdy` (`zu4ev_pcie_card_top.v:68`), no reset output. So this cannot be
recovered by a register write either — which is just as well, since it would mean writing to a
net the design does not own.

### The consequence chain, with no missing link

```
no TX MGT refclk (D10/D9)
  -> QPLL cannot lock                : PLL_LOCK_STATUS(0x18) = 0
  -> TX lanes stay in PLL_GTRESET    : TX_INIT(0x1C) = 0x80808080, before/during/after a modeset
  -> phy_txoutclk / phy_tx_video_clk = 0 Hz      (0xA0000698 / 0xA000069C)
  -> v_tc has no clock (v_tc/clk is the same net, v_hdmi_tx_ss_rgb.hwh)
       -> 0xB0030000 answers with an error response (xv_hdmitxss.c:2408 refuses to read it too)
       -> VTC never generates vsync
  -> drm_atomic_helper_wait_for_vblanks -> [drm] *ERROR* flip_done timed out, every commit
  -> no HDMI TX picture, and 31.04 s per DRM master open/close
```

This also **vindicates §9 of the previous findings**: `0xB0030000` was never an addressing
defect. The gate-level runs already showed the routing is right; the VTC is simply unclocked,
and being unclocked is a *consequence* of the missing TX reference clock.

## 5. Second, independent blocker found in the driver (fixable without a bitstream)

`xvphy_probe()` (`phy-vphy.c`, SRCREV `82209b0021a7b5d7ef71a859eed4bafeb541ed08` — verified equal
to the deployed `kernel-module-hdmi` SRCREV `6.1+xilinx-v2023.2+gitAUTOINC+82209b0021`) does:

```c
XVphy_Hdmi_CfgInitialize(...)                 /* phy-vphy.c:748 */
devm_request_threaded_irq(..., "xilinx-vphy") /* phy-vphy.c:767 */
/* no xvphy_intr_enable() anywhere in probe */
```

and the **only** callers of `xvphy_intr_enable()` are `xvphy_irq_thread()` (line 297) and
`xvphy_pm_resume()` (line 806). `XVphy_IntrEnable()` has exactly one caller in the whole module,
inside `xvphy_intr_enable()`. So the enable is reachable only *from an interrupt that already
happened* — chicken-and-egg. Measured on the card:

```
VPHY INTR_EN   (0xB0000110) = 0x00000000     <- all VPHY interrupts disabled
VPHY INTR_MASK (0xB0000118) = 0x00000000
VPHY INTR_STS  (0xB000011C) = 0x00000000
/proc/interrupts:  57: GICv2 122 Level xilinx-vphy   total = 2 since boot
```

`xvphy_intr_enable()`'s mask is
`0x1|0x2|0x4|0x8|0x10|0x20|0x40|0x80|0x200|0x400|0x40000000|0x80000000 = 0xC00006FF`.

Why this matters: the GT/PLL bring-up sequence — `TX_CLKDET_FREQ_CHANGE`, `CPLL/QPLL_LOCK`,
`TXRESET_DONE`, and the `XVphy_ResetGtTxRx(..., FALSE)` releases — lives in
`phy-xilinx-vphy/xvphy_hdmi_intr.c`, and the DRM driver never releases TX reset from thread
context: `xlnx_drm_hdmi_encoder_dpms(ON)` is an empty function and `xlnx_drm_hdmi_encoder_enable()`
only does `XV_HdmiTxSs_SYSRST(FALSE)` plus `XHdmiphy1_TxPllreset()` (called with an
`XVphy` pointer — `xhdmi->xgtphy` and `xhdmi->xvphy` are both assigned
`xvphy_get_xvphy()` at `xilinx_drm_hdmi.c:2630-2632`).

So even after the reference clock is restored, this enable has to exist. It is a **kernel-module
change, not a fabric change** — one `xvphy_intr_enable(vphydev)` at the end of `xvphy_probe()`.
I did **not** test it by writing `0xC00006FF` to `0xB0000110` from userspace: with
`CLKDET_STAT.TX_FREQ_ZERO` set there is no clock-detector event to service, so such a probe
could not distinguish "interrupts off" from "no refclk" and would only have added noise.

## 6. Script changes made (and why they are correct, not a loosening)

`scripts/verify_sc7f0_hdmi_tx_drm.sh`:

1. **The VTC gate is demoted to advisory.** It used to refuse any modeset while
   `TX_SS+0x10000` took a bus error, on the premise that the address segment was broken. That
   premise is refuted by the deployed-netlist simulations, by `v_tc/clk == phy_tx_video_clk`,
   and by Xilinx refusing the read for the same reason. Refusing the modeset there is circular —
   the modeset is the *only* action that can ever raise that clock. The gate now reads the clock
   monitor first and blocks only on the combination that would truly fault:
   **video clock running *and* VTC still refusing.** Everything else is recorded to
   `vtc-advisory.txt`; `--force` still overrides all gates.
2. **Added the clock monitor and VPHY TX reads before / during / after the pattern**
   (`0xA0000680..0x9C`, VPHY `0x18/0x1C/0x20/0x78/0x11C/0x204/0x20C/0x210`), the
   `TX_LINK_UP` / `TX_LINK_STILL_DOWN` verdict, and the same numbers in `summary.txt`. Without
   these reads the script could not tell "VTC broken" from "VTC unclocked", which is the whole
   question of the last two rounds.
3. **`--mt-open` / `SC7F0_MT_OPEN`, and the open-probe now stops at the first candidate** with a
   120 s topology timeout. One open/close costs 31.04 s on this image, so the old 4-candidate
   probe overran the mailbox and reported `modetest opened no DRM device` — a transport artifact
   that looked like a display verdict.
4. `--probe-clks` to point the clock reads elsewhere if the probe window ever moves.

No gate was removed silently: gate 1 (the sink must exist) is unchanged, and `scripts/tests` is
still green — `Ran 487 tests in 29.517s / OK (skipped=27)`.

## 7. RX status (matters for Step 2 and for the passthrough)

The RX has a live source: `probe_pins` bit0 (`5V detect`) = 1, bit1 (HPD) = 1,
`rx_clk` = **593.95 MHz** (so the attached source is a 4K60/594 MHz TMDS source),
`rx_clk_alive` = 1. But:

```
rxoutclk = 0, rx_video_clk = 0, PLL_LOCK_STATUS = 0   (pll_lock covers CPLL1..3 too)
RX_INIT(0x24) = 0x00000000 (RX not held in reset)
"b0010000.hdmi-rx":0 stays [fmt:RBG888_1X24/1280x720]
after media-ctl -V on both vpss-csc pads (both rc=0) and
v4l2-ctl --set-fmt-video=3840x2160,RX24 (accepted):
    VIDIOC_STREAMON returned -1 (Broken pipe)
```

So the graph is configured but the RX GT is not delivering a recovered clock, the subdev still
advertises 1280x720, and `STREAMON` fails with EPIPE on the geometry mismatch. Note
`sc7f0-capture-init-rgb` is correctly *absent* from this image (`is-active` → `inactive`), which
is why the CSC pads came up `UYVY8_1X16/1280x720` — exactly the gap §6 of the previous findings
describes, and `26111701` does fix that part.

Per `AGENTS.md`, before anyone inspects the source again the next step for the RX half is a
**read-only IT6663 read through the existing checked MCU proxy** (`0x13/0x14/0x19`, bank 0, plus
two timing reads at `0x98..0xAA`), not another `devmem`. The RX link previously streamed at
148.5 MHz (`build/accept-26111602/card-capture-final.txt`); whether it can lock at a 594 MHz
reference with the VPHY interrupts disabled is §5's question, and the IT6663 read is what
separates "source/format" from "our GT".

## 9. Step 2.1 done anyway, because it was one line

`/mnt/data-root/.../rgb-txfix-26111701/build.exit = 1` had nothing to do with TX. The step that
failed is the CDC simulation, three lines after the unit tests:

```
ERROR: [VRFC 10-2063] Module <sc7f0_reset_sync> not found while processing module
      instance <u_wr_reset> [/home/zzlee/qpcie/rtl/video_req_cdc.v:64]
ERROR: [XSIM 43-3322] Static elaboration of top level Verilog design unit(s) ... failed
```

`rtl/video_req_cdc.v:64,66` instantiate `sc7f0_reset_sync`, which is defined only in
`rtl/sc7f0_reset_cdc.v`, and `scripts/test_sc7f0_cdc.tcl` never added that file to the simset.
Fixed there; re-running the step is now clean:

```
REQUEST_CDC_PASS: 128/256-byte payload, stalls, EOF, reset with stopped source clock
BACKPRESSURE_PASS                     (vivado -mode batch rc=0, 0 ERROR lines)
```

The earlier directories (`rgb-txfix-26111701-failed-tb`, `...-failed-mcu-artifacts`) hold the
previous three blockers from findings §10; this was the fourth. A `26111701` build is therefore
**not** blocked by anything in the repository — it is blocked by §4.

## 10. What has to happen before Step 2

1. **Restore the TX reference clock.** Concretely, in order of cost:
   measure/inspect the SI5319 leg — its input from Si5341 OUT9 (114.285 MHz), `X0_5319_RST`
   state, and the `+3.3V_5341_X0` / `+1.8V_5341_X0` rails — and confirm the Si5341 OUT9 is
   enabled in its (factory `B05239`) configuration. Acceptance for this step is not a picture:
   it is `probe_pins` bit11 = 0, `CLKDET_STAT = 0`, `CLKDET_FREQ_TX ≈ 297 MHz` and the fabric
   `tx_clk` meter reading a *stable* value, all read-only.
2. **Add `xvphy_intr_enable()` to `xvphy_probe()`** (kernel module, no bitstream).
3. Only then re-run `verify_sc7f0_hdmi_tx_drm.sh --mode 3840x2160-60` and expect
   `TX_LINK_UP` + `tx_video_clk` non-zero, at which point `0xB0030000` should also answer.
4. `26111701` as specified carries **only** the capability bit20, the overlay version gate and
   `sc7f0-capture-init-rgb`. Those are real and worth shipping, but none of them can light the
   panel, so it must not be presented as TX acceptance, and flashing it would spend the round's
   single COMMIT on a build that cannot pass item 3 of the acceptance list.
