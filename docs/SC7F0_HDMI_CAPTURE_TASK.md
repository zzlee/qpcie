# SC7F0 HDMI 採集卡：任務定義與完成標準

更新日期：2026-10-20

## 1. 我要完成的是什麼

將 **YUAN SC7F0 N1 HDMI2 V11（Zynq UltraScale+ ZU4EV）** 做成一張能在 Linux
主機正常使用的 PCIe HDMI 採集卡。

使用者接上外部 HDMI 訊號後，卡端必須能以正確的 Xilinx 官方驅動初始化接收器、
辨識真實輸入訊號，將影像經 FPGA 與 PCIe DMA 傳到 host。Host 應能查詢輸入狀態、
解析度與色彩資訊，並透過標準 V4L2 介面開始或停止採集。

**完成的意思不是「有 driver」、「能編譯」或「TPG 有畫面」，而是整條真實 HDMI
採集路徑已在板卡上驗證，且建置、更新、安裝與測試流程可以重現。**

## 2. 系統分工

### 影像資料路徑

```text
外部 HDMI 訊號
  → 板載 IT6663／MCU 初始化的輸入路徑
  → Xilinx Video PHY
  → Xilinx HDMI RX Subsystem
  → FPGA capture／像素處理／跨時鐘域 FIFO
  → PCIe C2H DMA
  → Host 記憶體
  → Host V4L2 capture device
  → 擷取、儲存或預覽應用程式
```

### 控制與狀態路徑

```text
卡端 PetaLinux：官方 RX／PHY driver + V4L2 bridge／capture 控制整合
  → 卡端應用程式取得真實 timing／format／事件
  → 定義清楚的共享暫存器與通知協定
  → Host driver／工具讀取與顯示

Host V4L2 STREAMON／STREAMOFF
  → Host driver
  → FPGA capture gate／DMA 控制
  → 實際狀態與錯誤回報
```

本設計的影像主要送到 host，而非先擷取到 PS DDR。因此卡端必須補上的是與實際
PCIe capture pipeline 相符的整合層，不是為了讓 RX driver 綁定而虛構一個本地 DMA
或沒有資料路徑的 `/dev/videoX`。

## 3. 必須交付的功能

### A. 官方 HDMI RX／PHY 驅動正常運作

- 使用與實際 FPGA IP 世代、版本相符的 Xilinx 官方 driver。
  目前 HDMI RX SS 3.2／Video PHY 2.2 對應 HDMI 2.0 `hdmi-modules`；
  不可只改 compatible 就強迫使用另一代 HDMI 2.1 driver。
- 補齊 Device Tree 的位址、clock、IRQ、PHY lanes、PPC 與其他 IP 參數。
- 確認 PS 能控制 IP，RX／PHY IRQ 確實送達 Linux 並得到處理。
- 釐清 MCU、IT6663、EDID、HPD、DDC、PHY clock 與 reset 的初始化順序。
- 驗證接線、拔線及輸入時序改變時，官方 driver 的狀態與事件正確。

### B. 補齊可用的 capture pipeline

- 讓官方 HDMI RX subdevice 與卡端 V4L2 master／bridge 正確綁定，
  必要時建立對應實際硬體的 media topology。
- 核對 RX AXI-Stream 輸出與 capture engine 需要的像素排列、PPC、色彩格式、
  SOF、EOL、stride 與 frame geometry。
- 驗證跨時鐘域 FIFO、backpressure、overflow、丟幀與 reset 行為。
- 取得的影像必須與宣告的 V4L2 format 相符；不能只改 format 名稱而沒有相應轉換。
- 保留 TPG 作為回歸及診斷來源，但必須能明確區分 TPG 和真實 HDMI。

### C. 設計暫存器與卡端應用程式，將資訊傳到 host

定義一套雙方一致、可辨識版本的 ABI，至少能表示：

- 實體連線、接收器偵測狀態，以及目前哪些資訊有效。
- 輸入寬高、pixel clock、完整 timing 與 progressive／interlaced 狀態。
- 可由官方 driver 可靠取得的色彩資訊；未知資訊必須標示未知。
- 目前來源、capture／DMA 實際運行狀態，以及必要的錯誤、overflow／drop 計數。
- 卡端服務存活與資料新鮮度，避免 daemon 死亡後 host 仍顯示舊訊號。

卡端應用程式負責讀取 driver 的實測結果與事件，再發布給 host。
Host driver／工具負責一致地讀取、判斷有效性並顯示或通知應用程式。

協定必須避免讀到更新一半的多欄位資料，清楚區分讀寫權限、硬體狀態與軟體遙測。
若有 mailbox 命令，必須有成功、失敗、完成確認與 timeout，不能收到命令就假回成功。

### D. Host 能控制 STREAMON／STREAMOFF

- 以 Host V4L2 `VIDIOC_STREAMON`／`VIDIOC_STREAMOFF` 作為主要入口，
  不讓一般 app 直接寫 BAR0 與 kernel driver 搶控制權。
- STREAMON 前檢查來源、輸入有效性、geometry、format 與 buffers 是否就緒。
- 啟動時對齊完整 frame，避免第一幀從中間開始。
- STREAMOFF 必須停止新工作，確認在途 DMA 已安全結束或經可靠機制中止，
  再把 buffers 交還使用者，避免停止後仍寫入已重用的記憶體。
- 支援重複啟停；遇到拔線、改解析度或錯誤時，應安全停止或通知 host 重新配置。
- 區分「接收器仍在偵測訊號」和「正在向 host 採集」。官方 RX 的 `s_stream()`
  若是 no-op，就不能靠這個呼叫宣稱已關閉 capture／DMA。

## 4. 建置與部署也屬於任務的一部分

### 建置

1. 使用 Vivado 2023.2，修改 RTL／BD／IP 時依專案規範更新 `C_VERSION`。
2. 完成 synthesis、implementation、timing／CDC／DRC 檢查，不能只看 exit code。
3. 匯出配對 XSA，透過專案既有 **Make + Docker `petalinux`** 流程建置 PetaLinux。
4. 確認 BOOT.BIN、kernel／rootfs、Device Tree、卡端 modules／daemon
   都對應同一份硬體候選版本，記錄來源與 SHA-256。
5. 不混用 SD installer 和 eMMC production 映像；不因方便而覆寫既有可用版本。

### 部署到實機

1. 連線 `rd@sc7f0-test.local`，確認 PCIe 裝置、原 firmware、driver 與系統狀態。
2. 保存原 driver、工具與可回復映像；於測試機編譯配對其 kernel 的新 driver。
3. 使用 PCIe 升級工具先傳送並 VERIFY，通過後才 COMMIT。
4. 確認寫入成功，再進行必要的板卡重啟、PCIe 重新列舉與 driver 安裝／綁定。
5. 不重啟 host；不在結果不明時盲目重送燒錄命令。

使用者已要求執行上述部署與測試；這份文件不是新增的繞過驗證授權。
候選版本若未通過建置或安全檢查，應先修正，而不是為了繼續測試而強行燒錄。

## 5. 實機驗收標準

| 驗收項目 | 完成標準 |
| --- | --- |
| 啟動與 PCIe | 板卡正常開機，host 讀到預期版本，PCIe 維持預期鏈路，無新增異常 |
| 官方 driver | RX／PHY probe、IRQ、必要的時鐘與初始化流程均有實測證據 |
| 輸入偵測 | 有訊號、無訊號、拔插與時序變更的回報符合真實狀態 |
| 遙測 | Host 讀到真實且一致的 timing／format；失鎖、服務停止時不保留假有效資料 |
| 真實畫面 | 實體 HDMI 可透過 V4L2 擷取、儲存及預覽，尺寸、stride、色彩與幀邊界正確 |
| 串流控制 | STREAMON／OFF 可重複操作，停止後不再寫入已交還的 buffers |
| 模式改變 | 拔線、重新接線、改解析度或不支援格式時，不會卡死或以舊設定破壞記憶體 |
| 回歸 | 原有 TPG、PCIe debug 與升級能力仍可用 |
| 可重現性 | 另一位接手者能依紀錄重建、部署並重跑測試 |

4K 輸入／採集是既有 bring-up 的重要驗證目標；實際可宣告支援的解析度、幀率及
pixel format，必須逐項測試後列出。不預先宣稱所有 HDMI 模式或色彩格式都已支援。
單張截圖或 TPG 測試不足以證明持續的真實 HDMI 採集與啟停功能正常。

## 6. 必須留下的紀錄

- 建置工具／Docker image、來源版本與未提交修改的辨識資料。
- 每一步命令、退出碼、log 路徑、候選映像與 driver 的 checksums。
- 燒錄前後的 firmware version、PCIe link／AER、driver 與服務狀態。
- 各測試的輸入條件、預期值、實測值、擷取樣本與 PASS／FAIL／BLOCKED 結果。
- 失敗原因、修正內容、重跑結果，以及恢復舊版本的方式。

實際執行紀錄放在：
[`sc7f0_hdmi06_validation_log.md`](sc7f0_hdmi06_validation_log.md)。
這份任務定義不取代執行紀錄，也不把規劃中的步驟寫成已完成。

## 7. 目前進度與下一步

截至本次整理：

- 已確認測試機可透過 SSH 連線，sudo 與 host kernel headers 可用。
- 已讀回板卡版本 `0x26101905`、PCIe Gen3 x4、upgrade IDLE 與 debug READY。
- 已補上候選 HDMI06 的 RX／PHY DT、IRQ 與 HPD 接管，並做過 BD／DTS 檢查。
- 官方 HDMI 2.0 模組與 bridge 曾對現有 ARM64 kernel artifacts 編譯通過；
  不代表已完成配對新映像的正式建置或實機 probe。
- HDMI06 synthesis 程序已結束，但 log 仍有 **2 個 critical warnings**：
  top-level 的 `ps_hpm1_arid` 重複宣告。因此目前不是可部署的建置結果。
- 尚未執行本次候選版本的燒錄、板卡重啟或 driver 更換。
- 遙測 ABI、完整 host reader、capture 控制與端到端 STREAMON／OFF 驗收仍待完成。

接下來先修正 synthesis 警告並重新驗證，再推進 implementation／配對映像建置。
最終以實機端到端驗收判斷任務是否完成，不以軟體或 FPGA 任一層的局部成功代替。

## 8. 本輪範圍

重點是 **HDMI 視訊採集、輸入資訊上報、host 串流控制，以及可重現部署測試**。
HDMI TX 播放、完整音訊功能、HDCP、所有模式相容性與量產級自動復原，不因硬體
具有相關 IP 就視為本輪已完成；若需要，應另列需求與驗收項目。
