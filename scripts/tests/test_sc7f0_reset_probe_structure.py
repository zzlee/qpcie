#!/usr/bin/env python3
"""Static contract checks for the reset-domain / probe-level rework.

These always run - no Vivado, no board, no environment gate, so they cannot be
quietly skipped into a green release suite.  They exist because the defects that
report_cdc flagged are all *shapes* that are visible in the source:

  * an OR/AND of two asynchronous resets in front of xpm_cdc_async_rst, whose
    output is an asynchronous preset (CDC-10 + all 10 CDC-12 rows);
  * a caller handing a wider reset vector to a synchronizer than the module has
    sources for, so a source is silently dropped;
  * a FIFO whose flush only covers one side, so a peer restart replays stale
    data (rtl/sc7f0_dp_fifo.v, proven in simulation, see below);
  * a single-cycle cross-domain CSR event used as a reset;
  * foreign-domain diagnostic levels pushed into a synchronizer whose declared
    src_clk is not their clock;
  * a multi-stage synchronizer whose reported value is tapped from the WRONG
    stage - `chain <= {chain[1:0], src}` shifts the new sample in at [0], so
    reading [0] reads the first (possibly still resolving) stage while the RTL
    comment, the testbench and the release notes all claimed "third stage"
    (review P0-1; see probe_tap_problems() below and
    tb/sc7f0_hdmi_probe_async_levels_tb.sv P6/P7/P8);
  * a fake local `xpm_*` module that makes a simulation "pass" without the
    vendor contract.

The behavioural proof is the XSim gate:

    vivado -mode batch -notrace -nojournal -source scripts/sim_sc7f0_reset_cdc.tcl

which elaborates the REAL xpm_cdc / xpm_fifo models (tb/sc7f0_reset_cdc_tb.sv
S0..S7, tb/sc7f0_hdmi_probe_async_levels_tb.sv P0..P8).  A simulation cannot
prove the absence of metastability, so the structural claims below are checked
separately and the limits are written into the testbench headers.

Scope of the reset-shape scan - read this, not a whole-repo guarantee
    test_no_reset_combination_before_a_synchronizer_preset and
    test_no_call_site_pre_combines_reset_vectors look at FOUR port names only:
    `.src_arst`, `.wrst_n`, `.rrst_n`, `.src_rst_n`.  They do not see
    `xpm_fifo_*` / `xpm_cdc_*` `.rst(<a || !b>)`, nor an
    `always @(posedge clk or posedge <gate output>)` written by hand, so a "pass"
    here means "no pre-synchronizer combination on those four ports in
    rtl/*.{v,sv}".  It is NOT a claim that no combinational reset reaches any
    asynchronous preset anywhere in the repository: rtl/qpcie_csr_cdc.v:85,113
    still builds `!ps_ready_pcie || !dest_rst_n` and `!src_rst_n || !src_online`
    by hand for `.rst()` (both terms are same-domain there, so today it is a
    second hand-rolled convention rather than a CDC defect, and it is outside
    this scan).  Widening the scan is a separate, deliberate change - review
    P2-10 - and this round does not make it.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RTL = ROOT / "rtl"
TB = ROOT / "tb"

# sc7f0_reset_sync defaults to SOURCES=2 (rtl/sc7f0_reset_cdc.v).
DEFAULT_SOURCES = 2


def read(path: Path) -> str:
    return path.read_text()


def rtl_sources():
    return sorted(p for p in RTL.glob("*.v")) + sorted(p for p in RTL.glob("*.sv"))


def strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    return re.sub(r"//[^\n]*", " ", text)


def tcl_commands(text: str) -> str:
    """Tcl/XDC source with whole-line `#` comments removed.

    Prose inside an XDC comment is allowed to name a command it forbids ("no
    set_output_delay here"), so a rule about which commands the file really uses
    must look at command text only.
    """
    return "\n".join(line for line in text.splitlines()
                     if not line.lstrip().startswith("#"))


def port_expr(text: str, port: str, start: int = 0) -> str:
    """Return the connection expression of `.port( ... )` handling nested parens."""
    for m in re.finditer(r"\." + port + r"\s*\(", text[start:]):
        i = start + m.end()
        depth = 1
        j = i
        while j < len(text) and depth:
            if text[j] == "(":
                depth += 1
            elif text[j] == ")":
                depth -= 1
            j += 1
        return text[i:j - 1].strip()
    return ""


def vector_width(expr: str) -> int:
    """Number of elements of a connection expression, or -1 if not statically known."""
    expr = expr.strip()
    if expr.startswith("{") and expr.endswith("}"):
        inner, depth, parts = expr[1:-1], 0, 1
        for ch in inner:
            if ch in "{(":
                depth += 1
            elif ch in "})":
                depth -= 1
            elif ch == "," and depth == 0:
                parts += 1
        return parts
    return -1


def source_capture_clock(code: str, reg: str):
    """Which clock's `always @(posedge <clock>) begin ... end` block assigns `reg`?

    Derived from the file rather than transcribed, so the same helper can prove the
    current wiring and reject a mutation of it.
    """
    for m in re.finditer(r"always\s*@\(\s*posedge\s+(\w+)\s*\)\s*begin(.*?)\n\s*end\b",
                        code, re.S):
        if re.search(r"\b" + reg + r"\s*<=", m.group(2)):
            return m.group(1)
    return None


def instantiations(text: str, module: str):
    """Yield (parameter_text, connection_text) for each `module #(...) inst (`."""
    for m in re.finditer(r"\b" + module + r"\b\s*(#\s*\(((?:[^()]|\([^()]*\))*)\))?\s*\w+\s*\(", text):
        params = m.group(2) or ""
        start = m.end()
        depth, j = 1, start
        while j < len(text) and depth:
            if text[j] == "(":
                depth += 1
            elif text[j] == ")":
                depth -= 1
            j += 1
        yield params, text[start:j - 1]


def param_value(params: str, name: str):
    m = re.search(r"\." + name + r"\s*\(\s*([^)]*)\)", params)
    return m.group(1).strip() if m else None


# The seven foreign-domain diagnostic levels of rtl/sc7f0_hdmi_probe.v, in the
# order they occupy reg_probe_pins[31:25].
PROBE_CHAIN_ORDER = ["rxss_tlast_sync", "rxss_tuser_sync", "rxss_tready_sync",
                     "rxss_tvalid_sync", "phy_ch2_tvalid_sync",
                     "phy_ch1_tvalid_sync", "phy_ch0_tvalid_sync"]


def oldest_chain_stage(code: str, chain: str):
    """Which element of `chain` holds the OLDEST sample, i.e. the stage a
    synchronizer has to report?  Derived from the chain itself - never a literal
    copied out of the fixed file:

      * `reg [H:0] chain` declares H+1 physical stages;
      * `chain <= {chain[A:0], src}` concatenates the source at the LOW end, so
        the new sample enters at [0] and the oldest stage is the declared MSB H;
      * `chain <= {src, chain[H:B]}` enters at the top, so the oldest stage is [0];
      * anything else (a split that does not touch the end where the sample
        enters) returns None instead of being guessed at.

    rtl/sc7f0_hdmi_probe.v uses `chain <= {chain[1:0], src}` on a `reg [2:0]`, so
    the answer is [2].  That is the convention this file already relies on for its
    edge detectors (`if (scl_sync[2] && !scl_sync[1])` reads [2] as the older
    sample) and for its two-stage pins (`det5v_sync[1]`).
    """
    decl = re.search(r"\breg\s*\[\s*(\d+)\s*:\s*0\s*\]\s*" + chain + r"\b", code)
    if not decl:
        return None
    hi = int(decl.group(1))
    low_in = re.search(chain + r"\s*<=\s*\{\s*" + chain +
                       r"\[\s*(\d+)\s*:\s*(\d+)\s*\]\s*,\s*[^\s{},]+\}", code)
    if low_in:
        return hi if int(low_in.group(2)) == 0 else None
    high_in = re.search(chain + r"\s*<=\s*\{\s*[^\s{},]+\s*,\s*" + chain +
                        r"\[\s*(\d+)\s*:\s*(\d+)\s*\]\s*\}", code)
    if high_in:
        return 0 if int(high_in.group(1)) == hi else None
    return None


def probe_pin_fields(code: str):
    """The raw_probe_pins concatenation fields, MSB first, comments stripped."""
    m = re.search(r"wire \[31:0\] raw_probe_pins = \{(.*?)\};", code, re.S)
    if not m:
        return []
    return [f.split("//")[0].strip().rstrip(",").strip()
            for f in m.group(1).splitlines() if f.strip()]


def probe_tap_problems(code: str):
    """Tap-position violations of the seven probe chains ([] == clean).

    The expectation is computed from each chain's own declaration and shift
    direction, so this is a rule and not a transcription of the current source:
    a first-stage tap ([0], the review P0-1 defect) and a second-stage tap ([1],
    the same defect one stage over) both come back as problems."""
    fields = probe_pin_fields(code)
    if len(fields) < len(PROBE_CHAIN_ORDER):
        return [f"raw_probe_pins has {len(fields)} fields, expected at least "
                f"{len(PROBE_CHAIN_ORDER)}"]
    problems = []
    for i, chain in enumerate(PROBE_CHAIN_ORDER):
        oldest = oldest_chain_stage(code, chain)
        if oldest is None:
            problems.append(f"{chain}: stage order is not derivable from its own "
                            f"declaration and shift direction")
        elif fields[i] != f"{chain}[{oldest}]":
            problems.append(f"{chain}: reg_probe_pins[{31 - i}] reports {fields[i]!r}, "
                            f"the oldest stage is [{oldest}]")
    return problems


class ResetProbeStructure(unittest.TestCase):
    maxDiff = None

    # -- 1. no reset logic in front of an asynchronous preset -----------------
    def test_no_reset_combination_before_a_synchronizer_preset(self):
        offenders = []
        for path in rtl_sources():
            text = strip_comments(read(path))
            for m in re.finditer(r"\.src_arst\s*\(", text):
                expr = port_expr(text, "src_arst", m.start())
                if "|" in expr or "&" in expr:
                    offenders.append(f"{path.relative_to(ROOT)}: .src_arst({expr})")
        self.assertEqual([], offenders,
                         "a multi-source reset expression is driving xpm_cdc_async_rst's "
                         "asynchronous preset; synchronise each source separately "
                         "(rtl/sc7f0_reset_cdc.v)")

    def test_no_call_site_pre_combines_reset_vectors(self):
        """`.wrst_n(a && b)` / `.rrst_n(a || b)` at a call site is the same defect
        one level up: the FIFO would synchronise an already-mixed cross-domain
        level.  Review P0-2 counted the u_packet_commands/u_packet_completions
        `.wrst_n(csr_rst_n&&pcie_rst_n)` rows this way (all 10 CDC-12 rows)."""
        offenders = []
        for path in rtl_sources():
            text = strip_comments(read(path))
            for port in ("wrst_n", "rrst_n", "src_rst_n"):
                for m in re.finditer(r"\." + port + r"\s*\(", text):
                    expr = port_expr(text, port, m.start())
                    if "&&" in expr or "||" in expr:
                        offenders.append(f"{path.relative_to(ROOT)}: .{port}({expr})")
        self.assertEqual([], offenders,
                         "combine resets only after each one is synchronised, never at a "
                         "call site")

    # -- 2. every reset_sync source vector matches its SOURCES ----------------

    # -- 2. every reset_sync source vector matches its SOURCES ----------------
    def test_reset_sync_source_vectors_match_sources(self):
        problems = []
        for path in rtl_sources():
            text = strip_comments(read(path))
            for params, conns in instantiations(text, "sc7f0_reset_sync"):
                inst_dest_clk = port_expr(conns, "dest_clk")
                raw = port_expr(conns, "src_rst_n")
                declared = param_value(params, "SOURCES")
                want = int(declared) if declared and declared.isdigit() else DEFAULT_SOURCES
                got = vector_width(raw)
                if got < 0:
                    if declared and not declared.isdigit():
                        continue  # parameterised width (sc7f0_dp_fifo): checked below
                    continue      # a named vector, width is the caller's business
                if got != want:
                    problems.append(
                        f"{path.relative_to(ROOT)}: sc7f0_reset_sync SOURCES={want} "
                        f"but src_rst_n carries {got} bits ({raw!r}), dest_clk={inst_dest_clk}")
                # self-dependency: a reset output must never be its own source
                out = port_expr(conns, "dest_rst_n")
                if out and out in raw:
                    problems.append(
                        f"{path.relative_to(ROOT)}: sc7f0_reset_sync dest_rst_n={out} "
                        f"is also one of its own sources (dependency loop)")
        self.assertEqual([], problems,
                         "a dropped reset source (vector narrower than SOURCES) silently "
                         "disconnects a reset; a wider one is truncated")

    def test_every_reset_sync_has_a_real_clock_port(self):
        problems = []
        for path in rtl_sources():
            text = strip_comments(read(path))
            for _params, conns in instantiations(text, "sc7f0_reset_sync"):
                dest_clk = port_expr(conns, "dest_clk")
                if not re.fullmatch(r"[a-zA-Z_][\w.]*", dest_clk or ""):
                    problems.append(f"{path.relative_to(ROOT)}: dest_clk={dest_clk!r}")
        self.assertEqual([], problems)

    # -- 3. the FIFO flush really covers both sides --------------------------
    def test_dp_fifo_flushes_on_either_side(self):
        text = strip_comments(read(RTL / "sc7f0_dp_fifo.v"))
        for inst, own, other in (("u_reset", "wrst_n", "rrst_n"),
                                 ("u_read_reset", "rrst_n", "wrst_n")):
            m = re.search(r"sc7f0_reset_sync\s*#\s*\(\.SOURCES\(([^)]*)\)\)\s*" + inst, text)
            self.assertIsNotNone(m, f"{inst} must be an sc7f0_reset_sync")
            self.assertEqual("W_SOURCES+R_SOURCES", m.group(1),
                             f"{inst} must synchronise every source of both sides")
            conns = text[m.end():]
            src = port_expr(conns, "src_rst_n")
            self.assertIn("wrst_n", src, f"{inst} loses the write-side source")
            self.assertIn("rrst_n", src, f"{inst} loses the read-side source: a peer "
                                         "restart would then replay stale data")

    def test_dp_fifo_still_uses_one_xpm_fifo_and_no_pre_combined_reset(self):
        text = strip_comments(read(RTL / "sc7f0_dp_fifo.v")).split("module sc7f0_dp_sync_fifo")[0]
        self.assertNotIn("||", text,
                         "sc7f0_dp_fifo must not re-introduce a pre-synchronizer OR")
        self.assertEqual(1, text.count("xpm_fifo_async"))

    # -- 4. the single-cycle CSR event is not a reset ------------------------
    def test_global_reset_event_goes_through_the_hold_module(self):
        text = strip_comments(read(RTL / "custom_pcie_dma_top.v"))
        hits = [ln for ln in text.splitlines() if "global_reset_pulse_w" in ln]
        self.assertTrue(hits, "global_reset_pulse_w should still exist")
        allowed = (".evt(global_reset_pulse_w)",            # sc7f0_event_reset input
                   "wireglobal_reset_pulse_w",             # declaration
                   ".out_global_reset_pulse(global_reset_pulse_w)")  # CSR producer
        for ln in hits:
            flat = ln.replace(" ", "")
            self.assertTrue(any(a in flat for a in allowed),
                            f"the one-cycle event is used outside sc7f0_event_reset: {ln.strip()}")
            self.assertNotIn("src_arst", flat,
                             f"a one-cycle cross-domain event is driving an async preset: {ln.strip()}")
        self.assertIn("sc7f0_event_reset", text)
        # dma_rst_n must be produced by the reset synchronizer, not by an expression
        m = re.search(r"sc7f0_reset_sync\s*#\s*\(\.SOURCES\(3\)\)\s*u_dma_reset", text)
        self.assertIsNotNone(m, "dma_rst_n must come from sc7f0_reset_sync")
        src = port_expr(text[m.end():], "src_rst_n")
        self.assertIn("global_reset_hold_n", src)
        self.assertNotIn("global_reset_pulse_w", src)

# -- 5. probe diagnostic levels ------------------------------------------
    # chain -> (what drives its first stage, the true source clock port, the
    # report_cdc clock name, the named exception id in constraints/ and in the
    # implementation hook).  Round 26111202: report_cdc still filed six Critical
    # CDC-10 rows here because the level reached the pl_clk0 chain through the
    # vendor's combinational output; the fix is one register in the SOURCE clock,
    # and the exception is then written from that flop to chain[0] only.
    PROBE_CHAINS = {
        "rxss_tlast_sync": ("rxss_tlast_src", "clk_rx_video", "clkout2",
                            "probe_rxss_tlast_src_to_probe"),
        "rxss_tuser_sync": ("rxss_tuser_src", "clk_rx_video", "clkout2",
                            "probe_rxss_tuser_src_to_probe"),
        # tready is a constant at the only board-level consumer
        # (rtl/zu4ev_pcie_card_top.v:1053) and produced no CDC row, so it keeps no
        # source stage on purpose; an added stage would be dead logic.
        "rxss_tready_sync": ("rx_ss_video_tready", None, None, None),
        "rxss_tvalid_sync": ("rxss_tvalid_src", "clk_rx_video", "clkout2",
                             "probe_rxss_tvalid_src_to_probe"),
        "phy_ch2_tvalid_sync": ("phy_ch2_tvalid_src", "clk_rxout", "phy_rxoutclk",
                               "probe_phy_ch2_tvalid_src_to_probe"),
        "phy_ch1_tvalid_sync": ("phy_ch1_tvalid_src", "clk_rxout", "phy_rxoutclk",
                               "probe_phy_ch1_tvalid_src_to_probe"),
        "phy_ch0_tvalid_sync": ("phy_ch0_tvalid_src", "clk_rxout", "phy_rxoutclk",
                                "probe_phy_ch0_tvalid_src_to_probe"),
    }
    # The foreign port each source register belongs to, and the raw port that must
    # never reach a chain again.
    PROBE_RAW_PORTS = {
        "rxss_tlast_src": "rx_ss_video_tlast",
        "rxss_tuser_src": "rx_ss_video_tuser",
        "rxss_tvalid_src": "rx_ss_video_tvalid",
        "phy_ch0_tvalid_src": "phy_rx_axi4s_ch0_tvalid",
        "phy_ch1_tvalid_src": "phy_rx_axi4s_ch1_tvalid",
        "phy_ch2_tvalid_src": "phy_rx_axi4s_ch2_tvalid",
    }

    def test_probe_async_levels_have_one_async_reg_chain_each(self):
        text = read(RTL / "sc7f0_hdmi_probe.v")
        code = strip_comments(text)
        for chain, (feed, _clk, _clock_name, _exc) in self.PROBE_CHAINS.items():
            self.assertRegex(
                code,
                r"\(\* ASYNC_REG\s*=\s*\"TRUE\" \*\)\s*reg \[2:0\]\s*" + chain + r"\b",
                f"{chain} must be a 3-register ASYNC_REG chain")
            self.assertRegex(
                code,
                chain + r"\s*<=\s*\{\s*" + chain + r"\[1:0\]\s*,\s*" + feed + r"\s*\}",
                f"{chain} must be clocked by pl_clk0 from exactly {feed} (its "
                f"source-domain register, or the constant-tied tready input)")
            # the raw register must use the chain output, never the foreign input
            self.assertNotRegex(
                code,
                r"raw_probe_pins\s*=.*?" + feed + r"\s*,",
                f"{feed} must not reach raw_probe_pins unregistered")

    def test_probe_levels_are_first_captured_in_their_own_source_clock(self):
        """The 26111202 CDC-10 fix: a register in the true source domain, first.

        Each of the six levels must be captured by the clock report_cdc named for
        its launch flop (clk_rx_video = clkout2, clk_rxout = phy_rxoutclk), and no
        foreign port may feed a pl_clk0 chain again.  The source registers carry no
        reset on purpose (see the comment in the RTL): a reset for those domains
        would have to be a reset already synchronised into them, and pulling
        pl_clk0's rst_n into a clkout2 / phy_rxoutclk flop is the mixed-domain
        reset this project already unwound once.
        """
        code = strip_comments(read(RTL / "sc7f0_hdmi_probe.v"))
        for reg, clock in (("rxss_tlast_src", "clk_rx_video"),
                           ("rxss_tuser_src", "clk_rx_video"),
                           ("rxss_tvalid_src", "clk_rx_video"),
                           ("phy_ch0_tvalid_src", "clk_rxout"),
                           ("phy_ch1_tvalid_src", "clk_rxout"),
                           ("phy_ch2_tvalid_src", "clk_rxout")):
            self.assertRegex(code, r"\breg\s+" + reg + r"\b", f"{reg} must exist")
            self.assertRegex(code, r"reg\s+" + reg + r"\s*=\s*1'b0",
                             f"{reg} must initialise to 0 like the other "
                             f"foreign-domain registers in this file")
            self.assertEqual(clock, source_capture_clock(code, reg),
                             f"{reg} must be captured by {clock}, the clock "
                             f"report_cdc names for its launch flop")
            # the raw port may only appear as the input of that capture
            raw = self.PROBE_RAW_PORTS[reg]
            feeds = re.findall(r"(\w+_sync)\s*<=\s*\{[^{}]*\b" + raw + r"\b[^{}]*\}", code)
            self.assertEqual([], feeds,
                             f"{raw} feeds {feeds} directly; the crossing must go "
                             f"through {reg} first (that is the CDC-10 fix)")

    def test_probe_source_stage_has_no_foreign_domain_reset(self):
        """No pl_clk0 reset may reach the two foreign-domain capture flops."""
        code = strip_comments(read(RTL / "sc7f0_hdmi_probe.v"))
        for reg, clock in (("rxss_tlast_src", "clk_rx_video"),
                           ("phy_ch0_tvalid_src", "clk_rxout")):
            block = re.search(r"always\s*@\(\s*posedge\s+" + clock +
                              r"\s*\)(.*?)end\b", code, re.S)
            self.assertIsNotNone(block, f"capture block for {reg} not found")
            body = block.group(1)
            self.assertNotIn("rst_n", body,
                             f"{reg}'s block must not use a reset from another "
                             f"domain; it would create the mixed-domain reset this "
                             f"project already had to unwind")

    def test_probe_source_crossings_are_named_end_to_end(self):
        """One table, four places: RTL, XDC, hook, policy - or the round fails.

        A false path that names nothing, or a hook item whose cell pattern no
        longer matches the RTL, is exactly how an exception silently stops covering
        what it claims to cover.  This is the producer/policy contract test.
        """
        rtl = strip_comments(read(RTL / "sc7f0_hdmi_probe.v"))
        xdc = read(ROOT / "constraints" / "sc7f0_async_io.xdc")
        hook = read(ROOT / "scripts" / "check_sc7f0_named_constraints.tcl")
        policy = read(ROOT / "scripts" / "gates" / "sc7f0_clock_pair_review.json")
        for chain, (feed, _clk, _clock, exc) in self.PROBE_CHAINS.items():
            if exc is None:
                continue
            # Round 26111204 measured that Vivado 2023.2 has NO `-name` option on
            # set_false_path: `CRITICAL WARNING: [Common 17-170] Unknown option
            # '-name'` at constraints/sc7f0_async_io.xdc:199/202/205/208/211/214
            # (build/vcu-release-26111204-r1/fpga/project-logs/impl-vivado.log:3039-
            # 3044), and no exception was created for any of the six pairs - which is
            # why all six stayed timed at the 0.002 ns async requirement and held
            # that round's WNS -2.472 / TNS -11.946.  A pair is therefore named by
            # the comment above its command, and the command itself must be a plain
            # false path from the source flop to chain[0] only.
            self.assertIn("# " + exc, xdc, f"{exc} must name the reviewed pair")
            flat = tcl_commands(xdc).replace("\\\n", " ")
            mine = [re.sub(r"\s+", " ", c).strip()
                    for c in ("set_false_path" + part
                              for part in flat.split("set_false_path")[1:])
                    if "u_hdmi_probe/" + feed + "_reg" in c and
                    "u_hdmi_probe/" + chain + r"_reg\[0\]" in c]
            self.assertEqual(1, len(mine),
                             f"{exc}: exactly one command may cover this pair, got "
                             f"{len(mine)}")
            self.assertTrue(mine[0].startswith("set_false_path -from"), mine[0][:90])
            self.assertNotIn("-name", mine[0],
                             f"{exc}: set_false_path -name is rejected by 2023.2 and "
                             "drops the whole command")
            self.assertNotIn("get_clocks", mine[0],
                             f"{exc}: no clock may be cut, only the named flop pair")
            self.assertIn("u_hdmi_probe/" + feed + r"_reg", xdc,
                          f"{exc} must name the source register")
            self.assertIn("u_hdmi_probe/" + chain + r"_reg\[0\]", xdc,
                          f"{exc} must name the first stage and nothing else")
            self.assertIn(exc, hook, f"the implementation hook must measure {exc}")
            self.assertIn(exc, policy, f"a review entry must claim {exc}")
            self.assertRegex(rtl, r"\breg\s+" + feed + r"\b",
                             f"{feed} must exist for {exc} to resolve")
        for clock_pair in ("clkout2", "phy_rxoutclk"):
            self.assertIn(clock_pair, policy,
                          f"{clock_pair} must be declared in the clock-pair review")
            self.assertIn(clock_pair, hook, f"the hook must check {clock_pair}")

    def test_rx_ddc_output_direction_is_excepted_per_port(self):
        """check_timing HIGH of round 26111202: two output ports, two named rows.

        One command per port (no wildcard, no invented set_output_delay), and the
        four input-side rows must survive next to them: excepting the driver may
        not quietly except the vendor filter or the probe chain too.
        """
        xdc_cmds = tcl_commands(read(ROOT / "constraints" / "sc7f0_async_io.xdc"))
        for port, exc in (("hdmi_rx_ddc_scl", "async_out_hdmi_rx_ddc_scl"),
                          ("hdmi_rx_ddc_sda", "async_out_hdmi_rx_ddc_sda")):
            self.assertIn(f"set_false_path -name {exc} -to [get_ports {port}]", xdc_cmds,
                          f"{port} needs its own named output-direction exception")
            self.assertIn(f"set_false_path -from [get_ports {port}]", xdc_cmds,
                          f"{port} must keep its input-side first-stage exception")
        self.assertNotIn("set_output_delay", xdc_cmds,
                         "no output delay may be invented for an asynchronous "
                         "open-drain DDC pad")
        self.assertNotIn("set_clock_groups", xdc_cmds,
                         "a clock group would cut far more than the named entry")
        policy = read(ROOT / "scripts" / "gates" / "sc7f0_cdc_review.json")
        for exc in ("async_out_hdmi_rx_ddc_scl", "async_out_hdmi_rx_ddc_sda"):
            self.assertIn(exc, policy, f"{exc} must be itemised in io_items")

    def test_source_stage_contract_is_falsifiable(self):
        """Negative control, in Python, always running.

        Removing the source stage (the pre-26111202 shape) in memory must be
        reported by the same rules above; otherwise those rules only restate the
        current file and prove nothing.
        """
        code = strip_comments(read(RTL / "sc7f0_hdmi_probe.v"))
        mutated = code.replace("{rxss_tvalid_sync[1:0],    rxss_tvalid_src}",
                              "{rxss_tvalid_sync[1:0],    rx_ss_video_tvalid}", 1)
        self.assertNotEqual(mutated, code, "mutation did not apply")
        feeds = re.findall(r"(\w+_sync)\s*<=\s*\{[^{}]*\brx_ss_video_tvalid\b[^{}]*\}",
                          mutated)
        self.assertEqual(["rxss_tvalid_sync"], feeds,
                         "bypassing the source register must be detectable")
        block = re.search(r"always\s*@\(\s*posedge\s+clk_rx_video\s*\)\s*begin"
                          r"[^{}]*rxss_tvalid_src\s*<=.*?\n\s*end\b", code, re.S)
        self.assertIsNotNone(block, "the capture block was not found as expected")
        moved = (code[:block.start()] +
                 block.group(0).replace("posedge clk_rx_video", "posedge clk", 1) +
                 code[block.end():])
        self.assertNotEqual(moved, code, "clock mutation did not apply")
        self.assertEqual("clk", source_capture_clock(moved, "rxss_tvalid_src"),
                         "a capture re-clocked to pl_clk0 must be reported by the "
                         "same helper, otherwise the clock rule only restates the "
                         "current file")

    def test_probe_pin_array_single_is_in_domain(self):
        code = strip_comments(read(RTL / "sc7f0_hdmi_probe.v"))
        m = re.search(r"xpm_cdc_array_single\s*#\s*\(((?:[^()]|\([^()]*\))*)\)\s*u_pin_levels_cdc", code)
        self.assertIsNotNone(m, "u_pin_levels_cdc must exist")
        params = re.sub(r"\s+", "", m.group(1))
        self.assertIn(".SRC_INPUT_REG(1)", params,
                      "SRC_INPUT_REG(0) means the declared src_clk is not actually used")
        src_clk = port_expr(code[m.end():], "src_clk")
        dest_clk = port_expr(code[m.end():], "dest_clk")
        self.assertEqual(src_clk, dest_clk,
                         "the array_single now only carries same-domain bits, so src_clk "
                         "and dest_clk must be the same clock")
        self.assertIn("raw_probe_pins", port_expr(code[m.end():], "src_in"))

    def test_probe_bit_map_uses_the_oldest_stage_of_each_chain(self):
        """reg_probe_pins[31:25] must report the OLDEST stage of each chain.

        The expected index is derived by oldest_chain_stage() from the chain's own
        declaration and shift direction, so the assertion cannot be satisfied by
        transcribing whatever the RTL currently says.  It replaced a version that
        hard-coded `[0]` - the newest sample - and so certified the defect it was
        written to catch (review P0-1)."""
        code = strip_comments(read(RTL / "sc7f0_hdmi_probe.v"))
        self.assertEqual([], probe_tap_problems(code),
                         "reg_probe_pins[31:25] is not tapped at the oldest stage; "
                         "tb/sc7f0_hdmi_probe_async_levels_tb.sv P6/P7/P8 measures "
                         "the same rule as a 3+4 = 7 pl_clk0 edge delay")
        # and the documented bit positions themselves
        self.assertEqual(PROBE_CHAIN_ORDER, [f.split("[")[0] for f in probe_pin_fields(code)[:7]],
                         "reg_probe_pins[31:25] bit map changed; tb/"
                         "sc7f0_hdmi_probe_async_levels_tb.sv walks these positions")

    def test_probe_tap_rule_rejects_a_first_or_second_stage_tap(self):
        """Negative test for the rule above, in pure Python, always running.

        Mutate the tap to [0] and to [1] in memory and demand that the very same
        check reports a problem.  Without this, `assertEqual([], problems)` is
        only as good as whoever wrote the expected string."""
        code = strip_comments(read(RTL / "sc7f0_hdmi_probe.v"))
        self.assertEqual(2, oldest_chain_stage(code, "rxss_tlast_sync"),
                         "chain <= {chain[1:0], src} on a reg [2:0] means the oldest "
                         "sample is [2]; if this changed, rewrite the rule")
        for bad in (0, 1):
            mutated = code.replace("rxss_tlast_sync[2]", f"rxss_tlast_sync[{bad}]", 1)
            self.assertNotEqual(mutated, code, f"mutation to [{bad}] did not apply")
            problems = probe_tap_problems(mutated)
            self.assertTrue(problems,
                            f"a first/second-stage tap ([{bad}]) must be reported as a "
                            f"defect; the rule is not independent of the source")
            self.assertIn("rxss_tlast_sync", problems[0])
        # a chain whose shift direction no longer proves which end is oldest must
        # not silently pass either
        flipped = re.sub(r"rxss_tuser_sync\s*<=\s*\{\s*rxss_tuser_sync\[1:0\]\s*,",
                         "rxss_tuser_sync     <= {2'b00,", code)
        self.assertNotEqual(flipped, code, "shift-direction mutation did not apply")
        self.assertTrue(any("rxss_tuser_sync" in p for p in probe_tap_problems(flipped)),
                        "an undecidable stage order must be reported, not guessed")

    def test_probe_testbench_does_not_compare_a_chain_with_itself(self):
        """The vacuity guard.  The old P6 wrote
        `u_probe.rxss_tlast_sync[0] === reg_probe_pins[31]`, i.e. the design
        compared against the register it drives: every tap position satisfied it.
        Re-introducing that shape must fail here even if the prose still says
        'third stage'."""
        tb = read(TB / "sc7f0_hdmi_probe_async_levels_tb.sv")
        self.assertEqual([], re.findall(r"u_probe\.\w+_sync\s*\[\d\]\s*===\s*reg_probe_pins",
                                       strip_comments(tb)),
                         "hierarchical chain compared with the register it drives - "
                         "a tap on any stage passes that; compare against an "
                         "independent expected model instead")
        for anchor in ("m_expected", "m_chain", "stage_discriminated",
                       "PIPE_MIN", "early_arrivals", "pulse_edges"):
            self.assertIn(anchor, tb,
                          f"the expected-model / cycle-exact / non-vacuity machinery "
                          f"({anchor}) must stay in the probe level testbench")
        self.assertGreaterEqual(tb.count("PROBE_LEVEL_CHECK_PASS"), 1)

    # -- 6. the simulation must exercise the vendor models -------------------
    def test_no_local_xpm_stub_can_fake_the_contract(self):
        fakes = []
        for path in list(RTL.glob("*.v")) + list(RTL.glob("*.sv")) + list(TB.glob("*.sv")):
            if re.search(r"^\s*module\s+xpm_(cdc|fifo|memory)_\w+", read(path), re.M):
                fakes.append(str(path.relative_to(ROOT)))
        self.assertEqual([], fakes,
                         "a local stand-in for an XPM primitive lets a simulation claim "
                         "safety the vendor model does not provide")

    def test_sim_gate_script_covers_both_testbenches_with_real_xpm(self):
        tcl = read(ROOT / "scripts" / "sim_sc7f0_reset_cdc.tcl")
        self.assertIn("XPM_CDC", tcl)
        self.assertIn("XPM_FIFO", tcl)
        for top in ("sc7f0_reset_cdc_tb", "sc7f0_hdmi_probe_async_levels_tb"):
            self.assertIn(top, tcl)
        for src in ("rtl/sc7f0_reset_cdc.v", "rtl/sc7f0_dp_fifo.v", "rtl/sc7f0_hdmi_probe.v"):
            self.assertIn(src.replace("rtl/", "./rtl/"), tcl, f"{src} is not simulated")
        self.assertNotIn("shutdown", tcl, "shutdown is not a valid xsim console command")

    def test_recorded_simulation_verdict_is_a_pass_if_present(self):
        """A stored gate log must be a pass.  The command itself is:

        vivado -mode batch -notrace -nojournal -source scripts/sim_sc7f0_reset_cdc.tcl
        """
        logs = sorted((ROOT / "build").glob("reset-probe-validation-*/reset-sim-stdout*.log"))
        bad = []
        for log in logs:
            text = read(log)
            if "VIVADO_EXIT=" not in text:
                continue  # an interrupted capture, not a verdict
            tail = text.split("VIVADO_EXIT=")[-1].strip().splitlines()[0] if "VIVADO_EXIT=" in text else "?"
            if "RESET_CDC_SIM_GATE_PASS" not in text or tail != "0":
                bad.append(f"{log.relative_to(ROOT)}: VIVADO_EXIT={tail}")
        self.assertEqual([], bad, "a recorded reset/probe simulation log did not pass")


if __name__ == "__main__":
    unittest.main()
