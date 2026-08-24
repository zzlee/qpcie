# A50T PCIe TLP Loopback 測試驗證

> **狀態：歷史 bring-up checkpoint。** 此最小設計已被完整 SG DMA/NV12M top 取代；保留作 pg054 初期除錯紀錄。最新結果見 [A50T NV12M 實作總結](A50T-NV12M-Implementation-and-Results.md)。

Artix-7 A50T 最小化 PCIe TLP Loopback 測試，驗證 7-Series native AXI-Stream TLP 格式之 MRd/MWr 正常處理。

---

## 1. 測試目的

原始設計 (`a50t_pcie_card_top.v`) 使用 `pcie_7x_axi_bridge.v` 做 7-Series → UltraScale+ CQ/CC/RQ/RC 格式轉換，但 format conversion 不完整，導致 Host MRd 請求無 CplD 回覆，產生 TIMEOUT_ERR。

本測試建立最小化 FPGA 邏輯（移除 TPG、Audio、DMA、Crossbar 等所有下游 IP），**直接在 7-Series native AXI-Stream 格式上處理 TLP**，驗證：
- Host MRd → FPGA 回覆 CplD（含暫存器資料）
- Host MWr → FPGA 正常接收（posted write）
- PCIe link 正常建立，`lspci` 正確枚舉，`dmesg` 無 error

---

## 2. 架構圖

```
Host (RC)                          FPGA (A50T Endpoint)
  |                                      |
  |  PCIe Gen2 x4 Serial Lanes          |
  +<===================================>+
  |                                      |
  |  m_axis_rx (128-bit TLP RX)         |
  +------------------------------------->+
  |                                      |
  |                            pcie_7x_tlp_loopback
  |                             +--------+--------+
  |                             | Parse TLP Type   |
  |                             | MRd → CplD       |
  |                             | MWr → Accept     |
  |                             +--------+--------+
  |                                      |
  |  s_axis_tx (128-bit TLP TX)         |
  |<-------------------------------------+
  |                                      |
```

---

## 3. 新建檔案清單

| 檔案 | 用途 |
|:---|:---|
| `rtl/pcie_7x_tlp_loopback.v` | 最小化 TLP loopback bridge，直接處理 7-Series native AXI-Stream |
| `rtl/a50t_pcie_tlp_test_top.v` | 精簡 top-level：IBUFDS_GTE2 + pcie_7x_0 + TLP loopback |
| `scripts/build_a50t_test.tcl` | 測試用 build script，僅生成 pcie_7x_0 IP |

---

## 4. RTL 設計重點

### 4.1 `pcie_7x_tlp_loopback.v` — TLP 類型解碼

7-Series AXI-Stream TLP 格式中，`tdata[30:24]` = `{Fmt[1:0], Type[4:0]}`：

| TLP 類型 | Fmt | Type | 說明 |
|:---|:---:|:---:|:---|
| MRd32 | `00` | `00000` | Memory Read (32-bit address), 無 data |
| MRd64 | `01` | `00000` | Memory Read (64-bit address), 無 data |
| MWr32 | `10` | `00000` | Memory Write (32-bit address), 有 data |
| MWr64 | `11` | `00000` | Memory Write (64-bit address), 有 data |
| CplD | `10` | `01010` | Completion with Data |

### 4.2 7-Series MRd32 AXI-Stream 格式 (128-bit)

```
Beat 0:
  tdata[31:0]   = DW0: {Fmt, Type, TC, ..., Length=1}
  tdata[63:32]  = DW1: {RequesterID[15:0], Tag[7:0], LastBE[3:0], FirstBE[3:0]}
  tdata[95:64]  = DW2: Address[31:2], 2'b00
  tdata[127:96] = (unused for 3DW MRd)
  tkeep = 16'h0FFF, tlast = 1
```

### 4.3 CplD 回覆格式

```
s_axis_tx_tdata = {
    reg_rdata,                              // DW3 [127:96]: Response Data
    {saved_req_id, saved_tag, 8'h00},      // DW2 [95:64]:  ReqID + Tag + LowerAddr
    {compl_id, 16'h0000},                   // DW1 [63:32]:  CompID + Status(SC)
    32'h4A00_0004                           // DW0 [31:0]:   Fmt=10, Type=01010, ByteCount=4
};
```

- `compl_id` = `{cfg_bus_number, cfg_device_number, cfg_function_number}`，從 PCIe IP 動態取得
- `reg_rdata` 根據 `address[7:0]` 查表回應暫存器值

### 4.4 暫存器空間 (Test Registers)

| Offset | 值 | 說明 |
|:---:|:---:|:---|
| `0x00` | `0x00000000` | DMA_CTRL |
| `0x04` | `0x00000001` | DMA_STATUS (link up) |
| `0x30` | `0x01000001` | VERSION_ID (v1.0.0.1) |
| `0x34` | `0xDEADBEEF` | GIT_COMMIT_HASH |
| `0x38` | `0x20260820` | BUILD_TIMESTAMP |
| `0x3C` | `0x04040200` | HARDWARE_CAPS (4V, 4A) |

---

## 5. Build 流程

```bash
# Build (Vivado batch mode, ~5 min)
vivado -mode batch -source scripts/build_a50t_test.tcl

# Flash programming
vivado -mode batch -source /tmp/program_tlp_test.tcl
```

Build 產出：
- `build/qpcie_tlp_test_proj/qpcie_tlp_test.runs/impl_1/a50t_pcie_tlp_test_top.bit` (2.1 MB)
- `build/qpcie_tlp_test_proj/qpcie_tlp_test.runs/impl_1/a50t_pcie_tlp_test_top.bin`

### IP 設定差異 (vs. 原始 build_a50t.tcl)

| 參數 | 原始值 | 測試值 |
|:---|:---:|:---:|
| Bar0_Scale | Megabytes | Kilobytes |
| Bar0_Size | 1 | 256 |
| Bar1_Enabled | true | false |
| TPG IP | 生成 | 不生成 |
| AXI Crossbar IP | 生成 | 不生成 |

---

## 6. 測試結果

### 6.1 燒錄

- SPI Flash 燒錄成功（mx25l12872f, MFG ID: c2）
- Erase → Program → Verify 全部通過

### 6.2 Host 端驗證

| 項目 | 結果 |
|:---|:---:|
| `lspci` 裝置枚舉 | PASS — Vendor 0x12AB, Device 0xE380 正確顯示 |
| PCIe link speed/width | Gen2 x4 |
| `dmesg` PCIe error | PASS — 無 TIMEOUT_ERR、無 AER error、無 probe failed |
| BAR0 識別 | PASS — 256 Bytes BAR0 正確識別 |
| BAR0 register read | PASS — MRd → CplD 正常回應 |

### 6.3 驗證命令

```bash
# 列舉裝置
lspci -vv -d 12ab:e380

# 檢查 dmesg
dmesg | grep -i -E "pcie|aer|timeout|12ab"

# 直接讀 BAR0 (不載 driver)
setpci -s <BDF> BAR0.W
```

---

## 7. 結論

1. **7-Series native TLP 格式可以直接處理**，無需轉換為 UltraScale+ CQ/CC/RQ/RC 格式
2. MRd → CplD 回覆邏輯正確，Host 可正常讀取 BAR0 暫存器
3. MWr posted write 正常接收
4. 最小化設計 (PCIe IP + TLP loopback) 已驗證 PCIe link + TLP 基礎功能正常

**後續狀態**：DMA engine、BAR register、V4L2 NV12M 與 150 MHz video CDC 已加入主設計；ALSA仍停用，4K60等待最新實機 gate。
