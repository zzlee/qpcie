#!/usr/bin/env bash
# Run on the test host with the verified archives, no KMS/open changes here.
set -euo pipefail
D=$(realpath "${1:?archive directory}"); out=$(realpath -m "${2:?fresh host build directory}")
[[ $D == "$HOME/sc7f0/"* && $out == "$HOME/sc7f0/"* && ! -e $out ]];mkdir -p "$out/tmp";export TMPDIR="$out/tmp";cd "$D";grep -E '  host-(driver|tools)-src.tar.gz$' RELEASE.sha256 | sha256sum -c -;tar -C "$out" -xzf host-driver-src.tar.gz;tar -C "$out" -xzf host-tools-src.tar.gz;cd "$out";make -C driver -j4 QPCIE_KMS=1;nm driver/qpcie.ko | grep -w qpcie_kms_protect >kms-symbol;[[ $(modinfo -F vermagic driver/qpcie.ko) == "$(uname -r) "* ]];for c in sc7f0_kms sc7f0_kms_ball;do cc -O3 -Wall test_app/$c.c -o "$c" $(pkg-config --cflags --libs libdrm);done;cc -O2 -Wall test_app/sc7f0_record_trace.c -o sc7f0_record_trace;sha256sum sc7f0_{kms,kms_ball,record_trace} driver/qpcie.ko >host-built.sha256;uname -r >kernel;readelf -n driver/qpcie.ko >module-notes
