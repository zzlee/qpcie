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
    profile_flags = [] if args.disabled else ["-DSC7F0_HDMI_RX_ENABLE=1"]
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
    phy_params = xci("vid_phy_controller_0")
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
    rx_params = xci("v_hdmi_rx_ss_0")
    for prop, param in {"input-pixels-per-clock": "C_INPUT_PIXELS_PER_CLOCK",
                        "max-bits-per-component": "C_MAX_BITS_PER_COMPONENT",
                        "edid-ram-size": "C_EDID_RAM_SIZE"}.items():
        require(cells(rx, "xlnx," + prop), [int(rx_params[param])], param)
    for feature in ("C_INCLUDE_HDCP_1_4", "C_INCLUDE_HDCP_2_2"):
        require(rx_params[feature], "false", "HDCP disabled")
    require(cells("/qpcie_v4l2_bridge", "hdmirx"), cells(rx, "phandle"), "bridge phandle")
    require(strings("/qpcie_v4l2_bridge", "status"), ["okay"], "bridge enabled")
    require(run([fdtget, "-l", dtb, phy]).split(), ["lane0", "lane1", "lane2"], "PHY order")
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
