# SC7F0 HDMI 未壓縮擷取＋VCU 編碼雙路計劃書

**版本：討論稿 v2，2026-10-27。已按討論確認Vivado雙路分流與變長碼流DMA方向；尚未修改設計／建置／部署。**

## 1. MCU 結論：正常，停止測試

本輪只做一次基本唯讀確認，結果：

- MCU **v1.1.15 / 0x1262010F**，管理介面及 IT6663 回應正常。
- MCU telemetry：SCDT locked、HDMI mode、3840×2160，溫度讀值58°C。
- PS 官方 HDMI RX：**3840×2160p60、RGB 8-bit、4PPC、594MHz、8ch LPCM**；三條 link quality 均 excellent。
- `qpcie-debugd`、`qpcie-hdmi-daemon`、`qpcie-upgrade-daemon`、`sc7f0-ps-watchdog` 均 active。

就目前使用所需的基本功能，MCU 正常；**依使用者要求停止 MCU 測試，不升級 v16/v17 候選。**
既有 MCU WIP／離線報告留存，不再作為 VCU 專案的阻塞條件或新增工作。
沒有重新抓流、故障注入、MCU flash 或任何 reboot。

## 2. 本次目標與邊界

同一 HDMI 輸入，同時提供兩條資料路徑：

1. **A：HDMI → PL → PCIe → host RAM → 現有 V4L2／ALSA**。
2. **B：HDMI → PL 寫入 PS DDR → VCU 硬體編碼 → PS DDR → PL PCIe DMA → host RAM**。

A 保留現有低延遲未壓縮擷取；B 在卡上編碼，host 不做軟體視訊編碼。
「raw」在本文表示未經 H.264/H.265 壓縮；NV12 的色彩取樣轉換不等於 RGB bit-exact 無損。

VCU 是 **ZU4EV 的硬體 codec，由 PS Linux 控制**，不是讓 A53 軟體跑 x264/x265。
PS DDR 只加入 B 路；不能為了編碼而把現有 A 路改成必經 PS DDR。

### 建議第一版範圍（待討論）

| 項目 | 建議 |
|---|---|
| 共同來源／最終目標 | 目前已使用的3840×2160p60 |
| 同時工作的 A 路 | 先以NV12M 4K60完成並行；原有RGB24／NV16M單路功能保留 |
| B 路輸入 | NV12，8-bit，4:2:0，BT.709；色彩range與encoder VUI一致 |
| B 路編碼 | **HEVC/H.265先做**；如相容性優先可改H.264，不一開始同做兩套驗收 |
| 初始參數 | 50Mbps作可調試起點、GOP約1秒、無B-frame；不是畫質／峰值碼率保證 |
| host輸出 | 第二個V4L2 compressed capture節點，HEVC或H264；裝置號不硬寫死成`/dev/video1` |
| 首要用途 | A路預覽／擷取，同時B路錄下可解碼的elementary stream；容器封裝可由host現有工具處理 |
| 音訊 | 現有HDMI Front L/R → host ALSA不變；第一版不另做PS AAC encoder |

**暫不納入**：MCU升級、TX loopout、HDR／10-bit／4:2:2編碼、超低延遲slice模式、
AAC／SRT／RTMP、通用故障自癒、所有raw格式同時搭配所有codec的排列組合。
若RGB24／NV16M也必須從第一版與編碼同時運作，需在討論時明確加入範圍，不能悄悄刪除需求。

## 3. 實際基線：不是只開一個 encoder plugin

受控基線是已部署、已驗證的 **PL26102702／PS watchdog R2／Git2bce1d8**。
本輪另外確認了MCU與官方RX即時狀態，沒有重做既有A/V驗收。

| 已有 | 仍需新增／確認 |
|---|---|
| HDMI RX/VPHY、4PPC／150MHz capture、RGB/NV12/NV16與host PCIe擷取 | 獨立PS DDR capture路徑及其buffer ownership |
| host ALSA PCM、已通過的thin-ring競態修正 | VCU IP、clock/reset、AXI ports、IRQ、完整軟體堆疊 |
| PS V4L2/media bridge綁定HDMI subdevice | 現有bridge不是PS video framebuffer capture device |
| host→PS DDR升級H2C及單筆DDR readback | 不能當成已完成的PS DDR→host連續compressed C2H通道 |
| PetaLinux2023.2 layer已有VCU recipes | recipes存在不等於映像已安裝、driver已probe或編碼已可用 |

`vcu.dtsi` 現在主要只有refclk節點，VCU／encoder／decoder設定為註解；
目前建置腳本也沒有接通新需求所需的VCU／framebuffer資料路徑。
必須修改PL設計及匹配XSA／PS映像，不能只在現有bitstream上安裝GStreamer套件解決。

## 4. 建議架構

```text
HDMI → IT6663 → PL HDMI RX / VPHY
                      │ 4PPC / capture clock domain
              frame-aware、可獨立丟幀的分流
                 ┌────┴──────────────────────┐
                 │ A                         │ B
       現有RGB/NV12/NV16擷取             CSC / 4:2:0處理
                 │                      Frame Write DMA
           現有PCIe C2H                      │ AXI HP
                 │                        PS DDR NV12 pool
       host RAM / 現有V4L2                    │ shared DMA buffers
                                             VCU encoder
                                                 │
                                         PS DDR encoded buffers
                                                 │
                                  PS encoder agent → 小型staging pool
                                                 │ PL burst reader
                                         專用compressed C2H queue
                                                 │ PCIe
                                      host RAM / 第二個V4L2 capture

HDMI audio → 現有PCM／PCIe／host ALSA，維持原路徑
```

### 4.1 分流：B 路不能拖停 A 路

不直接使用「兩個sink都READY才接受資料」的阻塞式AXIS broadcaster。
HDMI不能無限反壓；VCU停止、PS buffer滿或host停收時，B路必須可在frame邊界停止／丟棄輸入，
A路及HDMI idle draining繼續工作。

- 每路獨立enable、buffer credit、frame valid/drop計數。
- B路中途overflow的frame作廢，不能把半張畫面送進VCU；未完成AXI transaction仍須正確收尾。
- 停A路不能連帶停B路，停B路也不能造成A路STREAMOFF／DMA卡死。
- NV12色彩處理／line buffer優先共享或重用，不能無條件複製一套大型buffer。

### 4.2 PS DDR capture 與 VCU

優先評估 `v_frmbuf_wr`＋Xilinx DMA/V4L2 capture；必須有正確的CSC／chroma subsampling，
不假設frame writer會自動把RGB轉NV12。若資源不容許，評估重用native NV12 packer加小型AXI writer，
並明確比較新增driver工作量。

- PS capture buffers透過Linux DMA API管理；capture→VCU優先共享DMA-BUF，避免CPU搬全幅4K frame。
- 是否可直接import，依2023.2實際VCU allocator／GStreamer stack確認，不把「零拷貝」當未證實前提。
- 初期估6張NV12 input約74.65MB；另須加VCU reference/reconstruction、alignment及bitstream buffers。
  CMA可先評估256–512MiB範圍，但須依實際需求決定，不能與Linux／升級reserved-memory重疊。
- HP0既有upgrade/readback保留。可評估HP1提供capture write＋小碼流read，HP2/HP3提供VCU encoder；
  最終port、AXI width／clock及QoS依實際VCU master interfaces與DDR budget確定，不把所有流量塞進現有100MHz port。

軟體沿用本地2023.2 recipes：`kernel-module-vcu`、`vcu-firmware`、`libvcu-xlnx`、
`libomxil-xlnx`、Xilinx `gstreamer1.0-omx`。以實際可用的 `omxh265enc`／`omxh264enc`為準，
不先假設VCU是通用V4L2 M2M encoder。plugin名稱及properties於核准後確認。

### 4.3 PS encoded buffer → PCIe → host

這是新資料通道，不經SSH／debug exec／eMMC檔案搬運當作成品。

第一版接受：PS端把低碼率compressed AU copy一次到bridge-owned DMA-coherent staging pool，
再由PL讀取並C2H DMA至host。50Mbps只有6.25MB/s，可先換取簡單、可控的ownership；
不先花時間做VCU輸出allocator到PCIe的全程zero-copy。

- 新增獨立byte-stream descriptor／completion queue，重用可用的PCIe TLP/RQ／SG基礎，
  不是把舊2D video engine直接宣稱成可用的PS DDR碼流DMA。
- PS DMA地址、host DMA地址及CPU虛擬地址是三種不同概念；各自走DMA API、正確cache／memory barrier。
- descriptors先完整寫妥才publish；payload完成後才送completion／IRQ，保留epoch防止舊buffer重播。
- AU長度可變，不假定一個I-frame等於平均碼率／固定128KiB；處理SG、4KiB邊界與非4-byte尾端，
  不能讓PCIe padding污染NAL stream。
- raw／audio保持優先或有界延遲；compressed有獨立queue，不得永久餓死或搶占現有資料面。

### 4.3.1 新DMA是變長packet通道，不是固定大小video-frame DMA

使用者已明確要求：HDMI RX AXIS分兩路，另設 **PS DDR→PCIe→host** 通道傳VCU產生的視訊碼流
（不是Vivado `.bit` 檔）。DMA不依賴width×height／固定frame size。

第一版建議一個packet對應一個完整access unit；同時保留AU_START／AU_END供fragment，
codec configuration與EOS也是有明確flags的獨立packet。AU／packet／PCIe TLP是三種不同邊界。

PS producer descriptor的64-byte候選格式如下，尚未凍結ABI：

| 欄位 | 大小 | 語意 |
|---|---:|---|
| `src_dma_addr` | 64bit | PS staging buffer的DMA地址 |
| `payload_bytes` | 32bit | 實際有效bytes，與buffer capacity分開 |
| `stream_id`, `flags` | 16+16bit | AU起迄、keyframe、codec config、PTS/DTS valid、discontinuity、EOS |
| `packet_sequence` | 64bit | 傳輸順序／遺失檢查 |
| `source_frame_id` | 64bit | 共同HDMI來源frame；config／EOS可標無有效frame |
| `pts`, `dts` | 64+64bit | 保留來源時間；無B-frame初版仍預留DTS |
| `duration` | 32bit | 來源timebase單位，無效時有對應標示 |
| `timebase_num`, `timebase_den` | 32+32bit | 時間刻度定義，不假設PS與host共用monotonic起點 |
| `stream_epoch` | 32bit | stream重啟／flush後的新世代 |

Host另外提供destination SGL／capacity／cookie queue；不能讓PS producer任意指定host DMA地址。
硬體同時取得完整PS packet與host buffer ownership後才開始讀／寫。
Completion回報cookie、actual bytes、sequence／timestamp／flags與error；**metadata與NAL payload分開**，
不把私有header或alignment padding混入可解碼碼流。

兩路在HDMI RX SOF處共用frame_id／capture timestamp；PS capture把該時間交給encoder input，
輸出繼承PTS。不能改用encode完成／DMA完成時間冒充採集時間。
需處理大I-frame、host buffer不足、PS buffer生命週期、AXI/TLP/SG分段、尾端byte enable及payload-before-completion。
這些是此DMA的基本功能，不另延伸成MCU或通用故障注入工作。

### 4.4 host 介面、PTS 與一般停收

第二個V4L2 capture node提供標準HEVC／H264壓縮格式，不改現有raw node語意。
初版由一個PS encoder agent及一個host capture工具串起；不另維護多套公開char-device／網路協議。

最小控制：codec、解析度／fps、bitrate、GOP、start/stop／request-IDR及狀態。
最小metadata：source frame ID、PTS/timebase、AU length、keyframe、sequence／epoch、discontinuity。
使用parser確保AU邊界，不能假定每個任意encoder buffer都是完整frame。

- 無B-frame先簡化reordering；兩路共同來源不表示完成時間相同，VCU本來就增加buffer／codec latency。
- 保留來源PTS；PS monotonic不能直接冒充host monotonic。初版錄製可用來源相對PTS，
  host V4L2 timestamp須有正確clock-domain轉換／標示；與現有ALSA的精密A/V對齊另行確認。
- host暫停接收時先限制queue並反壓PS編碼流程，必要時丟B路**尚未送入encoder**的完整frame。
  若已壓縮AU不得不丟棄，標示discontinuity並以新IDR＋VPS/SPS/PPS恢復，不能隨意丟reference frame後繼續裝正常。
- 初版不為encoder process故障新增整卡reset依賴；沿用既有PS watchdog，不停監控、不做MCU恢復工程。

## 5. 首要風險與容量預算

### 5.1 PL資源是第一個決策點

26102702凍結的placed utilization／routed timing：

- **BRAM127/128（99.22%）**。
- LUT75754/87840（86.24%），register111901/175680（63.70%），DSP82/728。
- WNS **+0.076ns**、WHS+0.010ns；setup餘量很小。

VCU雖是hard codec，新增frame writer、互連、CDC/FIFO及可選encoder buffer仍會吃fabric資源。
M0先提出實際BRAM回收表：未用legacy／診斷buffer、合理FIFO深度、可轉LUTRAM的small memories、共享line buffer。
不以刪除既有RGB/NV12/NV16或audio功能來偷偷過關；不可無條件啟用大型on-chip encoder buffer。

已對與凍結bit SHA相同的implementation目錄，唯讀開啟routed DCP取得實際階層報告：

| 階層／用途 | 等效BRAM36 tiles |
|---|---:|
| 自訂DMA top（合計） | 78.5 |
| └ SG host-fetch四個table FIFO | 21 |
| └ PS AXI ILA（4096 samples） | 19.5 |
| └ 四個video request CDC FIFO | 16 |
| └ DMA top其餘audio／loopback／SGL CDC／mailbox等 | 22 |
| PCIe IP內建buffer | 22 |
| HDMI RX subsystem | 8 |
| Video TPG | 6 |
| HDMI RX video CDC | 4 |
| PL HDMI TX subsystem＋video/audio bridge | 8.5 |
| **總計（不重複加DMA子項）** | **127** |

不是VCU用光：目前VCU cell使用數是0。**URAM也是0/48，仍有48個可用。**
第一優先可將ILA減深或在production profile關閉；完全關閉時可回收等效19.5 BRAM36，
其餘邏輯的等效用量為107.5，實際packing／時序仍須新build確認。

SG table FIFO是單clock且大，值得評估轉URAM，但要適配read latency／握手；
不能任意縮深，現有設計刻意緩存完整4K SGL以避免prefetch／consumer互等死鎖。
跨clock FIFO亦不能直接改成UltraRAM。TX／TPG如本版不需要可另討論裁剪，不默默刪除。
完整明細與證據見 [BRAM盤點](sc7f0_bram_breakdown_26102702.md)。
本地VCU1.2 IP有可選 `ENC_BUFFER_EN`；其配置及額外DDR流量要一起評估。

**若資源／時序不夠，先回到討論，不直接進入多輪盲目full build，也不私自降規。**

### 5.2 頻寬：先算已知下限，不捏造安全餘量

以下為3840×2160p60 active payload，十進位單位，不含stride／協議開銷：

| 資料 | 每秒payload |
|---|---:|
| NV12 | 746.496MB/s |
| NV16 | 995.328MB/s |
| RGB24 | 1492.992MB/s |
| HEVC/H264 50Mbps例子 | 6.25MB/s平均；I-frame峰值另計 |
| raw NV12＋50Mbps碼流經PCIe | 約752.746MB/s＋PCIe／metadata開銷 |

B路DDR至少有capture write＋encoder input read，NV12已約**1.493GB/s**，
還沒算VCU reference/reconstruction／motion search／bitstream與CPU staging。
不再沿用舊規劃「固定3.8GB/s、有效DDR14GB/s、CPU3%」作既成事實。
DDR實際clock／bus width／容量須核對凍結XSA、FSBL與實板設定，再量測可用頻寬。
PCIe目前是Gen3 x4，但總吞吐不代表各AXI port／FIFO沒有局部瓶頸。

## 6. 實施里程碑——全部待討論同意後才啟動

| 階段 | 工作與交付 | 足夠通過的標準 |
|---|---|---|
| M0：可行性／介面定案 | BRAM回收／clock／DDR port表、VCU2023.2依賴、首版格式及descriptor/PTS定義 | 有可信資源預算及明確範圍；不足就回報，不先燒板 |
| M1：必要硬體＋PS capture | 一個新候選整合分流、NV12 frame write、VCU及碼流DMA接口；匹配XSA／DT／rootfs | PS拿到真實NV12 frame，內容與frame rate正確，A路未被改壞 |
| M2：卡端硬體encode | 先用PS合成畫面短測VCU，再接HDMI；PS本地輸出短碼流 | 確認真正VCU在編碼，產物可decode，非軟體fallback |
| M3：碼流PCIe輸出 | PS agent、compressed C2H、host第二V4L2 node及錄製工具 | host bytes與PS碼流相符，可decode，PTS／sequence完整 |
| M4：雙路同時 | raw NV12＋VCU HEVC同時；一般start/stop／停收處理 | 下述最小驗收通過即可交付，不延伸MCU／極端故障研究 |

M1之後盡量用同一候選硬體分段啟用與檢查，不為每個小步驟重燒一次。
工期先不做不可靠承諾；M0確認資源回收成本後再估，不讓未知BRAM缺口被藏在日期裡。

### 受控變更與部署

- 同意後，從 `2bce1d8` 用乾淨branch/worktree開始，**不把未驗收MCU WIP／其大套測試隱含帶入VCU release**。
- 可能修改：HDMI/PS BD與top、capture分流／memory writer、compressed reader／C2H、CSR生成器、
  PS capture／encoder agent、host V4L2、VCU kernel/rootfs／DTS配置。
- 新版本、新output、匹配bit/XSA/PS image與host module；保留現有26102702回復包。
- 沿用VERIFY→備份→COMMIT→eMMC SHA讀回→真正PS reboot確認；不重啟x86，不更新MCU。
- 需要部署時才停capture；保持必要PS服務／watchdog。備份仍是人工回復資產，不宣稱自動A/B。

## 7. 最小驗收，不再無限擴張

1. PS capture一張真實NV12畫面＋短時間frame count，確認不是TPG／舊buffer。
2. VCU一段短碼流可decode，確認硬體encoder實際工作。
3. PCIe傳輸前後的碼流bytes／hash一致，含變長AU與大I-frame。
4. **raw＋encoded同時10分鐘**：已知60Hz來源，startup外接近60fps；記錄兩路frame count、PTS、DMA errors/drop與解碼結果。
   正常負載目標DMA errors/drop0，GUI render drop獨立列出，不拿GUI drop假裝DMA失敗或反之。
5. A/B各做一次一般stop/start；encoded consumer暫停／恢復一次，A路不得停住，B路可正確重同步。
6. 原有RGB24／NV16M及ALSA各做基本smoke regression，不重跑MCU故障矩陣。

不要求100次reset、拔電、SDA/SCL故障、disabled-MMIO hang、天級燒機或通用自癒才算第一版完成。
也不要求「零CPU、零延遲」這種不實際承諾。

## 8. 本輪討論需要決定的三件事

1. **Codec**：先HEVC/H.265（建議）還是H.264？4K60／8-bit NV12／50Mbps作初始目標是否可接受？
2. **並行raw格式**：第一版先NV12M＋encoder，還是RGB24／NV16M也必須同時支援？後者影響BRAM共享與工作量。
3. **成品形式**：第一版先host收到可decode的video碼流＋現有ALSA，還是必須同步交付帶聲音MP4／live preview？
   若要求後者，把clock mapping／mux及A/V驗收明確加入，而不是事後默認已完成。

**在這三點及架構討論完成前，不改RTL／driver／映像、不跑新build、不部署。**

## 9. 來源與舊規劃界線

- `docs/sc7f0_system_architecture.md`、`docs/sc7f0_audio_26102702_validation.md`。
- `build/sc7f0-audio-doorbell-26102702-r1/fpga/` 的utilization／timing。
- `rtl/h2c_ps_ddr_writer.v`、`rtl/custom_pcie_dma_top.v` 的 `zu4ev_ddr_readback`：目前upgrade／readback用途。
- `scripts/create_zu4ev_ps_bd.tcl`、`scripts/build_zu4ev.tcl`、`scripts/build_sc7f0_hdmi_08.tcl`。
- `petalinux/.../device-tree/files/vcu.dtsi` 與本地2023.2 VCU／OMX recipes。
- 本地Vivado2023.2 `vcu_v1_2/component.xml`：encoder／decoder與可選encoder buffer參數。
- AMD PG252 General Design Guidelines／Encoder Buffer作後續設計參考；本輪portal直取僅回JS loader，
  未把搜尋摘要的數字當成已查核的本板性能或2023.2配置。

舊 `docs/sc7f0_multiphase_hdmi_plan.md` 是歷史願景稿，含NUC100、QSPI、固定DDR/CPU餘量、阻塞broadcaster、
零延遲／零host負載等不適合作目前實作依據的內容；**本討論稿優先，舊稿不作完成證據。**
