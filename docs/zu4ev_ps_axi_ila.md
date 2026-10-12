# ZU4EV PS → PL AXI ILA (26101203)

This diagnostic build adds one ILA clocked from `pl_clk0` (~100 MHz), not the PCIe user clock. The ILA does not alter the PS AXI path. Keep `qpcie-upgrade-daemon.service` disabled for single-read diagnosis.

Timing caveat: 26101203 implementation reports 100 MHz `clk_pl_0` intra-clock WNS +1.681 ns, but overall timing is **not met** (WNS -1.706 ns; inter-clock paths violate timing). These builds are for standalone PS AXI diagnostics, not a claim that PCIe functionality is production-validated.

| Probe | Signal |
| --- | --- |
| 0 | `ps_axi_ila_status[31:0]`, bit map below |
| 1 | `s_axil_ps_araddr[31:0]` before BAR0 offset stripping |
| 2 | `arb_axil_araddr[31:0]` at DMA CSR slave |
| 3 | `s_axil_ps_rdata[31:0]` returned to PS |
| 4 | raw PS HPM0 `ARVALID` dedicated trigger (before protocol conversion) |
| 5 | raw PS HPM0 `ARID[15:0]` (must match `RID`) |
| 6 | raw PS HPM0 `ARLEN[7:0]` |
| 7 | PS HPM0 `ARSIZE[2:0]` |
| 8 | returned PS HPM0 `RID[15:0]` |
| 9 | returned PS HPM0 `RVALID` |
| 10 | raw PS HPM0 `ARREADY` |

Status bits: 0=`sys_100m_rst_n`; 1=`arb_awvalid`; 2=`env_awvalid`; 3=`cvt_bar0_arvalid` (PCIe); 4=`ps_arvalid`; 5=`ps_arready`; 6=`ps_rvalid`; 7=`ps_rready`; 8=`arb_arvalid`; 9=`arb_arready`; 10=`arb_rvalid`; 11=`arb_rready`; 12=`env_arvalid`; 13=`env_arready`; 14=`env_rvalid`; 15=`env_rready`; 17:16=`ps_rresp`; 19:18=`arb_rresp`; 21:20=`env_rresp`; 22=`pl_resetn0`. Remaining bits zero.

Arm ILA via JTAG **before** invoking `devmem` over UART. Trigger probe4 on 1, capture 4096 samples; save a CSV. First try `devmem 0xA0000000 32` (expected magic `0x12ABE380`); only if it completes, try `devmem 0xA0001000 32` (environment version). Do **not** access `0xB0000000` or `0xA0010000`: outside the mapped HPM0 64 KiB aperture. If the read wedges, do not issue more commands; preserve power and retrieve ILA through JTAG, then power-cycle as needed. If ILA never triggers, investigate PS/BD path before the HPM0 ports, or whether debug clock/reset are active. A triggered trace can distinguish no AR handshake, failed crossbar decode, hung CSR, and a reply not making it back to PS.

Vivado Hardware Manager: open local hardware target, load `build/qpcie_zu4ev_proj/qpcie_zu4ev_card.runs/impl_1/zu4ev_pcie_card_top.ltx` as probes file on `xczu4_0` (and refresh device); open `u_dma_top/u_ila_ps_axi`. Set trigger `probe4 == 1`, run trigger; then issue the single UART command. Export ILA waveform CSV, including the first and last samples. Probe position is independent of the PCIe link.

Alternatively from the repository root, run `source /opt/Xilinx/Vivado/2023.2/settings64.sh && vivado -mode batch -nolog -nojournal -source scripts/capture_zu4ev_ps_axi_ila.tcl` on the JTAG host; wait for the `ARMED` message before issuing the UART `devmem`. It writes `build/zu4ev_ps_axi_capture.csv`. If using the GUI instead, do not run the script at the same time: use one hardware manager per cable.

The two boot roles remain separate: SD root files (`BOOT.BIN`, `boot.scr`, `image.ub`) boot the eMMC installer; only `target_emmc/` gets copied to eMMC by that installer. The eMMC rootfs image in this diagnostic release explicitly masks the upgrade service (`/etc/systemd/system/qpcie-upgrade-daemon.service -> /dev/null`), as verified by extracting its FIT ramdisk. Capture the ILA *before* the first `devmem` because a hung read cannot be interrupted reliably from Linux.

0807 capture: `sys_100m_rst_n=0` held the slave in reset. 1201 fixed reset and PL returned `0x12ABE380`, **but Linux devmem still hung**. 1202 capture shows `ARID=0x002D`, `ARLEN=0`, `ARSIZE=2` while RTL forced `RID=0`: an AXI4 ID mismatch. 1203 adds an AMD AXI4-to-AXI4-Lite protocol converter between PS HPM0 and the existing shared BAR0 crossbar, replacing hardwired `RID/BID/RLAST`. Probe4 now triggers at the raw PS AXI4 interface. Require Linux `devmem` to actually return; PL-side handshake alone does not prove CPU completion.

Before burning 1203, run `source /opt/Xilinx/Vivado/2023.2/settings64.sh && vivado -mode batch -source scripts/sim_zu4ev_ps_axi_protocol.tcl`. The focused `tb/zu4ev_ps_axi_protocol_tb.sv` instantiates the **real Vivado converter IP** and a small AXI4-Lite CSR responder. It checks nonzero `ARID=0x002D` -> matching `RID`, `RLAST`, magic and version reads, nonzero `AWID` -> matching `BID`, and write/readback. Expect `TB_PASS`. This does **not** simulate the PS hard block, NoC, clock converter, crossbar with both masters, Linux driver, or installed board; still capture ILA and verify that `devmem` actually returns.
