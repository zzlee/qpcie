#!/usr/bin/env bash
# A/B regression: every testbench that touches rq_tx_encoder / custom_pcie_dma_top,
# built once with the pre-fix RTL pair (from HEAD) and once with the working-tree
# pair. Only a difference between the two columns is attributable to a change;
# both-FAIL rows are testbenches that need XPM/Vivado BD IP iverilog lacks.
set -uo pipefail
# ROOT used to be a hard-coded worktree path (/home/zzlee/vibecoding/
# sc7f0-dual-video) that no longer exists; derive it from the script.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
OUT="$ROOT/build/ab-iverilog"; rm -rf "$OUT"; mkdir -p "$OUT/pre"
# The pre-fix pair comes straight from HEAD, so this stays runnable later.
git -C "$ROOT" show HEAD:rtl/custom_pcie_dma_top.v > "$OUT/pre/custom_pcie_dma_top.v"
git -C "$ROOT" show HEAD:rtl/rq_tx_encoder.v      > "$OUT/pre/rq_tx_encoder.v"
RTL=$(ls rtl/*.v | grep -v 'card_top\|tlp_test' | sed "s|^rtl/|$PWD/rtl/|")

TBS="tb_rq_tx_encoder tb_rq_tx_encoder_256 tb_sg_c2h_burst_boundary tb_dma_4k_boundary
     tb_nv12_raw_loopback tb_sg_dma_engine tb_video_req_cdc tb_sgl_loopback_system
     sc7f0_packet_arb_tb sc7f0_c2h_pop_interlock_tb sc7f0_dualpath_tb sc7f0_live_video_tb
     sc7f0_c2h_caps_tb sc7f0_request_cdc_tb zu4ev_client_tag_rc_tb tb_thin_desc_fetch_engine"

printf '%-34s %-10s %-10s %s\n' TESTBENCH PRE-FIX PATCHED VERDICT
for tb in $TBS; do
  f="tb/$tb.v"; [[ -f $f ]] || f="tb/$tb.sv"
  for v in pre post; do
    if [[ $v == pre ]]; then
      src=($(echo "$RTL" | tr ' ' '\n' | grep -v -E "rq_tx_encoder.v|custom_pcie_dma_top.v"))
      src+=("$OUT/pre/custom_pcie_dma_top.v" "$OUT/pre/rq_tx_encoder.v")
    else
      src=($RTL)
    fi
    log="$OUT/$tb-$v.log"
    if iverilog -g2012 -i -s "$tb" -o "$OUT/$tb-$v.vvp" "${src[@]}" "$f" > "$log" 2>&1 &&
       timeout 300 vvp "$OUT/$tb-$v.vvp" > "$log.run" 2>&1 &&
       grep -Eq "PASSED|PASS!|SUCCESS|VERIFIED 100% PASS|_PASS|ALL .* TESTS PASSED" "$log.run"; then
      res=PASS
    else
      res=FAIL
    fi
    eval "res_$v=$res"
  done
  verdict="same"
  [[ $res_pre != "$res_post" ]] && verdict="** DIFFERS ** (pre=$res_pre post=$res_post)"
  printf '%-34s %-10s %-10s %s\n' "$tb" "$res_pre" "$res_post" "$verdict"
done
