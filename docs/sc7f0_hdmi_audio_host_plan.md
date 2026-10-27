# SC7F0 HDMI Audio → Host ALSA → GStreamer A/V 規劃

日期：2026-10-22。此文件是 code / read-only hardware inspection 後的實作計畫，
**本輪尚未修改音訊 RTL、驅動、燒錄或播放聲音**。

## 目標與不變項

```text
HDMI source
  ├─ Video → FPGA RGB→NV12 → PCIe C2H → host RAM/V4L2
  │                                       → GStreamer → Wayland 4K fullscreen
  └─ Audio → HDMI RX audio AXIS → LPCM unpack/channel alignment
             → PCIe C2H → host RAM/ALSA PCM → GStreamer → desktop audio output
```

- 保留已驗收 `0x26102204`、NV12/NV16/RGB 與 TPG；保留 4K NV12 原生大小、全螢幕，
  video 分支不加 `videoconvert` / `videoscale`。
- PS 只負責 RX/VPHY 控制、格式／鎖定狀態發布與升級；音訊也不先錄到 PS DDR。
- 初版推薦：**LPCM stereo、48 kHz、S32_LE（有效24位，對齊定義明確）**。
  先量測確認實際輸入，不能只因工具能開48k就宣告來源是48k。
- 首輪不做 AC3/DTS/IEC61937 壓縮直通、8ch、動態任意格式轉換。44.1/96k及多聲道
  在第一版 stereo 驗收後擴充；不支援的格式明確拒絕，不假裝PCM或輸出隨機雜音。
- 不重啟 x86。任何新 bitstream 仍需模擬、resource/DRC、routed timing / skew gates，
  沿用三支 build/package/flash scripts 與 rollback。

## 目前程式與硬體實況

### 已有可復用基礎

| 節點 | 檔案／現況 |
|---|---|
| RX SS 音訊輸出 | `rtl/zu4ev_pcie_card_top.v`：AUDIO_OUT tdata/tvalid/tready 已接線 |
| RX bridge | `rtl/hdmi_rx_audio_bridge.v`：32bit FIFO，格式 telemetry 保持0（未知），沒有硬編48k假量測 |
| Audio DMA | `rtl/audio_stream_engine.v`：4個32bit字打成16byte MWr，host circular ring、period IRQ、write pointer |
| C2H arbiter | `rtl/custom_pcie_dma_top.v`：視訊與音訊共用PCIe TX，現為 SG→video→audio 固定優先序 |
| ALSA | `driver/qpcie_alsa.c`：canonical ADEV0 `0x0500..0x05ff`，capture DMA/IRQ已存在 |
| 診斷程式 | `test_app/alsa_test_app.c`：刻意把 raw bits[27:4] 解成24bit PCM，證實目前不是一般S32 PCM |

實機 read-only 檢查：

- Host 是 x86，ALSA card ID **QPCIeAudio0**、device0 capture 已存在；名稱為
  `QPCIe AES3 Subframe PCM`。不能把 card 存在當成 HDMI PCM 已打通。
- PS 經 `sc7f0ctl exec` 查到 RX 音訊資訊：L-PCM、2ch、ACR N=5824、CTS約563063。
  這只是 RX 狀態，尚未驗證實際 sample payload、位深、LR順序或精確取樣率。
- RX 的 `s_axis_audio_aclk` 和 bridge 兩端實際都接 **PCIe125MHz**；bridge 注解的
  250MHz不可照抄。先核對 AXIS 時脈／協議，再決定是否保留不必要的 async FIFO。
- 當前 BRAM **127.5/128**，不可以直接再加大型 audio FIFO。
- 目前4K NV12 fullscreen service `sc7f0-nv12-4k-preview` 持續渲染，read-only調查未停止它；
  video drops仍0。
- Host 有 USB Audio 及 PCH HDMI playback 裝置；最終需固定實際桌面輸出。
  `pactl` 目前未安裝，不能把後續測試腳本建立在它一定存在的假設上。

### 優先問題／必查風險

1. **Raw AES3 不等於 ALSA S32_LE。** 現有 engine 原樣DMA含 preamble/V/U/C/parity 的
   subframe；ALSA卻廣告S32/S24。直接接 `alsasrc ! audioconvert ! sink` 有錯音風險。
2. **TID 被丟棄。** RX `AUDIO_OUT_tid()` 目前未接。需核對 Xilinx 真實 audio AXIS
   的 TID/聲道編碼、preamble、payload、validity/channel-status，不能僅假設L/R交替。
3. **來源綁 video。** 音訊 mux 用 `ch0_use_tpg`（video CTRL source）；audio-only capture
   或 video source/STREAMON/OFF 可能影響 audio。需要獨立來源與生命週期。
4. **Idle / STOP 沒有完整 live drain 策略。** HDMI不能永遠背壓；音訊關閉時要丟棄即時
   資料，下一次從完整L/R frame開始，不能播放FIFO積存的舊聲音。
5. **公平性不能只看平均頻寬。** Stereo48k S32僅384000B/s，遠小於4K NV12的
   746496000B/s，但固定優先序仍需量測最長等待／壓力模擬，必要時做packet-level
   bounded audio service；不能中斷已取得ownership的MWr。
6. **ALSA 約束過寬。** 現廣告2..8ch、48/96k、S24/S32，而 `hw_params` 尚未驗證來源或
   儲存格式；XRUN只記log/清旗標。需只宣告真實支援並正確回報失鎖/XRUN。
7. **A/V timestamp 尚未共時基。** V4L2目前在completion使用 `ktime_get_ns()`；engine
   descriptor timestamp也不是逐SOF即時sample。audio有block PTS但未形成完整host
   sample-counter/clock mapping。單一 GstPipeline 不會自動修正擷取端延遲差與長期漂移。

## Phase 0：建立可證明的音訊基線

不改bitstream前先保留04、host module與影像證據。

- 對照 vendor RX IP wrapper／driver／audio AXIS 文件與實際輸出：TID/preamble、
  16/24bit sample擺放、有效bit、PCM/non-PCM、channel map、block restart。
- 從 channel-status / ACR + 正確 TMDS reference 解出格式，與有效sample計數交叉核對；
  注意4K60 TMDS clock ratio，不用錯誤148.5MHz直接套ACR公式。
- 若使用現有raw capture作診斷，先確認它不會重設video，存raw並離線解析；
  **不直接拿raw播放到喇叭**，不能把TPG當HDMI。
- 發布音訊 lock、format-valid、rate/channels/bits/PCM、heartbeat；未知值保持未知。
- 測試素材：已知左右聲道不同頻率／脈衝，後續A/V使用同源flash+beep素材。

**Gate：** 有真實HDMI sample／LR／格式的證據；不能只有Audio InfoFrame或ALSA open成功。

## Phase 1：FPGA 標準PCM資料路徑

主要檔案：`hdmi_rx_audio_bridge.v`、`audio_stream_engine.v`、
`zu4ev_pcie_card_top.v`、`custom_pcie_dma_top.v`、CSR/telemetry定義。

- 依Phase0實證加入PCM adapter：移除傳輸標頭，處理符號、validity、LR／TID，
  輸出標準 interleaved L/R S32_LE。有效24bit放在32bit container高24位，低8位補0；
  對16bit來源依實證格式正確擴展，測試負值與滿刻度。不要把S24_LE低位對齊與S32高位對齊混淆。
- HDMI與TPG/RAW診斷明確選擇；音訊來源獨立於video CTRL。Streaming期間禁止來源改變。
- Idle持續drain；start重新對齊完整stereo frame；source失鎖／格式改變時清楚回報、
  丟棄partial frame，不能無聲切TPG或保留舊資料。
- 重用現有audio DMA/FIFO，優先在bridge內解碼或重排，保留BRAM上限；若需TID/狀態
  跨FIFO，重新計算width/depth，不能盲目把512×32加寬突破剩餘資源。
- 核對period IRQ對應的是已提交DMA資料；STOP等待in-flight MWr退休，禁止
  buffer釋放後仍寫DMA。audio/video reset與STREAMON/OFF互不破壞。
- 加可讀取 sticky overflow、drop、framing/invalid、sample/frame counter、FIFO peak、
  maximum arbitration wait；避免把單cycle pulse當成可可靠讀取的錯誤統計。
- 模擬audio與4K NV12/NV16/RGB競爭；必要時加入有界公平仲裁。

**Gate：** byte-exact PCM、LR/sign/rounding、stalls、ring wrap、period、reset、
STOP/restart、sample gap、video saturated traffic回歸；無frame/samples錯置，video既有測試全通過。

## Phase 2：Host ALSA 正規PCM介面

主要檔案：`driver/qpcie_alsa.c`、`driver/qpcie_driver.h`、必要IRQ/telemetry支援。

推薦先**新增標準HDMI PCM capture device**，保留既有device0 raw診斷／TPG相容性；
例如同一卡的device1（實作後以`arecord -l`確認）。這不是復活legacy audio channel1
的碰撞暫存器：DMA仍使用canonical ADEV0。兩個PCM device若共用engine，互斥open/prepare，
第二個要求回EBUSY，不允許同時控制同一ring。

- Stable ALSA card ID，使用 `hw:CARD=QPCIeAudio0,DEV=<PCM_DEVICE>`，不寫死card0。
- 初版只廣告確認支援的2ch/48k/S32_LE；沒有lock、non-PCM、rate/channel不符時清楚拒絕。
- 格式／sample counter／position一致，period與buffer的frame/byte邊界正確；
  pointer/IRQ wrap不造成重複period，STOP不做全卡reset。
- ALSA XRUN／失鎖向userspace回報，保護substream生命週期與IRQ並行，不能只有dmesg。
- 新介面直接提供真正PCM，讓 `alsasrc` 不需要自製AES3解碼plugin。

**Gate：** 先 `arecord`錄PCM/WAV，驗證取樣數、LR頻譜/幅度/符號、無preamble殘留與
沒有夾雜TPG；起停20次與至少10分鐘capture無XRUN。測audio-only、video-only、並行，
包括停止其中一個不影響另一個。

## Phase 3：單一 GStreamer A/V renderer

新增預計腳本：`scripts/sc7f0_av_preview.py`，保留現有video-only工具作回歸。
同一個 GstPipeline 的兩個 live source、共用base time／明確clock policy；不要啟動
兩條互不相干的gst-launch後就宣稱同步。

示意（**不是現版04可直接播放的指令**；PCM device及輸出sink實作/核對後才填入）：

```text
v4l2src device=/dev/video0 io-mode=mmap [force HDMI, pacer off]
 ! video/x-raw,format=NV12,width=3840,height=2160,framerate=60/1
 ! queue [bounded]
 ! waylandsink fullscreen=true sync=true

alsasrc device=hw:CARD=QPCIeAudio0,DEV=<HDMI_PCM_DEVICE>
        provide-clock=false slave-method=resample
 ! audio/x-raw,format=S32LE,layout=interleaved,rate=48000,channels=2
 ! queue [bounded]
 ! audioconvert ! audioresample
 ! <explicit desktop audio sink> sync=true
```

- Video固定4K→4K NV12，不做CPU影像縮放／色彩轉換。
- Audio可用CPU做必要的sample format/rate轉換；擷取仍由FPGA→PCIe DMA完成。
- 先確認桌面sink plugin/實際輸出；可經PipeWire/Pulse服務播放，或確認獨占條件後
  使用獨立ALSA playback硬體，不能誤選QPCIe capture或monitor回授。
- 目前video preview `sync=false` 是低延遲video-only設定，合併A/V要改 `sync=true`。
- 明確選擇並記錄pipeline實際master clock。擷取HDMI與USB/PC輸出可能有ppm差，
  需驗證source slaving/adaptive resampling。單純放一顆 `audioresample` 不代表漂移已解決。
- 捕捉GST bus ERROR/QOS/LATENCY/NEW_CLOCK，輸出rendered frame、audio sample數、
  queue/latency、XRUN/drop資料；啟動成功或PLAYING不是驗收。

## Phase 4：A/V同步與恢復驗收

分開報告兩個里程碑：**可看可聽**，以及**同步與長時間穩定**。

1. 同源flash+beep素材量測A/V offset與10分鐘以上漂移，建議初始目標絕對偏移≤50ms、
   10分鐘相對變化≤20ms；這是預定驗收門檻，不是目前已達成的數字。
2. 起初用host monotonic + latency calibration建立可量測基線；若達不到門檻，再將
   video實際SOF與audio首sample/sample-counter對應到共同FPGA timestamp，經host↔card
   時基映射輸出一致PTS。不能把descriptor-launch時間或period-IRQ抵達時間當sample時間。
3. 至少10分鐘4K60 NV12+audio同時render；再做30分鐘穩定測試：audio無XRUN、video
   DMA overflow/drop0，GUI QOS/drop與硬體drop分開記錄。
4. 無音訊、mute、HDMI拔插、格式改變、兩source不同起停順序、consumer變慢、
   STOP/START、卡端reboot後恢復；不播放失效/舊buffer、不掛死、不需要重啟x86。
5. 回歸NV16/RGB、TPG以及三支build/package/flash。保留04 rollback及native NV12預覽。

## 實施順序與交付物

1. 確認Phase0 payload格式，決定最小PCM adapter／telemetry ABI。
2. RTL+unit/stress tests，ALSA新PCM node與約束，再做bitstream/resource/timing gates。
3. 使用下一個未被占用的 `C_VERSION`（實作時核對，避免與使用者重跑26102205撞版）。
4. 沿用3 scripts產生含三個boot files+manifest的strict package；VERIFY→COMMIT→卡端POR，
   matched driver與SHA讀回，不重啟x86。
5. 先audio capture內容驗證，再單一GStreamer A/V管線與同步驗收。
6. 交付音訊驗證工具、A/V preview script、實測報告／waveform或頻譜證據、同步量測、
   執行指令、對應build/package/flash產物及rollback。

目前僅完成盤點與規劃；不把既有RX的LPCM/2ch資訊或ALSA節點視為音訊實測成功。
