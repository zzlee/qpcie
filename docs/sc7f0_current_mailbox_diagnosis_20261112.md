# SC7F0 目前 mailbox 診斷（2026-11-12，read-only）

範圍：只查「標準燒錄重啟後 PCIe mailbox exec 失效」目前的現場狀態。未做歷史研究、未改碼、
未做任何寫入。證據目錄：`build/current-mailbox-diagnosis-20261112T024025Z/`（README-rawlog.md 有完整命令/rc/raw 值）。

## 1. 現場識別（親測）
- Host `sc7f0-test`，kernel `7.0.0-42-generic`，2026-11-12T02:40:08Z uptime 1 day 1:28（host 未重啟）。
- Card `0000:03:00.0 [12ab:e380]`，driver `qpcie-dma`，D0；`/sys/module/qpcie/srcversion` = `2BA9C2B03340C193808943C`。
- 卡端空闲：無 qpcie/sc7f0ctl/vcud/debugd 行程、`fuser /dev/qpcie-debug-*` 空、module refcount 0。
- HDMI host telemetry：`Status: No Locked Timing / Receiver: Xilinx v_hdmi_rx_ss`；dmesg 最後一次
  telemetry `status 0x1 -> 0x3, res 0x0`（無 locked geometry）。

## 2. mailbox 原值（BAR0+0x2000，兩次相隔 1.5003 s，PROT_READ mmap resource0）
| 欄位 | sample1 02:41:14.250Z | sample2 02:41:15.750Z |
|---|---|---|
| MAGIC/ABI/READY | 0x53434442 / 0x1 / 0x1 | 同 |
| CARD_EPOCH | 0xe890de41 | 0xe890de41（未換 session） |
| CARD_BEAT | 0x00342a7f (3418751 ms) | 0x0034305c (3420252 ms)，+1501 ms/1500.3 ms → 心跳 1:1 正常 |
| **H2C_SEQ / H2C_ACK** | **0x4 / 0x4（相同）** | **0x4 / 0x4（相同）** |
| H2C_TYPE/ID/LEN | 0x2(DB_ECHO)/0x1/0x4 | 同 |
| **C2H_SEQ / C2H_ACK** | **0x4 / 0x3（未消費）** | **0x4 / 0x3（不變）** |
| C2H_TYPE/ID/LEN/CODE | 0x4(DB_ECHO_REPLY)/0x1/0x4/0 | 同 |
| HOST_EPOCH / ACK_EPOCH / HOST_BEAT | 0x0e3417d8 / 0x00000000 / 0x0548a12d | 同（無 live client） |

結論 Q1：**H2C 沒有卡在「pending 同 SEQ 不消費」；SEQ==ACK==0x4。卡住的殘留實在 C2H 方向**
（daemon 已產出一筆 4 byte ECHO_REPLY，host 端从未 ACK）。`sc7f0ctl status` 兩次 rc=0、heartbeat 遞增，
daemon 存活且 READY=1。

## 3. payload 落點（各讀 4 bytes）
- block 0x800（現行 DB_H2C_DATA）= `0x50494e47` = **"PING"** → 上一個客戶端確實把命令文字寫在 0x800。
- block 0x1000（DB_C2H_DATA，新舊 header 完全相同）= **0x00000000** → daemon 回傳的是 4 個 0，不是 "PING"。
- block 0x400（3588f89 之前的舊 DB_H2C_DATA，落在 VCU ring 0x200..0x43F 內）現值 0。
→ daemon 讀命令的視窗 **不是 0x800**（否則會 echo 出 "PING"）。這是從位元組得出的 ABI 錯位證據。

## 4. 二進位 offset 證據
- 已安裝 host 客戶端 `/usr/local/bin/sc7f0ctl`（sha `0e3a824f…`）objdump：`mov $0x800` ×2、`mov $0x1000` ×1、
  無 `$0x400` → **客戶端 ABI = 0x800 已證**（與現場 "PING"@0x800 一致）。
- 已燒 image.ub（tar sha `0efab7ac…`，image.ub sha `46da8a2e…`）抽出 `usr/bin/qpcie_debugd`
  sha `84a67bba…`、BuildID `c92465f9…`：與 host 上 `/home/rd/qpcie_debugd_0x800`
  （sha `e200063c…`、BuildID `110a6131…`）**是不同建置**。
- 該 debugd 字串為 `Debug mailbox ready (exec %s, shell %s)`，無 WIP 的 `mailbox ABI h2c=` banner。
- **未證**：本機/測試機無任何 aarch64 反組譯工具（objdump/gdb BFD 無 aarch64、無 llvm/cross objdump、無 capstone），
  且無 dumpimage/dtc；因此「燒进去的 debugd 編譯常數 == 0x400」這句話本身 **NotProven**，
  已證的只有「它读的 H2C 視窗 ≠ 0x800」。（**本節 NotProven 已被 §8 以反組譯推翻**：cross objdump 其實存在，只是不在 PATH。）

## 5. 機制（讀碼，aea8612 迴圈未受 WIP 影響）
`sc7f0ctl transact()` 對 echo 會 `memcmp` 回覆內容，不符即 `break` 且不 ACK C2H → 留下 C2H_SEQ(4)!=C2H_ACK(3)、
印 "Debug transport lost/timed out"、rc=125、不重試 —— 與觀測值完全吻合。
`qpcie_debugd` 在新的 HOST_EPOCH 時會自行清場（H2C_ACK=H2C_SEQ、C2H_SEQ=C2H_ACK）才寫 ACK_EPOCH；
目前 ACK_EPOCH=0 只代表「無 live session」，不代表需要手動清 mailbox。

## 6. cold reboot 前基線與判讀（本次未執行 reboot）
重啟前後各取同樣 5 個讀值：`CARD_EPOCH`、`CARD_BEAT`、`H2C_SEQ/H2C_ACK`、`C2H_SEQ/C2H_ACK`、
block 0x800/0x1000 兩字，加上 host `hdmi_status`。
- 支持「軟狀態殘留」：CARD_EPOCH 改變後 C2H 變 SEQ==ACK（本來就會，因 daemon 啟動時自己清）、
  且**同一份 image 下 echo 突然成功**（回覆內容變成輸入文字）。
- 支持「image 固有問題」：CARD_EPOCH 改變、beat 歸零、ring 全部清乾淨之後，echo 的回覆仍是 0、
  0x800 仍寫入命令文字、C2H 又卡一筆未 ACK —— 即 cold reboot 無法修好。
以本次證據預期為後者：失敗元件（daemon 的 H2C 視窗 vs 已安裝 client 的 0x800）來自 eMMC 內同一份 image.ub，
重開機只是重跑同一支 debugd。真正修正需要部署用 0x800 header 編譯的 debugd（或改用配對 client），
不屬本次唯讀診斷範圍。建議：不要把 cold reboot 當修復手段；若要執行，僅作為上述前後對照實驗，
並留意 vcud/HDMI 只能靠 host sysfs telemetry 觀察（PS 端 exec 正是失效項目，無法作為判讀依據）。

## 7. 未做的副作用操作
未 cold/host/card reboot、未 VERIFY/COMMIT、未上傳/覆蓋/安裝任何 PS 或 PL 檔案、未重載或安裝 driver、
未動服務/I2C/MCU/capture、未送 echo/exec/loopback/CANCEL、未寫 doorbell/H2C、未 dump 整 BAR 或 FIFO、
未用 `qpcie_upgrade --status`（會 setpci）、未 git stage/commit。僅做 PROT_READ 暫存器讀、
既有唯讀工具 `sc7f0ctl status`、文件所載 `hdmi_status`、本機 tar 解檔與 host 檔下載（host 檔未改）。
**未對卡端做任何寫入。**

## 8. 已燒 debugd 的 H2C payload offset — 以反組譯確證為 0x400（非 0x800）
工具（先前 §4 判斷錯誤；四個精確候選中三個存在，皆未安裝任何東西）：
`/opt/Xilinx/Vitis/2023.2/gnu/aarch64/lin/aarch64-linux/bin/aarch64-linux-gnu-objdump`（2.39，`--info` 支援 elf64-littleaarch64）
與 `.../aarch64-none/bin/aarch64-none-elf-objdump`、`/opt/Xilinx/petalinux/2023.2/tools/xsct/gnu/aarch64/lin/aarch64-none/bin/aarch64-none-elf-objdump`。
物件檔 `build/current-mailbox-diagnosis-20261112T024025Z/shipped/usr/bin/qpcie_debugd`（sha256
`84a67bbaf3243508baf4e73edb65a48507fa8533837b037e350c8c5869c6d248`、BuildID `c92465f9…`、static、未 strip、含 debug_info）。
片段存於同目錄 `shipped-debugd-h2c-offset.objdump.txt`。

- `db_payload@0x401a00`：偏移為引數 w1，`401a5c lsr w5,w19,#2` → `401a8c ldr w4,[x3,x6,lsl #2]`（mmap 路徑）
  或 `401bc0 bl __libc_pread`（pos=w1）；`401a14 cmp w3,#0xc00` 為長度上限 → **DB_PAYLOAD = 3072**
  （`sub sp,sp,#0xc60` = 0x60+0xc00 緩衝，同值佐證）。現行 `include/qpcie_debug.h` 為 2048U ⇒ **不同版**。
- `main` 內唯一兩個 read 呼叫點 `0x400d2c`／`0x400f60` 前皆 `mov w1,#0x400; mov w4,#0`
  （`0x400d20`／`0x400f48`）→ **H2C payload 絕對偏移 = 0x400**；其後 `strb wzr,[x2,w26]` = 現行源碼
  `db_payload(&io,DB_H2C_DATA,command,len,false); command[len]=0;`（`test_app/qpcie_debugd.c:161`）的同一條陳述。
- `db_send.constprop.0@0x401df0` 用 `mov w1,#0x1000; mov w4,#0x1` → C2H payload = 0x1000（新舊 header 相同），
  並寫 `+0x38/0x3c/0x40/0x44` = DB_C2H_TYPE/ID/LEN/CODE、RMW `+0x30` DB_C2H_SEQ。
- 暫存器面與現行 header 逐一对應（0x1c/0x20/0x24/0x28/0x2c/0x48/0x10/0x14/0x30/0x34），
  `db_valid@0x401d10` 要求 `[base+0]==0x53434442` 且 `[base+4]==1` ⇒ 基底確為 mailbox header(+0=DB_MAGIC)，
  偏移非「另一層 base」；mmap 長度 0x2000（`0x400824`、munmap `0x401908`），0x400+3072 正好止於 0x1000，
  與 0x1000 的 C2H 視窗零重疊——結構上也只允許 0x400。
- app code（0x400340–0x402400）內 `db_payload` 呼叫點僅此三處，`#0x800` 立即數 **0 筆**；
  且無現行 `qpcie_debugd mailbox ABI h2c=0x800 c2h=0x1000` banner 字串（僅 `Debug mailbox ready (exec %s, shell %s)`）。

**判定：ConfirmedMismatch（高可信度）。** 已燒 image 的 daemon 讀 H2C 命令文字於 mailbox 內部偏移 **0x400**，
已安裝 host 客戶端寫 **0x800**（§4 已證），兩者永不同窗；§3 的「0x800=PING / 0x1000=0」因此只是錯位的旁證，
stale-reply／payload 被覆寫等替代解釋已不再是必要假設（但仍無須重作動態交易）。本節僅離線讀 binary 與既有证据目錄，
**未做新的動態交易、未重建、未補 daemon、未燒錄、未動卡**。

## 9. 動態確證：既有 compat400 客戶端恰一次 echo 成功（2026-11-12T02:52–02:55Z）
本節**不是唯讀**：一次有意的 mailbox 交易（HOST_EPOCH/HOST_BEAT/H2C 正常協定更新）。
未手動清 slot、未重試、未換工具輪掃、未 reboot、未補檔、未動 symlink/預設客戶端。
證據目錄 `build/current-mailbox-diagnosis-20261112T024025Z/run-025213Z/`（README-run.md 有完整命令/rc/時間）。

- 測前：卡端空闲（無 qpcie/sc7f0ctl/vcud/debugd/capture 行程、`fuser` 空、refcnt 0），H2C SEQ==ACK==4（無 pending），
  殘留仍是 C2H 4/3、0x800="PING"、0x400=0 —— 與 §2/§3 完全一致（未過期，當下復核）。
- **恰一次** `/home/rd/sc7f0ctl_compat400 --timeout 10 echo SC7F0_ABI400_TEST` → **rc=0，9 ms**，
  stdout 17 bytes + `\n`，與輸入**逐 byte 相同**，stderr 空。事後 H2C **5/5**、C2H **4/4（協定內自行清掉舊 4/3）**、
  H2C_LEN=C2H_LEN=0x11、**0x400="SC7F…"（命令與回覆）**、0x1000 同文字，而 **0x800 仍是舊 "PING" 未被讀**。
  CARD_EPOCH 未變（debugd 未重啟）、heartbeat 1:1、TIMEOUT_MS 變 10000（即本次 `--timeout 10`）。
- 同客戶端兩個無副作用 exec：`uname -r` → `6.1.30-xilinx-v2023.2`（rc=0）；
  `cat /proc/sys/kernel/random/boot_id` → **`b8a77c32-483a-400b-8771-ae392ab3cbe4`**（rc=0）→ PS 端通道可用。
- host `hdmi_status`（一次）：維持 **`Status: No Locked Timing`**，未變好也未變壞。
- 預設 0x800 客戶端**未重測**（其 ABI 已由 §4 證明與已燒 daemon 不同窗，重測無新資訊）。

### 9.1 改址是「碼已改、板上仍是舊 binary」（精準對照，見 README-run.md 表）
`include/qpcie_debug.h` 的 `DB_H2C_DATA` 只在兩次 commit 變動：dc202ee（2026-10-15）建為 **0x400**／DB_PAYLOAD 3072；
**3588f89（2026-11-09T20:43:59+08:00，VCU race 修復的附帶改動）改為 0x800／2048**，commit 本體明載理由：
避免 H2C 視窗與 BAR0+0x2200 的共享 VCU host ring（block 0x200..0x43F）重疊，舊寫法會用命令文字踩到 ring slot 7..15。
已燒 image.ub 內 debugd 的兩個 read 呼叫點仍是 `mov w1,#0x400` 且長度上限 0xc00=3072 ⇒ **改址前的標頭建置**；
已安裝 host 客戶端為 0x800。`test_app/sc7f0ctl_compat400.c` 為 `#undef DB_H2C_DATA / #define 0x400 / #include "sc7f0ctl.c"`，
與預設客戶端的**全程式反組譯只差一條寫入點（`mov $0x800→$0x400` 與同站點 `add`）**，其餘逐 bytes 相同（含 C2H 0x1000）：
**更正 §「control」舊述——compat400 不是 dual-window，也沒有 ABI 協商或 legacy fallback**，其剩餘 `$0x800` 是 `DB_PAYLOAD=2048` 的長度檢查。
`driver/qpcie_debug.c:54-58` 同時放行 0x400 與 0x800 兩個視窗（731c599 加入），故載入的 kernel 模組不是瓶頸。
**未查（不猜）**：26111101 為何收進改址前的 debugd。

### 9.2 分層判定
**PCIe debug transport 可用**（PS daemon 可 attach／回覆／執行），故障層是「更新包內 debugd（H2C 0x400，pre-3588f89）」與
「預設 host 客戶端（0x800，post-3588f89）」的 **ABI 常數不一致**；這是**層級判定，不是整體影像驗收通過**：
板卡影像仍屬舊 debugd，且 HDMI 仍無 lock。修正方向＝以同一來源重建「標頭／debugd／service／host 客戶端」一致的完整包，
非改 symlink、非拿已知缺 runtime 的舊包重燒。本次未做任何修復動作。
