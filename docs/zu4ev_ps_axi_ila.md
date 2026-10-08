# ZU4EV PS → PL AXI ILA (26100807)

This diagnostic build adds one ILA clocked from `pl_clk0` (~100 MHz), not the PCIe user clock. The ILA does not alter the PS AXI path. Keep `qpcie-upgrade-daemon.service` disabled for single-read diagnosis.

Timing caveat: implementation reports 100 MHz `clk_pl_0` intra-clock WNS +1.749 ns, but overall timing is **not met** (WNS -1.716 ns, mainly `clk_pl_0` → `pcie_user_clk` inter-clock paths). This build is for standalone PS AXI diagnostics, not a claim that PCIe functionality is production-validated.

| Probe | Signal |
| --- | --- |
| 0 | `ps_axi_ila_status[31:0]`, bit map below |
| 1 | `s_axil_ps_araddr[31:0]` before BAR0 offset stripping |
| 2 | `arb_axil_araddr[31:0]` at DMA CSR slave |
| 3 | `s_axil_ps_rdata[31:0]` returned to PS |
| 4 | `s_axil_ps_arvalid` dedicated trigger |

Status bits: 0=`sys_100m_rst_n`; 1=`arb_awvalid`; 2=`env_awvalid`; 3=`cvt_bar0_arvalid` (PCIe); 4=`ps_arvalid`; 5=`ps_arready`; 6=`ps_rvalid`; 7=`ps_rready`; 8=`arb_arvalid`; 9=`arb_arready`; 10=`arb_rvalid`; 11=`arb_rready`; 12=`env_arvalid`; 13=`env_arready`; 14=`env_rvalid`; 15=`env_rready`; 17:16=`ps_rresp`; 19:18=`arb_rresp`; 21:20=`env_rresp`. Remaining bits zero.

Arm ILA via JTAG **before** invoking `devmem` over UART. Trigger probe4 on 1, capture 4096 samples; save a CSV. First try `devmem 0xA0000000 32` (expected magic `0x12ABE380`); only if it completes, try `devmem 0xA0001000 32` (environment version). Do **not** access `0xB0000000` or `0xA0010000`: outside the mapped HPM0 64 KiB aperture. If the read wedges, do not issue more commands; preserve power and retrieve ILA through JTAG, then power-cycle as needed. If ILA never triggers, investigate PS/BD path before the HPM0 ports, or whether debug clock/reset are active. A triggered trace can distinguish no AR handshake, failed crossbar decode, hung CSR, and a reply not making it back to PS.

Vivado Hardware Manager: open local hardware target, load `build/qpcie_zu4ev_proj/qpcie_zu4ev_card.runs/impl_1/zu4ev_pcie_card_top.ltx` as probes file on `xczu4_0` (and refresh device); open `u_dma_top/u_ila_ps_axi`. Set trigger `probe4 == 1`, run trigger; then issue the single UART command. Export ILA waveform CSV, including the first and last samples. Probe position is independent of the PCIe link.

Alternatively from the repository root, run `source /opt/Xilinx/Vivado/2023.2/settings64.sh && vivado -mode batch -nolog -nojournal -source scripts/capture_zu4ev_ps_axi_ila.tcl` on the JTAG host; wait for the `ARMED` message before issuing the UART `devmem`. It writes `build/zu4ev_ps_axi_capture.csv`. If using the GUI instead, do not run the script at the same time: use one hardware manager per cable.

The two boot roles remain separate: SD root files (`BOOT.BIN`, `boot.scr`, `image.ub`) boot the eMMC installer; only `target_emmc/` gets copied to eMMC by that installer. The eMMC rootfs image in this diagnostic release explicitly masks the upgrade service (`/etc/systemd/system/qpcie-upgrade-daemon.service -> /dev/null`), as verified by extracting its FIT ramdisk. Capture the ILA *before* the first `devmem` because a hung read cannot be interrupted reliably from Linux.
