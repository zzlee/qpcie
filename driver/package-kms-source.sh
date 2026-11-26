#!/usr/bin/env bash
# Build a matching host-only source archive OUTSIDE the frozen PL tree.
set -euo pipefail
[[ $# == 2 ]] || { echo "usage: bash $0 FROZEN_26112407 NEW_OUTPUT_DIR" >&2; exit 2; }
frozen=$(realpath "$1")
out=$(realpath -m "$2")
root=$(cd "$(dirname "$0")/.." && pwd)
[[ ! -e "$out" && "$out/" != "$frozen/"* ]]
[[ "$(basename "$frozen")" = rgb-vcu-flip-26112407 ]]
(
    cd "$frozen/src"
    sha256sum -c "$frozen/SOURCE.sha256" --quiet
    sha256sum -c --quiet <<'HASH'
c537350578e0a877326b4ca7a25e3e648cc90e8c3e05baa858d9116e338c5875  rtl/sc7f0_flip_scheduler.v
83b9b6ea346d7fa49f614dfb338a515c896122b4d2418a0e1f59118c65748075  include/qpcie_overlay.h
HASH
)
mkdir "$out"
stage=$(mktemp -d "$out/.src.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage"/{include,driver/tests}
cp "$frozen"/src/include/*.h "$stage/include/"
find "$root/driver" -maxdepth 1 -type f \
    \( -name 'Makefile' -o -name '*.c' -o -name '*.h' -o -name 'sc7f0-kms.md' \) \
    ! -name '*.mod.c' -exec cp -t "$stage/driver" {} +
cp -R "$root"/driver/tests/{kms_gate.c,kms_v1.c,kms_policy.c,mock} "$stage/driver/tests/"
(
    cd "$stage"
    find driver include -type f -print0 | LC_ALL=C sort -z |
        xargs -0 sha256sum > "$out/HOST-SOURCE.sha256"
    tar --sort=name --mtime=@0 --numeric-owner --owner=0 --group=0 \
        -czf "$out/host-driver-src.tar.gz" driver include
)
(
    cd "$out"
    sha256sum HOST-SOURCE.sha256 host-driver-src.tar.gz > SHA256SUMS
    sha256sum "$frozen/SOURCE.sha256" > FROZEN-SOURCE.sha256
)
