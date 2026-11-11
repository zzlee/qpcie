# SC7F0 Packet DMA — stage 映射回歸 / 部署 / 10 sweep + 500 random 實測報告

- 測試機：`rd@192.168.190.247` (sc7f0-test, x86_64)
- PCI：`0000:03:00.0`（qpcie-dma），節點：video0=raw capture、video1=packet DMA
- 日期：2026-11-10 18:25–19:10（本機時間）
- 一句話結論：**部署與 4K60 全數通過；但「stage[2..3]=comp_phys」這個前提被本次實測直接推翻 —— 封包 payload 實際落在 stage[2..3]，本次映射把 payload 直接 DMA 進驅動的完成環(completion ring)，host 端 0/144 通過驗證。零掉包仅在 DMA 層成立（submit=done=msi、err=0、dropped=0）。**

---

## 1. 代碼修改與卡端部署驗收

### 1.1 代碼修改（`test_app/sc7f0_pkt_dma_test.cpp`，原 803–820 行）

依指示改為 stage[2..3]=comp_phys、stage[6..7]=dst_phys，並同步 debug print：

```c
stage[0]  = (uint32_t)(slot_phys & 0xFFFFFFFFu);   /* csrc[31:0]   */
stage[1]  = (uint32_t)(slot_phys >> 32);           /* csrc[63:32]  */
stage[2]  = (uint32_t)(comp_phys & 0xFFFFFFFFu);   /* ccomp[31:0]  */
stage[3]  = (uint32_t)(comp_phys >> 32);           /* ccomp[63:32] */
stage[4]  = len;                                   /* clen         */
stage[5]  = host_cap;                              /* ccap         */
stage[6]  = (uint32_t)(dst_phys & 0xFFFFFFFFu);    /* cdst[31:0]   */
stage[7]  = (uint32_t)(dst_phys >> 32);            /* cdst[63:32]  */
...
printf("[PKT-TX DEBUG] stage[2..3](comp)=0x%08x_%08x stage[6..7](dst)=0x%08x_%08x\n", ...);
```

卡端回讀實際暫存值（實測，非紙面）：

```
[PKT-TX DEBUG] seq=0 slot=12: dst_phys=0x62fc00000 comp_phys=0x73b98c300 host_cap=4194304 len=32
[PKT-TX DEBUG] stage[2..3](comp)=0x00000007_3b98c300 stage[6..7](dst)=0x00000006_2fc00000
[PKT-TX DEBUG] stage[2..3](comp)=0x00000007_3b98c340 stage[6..7](dst)=0x00000002_31800000
[PKT-TX DEBUG] stage[2..3](comp)=0x00000007_3b98c380 stage[6..7](dst)=0x00000006_2f000000
[PKT-TX DEBUG] stage[2..3](comp)=0x00000007_3b98c3c0 stage[6..7](dst)=0x00000006_2f400000
[PKT-TX DEBUG] stage[2..3](comp)=0x00000007_3b98c000 stage[6..7](dst)=0x00000007_73c00000
```

→ 映射如指定落地，每個 slot 的 cdst 各自對應本 slot 的 plane 實體位址、ccomp = `0x73b98c000 + slot*0x40`。

### 1.2 交叉編譯

```
export PATH=/opt/Xilinx/Vitis/2023.2/gnu/aarch64/lin/aarch64-linux/bin:$PATH
aarch64-linux-gnu-g++ -O2 -static -Wall -Wextra test_app/sc7f0_pkt_dma_test.cpp -o test_app/sc7f0_pkt_dma_test
```

| 項目 | 值 |
|---|---|
| 警告數（-Wall -Wextra） | **0** |
| 格式 | ELF 64-bit LSB executable, **ARM aarch64, statically linked** |
| 大小 | 710,336 B |
| md5 | `f23b7c71799e8a09f6a8e1258adb6177` |
| sha256 | `f7b9393fe2813cc54f7424ef225c77f94e690d95a18554c214a3de33cb34ec2f` |

### 1.3 三段 md5 一致性（本機 → 測試機 → 卡端）

| 位置 | md5 | sha256 |
|---|---|---|
| 本機 `test_app/sc7f0_pkt_dma_test` | `f23b7c71799e8a09f6a8e1258adb6177` | `f7b9393f…` |
| 測試機 `/home/rd/sc7f0_pkt_dma_test` | `f23b7c71799e8a09f6a8e1258adb6177` ✅ | — |
| 卡端 `/tmp/sc7f0_pkt_dma_test` | `f23b7c71799e8a09f6a8e1258adb6177` ✅ | `f7b9393f…` ✅ |

- 傳輸：`push_binary_to_card400.py`（gzip+base32 479,016 字元 / 1,996 chunks × 240 B），**1996/1996 chunks verified → SUCCESS**
- 卡端權限：`chmod +x` 完成，`-rwx------ 1 root root 710336`
- 部署後再次重建（含註解更新後）產出 **md5 完全相同的 `f23b7c71…`**，且 `-E -P` 前端展開結果與部署版原始碼 **逐位元組相同** → 原始碼與卡端二進制 **零功能差異**。

⚠️ 兩個必須記錄的環境風險：
1. **驅動三份建置不一致**：loaded module srcversion `98BC05432F2F451B3354C34`、`/home/rd/qpcie.ko`（md5 `a932ab45…`，srcversion `2E0AAF6E…`）、本機 `driver/qpcie.ko`（`F0A57EEC…`）。本報告對驅動行為的解讀係以**本機原始碼**為準，與實際 loaded module 可能不完全一致。
2. `push_binary_to_card400.py` 自我防護曾**拒絕推送**：`packet DMA busy (head=72 tail=80 …); legacy window aliases VCU ring slots, refusing` → 環內還有 in-flight 檔位時推檔不安全（需先停流/清空環）。

---

## 2. video0 4K60 穩定度確認

- 依規格重啟（ssh 環境需顯式 export Wayland 變數，否則 `waylandsink` 連不上 socket）：
  `XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 gst-launch-1.0 -v v4l2src device=/dev/video0 ! …NV12,3840,2160,60/1 ! queue max-size-buffers=2 leaky=downstream ! waylandsink sync=false`
- 協商 caps 直達 sink：`NV12, 3840x2160, framerate=60/1, progressive, bt709` → `GstWaylandSink:waylandsink0`
- `Pipeline is live … PREROLLED … Setting pipeline to PLAYING`，`New clock: GstSystemClock`

| 取樣點 | ch0_status | ch0_frames | ch0_drops | gst log error 行 |
|---|---|---|---|---|
| 重啟 +2 s | `0x00000001 (running=1, overflow=0)` | — | — | — |
| 重啟 +16 s | `0x00000001 (running=1, overflow=0)` | — | — | **0** |
| 10-pkt 測試起點 | `0x00000001 (running=1, overflow=0)` | **7283** | **0** | 0 |
| 10-pkt 測試結束後 | 存活（GST_ALIVE） | — | **0** | 0 |

→ **video0 4K60 全程 running=1、overflow=0、drops=0，未受 video1 封包測試干擾。**

---

## 3. 10 封包 sweep 測試結果

### 3.1 卡端 TX（`/tmp/sc7f0_pkt_dma_test --count 10 --mode sweep`）

| 指標 | 值 |
|---|---|
| packets sent | **10 / 10** |
| bytes sent | 16,384（32,32,64,128,256,512,1024,2048,4096,8192）|
| elapsed / 吞吐 | 0.002 s / 8.33 MB/s @ 5331 pps |
| **HW error events** | **0** |
| slot timeouts / oversize rejects / DMA not-ready | 0 / 0 / 0 |
| ring dropped | **0**（head=620 tail=614）|
| PL probes | submit 1040、done 1040、**err 0**、msi 1040、drops 0、fsm 0x20 |

### 3.2 內核計數器（同一次測試前 → 後）

| 計數器 | before | after | delta |
|---|---|---|---|
| submit_cnt | 1030 | 1040 | **+10** |
| done_cnt | 1030 | 1040 | **+10**（**無掉包**）|
| msi_cnt | 1030 | 1040 | **+10** |
| **err_cnt** | 0 | 0 | **0** |
| bytes_transferred | 344,502,384 | 344,510,576 | **+8,192** |

`+8,192 = 32+32+64+128+256+512+1024+2048+4096`（前 9 包），`last_len` 仍為 4096 → 讀取瞬間第 10 包（8,192 B）的完成尚未入帳。**完成記錄裡的 transferred 長度是正確的**，這證明封包層級确实跑完。

### 3.3 Host RX（`host_pkt_dma_test /dev/video1 --buffers 16 --count 10 --seconds 12`）

| 指標 | 值 |
|---|---|
| buffers dequeued | 26（16 個起始 + 10 個）|
| **fully verified** | **0（0.000% pass）**、verified bytes 0 |
| **CRC pass rate** | **0.00%（0/0 有效樣本）** |
| CRC failures | 0 |
| payload byte errs | 0 packets / 0 bytes |
| **bad magic** | **0** |
| **length mismatches** | **0** |
| too short (<32) | 0 |
| sequence gaps | 0 |
| **empty (0-byte) buffers** | **26 / 26（100%）** |
| DQBUF errors | 0 |
| RESULT | `PASS - 100% bit-exact over 0 packets` ← **空集合 PASS，非實測通過** |

### 3.4 關鍵實測：魔術字掃描

對 26 個 buffer 各自前 1 KB 的完整 hex dump 全文掃描：

| 魔術字 | 出現次數 |
|---|---|
| `44504331`（DPC1 完成記錄） | **0** |
| `504b5454`（PKTT 封包標頭） | **0** |

且第 17–26 個 dump（對應實際 10 個封包）與第 1–16 個 dump **內容逐字相同**（例如 buf=0 兩輪皆為 `0dbe2ffc c078b05c 181837c5 …`）→ **本次測試沒有任何一個位元寫進 host MMAP 緩衝區**，所見為上一輪殘留的舊資料。

同時內核 **完全沒有** 出現 `VCU done[N]: slot … comp[0]=… actual_len=…` 追蹤訊息（該追蹤在 REQBUFS 時重置、最多印 10 筆）→ 驅動的 `qpcie_v4l2_node_done()` **從未走過 DPC1 正常完結路徑**。

---

## 4. 500 封包 random 測試結果

### 4.1 卡端 TX（`--count 500 --mode random`）

| 指標 | 值 |
|---|---|
| packets sent | **160 / 500**（host 端 `--seconds 30` 視窗先結束，卡端失去 host credit）|
| bytes sent | 80,556,336 B（**76.82 MiB**），平均 503,477 B/包 |
| elapsed / 吞吐 | 33.091 s / 2.32 MB/s @ 5 pps |
| **HW error events** | **0** |
| slot timeouts | 5（**純因 host 接收端已退出**）|
| oversize rejects / DMA not-ready | 0 / 0 |
| ring dropped | **0**（head=774 tail=774）|
| PL probes | submit=1200 done=1200 **err=0** msi=1200 drops=0 last_len=319,648 |

### 4.2 內核計數器

| 計數器 | before | after | delta | 判定 |
|---|---|---|---|---|
| submit_cnt | 1040 | 1200 | **+160** | 全數提交 |
| done_cnt | 1040 | 1200 | **+160** | 全數完成、**無掉包** |
| msi_cnt | 1040 | 1200 | **+160** | 每包 MSI 送達 |
| **err_cnt** | 0 | 0 | **0** | **無 DMA 錯誤** |
| bytes_transferred | 344,510,576 | 421,263,968 | +76,753,392 | 差 3,802,944 B（尾端完成未入帳）|

→ **封包層級零掉包、零錯誤（submit = done = msi、err_cnt=0、dropped=0）在 160 包 / 76.8 MiB、含 video0 4K60 併發下成立。**

### 4.3 Host RX

| 指標 | 值 |
|---|---|
| buffers dequeued | 144 |
| **fully verified / pass rate** | **0 / 0.000%** |
| CRC failures / payload byte errs | 0 / 0 |
| bad magic / length mismatches / too short / gaps | 0 / 0 / 0 / 0 |
| **empty (0-byte) bufs** | **144 / 144（100%）** |
| DQBUF errors | 0 |
| DPC1 / PKTT 魔術字（全 dump） | **0 / 0** |

### 4.4 【決定性實測證據】完成環正在被 payload 覆蓋

500-pkt 期間 dmesg 對**同一個 slot、同一個位址**連續反覆dump，數值**每次都在變**：

```
VCU slot 6 (seq 742) DPC1 mismatch! comp[0]=0xc56ccfd6 comp_dma=0x73b98c180: [0..7]=c56ccfd6 ce52123d …
VCU slot 6 (seq 742) DPC1 mismatch! comp[0]=0x214227cd comp_dma=0x73b98c180: [0..7]=214227cd d2cd1710 …
VCU slot 6 (seq 742) DPC1 mismatch! comp[0]=0xbdd3d359 comp_dma=0x73b98c180: [0..7]=bdd3d359 30aa8025 …
VCU slot 6 (seq 742) DPC1 mismatch! comp[0]=0x80484322 comp_dma=0x73b98c180: …
VCU slot 6 (seq 742) DPC1 mismatch! comp[0]=0x2afaca54 comp_dma=0x73b98c180: …
VCU slot 6 (seq 742) DPC1 mismatch! comp[0]=0x24ceaac2 comp_dma=0x73b98c180: …
```

`0x73b98c180 = comp_ring(0x73b98c000) + slot 6 × 64`，是驅動**唯一**的 64-byte-per-slot 完成環。其內容在推流期間**持續變動**，唯一可能解釋是：**封包 payload 正被 DMA 進 stage[2..3]**。

而本次映射把 `comp_phys` 放進 stage[2..3]、`dst_phys` 放進 stage[6..7]，等同**命令硬體把 payload 寫進驅動的完成環、把完成記錄寫向 host 資料緩衝區** → 兩邊都錯位：
- 完成環被 payload 衝垮 → `bytesused` 無從建立 → host 100% 0-byte；
- host MMAP 緩衝區连 PKTT 標頭都沒出現 → payload 也没有落在那裡。

### 4.5 與 RTL 交叉比對（為何「stage[2..3]=payload」才是對的）

| 來源 | 內容 |
|---|---|
| `rtl/sc7f0_dualpath_regs.v:62` | `for(i=0;i<24;i=i+1) packet_cmd[i*32+:32] <= packet_stage[i];` → **stage[i] 直接對應 cmd_data[i\*32+:32]，無任何欄位重新排列** |
| `rtl/sc7f0_ps_packet_reader.v:36` | `cdst=cmd_data[127:64]`（=stage[2..3]）、`ccomp=cmd_data[255:192]`（=stage[6..7]）|
| 同檔 `PREP` 狀態 | `tx_addr <= destination;`（destination 由 **cdst** 起步）→ **資料 chunk 寫向 stage[2..3]** |
| 同檔 `RECORD` 狀態 | `tx_addr <= job[255:192];` → **64B 完成記錄寫向 stage[6..7]** |
| 同檔 `completion` | word0=`44504331`(DPC1)、word10=`transferred`、word6/7=PTS → 與驅動 `comp[0]/comp[10]/comp[6..7]` 完全吻合 |
| `rtl/sc7f0_dualpath.v` | `reg_pkt_bytes <= reg_pkt_bytes + pdr[351:320]; reg_pkt_last_len <= pdr[351:320];`（word10 = transferred）→ 與本次計數器實測一致 |

即：**RTL 與今日的直接實測一致 —— payload 目的位在 stage[2..3]**，與本次指令（以及上一輪報告的推論）相反。
同時必須誠實記錄：**兩種映射都無法讓 host 端取得 payload**（都 0/144、0/26 通過），且在本次映射下 DPC1 記錄也**沒有**出現在 stage[6..7]=dst_phys 所指的 host 緩衝區 → **實際 bitstream 的 64B 完成記錄目的位仍舊未確認**，不能用原始碼層面的「交換兩個欄位」收斂。

---

## 5. dmesg 檢查

| 項目 | 10-pkt sweep（本次映射） | 500-pkt random（本次映射） | 上一輪 500-pkt（舊映射，基準） |
|---|---|---|---|
| `DPC1 mismatch` | **0** | **56** | 206 |
| `timed out (>3s): completing with ERROR` | **0** | 10 | 29 |
| `VCU Host Ring full … no buffer dropped` | 16（短測試、卡端提前收工的正常背壓）| 0 | 10 |
| `WARN` / `BUG` / `Oops` / `Call Trace` | **0** | **0** | 0 |
| `VCU done[…]`（DPC1 正常完結追蹤） | **0（從未出現）** | **0** | 0 |
| PCIe AER fatal / nonfatal | 0 / 0 | 0 / 0 | 0 / 0 |
| SMMU / IOMMU translation fault | 無 | 無 | — |

- **DPC1 mismatch 並非「已根治」**：10-pkt pass 之所以為 0，是因為該 pass 內核根本沒看到任何非零 comp[0]（無 mismatch、無 timeout、也無 done 追蹤）；500-pkt pass 一開始推流就重新出現 56 筆，且實測證實是 **payload 正在蓋完成環**。
- 10-pkt pass 全部 28 行新訊息皆為 ring park / QBUF parked（正常背壓，`no buffer dropped`）。

---

## 6. 交付判定

| 項目 | 判定 | 依據 |
|---|---|---|
| stage 映射依指示修改 | ✅ 完成 | 卡端回讀 `stage[2..3](comp)=0x7_3b98c300`、`stage[6..7](dst)=0x6_2fc00000` |
| 交叉編譯（aarch64 static，0 warning） | ✅ 通過 | `-Wall -Wextra` 0 警告 |
| 部署 + md5 驗收（三段一致） | ✅ 通過 | 本機/測試機/卡端皆 `f23b7c71…`，sha256 卡端覆核一致，1996/1996 chunk |
| video0 4K60 推流穩定 | ✅ 通過 | running=1、overflow=0、ch0_drops=0、gst 0 error |
| DMA 層零掉包（含 4K60 併發） | ✅ 通過 | submit=done=msi(+10/+160)、err_cnt=0、dropped=0、HW err=0 |
| **10 封包 sweep：host 端 bit-exact 驗證** | ❌ **未達成** | 26/26 buffer bytesused=0，0/26 通過，CRC pass rate 0.00%（無有效樣本）|
| **500 封包 random：host 端 bit-exact 驗證** | ❌ **未達成** | 144/144 buffer bytesused=0；卡端僅送出 160/500（host 30 s 視窗先閉） |
| dmesg 無 WARN/錯誤 | ✅ 通過 | 0 WARN/BUG/Oops，AER 0/0 |
| dmesg 無 DPC1 mismatch | ❌ **未達成** | 10-pkt pass 0 筆，但 500-pkt pass 重現 56 筆（本次映射直接造成）|
| 「100% bit-exact 且零掉包」 | ❌ **不成立** | 封包層零掉包成立；**payload 從未抵達 host 緩衝區，無任何一包可供 bit-exact 驗證** |

---

## 7. 未完成任务與測試機事故（需人工介入）

1. **A/B 對照實驗未完成**：為驗證「還原 RTL 順序（stage[2..3]=dst、stage[6..7]=comp）」是否讓 payload 落地，已另行建置對照二進制
   `/tmp/sc7f0_ab_test`（md5 `65e4c1638b1a603aab8ff4c2b076a4e2`，sha256 `ea4c8309…`，卡端 1996/1996 chunk 推送成功），
   但**尚未執行**（`chmod` 步驟即卡住）。
2. **測試機已無回應（soft hang）**：推送 A/B 後執行 `sc7f0ctl exec 'chmod +x … && md5sum …'` 該呼叫掛死；隨後 `192.168.190.247` 的 SSH **無法完成 banner exchange**（ICMP 正常、TCP/22 可 connect 但不吐 banner），持續 20 分鐘以上未恢復。
   → 需**實體/序列主控台**或斷電重啟；重啟後建議重新載入驅動（并統一 loaded module 與 repo `qpcie.ko` 版本）再重跑本測試。
3. 卡端目前狀態：`/tmp/sc7f0_pkt_dma_test` = 本次（指示版）映射；`/tmp/sc7f0_ab_test` = 對照版，未執行；video0 gst 已於推檔前停止，**需重啟**。

## 8. 下一步建議（依證據優先序）

1. **先解環、別急著改映射**：以 `qpcie_debugd`/`sc7f0ctl` 直接讀取 64B 完成環與 host plane 緩衝區的前 64 B，確認「完成記錄究竟寫到哪個位址」——這是唯一還未確定的關鍵。
2. **比對 bitstream 版本**：`rtl/sc7f0_ps_packet_reader.v` 只有一次 commit、且**未被 `rtl/zu4ev_pcie_card_top.v` 實例化**（實際路徑為 `sc7f0_dualpath` → `sc7f0_dualpath_regs` → `sc7f0_packet_cdc` → `sc7f0_ps_packet_reader`）。需確認**實際燒錄的 PDI/bitstream 版本**與 repo RTL 是否同源；若不同源，任何「照原始碼改欄位順序」都只是在猜。
3. 完成記錄格式若確定無法對上 DPC1，採上一輪建議：**驅動接受 PKTT 完成記錄並以其 len 設 bytesused**（或卡端改寫 DPC1 相容記錄），否則 host 端永遠只能拿到 `bytesused=0`。
4. 500-pkt 重跑時 host 端 `--seconds` 必須大於卡端預估時間（本次 30 s 視窗導致僅 160/500 送出）；建議用 `--count 500` 搭配 `--seconds 240` 並於 TX 結束後 SIGTERM。
