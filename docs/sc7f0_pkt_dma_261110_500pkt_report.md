# SC7F0 Packet DMA 驗證報告 — 卡端部署 + video0 4K60 + 10 sweep / 500 random

- 測試機：`rd@192.168.190.247` (sc7f0-test, Linux 7.0.0-42-generic)
- PCI：`0000:03:00.0`（qpcie-dma）
- 日期：2026-11-10 18:05–18:18 (主機本地時間)
- 結論一句話：**封包 DMA 本身（含修正後的 stage 映射）零掉包、零 HW 錯誤；但 Host 驅動只認 `DPC1` 完成記錄、卡端測試寫 `PKTT`，導致 bytesused=0，Host 端完全無法驗證 payload。**

---

## 1. 卡端二進制部署與 md5sum 驗證

| 項目 | 值 |
|---|---|
| 來源（測試機） | `/home/rd/sc7f0_pkt_dma_test`，710,336 B，ELF 64-bit ARM aarch64 **statically linked** |
| 來源 md5 | `9e8e2baecb92692ea26697da05e877c5` |
| 來源 sha256 | `e407ef3ce162a37a3895a3e379766e1d5b520eb2279e0b075a1bde423da89a42` |
| 本機 build 對照 | `test_app/sc7f0_pkt_dma_test` md5 = `9e8e2baecb92692ea26697da05e877c5` → **與部署件完全一致** |
| 部署前卡端舊檔 | `/tmp/sc7f0_pkt_dma_test` 76,768 B（Nov 8 16:05），md5 `c22f42d84a736b387d21a701a83f0e45` → 已過期，已汰換 |
| 傳輸方式 | `push_binary_to_card400.py`：gzip+base32 479,016字元 → **1996 chunks × 240 B**，每 chunk 卡端 SHA-256 驗證 |
| 傳輸結果 | `1996/1996 chunks verified` → `SUCCESS: /tmp/sc7f0_pkt_dma_test sha256=e407ef3c…` |
| 部署後卡端 | `-rwx------ 1 root root 710336`，`md5sum` = `9e8e2baecb92692ea26697da05e877c5` ✅ |
| 權限 | `chmod +x` 已執行（`cp` 步驟已自帶 +x；mode `0700 root`，卡端 daemon 以 root 執行，不受影響） |

⚠️ 需注意：驅動版本三份不一致（本次未重載，僅記錄）

| 物件 | srcversion |
|---|---|
| 目前 loaded module | `98BC05432F2F451B3354C34` |
| `/home/rd/qpcie.ko` | `2E0AAF6E93DD79E8AFBFE60` |
| 本機 `driver/qpcie.ko` | `F0A57EECA9EE285274188BB` |

---

## 2. video0 4K60 推流重啟狀態確認

### 2.1 暫停
- `pkill -f gst-launch-1.0`（實際以 `gst-lau[n]ch-1.0` 括号式樣式避免自我比對）殺掉 pid **162799**
- 殺掉後 `ch0_status = 0x00000300 (running=0, overflow=0)`

### 2.2 重啟（pipeline 完全依規格）
`ssh` 環境沒有 Wayland 變數，需顯式 export，否則 `waylandsink` 無法連 socket：
`XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0`（socket `/run/user/1000/wayland-0` 確認存在）

```
gst-launch-1.0 -v v4l2src device=/dev/video0 ! video/x-raw,format=NV12,width=3840,height=2160,framerate=60/1 \
  ! queue max-size-buffers=2 leaky=downstream ! waylandsink sync=false
```
- `Pipeline is live… PREROLLED … Setting pipeline to PLAYING`、`New clock: GstSystemClock`
- 協商 caps 直達 sink：`NV12, 3840x2160, 60/1, progressive, bt709` → `GstWaylandSink:waylandsink0`
- pid **169041**（報告撰寫時仍存活）

### 2.3 推流穩定性（實測計數器）

| 取樣 | ch0_frames | delta | fps | running | overflow | drops |
|---|---|---|---|---|---|---|
| t0 / t0+10s | 493 → 1093 | 600 | **60.000** | 1 | 0 | 0 |
| 500-pkt 測試期間（5s） | — | 300 | **60.000** | 1 | 0 | 0 |
| 全部測試結束後（15s） | 23630 → 24530 | 900 | **60.000** | 1 | 0 | 0 |

- `frame_drop_count = 0 frames dropped`，`ch0_drops = 0`
- `hdmi_status`：`Signal Locked`，`3840x2160p`，pixel clock `594000000 Hz`
- → **4K60 全程穩定，未受 video1 packet DMA 測試干擾**

---

## 3. 10 封包 sweep 測試結果

### 3.1 卡端 TX（`/tmp/sc7f0_pkt_dma_test --count 10 --mode sweep`）

```
mode=sweep count=10 min=32 max=1048576 fixed=4096 rate=full-speed seed=0x5eed1234
Packet DMA CSR: magic=0x44505631 ("1VPD") version=0x00010000
host ring @0xa0002200: magic=0x56435552 ("VCUR") ring_size=16 host_head=36 ps_tail=20
```
| 指標 | 值 |
|---|---|
| packets sent | **10** |
| bytes sent | 16,384（32+32+64+128+256+512+1024+2048+4096+8192，逐包 ×2 sweep ✅） |
| elapsed / 吞吐 | 0.002 s / 8.53 MB/s @ 5457 pps |
| HW error events | **0** |
| slot timeouts（no host credit） | 0 |
| oversize rejects | 0 |
| DMA not-ready | 0 |
| ring dropped | 0 |
| PL probes | submit 446→456，done 456，err 0，msi 456，drops 0，fsm 0x20 |

### 3.2 Stage 映射驗證（`stage[2..3]`=cdst、`stage[6..7]`=ccomp 回讀）

| card seq | slot | dst_phys | comp_phys | len |
|---|---|---|---|---|
| 0 | 10 | `0x7_4bc00000` | `0x7_3b98c280` | 32 |
| 1 | 11 | `0x7_4e000000` | `0x7_3b98c2c0` | 32 |
| 2 | 12 | `0x7_4d800000` | `0x7_3b98c300` | 64 |
| 3 | 13 | `0x6_4b800000` | `0x7_3b98c340` | 128 |
| 4 | 14 | `0x2_6dc00000` | `0x7_3b98c380` | 256 |

→ 每個 slot 的 `cdst` 各別對應各自 QBUF plane 實體位址、`ccomp = 0x73b98c000 + slot*0x40`，**修正後的 stage 映射正確**。

### 3.3 Host RX（`host_pkt_dma_test /dev/video1 --buffers 16 --count 10 --seconds 12`）

| 指標 | 值 |
|---|---|
| buffers dequeued | 26 |
| **fully verified** | **0（0.000% pass）** |
| CRC failures | 0 |
| payload byte errs | 0 packets / 0 bytes |
| **bad magic** | **0** |
| **length mismatches** | **0** |
| too short (<32) | 0 |
| **sequence gaps** | **0** |
| **empty (0-byte) bufs** | **26** |
| DQBUF errors | 0 |
| RESULT | `PASS - 100% bit-exact over 0 packets`（**空集合 PASS，非實測通過**） |

時序解讀：16 個初始空緩衝 + 卡端送完後約 3 秒整齊釋出 10 個（每秒窗口 `rx=9`）= 26，即 10 個封包各走一次「完成逾時 → ERROR 完結」。

### 3.4 Payload 確實落地（buffer hex dump 證據）

每個 buffer：`+0x00 = 0x44504331`（DPC1），`+0x40 = 0x504b5454`（PKTT），且 seq/length 與 sweep 逐一吻合：

| buf | PKTT seq | len 欄位 |
|---|---|---|
| 5 | 6 | `0x00000400` (1024) |
| 6 | 7 | `0x00000800` (2048) |
| 7 | 8 | `0x00001000` (4096) |
| 8 | 9 | `0x00002000` (8192) |

→ 資料 DMA 寫入位址/長度/序號皆正確，**只是驅動回報 `used=0` 使 host 端放棄驗證**。

---

## 4. 500 封包 random 測試結果與統計

### 4.1 卡端 TX（`--count 500 --mode random`，前台 `sc7f0ctl --timeout 300 exec`）

| 指標 | 值 |
|---|---|
| packets sent | **500 / 500** |
| bytes sent | **264,750,112（252.49 MiB）**，平均 529,500 B/包（max 1,048,528） |
| elapsed | 93.588 s |
| 平均吞吐 | **2.70 MB/s @ 5 pps** |
| **HW error events** | **0** |
| slot timeouts（no host credit） | **0** |
| oversize rejects | 0 |
| DMA not-ready | 0 |
| ring dropped | **0**（head 606 / tail 594） |
| PL probes | submit 1020、done 1019、err 0、msi 1019、drops 0（讀取瞬間 1 包 in-flight） |

### 4.2 內核計數器（`packet_stats`，測試前 → 測試後）

| 計數器 | before | after | delta | 判定 |
|---|---|---|---|---|
| submit_cnt | 520 | 1020 | **+500** | 全部提交 ✅ |
| done_cnt | 520 | 1020 | **+500** | 全部完成 ✅ **無掉包** |
| err_cnt | 0 | 0 | **0** | **無 DMA 錯誤** ✅ |
| msi_cnt | 520 | 1020 | +500 | 每包 MSI 皆送達 ✅ |
| bytes_transferred | 93,836,112 | 344,494,192 | +250,658,080 | ⚠️ 比卡端 264,750,112 少 14,092,032 B（≈26 個平均大小封包） |

`submit_cnt == done_cnt == msi_cnt`（+500）與 `err_cnt = 0` 說明**封包層級無掉包**；
`bytes_transferred` 差額屬**完成記錄計帳**問題（驅動只累計它能解析的 DPC1 完成），非鏈路丟資料 — 但建議修復完成格式後重新核對為宜。

### 4.3 Host RX（`--buffers 16 --count 500 --seconds 240`，於 TX 結束後 SIGTERM）

| 指標 | 值 |
|---|---|
| buffers dequeued | 512 |
| **fully verified** | **0（0.000% pass）**，verified bytes 0 |
| elapsed | 100.600 s |
| CRC failures / payload byte errs | 0 / 0 |
| **bad magic / length mismatches / too short** | 0 / 0 / 0 |
| **sequence gaps** | **0** |
| **empty (0-byte) bufs** | **512（100%）** |
| DQBUF errors | 0 |

每秒分佈呈 `14, 0, 0` 週期（16 slot ÷ 3 s 逾時 ≈ 5.3 pps）→ **瓶頸是驅動 3 秒逾時，不是 PCIe/DMA 頻寬**；也解釋卡端為何穩定 5 pps 而非全速。

---

## 5. dmesg：有無 WARN 或錯誤

- **`WARN` / `BUG` / `Oops` / `Call Trace`：整段 ring buffer 共 0 筆 ✅**
- PCIe AER：`TOTAL_ERR_FATAL = 0`、`TOTAL_ERR_NONFATAL = 0` ✅
- 500-pkt 期間新增 255 行，全部為驅動完成路徑的診斷：

| 訊息 | 筆數 |
|---|---|
| `VCU slot N (seq N) DPC1 mismatch! comp[0]=0x…` | 206 |
| `VCU slot N (seq N) timed out (>3s): completing with ERROR` | 29 |
| `VCU Host Ring full … parking publisher, **no buffer dropped**` | 10 |
| `VCU ch1: N QBUFs parked, card is not consuming the Host Ring` | 數筆 |
| `VCU ch1 session reset / STREAMOFF reset / ring parks=101 republished=3` | 各 1 |

### 5.1 根因（已對到程式碼）

- 驅動 ch1 完成解析只認 DPC1：`driver/qpcie_v4l2.c:3050` `#define QPCIE_VCU_DPC1_MAGIC 0x44504331`、`:3112` `if (comp[0] != QPCIE_VCU_DPC1_MAGIC) { … DPC1 mismatch … }`
- 卡端封包測試把**封包標頭本身**（`PKTT 0x504b5454` + seq + len + crc）寫進同一個 `comp_dma` 位址 → 驅動視為不匹配 → 3 s 逾時 → 以 ERROR 完結
- `driver/qpcie_v4l2.c:3222` 註解明定：ch1 的 `bytesused` **只**能來自完成記錄；完成為 0 → `vb2_set_plane_payload(..., 0)` → host 端 `bytesused=0`
- 因此 host 端 `CRC/bad magic/length/gap` 全 0 是「**從未取得可驗證 payload**」，並非「驗證全過」。

### 5.2 後續建議（任一即可解除 host 端驗證阻塞）

1. 驅動接受 `PKTT` 完成記錄，並以其 `len` 欄位設 `bytesused`；或
2. 卡端測試改寫 DPC1 格式完成記錄（保留 PKTT 於 payload 內）；或
3. 新增獨立 packet-mode 節點/flag，讓 ch1 完成解析依模式選擇 DPC1 / PKTT。
   修復後重跑 500 random，才能取得**真正**的 CRC / bit-exact 統計。

---

## 6. 執行環境注意事項（本次踩到，供後續腳本避開）

1. `ssh "... pkill -f gst-launch-1.0 ..."` 與 `pkill -f host_pkt_dma_test` 會**自我比對**到 ssh 的 `bash -c` 命令列 → 用 `gst-lau[n]ch-1.0` 括号式樣式或 `pkill -x host_pkt_dma_te`，並把長腳本落地成檔再執行。
2. `sc7f0ctl --timeout` 上限約 300 s（`--timeout 420` 直接印 usage 並拒絕執行，卡端指令完全沒跑到）。
3. 卡端 `sc7f0ctl exec '… &'` **無法**讓行程在 exec 結束後存活（`/tmp/tx500.log` 0 bytes、`ps` 無行程、`submit_cnt` 不進）→ 長測試必須前台 exec 且 `--timeout` 內完成。
4. `host_pkt_dma_test` 對 `used=0` buffer 會印 `EMPTY-DEBUG-DEBUG` hex dump（約 4KB/緩衝）→ 500 包會淹沒輸出，务必導向檔並 `awk`/`grep` 取 summary。
5. SIGTERM 會讓 `host_pkt_dma_test` 正常印 RECEIVE SUMMARY（可用於 TX 結束後提前收房）。

---

## 7. 交付判定

| 項目 | 判定 |
|---|---|
| 卡端二進制部署 + md5 驗證 | ✅ 通過（md5/sha256 三重一致，1996/1996 chunk 驗證） |
| video0 4K60 重啟並穩定推流 | ✅ 通過（60.000 fps、0 drop、overflow=0，全程維持） |
| 10 封包 sweep：stage 映射 | ✅ 通過（cdst/ccomp 回讀正確，落地 seq/len 吻合） |
| 10 封包 sweep：host 端 payload 驗證 | ❌ 阻塞（26/26 buffer used=0，無法驗證） |
| 500 封包 random：DMA 掉包/損毀 | ✅ DMA 層無掉包（submit=done=msi=+500、err=0、dropped=0、HW err=0） |
| 500 封包 random：host 端 bit-exact 驗證 | ❌ 阻塞（512/512 buffer used=0） |
| dmesg WARN/錯誤 | ✅ 0 WARN/BUG/Oops、AER 0 fatal/0 nonfatal（僅 DPC1 mismatch 診斷訊息） |
