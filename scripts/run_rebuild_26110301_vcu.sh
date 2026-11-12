#!/usr/bin/env bash
# Retired 2026-11-11. This script was the 2026-11-03/09/10/11 rebuild wrapper.
# It is kept only as a signpost, because two of its properties made the last
# releases unattributable and it can no longer run at all:
#
#   * ROOT was hard-coded to /home/zzlee/vibecoding/sc7f0-dual-video, a worktree
#     deleted on 2026-11-11, so every path it wrote (including the timing/CDC
#     reports for the 11-11 build) is gone;
#   * it exported SC7F0_TIMING_GATE="record", i.e. the shipped whole-design
#     timing/CDC gate was recorded instead of enforced, while
#     scripts/build_sc7f0_dual_video_hw.sh defaults to "strict";
#   * it never set C_VERSION / GIT_COMMIT_HASH_DEF / BUILD_TIMESTAMP_DEF, so the
#     identity taken when the project was first created was reused verbatim by
#     three later rebuilds (Hardware Version 0x26110301, GIT 0x2BCE1D81 = a
#     2026-10-27 commit, reported by all of them).
#
# Use the reproducible entry point instead; it pins one identity per attempt,
# stamps it at re-synthesis, and refuses anything but the strict gate:
#
#   scripts/build_sc7f0_vcu_release.sh --out build/vcu-release-<version>-r1
set -euo pipefail
cat >&2 <<'MSG'
scripts/run_rebuild_26110301_vcu.sh is retired (deleted ROOT path, SC7F0_TIMING_GATE=record,
no build-identity injection). Use:
  scripts/build_sc7f0_vcu_release.sh --out build/vcu-release-<version>-r1 [--stage fpga|ps|package]
See docs/sc7f0_full_package_rebuild_20261111.md for the reason and the gate policy.
MSG
exit 64
