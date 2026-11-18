#!/usr/bin/env python3
"""Compile the complete board DTS and check HDMI bindings against generated XCI.

Uses existing DTG PS sources, not a synthetic test tree. This checks software
consistency only, not a new XSA import, electrical clocks, or runtime probe.
Outputs are scratch artifacts, never images/linux/system.dtb.
"""
import argparse
import json
import shutil
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PLNX = ROOT / "petalinux/qpcie-zu4ev"


def run(args):
    return subprocess.check_output([str(a) for a in args], text=True).strip()


def check(args, output):
    generated = args.generated_dt
    user = PLNX / "project-spec/meta-user/recipes-bsp/device-tree/files"
    preprocessed = output / "system-top.dts.pp"
    dtb = output / "sc7f0-hdmi-rx-test.dtb"
    capture = getattr(args, "capture", False) or getattr(args, "rgb", False)
    if capture and args.disabled:
        raise ValueError("Capture cannot be enabled on the disabled/debug profile")
    profile_flags = [] if args.disabled else ["-DSC7F0_HDMI_RX_ENABLE=1"]
    if capture:
        profile_flags.append("-DSC7F0_PS_CAPTURE_ENABLE=1")
    # SC7F0-RGB-COMPOSITOR-2PPC is a personality of the display tree, and the
    # bbappend refuses the combination unless both stages are enabled, so the
    # RGB profile preprocesses with all four flags.
    rgb = getattr(args, "rgb", False)
    if rgb:
        profile_flags += ["-DSC7F0_PS_CAPTURE_ENABLE=1",
                          "-DSC7F0_HDMI_TX_ENABLE=1",
                          "-DSC7F0_RGB_COMPOSITOR_ENABLE=1"]
    with preprocessed.open("w") as stream:
        subprocess.run([
            "gcc", "-E", "-nostdinc", "-undef", "-D__DTS__",
            *profile_flags, "-x", "assembler-with-cpp", "-I", str(user),
            "-I", str(generated), "-I", str(generated / "include"),
            str(generated / "system-top.dts"),
        ], stdout=stream, check=True)
    subprocess.run([
        str(args.dtc), "-I", "dts", "-O", "dtb", "-i", str(generated),
        "-o", str(dtb), str(preprocessed),
    ], check=True)
    fdtget = args.dtc.with_name("fdtget")
    if not fdtget.is_file():
        # Vivado prepends Vitis/bin/dtc, but that directory has no fdtget.
        # Resolve the independent tool instead of assuming they ship together.
        fdtget = Path(shutil.which("fdtget") or str(PLNX /
                     "build/tmp/sysroots-components/x86_64/dtc-native/usr/bin/fdtget"))
    if not fdtget.is_file():
        raise FileNotFoundError("fdtget is required (install device-tree-compiler or build dtc-native)")

    def cells(node, prop):
        return [int(x, 16) for x in run([fdtget, "-t", "x", dtb, node, prop]).split()]

    def strings(node, prop):
        return run([fdtget, "-t", "s", dtb, node, prop]).split()

    def require(actual, expected, description):
        if actual != expected:
            raise ValueError(f"{description}: {actual!r} != {expected!r}")

    if args.disabled:
        require(strings("/qpcie_v4l2_bridge", "status"), ["disabled"], "default bridge")
        children = run([fdtget, "-l", dtb, "/amba_pl@0"]).split()
        if "phy@b0000000" in children or "hdmi-rx@b0010000" in children:
            raise ValueError("Default/debug DTS must not probe HDMI apertures")
        print("HDMI_DT_DISABLED_PASS: default/debug DTS does not enable HDMI probes")
        return

    def xci(module):
        data = json.loads((args.xci_dir / module / f"{module}.xci").read_text())
        return {k: v[0]["value"] for k, v in
                data["ip_inst"]["parameters"]["component_parameters"].items()}

    phy = "/amba_pl@0/phy@b0000000"
    rx = "/amba_pl@0/hdmi-rx@b0010000"
    require(cells(phy, "reg"), [0, 0xb0000000, 0, 0x1000], "VPHY aperture")
    require(cells(rx, "reg"), [0, 0xb0010000, 0, 0x10000], "RX aperture")
    # ZynqMP PL IRQ0[n] is GIC ID 121+n, DT SPI 89+n (SPI excludes first 32).
    require(cells(phy, "interrupts"), [0, 121 + 1 - 32, 4], "VPHY IRQ")
    require(cells(rx, "interrupts"), [0, 121 + 2 - 32, 4], "RX IRQ")
    require(cells(phy, "interrupt-parent"), cells(rx, "interrupt-parent"), "GIC parent")
    require(strings(phy, "compatible"), ["xlnx,vid-phy-controller-2.2"], "VPHY match")
    require(strings(rx, "compatible"), ["xlnx,v-hdmi-rx-ss-3.2",
                                        "xlnx,v-hdmi-rx-ss-3.1"], "HDMI 2.0 match")
    require(strings(phy, "clock-names"), ["vid_phy_axi4lite_aclk", "drpclk", "dru-clk"],
            "VPHY clock names")
    require(strings(rx, "clock-names"), ["s_axi_cpu_aclk", "s_axis_video_aclk"],
            "RX clock names")
    require(strings(rx, "phy-names"), ["hdmi-phy0", "hdmi-phy1", "hdmi-phy2"],
            "RX PHY names")
    # The RGB personality builds separate IP modules (scripts/
    # create_sc7f0_rgb_compositor_ip.tcl freezes the legacy 4PPC names), and the
    # whole point of comparing against the XCI is to catch the tree describing
    # the *other* geometry - which is exactly how 0x26111503 shipped with
    # xlnx,transceiver-width = <4> while vid_phy_controller_rgb carries
    # Transceiver_Width = 2 / C_INPUT_PIXELS_PER_CLOCK = 2 and the generated GT
    # channel wrapper carries GTHE4_CHANNEL_RX_DATA_WIDTH = 20.
    phy_mod = "vid_phy_controller_rgb" if rgb else "vid_phy_controller_0"
    rx_mod = "v_hdmi_rx_ss_rgb" if rgb else "v_hdmi_rx_ss_0"
    phy_params = xci(phy_mod)
    for prop, param in {
        "input-pixels-per-clock": "C_INPUT_PIXELS_PER_CLOCK",
        "transceiver-width": "Transceiver_Width",
        "nidru-refclk-sel": "C_NIDRU_REFCLK_SEL",
        "rx-no-of-channels": "C_Rx_No_Of_Channels",
        "tx-no-of-channels": "C_Tx_No_Of_Channels",
        "rx-refclk-sel": "C_RX_REFCLK_SEL", "tx-refclk-sel": "C_TX_REFCLK_SEL",
        "rx-pll-selection": "C_RX_PLL_SELECTION", "tx-pll-selection": "C_TX_PLL_SELECTION",
    }.items():
        require(cells(phy, "xlnx," + prop), [int(phy_params[param])], param)
    for prop, param in {"nidru": "C_NIDRU", "hdmi-fast-switch": "C_Hdmi_Fast_Switch",
                        "tx-buffer-bypass": "Tx_Buffer_Bypass",
                        "use-gt-ch4-hdmi": "C_Use_GT_CH4_HDMI"}.items():
        require(cells(phy, "xlnx," + prop), [int(phy_params[param] == "true")], param)
    require(phy_params["Transceiver"], "GTHE4", "Transceiver name")
    require(cells(phy, "xlnx,transceiver-type"), [5], "GTHE4 driver enum")
    for direction in ("rx", "tx"):
        require(phy_params[f"C_{direction.capitalize()}_Protocol"], "HDMI", "PHY protocol")
        require(cells(phy, f"xlnx,{direction}-protocol"), [1], "HDMI protocol enum")
    rx_params = xci(rx_mod)
    for prop, param in {"input-pixels-per-clock": "C_INPUT_PIXELS_PER_CLOCK",
                        "max-bits-per-component": "C_MAX_BITS_PER_COMPONENT",
                        "edid-ram-size": "C_EDID_RAM_SIZE"}.items():
        require(cells(rx, "xlnx," + prop), [int(rx_params[param])], param)
    for feature in ("C_INCLUDE_HDCP_1_4", "C_INCLUDE_HDCP_2_2"):
        require(rx_params[feature], "false", "HDCP disabled")
    require(cells("/qpcie_v4l2_bridge", "hdmirx"), cells(rx, "phandle"), "bridge phandle")
    require(strings("/qpcie_v4l2_bridge", "status"), ["disabled" if capture else "okay"], "bridge ownership")
    # phy-vphy numbers the VPHY's children in declaration order and
    # sc7f0-hdmi-tx.dtsi appends the three TX lanes after the three RX lanes, so
    # a display personality carries lane0..lane5 while a capture-only tree stops
    # at lane2.  The RX SS must still reference only the first three.
    lanes = 6 if rgb else 3
    require(run([fdtget, "-l", dtb, phy]).split(),
            [f"lane{i}" for i in range(lanes)], "PHY order")
    expected_phys = []
    for i in range(3):
        lane = phy + f"/lane{i}"
        require(cells(lane, "#phy-cells"), [4], "PHY specifier size")
        expected_phys += cells(lane, "phandle") + [0, 0, 0, 0]
    require(cells(rx, "phys"), expected_phys, "RX-only PHY specifiers")
    require(cells("/hdmi-dru-clock", "clock-frequency"), [156250000], "DRU rate")
    require(cells("/hdmi-rx-video-clock", "clock-frequency"), [0], "unmanaged video rate")
    children = run([fdtget, "-l", dtb, "/amba_pl@0"]).split()
    if "zzlab_env@b0000000" in children:
        raise ValueError("Legacy environment node still aliases VPHY")
    if capture:
        fb = "/amba_pl@0/framebuffer@b0050000"
        csc = "/amba_pl@0/vpss-csc@b0060000"
        tap = "/amba_pl@0/frame-tap@b0070000"
        cap = "/video-capture"
        for node, address, size in [(fb, 0xb0050000, 0x1000), (csc, 0xb0060000, 0x10000), (tap, 0xb0070000, 0x1000)]:
            require(cells(node, "reg"), [0, address, 0, size], node + " aperture")
            require(strings(node, "status"), ["okay"], node + " enabled")
        require(cells(fb, "interrupts"), [0, 93, 4], "framebuffer IRQ0[4]")
        require(cells(fb, "reset-gpios"), cells(tap, "phandle") + [0, 1], "writer reset_n")
        require(cells(csc, "reset-gpios"), cells(tap, "phandle") + [1, 1], "CSC reset_n")
        require(cells(cap, "dmas"), cells(fb, "phandle") + [0], "capture DMA")
        require(cells(cap, "yuan,frame-tap"), cells(tap, "phandle"), "SOF provider")
        require(cells("/capture-clock", "clock-frequency"), [300000000], "capture clock")
        require(strings(fb, "compatible"), ["xlnx,axi-frmbuf-wr-v2.2"], "framebuffer driver match")
        # A1 (round 26111602): under the RGB personality the capture buffer is Plane A,
        # so it is RGBX ("xbgr8888" -> XILINX_FRMBUF_FMT_RGBX8 -> DRM_FORMAT_XBGR8888 ->
        # memory R,G,B,X, which is what AB24 reads).  "xrgb8888" is the OTHER format
        # (FMT_BGRX8, memory B,G,R,X) and would come out of the HDMI output with red and
        # blue exchanged, so the two strings are not interchangeable here.
        require(strings(fb, "xlnx,vid-formats"),
                ["xbgr8888"] if rgb else ["nv12"], "capture formats")
        fp = xci("sc7f0_frmbuf_wr")
        cp = xci("sc7f0_vpss_csc")
        for prop, param in {"dma-addr-width": "AXIMM_ADDR_WIDTH", "pixels-per-clock": "SAMPLES_PER_CLOCK", "max-width": "MAX_COLS", "max-height": "MAX_ROWS"}.items():
            require(cells(fb, "xlnx," + prop), [int(fp[param])], "framebuffer " + param)
        require(int(fp["AXIMM_DATA_WIDTH"]), 256, "4PPC framebuffer native width")
        wp = xci("sc7f0_capture_width")
        for param, value in {"SI_DATA_WIDTH": 256, "MI_DATA_WIDTH": 128,
                             "ADDR_WIDTH": 64, "SI_ID_WIDTH": 1}.items():
            require(int(wp[param]), value, "capture width converter " + param)
        require(wp["PROTOCOL"], "AXI4", "capture width converter protocol")
        require(int(fp["HAS_Y_UV8_420"]), 1, "NV12 enabled")
        require(int(fp["HAS_RGB8"]), 0, "NV12-only IP")
        require(int(cp["C_TOPOLOGY"]), 3, "CSC-only topology")
        require(int(cp["C_COLORSPACE_SUPPORT"]), 0, "420 chroma support")
        require(int(cp["C_SAMPLES_PER_CLK"]), 4, "CSC PPC")
        require(cells(csc, "xlnx,max-width"), [int(cp["C_MAX_COLS"])], "CSC max width")
        require(cells(csc, "xlnx,max-height"), [int(cp["C_MAX_ROWS"])], "CSC max height")
        cross = xci("axi_crossbar_hdmi")
        # scripts/build_zu4ev.tcl builds the HDMI crossbar with two extra
        # masters when the RGB compositor is present, and sc7f0-rgb-compositor.dtsi
        # names M07/M08/M09 as the Reader-A / Reader-B / overlay windows, so the
        # destination count and those three windows are personality facts.
        # G8 (round 26111602) added the third RGB slice (M10 at 0xB0030000, the upper
        # half of the HDMI TX subsystem aperture, so the Timing Controller at
        # tx_ss + 0x10000 is reachable).  11 is read out of this round's own generated
        # axi_crossbar_hdmi.xci, not derived arithmetically.
        require(int(cross["NUM_MI"]), 11 if rgb else 7, "control destinations")
        # G8 (round 26111602): under the RGB personality the HDMI TX subsystem is
        # decoded as TWO 64 KiB slices, M02 = 0xB0020000 and M10 = 0xB0030000, and
        # that split IS the fix - 26111601 shipped one 128 KiB M02 and 0xB0030000
        # DECERRed, because the subsystem's own control port loses address bit 16 and
        # the VTC therefore has to arrive on a separate slice.  Nothing checked it:
        # the window list below only covers M04..M09, so a build that quietly kept
        # the old 128 KiB slice passed this gate unchanged.  Assert both slices here,
        # and keep the legacy personality's single slice asserted too so neither one
        # can drift by accident.
        require(int(cross["M02_A00_BASE_ADDR"], 16), 0xB0020000, "TX SS control base")
        require(int(cross["M02_A00_ADDR_WIDTH"]), 16 if rgb else 17,
                "TX SS lower slice width (64 KiB under RGB, 128 KiB legacy)")
        if rgb:
            require(int(cross["M10_A00_BASE_ADDR"], 16), 0xB0030000,
                    "TX SS upper slice base (the VTC half)")
            require(int(cross["M10_A00_ADDR_WIDTH"]), 16,
                    "TX SS upper slice width")
        windows = [(4, 0xb0050000, 12), (5, 0xb0060000, 16), (6, 0xb0070000, 12)]
        if rgb:
            windows += [(7, 0xb0080000, 16), (8, 0xb0090000, 12),
                        (9, 0xb00a0000, 12)]
        for index, base, width in windows:
            require(int(cross[f"M{index:02}_A00_BASE_ADDR"], 16), base, "control base")
            require(int(cross[f"M{index:02}_A00_ADDR_WIDTH"]), width, "control window")
        links = [(rx + "/ports/port@0/endpoint", tap + "/ports/port@0/endpoint"),
                 (tap + "/ports/port@1/endpoint", csc + "/ports/port@0/endpoint"),
                 (csc + "/ports/port@1/endpoint", cap + "/ports/port@0/endpoint")]
        for a, b in links:
            require(cells(a, "remote-endpoint"), cells(b, "phandle"), "graph forward")
            require(cells(b, "remote-endpoint"), cells(a, "phandle"), "graph reverse")
        print("SC7F0_CAPTURE_DT_PASS: board graph/control/IRQ/reset/format match XCI; runtime/XSA import not proven")
    if rgb:
        # Plane A (the compositor's Reader-A) and the HDMI TX subsystem, both
        # read out of their own generated IP rather than from a remembered
        # number: the reader geometry decides xlnx,dma-align and the format list
        # the DRM side is handed, and the TX subsystem's PPC decides the width of
        # VIDEO_IN the compositor must drive.
        tx = "/amba_pl@0/hdmi-tx@b0020000"
        plane_a = "/amba_pl@0/framebuffer@b0080000"
        tx_params = xci("v_hdmi_tx_ss_rgb")
        for prop, param in {"input-pixels-per-clock": "C_INPUT_PIXELS_PER_CLOCK",
                            "max-bits-per-component": "C_MAX_BITS_PER_COMPONENT"}.items():
            require(cells(tx, "xlnx," + prop), [int(tx_params[param])], "tx " + param)
        rd = xci("sc7f0_frmbuf_rd_rgb")
        require(int(rd["SAMPLES_PER_CLOCK"]), 2, "reader samples per clock")
        for prop, param in {"pixels-per-clock": "SAMPLES_PER_CLOCK",
                            "dma-addr-width": "AXIMM_ADDR_WIDTH",
                            "max-width": "MAX_COLS", "max-height": "MAX_ROWS"}.items():
            require(cells(plane_a, "xlnx," + prop), [int(rd[param])], "reader " + param)
        # The DTG publishes dma-align as the reader's native AXIMM byte width; a
        # 2 PPC reader is natively 128 bit, i.e. the PS HP width, so no width
        # converter sits in front of it.
        require(cells(plane_a, "xlnx,dma-align"),
                [int(rd["AXIMM_DATA_WIDTH"]) // 8], "reader dma-align")
        formats = strings(plane_a, "xlnx,vid-formats")
        want = [f for f, on in (("abgr8888", rd["HAS_RGBA8"]),
                               ("argb8888", rd["HAS_BGRA8"])) if on == "1"]
        require(formats, want, "reader formats")
        # A1: the writer side of the same claim.  The buffer Plane A reads must be built
        # by an IP that was actually configured HAS_RGBX8, and the DT must describe that
        # IP (4 PPC, native 256-bit AXIMM), not the NV12 one.
        wr = xci("sc7f0_frmbuf_wr_rgbx")
        require(int(wr["HAS_RGBX8"]), 1, "RGBX writer HAS_RGBX8")
        for off in ("HAS_BGRX8", "HAS_RGB8", "HAS_Y_UV8_420"):
            require(int(wr[off]), 0, "RGBX writer " + off + " must be off")
        require(int(wr["SAMPLES_PER_CLOCK"]),
                cells(fb, "xlnx,pixels-per-clock")[0], "RGBX writer pixels-per-clock")
        require(int(wr["AXIMM_DATA_WIDTH"]), 256, "RGBX writer native AXIMM width")
        # The CSC runs RGB -> RGB under this personality (xilinx-vpss-csc.c numbers
        # RGB = 0), because the writer downstream takes RGBX.
        # The ports live under the CSC node's `ports` container, exactly as the
        # graph-link check above addresses them; a bare csc/port@0 path does not
        # exist in the DTB and fdtget answers FDT_ERR_NOTFOUND.
        for port in ("port@0", "port@1"):
            require(cells(csc + "/ports/" + port, "xlnx,video-format"), [0],
                    "CSC " + port + " colour space is RGB under the RGB personality")
        print("SC7F0_RGB_GEOMETRY_DT_PASS: VPHY/RX/TX/plane-A/plane-buffer cells match "
              "the *_rgb and RGBX-writer XCI (transceiver-width, pixels-per-clock, "
              "dma-align, formats, colour spaces)")
    print("HDMI_DT_PASS: complete board DTS compiled; RX/PHY parameters match XCI")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--generated-dt", type=Path,
                        default=PLNX / "components/plnx_workspace/device-tree/device-tree")
    parser.add_argument("--xci-dir", type=Path, default=ROOT /
                        "build/qpcie_zu4ev_hdmi_proj/qpcie_zu4ev_card.srcs/sources_1/ip")
    dtc = shutil.which("dtc") or str(PLNX /
          "build/tmp/sysroots-components/x86_64/dtc-native/usr/bin/dtc")
    parser.add_argument("--dtc", type=Path, default=Path(dtc))
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--capture", action="store_true", help="Check the official framebuffer capture graph (26102801+ only)")
    parser.add_argument("--rgb", action="store_true",
                        help="Check the SC7F0-RGB-COMPOSITOR-2PPC personality against the "
                             "vid_phy_controller_rgb / v_hdmi_rx_ss_rgb / v_hdmi_tx_ss_rgb / "
                             "sc7f0_frmbuf_rd_rgb XCI instead of the legacy 4PPC modules")
    parser.add_argument("--disabled", action="store_true",
                        help="Check the safe, non-opt-in/default DTS instead of HDMI06")
    args = parser.parse_args()
    if args.output_dir:
        args.output_dir.mkdir(parents=True, exist_ok=True)
        check(args, args.output_dir)
    else:
        with tempfile.TemporaryDirectory(prefix="sc7f0-hdmi-dt-", dir="/tmp/opencode") as path:
            check(args, Path(path))


if __name__ == "__main__":
    main()
