# 仿真、Timing 與實機驗證指南

## 1. Automated regression

```bash
cd /home/zzlee/qpcie
./sim/run_sim.sh
```

目前 suite 為 18 個 self-checking tests：

| Testbench | 驗證重點 |
|---|---|
| `tb_pcie_tag_manager.v` | Tag allocation/recycle |
| `tb_cq_rx_decoder.v` | BAR0/BAR1 MRd/MWr、4-DW MWr、relative BAR address |
| `tb_cc_tx_encoder.v` | CplD header/data |
| `tb_axil_reg_space.v` | BAR0 registers、retained pointers、VIDEO_CTRL `0x80` |
| `tb_rq_tx_encoder.v` | MRd/MWr/Msg、multi-beat payload、random backpressure |
| `tb_rc_rx_decoder.v` | pg054 CplD fields、Tag routing |
| `tb_desc_fetch_engine.v` | 64-byte descriptor fetch/parse |
| `tb_h2c_dma_engine.v` | H2C data path |
| `tb_c2h_dma_engine.v` | C2H data path |
| `tb_interrupt_ctrl.v` | MSI request/mask/ack |
| `tb_sg_dma_engine.v` | SG head/tail/completion |
| `tb_sg_c2h_burst_boundary.v` | 128-byte MWr 與 4 KiB boundary split |
| `tb_nv12_capture_engine.v` | byte-accurate YUV444→NV12M、rounded chroma |
| `tb_nv12_capture_performance.v` | 1080p pipeline throughput |
| `tb_nv12_capture_4k_performance.v` | 4K random-ready performance gate |
| `tb_pcie_dma_system.v` | integrated DMA top |
| `tb_pcie_7x_axi_bridge.v` | pg054 bridge byte ordering/TLP conversion |
| `tb_sg_dma_pipeline.v` | end-to-end descriptor→RQ→host golden memory |

最新結果：

```text
Simulation Summary: 18 Passed, 0 Failed
```

## 2. 關鍵 performance assertions

### 1080p

```text
518,425 clocks/frame
4.147 ms @125 MHz
24,300 × 128-byte MWr/frame
約 241.1 FPS / 715.2 MiB/s
```

### 4K

```text
2,073,632 clocks/frame
16.589 ms @125 MHz
97,200 × 128-byte MWr/frame
Random RQ ready ≈75%
Input stalls: 0
60 FPS budget: 2,083,333 clocks
```

## 3. Vivado signoff

乾淨 build：

```bash
rm -rf build/qpcie_a50t_proj
/opt/Xilinx/Vivado/2023.2/bin/vivado \
  -mode batch -source scripts/build_a50t.tcl
```

必查：

```text
.../impl_1/a50t_pcie_card_top_timing_summary_routed.rpt
.../impl_1/a50t_pcie_card_top_utilization_placed.rpt
.../impl_1/a50t_pcie_card_top_drc_routed.rpt
```

commit `2450dcb7` signoff：

```text
WNS +0.069 ns, TNS 0
WHS +0.041 ns, THS 0
0 critical warnings, 0 errors
LUT 31.33%, FF 16.01%, BRAM 36.67%, DSP 31.67%
```

Reset/CDC：

- PCIe reset → 150 MHz video reset 使用 asynchronous capture、synchronous output stages。
- BAR0 video reset request → 150 MHz 使用兩級 `ASYNC_REG` synchronizer。
- XPM AXIS FIFO 自帶 independent-clock CDC constraints。
- 第一級 synchronizer data path 有明確 false-path exception；其餘同步 stages 必須 timing clean。

## 4. Driver/app build gate

```bash
make -C driver clean && make -C driver
make -C test_app clean && make -C test_app v4l2_test_app
```

支援 Linux `<6.8` 的 `min_buffers_needed` 與 `>=6.8` 的 `min_queued_buffers`。

## 5. 實機分層驗證

1. PCIe/BAR：version `0x02010001`、caps `0x0004040F`。
2. SG：4 × 4096-byte C2H/H2C full payload。
3. 1080p paced：60 frames、static hashes、sequence、彩條。
4. 1080p uncapped：檢查 4K60 等效 payload rate。
5. Mode switch：1080p → 4K，確認 TPG/FIFO reset 無 stale frame。
6. 4K correctness：60 frames、12,441,600-byte output。
7. 4K sustained：600 frames。

## 6. 4K60 最終 acceptance

```bash
./test_app/v4l2_test_app --dev /dev/video0 \
  --width 3840 --height 2160 --benchmark --frames 600 --pattern 9
```

全部必須成立：

- 600/600 frames。
- sequence 無跳號。
- data errors 0。
- throughput `>=711.91 MiB/s`。
- STREAMOFF kernel log：`drained=1`、head=tail、`video_errors=0`。
- 無 SMMU/context fault/decode/protocol error。

> 目前 4K 仿真與 1080p 等效吞吐量已達標，但最新 4K mode 尚待此實機 gate。
