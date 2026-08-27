# QPCIe PCIe 頻寬升級與瓶頸分析計畫

## 1. 目標

目前 QPCIe A50T：

- PCIe：Gen2 x4
- PCIe raw line-rate：2.0 GB/s
- 目前實測：801.30 MiB/s
- 4K60 NV12 需求：711.91 MiB/s
- 目前 4K60 throughput margin：12.6%
- 目前相對 PCIe protocol-level payload ceiling 的利用率：約 47%

### 升級目標

分三階段：

| 階段 | 目標吞吐量 | 目的 |
|---|---:|---|
| P0 | ≥ 1,000 MiB/s | 找出並消除明顯 bubble / serialization |
| P1 | ≥ 1,400 MiB/s | 建立真正 multi-TLP pipelining / outstanding request |
| P2 | 1,600–1,700 MiB/s | 接近 Gen2 x4 protocol-level payload ceiling |

---

## 2. 核心判斷

目前瓶頸已經不是 NV12 frontend。

目前資料路徑：

```text
TPG @150 MHz
      │
      ▼
NV12 capture engine @150 MHz
      │
      ▼
video_req_cdc
      │
      ▼
RQ TX @125 MHz / 128-bit
      │
      ▼
PCIe Gen2 x4
      │
      ▼
Host DDR
```

150 MHz migration 已經把 video frontend 的 125 MHz ceiling 移除。

最新實機：

```text
1080p60 uncapped : 801.18 MiB/s
4K60 uncapped    : 801.30 MiB/s
4K60 requirement : 711.91 MiB/s
margin           : 12.6%
```

因此下一階段應集中分析：

```text
video_req_cdc
      ↓
request buffering
      ↓
rq_tx_encoder
      ↓
pcie_7x_axi_bridge
      ↓
PCIe RQ interface
```

---

# 3. 第一階段：建立硬體 Performance Monitor

## 3.1 原則

第一階段先不使用 ILA。

使用：

```text
RTL performance counters
        ↓
BAR registers
        ↓
Linux driver
        ↓
debugfs/sysfs
        ↓
benchmark report
```

原因：

- 可以長時間跑 4K60 / 600 frames
- BRAM 資源消耗遠小於 ILA
- 可以直接統計完整 benchmark window
- 可以把 bandwidth loss 做 quantitative attribution

---

## 3.2 建議新增 `qpcie_perfmon`

建議位置：

```text
rtl/qpcie_perfmon.v
```

主要掛在：

```text
rq_tx_encoder
```

同時取得 request / FIFO / PCIe RQ 狀態。

---

## 3.3 第一版 counters

### 基本計數

```text
cycle_count
tlp_count
payload_bytes
```

### TX utilization

```text
tx_active_cycles
tx_idle_cycles
```

### PCIe backpressure

```text
tready_stall_cycles
```

定義：

```verilog
tvalid && !tready
```

### TLP bubble

```text
inter_tlp_gap_cycles
```

統計兩個 TLP 完成之間沒有有效 payload transmission 的 cycle。

### Payload size

```text
tlp_128b_count
tlp_256b_count
```

### Queue

```text
request_queue_depth
request_queue_max_depth
```

### Boundary

```text
split_4k_count
```

---

# 4. 第二版：Idle Reason Counter

單純知道 idle 還不夠。

需要把 idle cycle 分類：

```text
IDLE_NO_REQUEST
IDLE_CDC_EMPTY
IDLE_PACKETIZER
IDLE_PCIE_NOT_READY
IDLE_4KB_BOUNDARY
IDLE_OTHER
```

最終輸出：

```text
TX idle breakdown
------------------
CDC empty          3.2%
No request         1.1%
Packetizer         0.8%
PCIe not ready     0.3%
4KB boundary       0.1%
Other              0.2%
```

這可以直接判斷瓶頸屬於：

- upstream starvation
- CDC
- packetizer
- PCIe backpressure
- TLP boundary handling

---

# 5. Linux Driver Interface

建議提供：

```text
/sys/class/qpcie/qpcie0/
    perf_enable
    perf_reset
    perf_cycles
    perf_tlp_count
    perf_payload_bytes
    perf_tx_active
    perf_tx_idle
    perf_tready_stall
    perf_inter_tlp_gap
    perf_128b_tlp
    perf_256b_tlp
    perf_split_4k
    perf_max_queue_depth
```

如果 driver 架構較適合 debugfs，也可以使用：

```text
/sys/kernel/debug/qpcie/
```

推薦 debugfs 作為第一版 debug interface，sysfs 保留簡單狀態與控制項。

---

# 6. Benchmark 方法

每次 benchmark 前：

```bash
echo 1 > perf_reset
echo 1 > perf_enable
```

執行：

```bash
./test_app/v4l2_test_app \
    --width 3840 \
    --height 2160 \
    --benchmark \
    --frames 600
```

完成後：

```bash
cat /sys/kernel/debug/qpcie/perf_*
```

同時收集：

```text
FPS
MiB/s
TLP count
payload bytes
active cycles
idle cycles
TREADY stalls
inter-TLP gaps
queue depth
4KB splits
```

---

# 7. Bandwidth Attribution

125 MHz / 128-bit RQ interface：

```text
128 bit × 125 MHz
= 16 Gbit/s
= 2.0 GB/s
```

實際 throughput 可拆成：

```text
Theoretical RQ capacity
        │
        ├── TX active
        │
        ├── no request
        │
        ├── CDC starvation
        │
        ├── packetizer gap
        │
        ├── PCIe TREADY stall
        │
        └── protocol overhead
```

## 判斷規則

### Case A：TREADY stall 很高

例如：

```text
TX active        95%
TREADY stall     30%
TX idle           5%
```

判定：

> PCIe downstream / RQ interface backpressure 是主要瓶頸。

下一步使用 ILA。

---

### Case B：TREADY stall 很低，但 TX idle 很高

例如：

```text
TX active        65%
TREADY stall      1%
TX idle          35%
```

判定：

> PCIe link 沒有吃滿，是 FPGA upstream 沒有持續產生 request。

優先檢查：

```text
nv12_capture_engine
video_req_cdc
request FIFO
packetizer
```

不需要立即使用 ILA。

---

### Case C：inter-TLP gap 很高

例如：

```text
TLP payload active = 80%
inter-TLP gap      = 20%
```

判定：

> TLP serialization / packetizer bubble。

優先改：

```text
rq_tx_encoder
```

目標是：

```text
TLP #0 ──────────┐
TLP #1 ──────────┤
TLP #2 ──────────┤── continuous RQ stream
TLP #3 ──────────┘
```

---

# 8. P0：突破 1,000 MiB/s

## 目標

```text
801 MiB/s
    ↓
≥ 1,000 MiB/s
```

優先檢查：

1. TLP 是否一包一包 serial
2. TLP 間是否有固定 bubble
3. `tvalid/tready` 是否產生不必要 stall
4. request FIFO 是否經常 empty
5. `video_req_cdc` 是否限制 outstanding request
6. 256B MWr 是否真的持續使用
7. 4KB boundary 是否造成異常 fragmentation

### P0 完成條件

```text
4K60 ≥ 1,000 MiB/s
TLP size ≥ 256B
inter-TLP gap 明顯下降
data errors = 0
```

---

# 9. P1：Multi-TLP Pipelining

## 目標

```text
≥ 1,400 MiB/s
```

目前架構若存在：

```text
generate TLP
    ↓
wait transaction completion
    ↓
next TLP
```

應改成：

```text
request FIFO
    │
    ├── TLP #0
    ├── TLP #1
    ├── TLP #2
    ├── TLP #3
    └── ...
            ↓
       PCIe RQ
```

## 建議

增加：

```text
outstanding request queue
```

例如：

```text
8 ~ 32 outstanding TLP
```

並讓 requester 可以在 PCIe RQ stream 上連續送出 payload。

---

# 10. P2：接近 PCIe Gen2 x4 ceiling

## 目標

```text
1,600–1,700 MiB/s
```

此階段需要檢查：

- RQ 128-bit / 125 MHz utilization
- TLP header overhead
- 256B payload efficiency
- 4KB boundary split
- PCIe IP backpressure
- request queue depth
- DMA descriptor / completion traffic
- CDC overhead

如果仍然卡在約 1.0–1.2 GiB/s，應重新評估：

```text
128-bit × 125 MHz
```

是否需要改成更高頻率或更寬的 internal datapath。

---

# 11. ILA 使用策略

ILA 不應該作為第一個 debugging tool。

## 第一階段

```text
RTL counters
+
Linux driver
```

取得：

```text
why bandwidth is lost
```

## 第二階段

只有在 counter 指出：

```text
TREADY stall
```

或其他需要 cycle-level correlation 的問題時才加入 ILA。

### 建議 ILA signals

```text
s_axis_rq_tvalid
s_axis_rq_tready
s_axis_rq_tlast
s_axis_rq_tdata
s_axis_rq_tuser

req_valid
req_ready
req_last

fifo_empty
fifo_full
fifo_level

tx_state
tlp_len
tlp_addr
```

### 建議 trigger

```text
TVALID && !TREADY 持續 N cycles
```

或：

```text
inter-TLP gap > threshold
```

或：

```text
request queue unexpectedly empty
```

---

# 12. 建議的實作順序

```text
Step 1
  qpcie_perfmon.v
       ↓
Step 2
  BAR performance registers
       ↓
Step 3
  Linux debugfs interface
       ↓
Step 4
  1080p / 4K 600-frame benchmark
       ↓
Step 5
  bandwidth attribution
       ↓
Step 6
  修正 rq_tx_encoder / CDC / FIFO
       ↓
Step 7
  再跑 benchmark
       ↓
Step 8
  若 TREADY/backpressure 仍可疑
       ↓
  ILA
       ↓
Step 9
  multi-TLP outstanding pipeline
       ↓
Step 10
  目標 1.4–1.7 GiB/s
```

---

# 13. 最終 KPI

| KPI | Current | P0 | P1 | P2 |
|---|---:|---:|---:|---:|
| Throughput | 801 MiB/s | ≥1000 | ≥1400 | 1600–1700 |
| PCIe utilization | ~47% | ~59% | ~82% | ~94–100% |
| 4K60 margin | 12.6% | >40% | >95% | >125% |
| TLP size | 256B | 256B | 256B | 256B |
| TLP pipeline | TBD | reduced bubble | multi-TLP | saturated |
| TREADY stall | TBD | quantified | minimized | minimized |
| Data errors | 0 | 0 | 0 | 0 |

---

# 14. 結論

目前 QPCIe 已經可以穩定支援 4K60 NV12，但 PCIe Gen2 x4 的可用頻寬仍只利用約一半。

最重要的下一步不是直接使用 ILA，而是建立：

```text
qpcie_perfmon
    +
BAR counters
    +
Linux debugfs
```

先回答：

> 801 MiB/s 到底是消耗在 FPGA idle、request starvation、CDC、TLP gap，還是 PCIe `tready` backpressure？

取得這個答案後，再針對性使用 ILA。

最終優化路線：

```text
801 MiB/s
   ↓
P0  ≥ 1.0 GiB/s
   ↓
P1  ≥ 1.4 GiB/s
   ↓
P2  1.6–1.7 GiB/s
```

核心原則：

> **先量測，再定位，再修改 RTL；不要先用 ILA 猜問題。**
