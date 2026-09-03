# Host SGL Fetch 驗證與實施計畫

## 狀態與目的

本文件是交接給後續 coding agent 的實施計畫。目標是驗證 QPCIe 的 **host SGL fetch linked-page** 路徑，不是提高目前已達標的 direct-DMA loopback 吞吐量。

截至 2026-09-03，Jetson Orin NX 的 4K loopback 實測為：

```text
FPGA build ID       : 0x14CEA1AD
H2C window          : 16 outstanding MRd (tags 2..17)
4K 600 frames       : 934.60 MiB/s, 78.77 FPS
Data integrity      : 100% bit-exact, errors 0
```

當次 driver log 對所有 Ch1 H2C/C2H NV12 planes 都顯示：

```text
nents=1
direct DMA
host SGL fetch disabled
```

所以以上性能是 **direct contiguous-I/O-VA DMA** 的結果，並沒有使用 host SGL fetch。

## 已確認的 DMA 與 IOMMU 現況

Jetson 的 PCI endpoint `0004:01:00.0` 與 root port 位於 IOMMU group 5。Kernel config 包含：

```text
CONFIG_IOMMU_DEFAULT_DMA_STRICT=y
CONFIG_IOMMU_DEFAULT_PASSTHROUGH is not set
CONFIG_TEGRA_IOMMU_SMMU=y
CONFIG_ARM_SMMU=y
CONFIG_ARM_SMMU_DISABLE_BYPASS_BY_DEFAULT=y
```

因此 driver 中的 `dma_addr_t`、`sg_dma_address()` 與 log 中位址是 device-visible **IOVA/DMA address**，不是可直接宣稱的 CPU physical address。測試及實作必須保持 SMMU enabled；不要為了強制產生scatterlist而停用 IOMMU 或切換到 bypass。

## 三個容易混淆的結構

| 結構 | 現況 | 定義 |
|---|---|---|
| Descriptor ring | 已使用 | 16-entry coherent circular ring，由 head/tail doorbell 推進；不是 linked list。 |
| Linux `sg_table` | 已使用 | `vb2_dma_sg_plane_desc()` 提供DMA-mapped plane segments；目前每個plane被DMA API合併為一個`nents=1` IOVA segment。 |
| Host SGL linked pages | 未使用 | FPGA以Tag 1發MRd讀取host SGL entries；每個4KiB slot的entry 255可用`SGL_FLAG_CHAIN_PTR`連到下一slot。 |

不要將 descriptor ring 稱為 descriptor linked list。此計畫驗證的是第三項，host SGL linked-page table。

## 現有實作位置

| 項目 | 檔案 | 重要內容 |
|---|---|---|
| V4L2 descriptor/SGL建立 | `driver/qpcie_v4l2.c` | `qpcie_publish_buffer()`僅於任一plane `nents > 1`時設定`DESC_CTRL_SG_FETCH_MODE`。 |
| SGL entry writer | `driver/qpcie_v4l2.c` | `qpcie_build_variable_sgl()`建立16-byte `{addr,len,flags}` entries。 |
| SGL ABI | `driver/qpcie_driver.h` | `SGL_FLAG_CHAIN_PTR=BIT(0)`、`SGL_FLAG_LAST_SEG=BIT(1)`。 |
| Host SGL fetch RTL | `rtl/sg_host_fetch_engine.v` | 固定Tag 1、每次64B/16DW MRd，解碼entries並跟隨chain pointer。 |
| Segment consumer | `rtl/sg_segment_walker.v` | 依SGL segment與4KiB boundary限制H2C/C2H requests。 |
| H2C request engine | `rtl/sg_dma_engine.v` | H2C SGL mode依descriptor control bits 4/5啟用。 |

## 建議實作：`force_sgl_fetch=1`

### Scope

新增一個僅用於驗證的 driver module parameter：

```text
force_sgl_fetch=0     default，保持目前行為
force_sgl_fetch=1     強制所有V4L2 H2C/C2H NV12 planes走host SGL fetch
```

建議把parameter定義在`driver/qpcie_v4l2.c`：

```c
static bool force_sgl_fetch;
module_param(force_sgl_fetch, bool, 0644);
MODULE_PARM_DESC(force_sgl_fetch,
                 "Force 4KiB host SGL fetch tables for V4L2 DMA validation");
```

不可改變預設`0`的現有direct-DMA性能路徑。

### Driver changes

1. 在`qpcie_publish_buffer()`將模式判斷改為：

```c
host_sgl = force_sgl_fetch || sgt0->nents > 1 || sgt1->nents > 1;
```

2. `force_sgl_fetch=1`時，`qpcie_build_variable_sgl()`必須把每個DMA segment切成**最多4KiB** entries，即使`sgt->nents == 1`。

```text
entry address  = current DMA IOVA
entry length   = min(remaining, bytes until next 4KiB boundary)
current += entry length
```

3. 切分後每個plane的最後一個data entry必須帶`SGL_FLAG_LAST_SEG`。

4. 每slot只可放255個data entries，index 255保留給chain pointer。slot滿時：

```text
slot[255].phys_addr = next coherent SGL slot IOVA
slot[255].len_bytes = 0
slot[255].flags     = SGL_FLAG_CHAIN_PTR
```

5. `qpcie_build_variable_sgl()`應回傳成功/失敗、data-entry count與chain count；不可像目前一樣slot不足時靜默截斷。publish失敗必須拒絕buffer並記錄error。

6. 強制模式下H2C descriptor control必須包含`DESC_CTRL_SG_FETCH_MODE (0x20)`：

```text
H2C base control: 0x09 | channel<<6 | 0x20
C2H base control: 0x0B | channel<<6 | 0x20
```

7. 每個buffer首次publish時記錄：direction、`force_sgl_fetch`、mapped `nents/orig_nents`、SGL data entries、chain count、Y/UV table IOVA及最終control word。

### 4K sizing requirements

4K NV12M payload：

```text
Y  : 8,294,400 bytes = 2,025 4KiB entries
UV : 4,147,200 bytes = 1,013 4KiB entries (last entry partial)
```

現有slot capacity：

```text
Y  : 8 slots × 255 data entries = 2,040 entries
UV : 4 slots × 255 data entries = 1,020 entries
```

兩者剛好足夠，但幾乎沒有裕量。實作需顯式檢查上限；不可假定未來更大解析度或stride仍適用。

## Required RTL and Simulation Review

後續agent必須先檢查並補強下列項目：

1. `rtl/sg_host_fetch_engine.v`在chain entry後是否正確切換到next slot，且不把chain entry推到segment walker。
2. 確認Y最後entry後才切到UV table，並保留partial final UV entry的長度。
3. 確認Tag 1 SGL fetch與Tags 2..17 H2C payload MRds可正確共存；Tag 1不得進入H2C reorder buffer。
4. 確認SGL fetch在segment walker FIFO almost-full時停住而不遺失entry。
5. 新增/擴充RTL test：至少兩個4KiB SGL slots、entry 255 chain pointer、跨slot的最後segment，以及Y/UV切換。
6. 完整執行：

```bash
./sim/run_sim.sh
./scripts/build_a50t.sh
```

不可放寬timing constraints；最終WNS必須非負、TNS為0。

## Hardware Validation Procedure

在測試機完成driver build並重載：

```bash
cd ~/qpcie
git pull --ff-only
make -C driver clean
make -C driver
sudo rmmod custom_pcie_av
sudo insmod driver/custom_pcie_av.ko force_sgl_fetch=1
sudo dmesg -C
./test_app/loopback_test_app -o /dev/video1 -d /dev/video2 -w 1920 -h 1080 -b
./test_app/loopback_test_app -o /dev/video1 -d /dev/video2 -w 3840 -h 2160 -b
sudo dmesg | grep -E 'SGL ch|DMA ch|SG fetch|qpcie-dma'
```

### Acceptance criteria

1. Log明確顯示`force_sgl_fetch=1`、`host SGL fetch enabled`及control含`0x20`。
2. 4K log顯示至少Y 2,025 entries、UV 1,013 entries，以及非零chain count。
3. 1080p與4K均完成目標frame count、`100% BIT-EXACT MATCH PASS`。
4. `NV12M STREAMOFF`必須是`drained=1`、`head == tail`、`video_errors=0`。
5. `sudo dmesg | grep -Ei 'smmu|iommu|context fault|decode error|protocol error'`沒有新的fault/error。
6. 記錄forced-SGL吞吐，但不要以它取代direct-DMA baseline。因Tag 1 SGL fetch目前串行發送，forced模式預期吞吐可能較低。

### Baseline restoration

完成驗證後，必須回到預設direct模式再測一次：

```bash
sudo rmmod custom_pcie_av
sudo insmod driver/custom_pcie_av.ko force_sgl_fetch=0
```

預設direct模式必須維持目前`nents=1`時不建立SGL、不設control bit 5的行為。

## 已發現的死鎖與修復（2026-09-03 實測回報）

第一次 1080p forced-SGL 實測（`force_sgl_fetch=1`）結果：`TX: 7 / RX: 0`，capture DQBUF timeout，FPGA head 完全沒有前進，兩方向零 completion。

**Root cause（硬體整合死鎖，非 RTL 單一模組 bug）**：

1. `desc_fetch_engine` 的 `WAIT_SGL_FETCH` 會阻塞整個 descriptor pipeline，直到共享的 `sg_host_fetch_engine` 完成該 descriptor 的 SGL table fetch。
2. C2H descriptor 的 SGL entries 經 64-deep CDC FIFO（prog_full=48）餵給 capture engine；fetch 在 FIFO 滿時停住。
3. Capture engine 只有在寫出 C2H 資料（consuming SGL entries）時才會 drain FIFO，而 C2H 資料需要 loopback input —— 由 H2C DMA 產生。
4. 舊 driver 每個 pair 先 publish C2H、後 publish H2C：C2H0 的 fetch 停在 FIFO 滿 → `desc_fetch` 卡在 `WAIT_SGL_FETCH` → H2C0 永遠不會被 dispatch → 沒有 input → engine 無法 drain → **全系統死鎖**。

**第一次修復嘗試（driver-only）**：`qpcie_buf_queue()` 改為先 publish H2C（output）、後 publish C2H（capture），預期 H2C frame 先串流、capture engine 隨寫出消耗 SGL entries。IRQ completion matching 是按方向分開的 FIFO，reorder 安全。**但 2026-09-03 第二次實測（H2C-first 順序已生效、dmesg 確認 `SGL ch1 H2C bufX` 先於 `SGL ch1 C2H bufX`）仍然 `TX: 7 / RX: 0` 全死鎖** —— 死鎖與 ring 順序無關。

**真正 root cause（RTL 整合缺陷）**：`desc_fetch_engine` 在 `WAIT_SGL_FETCH` 等整個 table 被 push 進 consumer FIFO 才前進，但 consumer FIFO 只能靠自己的 engine 消耗來 drain：

1. H2C 方向：H2C walker FIFO（64-deep, almost_full≈44）只有 H2C engine 發出 MRd 才 drain；H2C engine 又受 loopback FIFO（64×16B = 1KB！）與 capture 端 sink 限制 —— 16 個 outstanding MRd（ROB=16×512B）推完 ~10-20KB 就停。
2. C2H 方向：capture walker/CDC FIFO（64-deep, prog_full≈48）只有 capture engine 寫出 C2H 資料才 drain，而寫出需要 loopback input（來自 H2C）。
3. 任一方向：fetch 停在 FIFO 滿 → `sg_fetch_busy` 保持 high → `desc_fetch` 卡在 `WAIT_SGL_FETCH` → 對向 descriptor 永遠不 dispatch → 對向 engine 不跑 → FIFO 永不 drain → **雙向全死鎖**。無論 H2C-first 或 C2H-first 都死鎖（只是對稱）。

**修復（RTL，需要重新 flash bitstream）**：`rtl/sg_host_fetch_engine.v` 改為 direction-decoupled table buffering：

- 每個方向各有一對 internal block-RAM FIFO（Y 2048 entries = 4K Y table 2025、UV 1024 entries = 4K UV table 1013），fetch 直接把 table 全部 buffer 進 internal FIFO，**不再因 consumer almost-full 停住**。
- fetch 完成（`sg_fetch_busy` low）只需 table 全部上片（約 1-2µs/64B MRd × 760 MRds），`desc_fetch` 立即前進、對向 descriptor 被 dispatch、對向 engine 開始跑，死鎖鏈斷開。
- Background drain 依 consumer backpressure 把 entries 依序 push 到各 walker/CDC FIFO（round-robin 仲裁 H2C/C2H，Y/UV 獨立）。
- 同方向的下一個 fetch 只有在該方向前一個 descriptor 的 DMA 完成後才會被 dispatch，此時 internal FIFO 必已完全 drain/consumed，故不會混入殘留 entries。
- SGL push port 由單一 `sgl_channel` 改為 `sgl_y_channel`/`sgl_uv_channel`（Y/UV push 各自帶 channel），`custom_pcie_dma_top.v` demux 同步更新。

驗證：sim 26/26 PASS（`tb_sg_host_fetch_engine` 新增 deadlock 測試：consumer 全程 almost-full 時 fetch 仍完成、釋放後 entries 依序 drain；以及 H2C/C2H 雙方向並行 drain 測試）。

重新測試前（driver 不變，只需重刷 bitstream）：

```bash
cd ~/qpcie
./scripts/flash_a50t.sh        # 新 bitstream（含 deadlock fix）
sudo rmmod custom_pcie_av; sudo insmod driver/custom_pcie_av.ko force_sgl_fetch=1
```

## Out of Scope

- 不要把descriptor ring改為linked list。
- 不要停用Tegra SMMU/IOMMU或使用physical-address bypass。
- 不要把forced-SGL性能與direct-DMA的934.60 MiB/s baseline混為同一指標。
- 不要在未完成上述correctness與fault檢查前，將forced-SGL列為production預設路徑。
