#!/bin/bash
# Run the narrow cfg-reader fixture.  Compiles only rtl/sc7f0_pcie_ext_tag_enable.v
# and its testbench, simulates with xsim, and exits non-zero unless the run
# prints FIXTURE_PASS.  Nothing here speaks about device utilisation or timing.
set -u
Q=${REPO:-/home/zzlee/qpcie}
OUT=${OUTDIR:-/mnt/data-root/home/zzlee/sc7f0-vivado-builds/rgb-compositor-int-26111317-20261113T082428Z}
W=$OUT/tmp/extfix-$(date -u +%H%M%S)
mkdir -p "$W"
export TMPDIR="$OUT/tmp" TEMP="$OUT/tmp" TMP="$OUT/tmp"
cd "$W" || exit 3

/opt/Xilinx/Vivado/2023.2/bin/xvlog -sv \
    "$Q/scripts/tb_sc7f0_pcie_ext_tag_enable.sv" \
    "$Q/rtl/sc7f0_pcie_ext_tag_enable.v" > xvlog.log 2>&1
rc=$?
echo "XVLOG_RC=$rc"
grep -E "^ERROR" xvlog.log | head -5
[ $rc -ne 0 ] && { echo "FIXTURE_BUILD_FAIL xvlog"; exit 1; }

# note: passing the unit name twice (-top X ... X) makes xelab fail static
# elaboration with XSIM 43-3322 and no useful message; name it once.
/opt/Xilinx/Vivado/2023.2/bin/xelab -debug typical \
    tb_sc7f0_pcie_ext_tag_enable -s ext_tag_sim > xelab.log 2>&1
rc=$?
echo "XELAB_RC=$rc"
grep -E "^ERROR|^\[error\]" xelab.log | head -5
[ $rc -ne 0 ] && { echo "FIXTURE_BUILD_FAIL xelab"; exit 1; }

/opt/Xilinx/Vivado/2023.2/bin/xsim ext_tag_sim -R > xsim.log 2>&1
rc=$?
echo "XSIM_RC=$rc"
grep -E "^ok:|^FIXTURE_|^ERROR|Error:" xsim.log | head -24
if [ $rc -eq 0 ] && grep -q "FIXTURE_PASS sc7f0_pcie_ext_tag_enable" xsim.log; then
    echo "FIXTURE_OK (log: $W/xsim.log)"
    exit 0
fi
echo "FIXTURE_NOT_OK (log: $W/xsim.log)"
exit 1
