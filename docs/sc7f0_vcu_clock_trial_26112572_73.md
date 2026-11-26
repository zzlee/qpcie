# SC7F0 VCU 時鐘實驗結案：26112572 / 26112573（2026-11-26）

**保留 PL 26112419 / PS 26112501。** 72 在 IP 階段被否決，沒有板測；73 經手動 SD 路徑實際測試，再經 PCIe 回退。73 的 AVC 吞吐未改善。這是成對時鐘點比較，不能把差異單獨歸因於 core，也不是量產認證。

| 設定／MHz | 19/01 原版 | 72 | 73 |
|---|---:|---:|---:|
| `CONFIG.CORE_CLK` / `MCU_CLK` | 667 / 預設 444 | 712 / 預設 444 | 708 / 明設 354 |
| RPLL /45 → PL1_REF | 33.330 | 同左 | 同左 |
| VCU PLL 倍率；post、core、MCU 除數 | 80；2、2、3 | 85；2、2、3 | 85；2、2、4 |
| core / MCU 有效時鐘 | 666.600 / 444.400 | 708.263 / **472.175**（推算） | 708.262500 / 354.131250 |

19、73 為 Linux clk_summary，非示波器實測。舊 consumer 先 ref、MCU、再 core，最後一項可重調共同 parent，MCU 超出 444；另測 32 MHz 請求實得 31.911705，不能假設精確 32。73 僅接受 33,330,000 Hz、cold-reset profile；provider 發布前關閉並核對四個預設開啟的 gates，consumer 在 gates 關閉時設定兩葉、鎖定 rate 並讀回，再使能；不對活動 PLL 改頻。21 個故障注入及拒絕錯誤 gate/ref/XCI 的 stub 測試通過，不代替實機驗證。

### 離線重現（全新工作目錄）

1. PL 複製 `build/rgb-vcu-uram-26112419/src`，以該 build 的 `SOURCE.sha256` 核對原始碼。改 `scripts/create_zu4ev_ps_bd.tcl` 中 VCU 1.2 的兩項屬性如表；encoder on / decoder off、PLL_BYPASS=0、PLL_CLK=33.333333、AXI_ENC/MCU=300/300、depth=11168、buffer=349 KiB 不變。工具 Vivado/Vitis/PetaLinux 2023.2，器件 xczu4ev-fbvb900-2-e。
2. 以如下環境執行 `vivado -mode batch -source scripts/build_zu4ev.tcl`（兩個輸出路徑替換為新工作目錄）：

```sh
export SC7F0_BUILD_DATE=20261125
export SC7F0_ENABLE_VCU=1
export SC7F0_GIT_HASH=E53C4C31
export SC7F0_PHYS_OPT_DIRECTIVE=AggressiveExplore
export SC7F0_PLACE_DIRECTIVE=Explore
export SC7F0_POST_ROUTE_PHYS_OPT=AggressiveExplore
export SC7F0_PROFILE=rgb_compositor
export SC7F0_PROJECT_DIR=${OUT}/fpga/proj
export SC7F0_RGB_COMPOSITOR=1
export SC7F0_ROUTE_DIRECTIVE=Explore
export SC7F0_VERSION=26112573
export SC7F0_XSA_OUT=${OUT}/fpga/hardware.xsa
```

3. 使用最後 routed checkpoint 比較 timing、CDC、reset 與記憶體；正式 gate exit=1，沿用 19 的十條具名診斷，**沒有** build.ok/package.ok。診斷用匯出含 bit 的 XSA，比對內嵌 bit，匯入 PS 並比對 HDF/DT workspace XSA。PS/host 基底 `b1135828502412417b148a3d7aed6658d14cc964`，VCU module upstream `689c8d823b383e2a8a5249be49de627f866cfaf2`。下附相對此 PS/host 基底的完整 meta-user 與 host 原始碼差異，含兩份 BitBake patch、recipe、PS identity 及 exact-pin KMS 測試；只用於離線重現。用匹配 XSA 建置 petalinux-image-minimal（歷史 4628 tasks 成功），以匹配 FSBL/PMU/ATF/U-Boot/bit 產 BOOT.BIN；驗證 package manifest、FIT 內服務及兩個 clock module。host 使用 7.0.0-43-generic headers 並啟用 KMS。

| routed 指標 | 19 | 73 |
|---|---:|---:|
| LUT / FF | 85075 / 135721 | 85130 / 135700 |
| BRAM tiles / URAM / DSP | 122.5 / 20 / 87 | 同左（VCU 自身 12 URAM、0 BRAM） |
| WNS / WHS / min bus skew (ns) | +0.013 / +0.010 / +1.719 | +0.002 / +0.007 / +1.317 |
| 完成 routing 的 nets | 209192/209192 | 208968/208968 |

兩者 routing errors=0；73 無新增 critical CDC endpoint；單一 ownership reset final FF 到 scheduler 與 1,633 ingress endpoints，不能豁免正式 gate。DS925 的 712 是 DCI 4K 列，非 UHD 3840×2160 認證；PG252 不建議 PS PLL 作 ref。V11 標稱 VCCINT_VCU 0.9 V，未量測 rail/jitter。Si5341 OUT8 300 MHz /8 的獨立最小設計 route 9/9、DRC 0：37.5 MHz ×75 /2 再 /2、/4 = 703.125/351.5625；未整合、未上卡。/9 wizard 依假設輸入 jitter 得 126.270–138.164 ps，不能證明端點 <100 ps。

### 上卡與回退：分開記錄兩條路徑

* SD：以獨立手動 SD kit 進入 73，冷啟 kernel 記錄 ref 33330000、M85、兩葉符合；boot mode 讀值 0x6 / 0x666。另行備妥 19/01 救援：保留 historical installer 開機三檔，accepted-26112501/ 內才是目標三檔；無 target_emmc 自動重分割標誌。手動辨識 SD/MMC、驗 SHA、只換既有 eMMC FAT p1 三檔、重新唯讀掛載驗 SHA；救援 kit 本身離線驗證，不把下面 PCIe 成功算作 SD 回退實測。
* PCIe：修正 installer 的 PL/PS 配對及 KMS 流程後，從 73 回 19/01，非 PS-only。完整配對套件 VERIFY 到 0x05、一次 COMMIT 到 0x04，前後讀回三 SHA；PS boot ID `346cc271-8d5c-4529-9e49-333585b7794d` → `da510c3c-b678-4aea-ba5d-c4cc4c7fc82d`，x86 boot ID 不變，MCU runtime restart 一次；FLASH_PASS，KMS flip、HDMI lock、HEVC CBR 40/40，323/323 frames 解碼。此為實測單向回退，不宣稱 19→73 曾由 PCIe 寫入。installer 工作樹及 31 tests 與本實驗分開保留。

### 相同工作負載的有效重疊窗口

HDMI 3840×2160、AVC CBR 40/40、raw + DRM；以單調時鐘取交集，依實體來源 ID 計缺幀，計數與全程 decode 分列。來源並非已證實逐幀相同的 replay。

| 指標 | 73 | 回退 19/01 |
|---|---:|---:|
| 重疊秒 / 影格 / fps | 180.576 / 10398 / 57.583 | 180.588 / 10608 / 58.742 |
| 重疊缺幀 / 比例 | 438 / 4.042% | 228 / 2.104% |
| 全程缺幀 / 解碼數 / Mbps | 474 / 10815 / 37.141 | 235 / 11063 / 39.189 |
| raw 幀 / gap；DRM ACK | 11520 / 0；27 | 11520 / 0；27 |
| pool full 次數 / 累計 ms | 759 / 1165.392 | 508 / 544.463 |
| AMS 20/7/8 全程峰值 °C（各 39 次取樣） | 73.907 / 70.378 / 70.643 | 87.849 / 83.326 / 83.932 |

兩次 HDMI 持續 lock，PTS/DQ 無逆序，AER 無變化；皆未達無缺幀門檻。兩葉同時改變，起始溫度也不同（20 通道 66.772 vs 83.932 °C），環溫、風量、接面峰值與長期穩定度未控制，不推論功耗或熱優勢。既有 packaged 19/01 長測 AVC 606.987 s、58.753 fps、缺 754；HEVC + ball 60.007 fps、缺 0。

### SHA-256（歷史檔案身分）

原版 19/01：

```text
e925d9d9188c57875361dd0b00912c6af4199df3dc4bc7a8ea9d38810144a2cf  upgrade-26112501.tar
70378bcd48f4e254d6cb2861920c8c3f6c9a817477570d85432625d4a9ede7ee  host-driver-src.tar.gz
30637d0346077cf8667506ffd56e48f3f3116ba1b843365b1b933401bcb86e6e  host-tools-src.tar.gz
3851cdc9c4b9ca43de20c7fe59a970f6c2fab44af10968a726eb264bb245c06b  images/BOOT.BIN
0eb4e17d3cb1c8e893038964336f13d7a18577e139b15aab422ae357e32a9287  images/image.ub
14c14ececc4b35eb6ac10253f06a0f3dad10b7750d7283a7892676288df3bad6  images/boot.scr
7509397654d5ba8a00ea8b1c9ca7ff9a845afab391fca0f72cb467b0b13f23b3  fpga/hardware.xsa
4d7b869d119287b12b5691431a9084cc6974f2573155c50b64ff682cb3e2e7e2  fpga/zu4ev_pcie_card_top.bit
92edee1c53af9134f0ff1089bf6ed006a93be0ea5d3e3d594a95d4809a287c91  LAB-ONLY.md
854b88ac56120b17ddd1e1b7a1ca517f97c533a8fbe5c4d6c89f505eaf77b2a3  PL_VERSION
6fb06e399ec3e37ee57712eec9a756df5955acbebeb8167733dac4fe3005808b  VERSION
f486b477dcba08340f49bbd2289383d1ec2af76d01f7a9c6c35b3fb269d2d0e3  release.json
```

候選 73（routed bit SHA-256 `d4e087a7628484d553ac16f2ede228ef001a183bb94d7619ecfeb57566b1d1f3`）：

```text
199cfcad2ab712d26908fd9aeb65e23d6da7a8206e04989949af6659242f1f5c  upgrade-26112573.tar
67d78b2d63e8c50aa3960f0a9c6181e7a9d67a1506c9d2db279ce1264c60c7e6  host-driver-src.tar.gz
30637d0346077cf8667506ffd56e48f3f3116ba1b843365b1b933401bcb86e6e  host-tools-src.tar.gz
24d83c6cd95cab2d1731c53fd55fbc8c251cedfd0cadcc216af504163c1722b9  images/BOOT.BIN
d5b79309d7c334466dc4581158f1b2e903db2fcc4ba83139933d9bd5b3d6cd75  images/image.ub
14c14ececc4b35eb6ac10253f06a0f3dad10b7750d7283a7892676288df3bad6  images/boot.scr
c9d9d6edf377210e9db2493a0917f2807f7b4a480eeae4418e3946b3d98eb8c3  ../fpga/offline-26112573.xsa
```

手動 SD 與候選 host：

```text
84b24ccbcbe43628fc48c92441cf3f5e5374c8daf80f3432a691ecd7be6eb2a2  candidate/SC7F0-manual-SD-26112573-NOT-FOR-FLASH.tar
af2ee96420d6710b3ad0bad1395dd58441c28cb0a348b2c791056eb39f33ce99  rollback/SC7F0-manual-SD-26112501-PL19.tar
c9d1080ed5d9f71ebe43dfc99e7aa1c229f0d97bd681908b05860f9f74c98bc1  host/qpcie.ko
67d78b2d63e8c50aa3960f0a9c6181e7a9d67a1506c9d2db279ce1264c60c7e6  host/host-driver-src.tar.gz
```

### 73 診斷差異（從 code block 原樣取出可用 `git apply`）

```diff
--- a/petalinux/qpcie-zu4ev/project-spec/meta-user/recipes-apps/sc7f0-vcud/files/sc7f0-ps-release
+++ b/petalinux/qpcie-zu4ev/project-spec/meta-user/recipes-apps/sc7f0-vcud/files/sc7f0-ps-release
@@ -1 +1 @@
-26112501
+26112573
--- a/petalinux/qpcie-zu4ev/project-spec/meta-user/recipes-multimedia/vcu/kernel-module-vcu_%.bbappend
+++ b/petalinux/qpcie-zu4ev/project-spec/meta-user/recipes-multimedia/vcu/kernel-module-vcu_%.bbappend
@@ -1,2 +1,3 @@
 SRCREV = "689c8d823b383e2a8a5249be49de627f866cfaf2"
-
+FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
+SRC_URI:append = " file://0001-sc7f0-paired-gated-encoder-clocks.patch"
--- /dev/null
+++ b/petalinux/qpcie-zu4ev/project-spec/meta-user/recipes-multimedia/vcu/files/0001-sc7f0-paired-gated-encoder-clocks.patch
@@ -0,0 +1,239 @@
+--- a/common/xil_clk.c
++++ b/common/xil_clk.c
+@@ -1,136 +1,126 @@
+ // SPDX-License-Identifier: GPL-2.0
+-/*
+- * Xilinx vcu clock consumer driver
+- *
+- * Copyright (C) 2021 Xilinx, Inc.
+- *
+- * Author: Rohit Visavalia <rohit.visavalia@xilinx.com>
+- *
+- * This file is used to set the encoder and decoder clk.
+- * it acts as a clk consumer for xilinx VCU.
++/* SC7F0 26112573 encoder-only lab point. Based on Xilinx 2023.2.
++ * Program and lock both branches while ALL codec leaves are gated.
++ * No reference retune; never run one branch while programming the other.
+  */
+ #include <linux/version.h>
+ #if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 15, 0)
+ #include <linux/io.h>
+-#include <linux/uaccess.h>
+-#include <linux/mfd/syscon/xlnx-vcu.h>
+-#include <linux/regmap.h>
++#include <linux/bitfield.h>
+ #include <linux/clk.h>
+-
++#include <linux/regmap.h>
++#include <linux/mfd/syscon/xlnx-vcu.h>
+ #include "al_codec.h"
+ 
+-#define VCU_PLL_CLK                     0x34
+-#define VCU_PLL_CLK_DEC                 0x64
+-#define VCU_MCU_CLK                     0x24
+-#define VCU_CORE_CLK                    0x28
+-#define MHZ                             1000000
+-#define FRAC                            100
++#define PLAN_REF 33330000UL
++#define PLAN_PLL (PLAN_REF * 85UL)
++#define PLAN_CORE (PLAN_PLL / 4)
++#define PLAN_MCU (PLAN_PLL / 8)
+ 
+-int xil_clk_set_up(struct platform_device *pdev, struct al5_codec_desc *codec,
+-		   const char *core_clk, const char *mcu_clk)
++static bool all_off(struct xvcu_device *v)
+ {
+-	u32 refclk, coreclk, mcuclk, inte, deci;
+-	int err;
+-	struct xvcu_device *xvcu_core = dev_get_drvdata(pdev->dev.parent);
++	unsigned int off;
++	for (off = 0x30; off <= 0x3c; off += 4)
++		if (readl(v->vcu_slcr_ba + off) & BIT(12))
++			return false;
++	return true;
++}
+ 
+-	codec->logicore_reg_ba = xvcu_core->logicore_reg_ba;
++static bool settings_match(struct xvcu_device *v)
++{
++	static const unsigned int expected[][2] = {
++		{VCU_ECODER_ENABLE, 1}, {VCU_DECODER_ENABLE, 0},
++		{VCU_CORE_CLK, 708}, {VCU_MCU_CLK, 354},
++		{VCU_PLL_BYPASS, 0}, {VCU_PLL_CLK, 33}, {VCU_PLL_CLK_DEC, 32},
++	};
++	unsigned int i, val;
++	for (i = 0; i < ARRAY_SIZE(expected); i++)
++		if (regmap_read(v->logicore_reg_ba, expected[i][0], &val) ||
++		    val != expected[i][1])
++			return false;
++	return true;
++}
+ 
+-	codec->pll_ref = devm_clk_get(pdev->dev.parent, "pll_ref");
+-	if (IS_ERR(codec->pll_ref)) {
+-		if (PTR_ERR(codec->pll_ref) != -EPROBE_DEFER)
+-			dev_err(&pdev->dev, "Could not get pll_ref clock\n");
+-		return PTR_ERR(codec->pll_ref);
+-	}
+-
+-	codec->core_clk = devm_clk_get(pdev->dev.parent, core_clk);
+-	if (IS_ERR(codec->core_clk)) {
+-		if (PTR_ERR(codec->core_clk) != -EPROBE_DEFER)
+-			dev_err(&pdev->dev, "Could not get core clock\n");
+-		return PTR_ERR(codec->core_clk);
+-	}
+-
+-	codec->mcu_clk = devm_clk_get(pdev->dev.parent, mcu_clk);
+-	if (IS_ERR(codec->mcu_clk)) {
+-		if (PTR_ERR(codec->mcu_clk) != -EPROBE_DEFER)
+-			dev_err(&pdev->dev, "Could not get mcu clock\n");
+-		return PTR_ERR(codec->mcu_clk);
+-	}
+-
+-	regmap_read(codec->logicore_reg_ba, VCU_PLL_CLK, &inte);
+-	regmap_read(codec->logicore_reg_ba, VCU_PLL_CLK_DEC, &deci);
+-	regmap_read(codec->logicore_reg_ba, VCU_CORE_CLK, &coreclk);
+-	regmap_read(codec->logicore_reg_ba, VCU_MCU_CLK, &mcuclk);
++static void unlock(void *p) { clk_rate_exclusive_put(p); }
++static void disable(void *p) { clk_disable_unprepare(p); }
+ 
+-	if (!mcuclk || !coreclk) {
+-		dev_err(&pdev->dev, "Invalid mcu and core clock data\n");
+-		return -EINVAL;
+-	}
++static int pin(struct device *dev, struct clk *c)
++{
++	int ret = clk_rate_exclusive_get(c);
++	return ret ?: devm_add_action_or_reset(dev, unlock, c);
++}
+ 
+-	refclk = (inte * MHZ) + (deci * (MHZ / FRAC));
+-	coreclk *= MHZ;
+-	mcuclk *= MHZ;
+-	dev_dbg(&pdev->dev, "Ref clock from logicoreIP is %uHz\n", refclk);
+-	dev_dbg(&pdev->dev, "Core clock from logicoreIP is %uHz\n", coreclk);
+-	dev_dbg(&pdev->dev, "Mcu clock from logicoreIP is %uHz\n", mcuclk);
+-
+-	err = clk_set_rate(codec->pll_ref, refclk);
+-	if (err)
+-		dev_warn(&pdev->dev, "failed to set logicoreIP refclk rate %d\n"
+-			 , err);
+-
+-	err = clk_prepare_enable(codec->pll_ref);
+-	if (err) {
+-		dev_err(&pdev->dev, "failed to enable pll_ref clk source %d\n",
+-			err);
+-		return err;
+-	}
+-
+-	err = clk_set_rate(codec->mcu_clk, mcuclk);
+-	if (err)
+-		dev_warn(&pdev->dev, "failed to set logicoreIP mcu clk rate "
+-			 "%d\n", err);
+-
+-	err = clk_prepare_enable(codec->mcu_clk);
+-	if (err) {
+-		dev_err(&pdev->dev, "failed to enable mcu %d\n", err);
+-		goto error_mcu;
+-	}
+-
+-	err = clk_set_rate(codec->core_clk, coreclk);
+-	if (err)
+-		dev_warn(&pdev->dev, "failed to set logicoreIP core clk rate "
+-			 "%d\n", err);
+-
+-	err = clk_prepare_enable(codec->core_clk);
+-	if (err) {
+-		dev_err(&pdev->dev, "failed to enable core %d\n", err);
+-		goto error_core;
+-	}
+-	return 0;
++static int turn_on(struct device *dev, struct clk *c)
++{
++	int ret = clk_prepare_enable(c);
++	return ret ?: devm_add_action_or_reset(dev, disable, c);
++}
+ 
+-error_core:
+-	clk_disable_unprepare(codec->mcu_clk);
+-error_mcu:
+-	clk_disable_unprepare(codec->pll_ref);
++int xil_clk_set_up(struct platform_device *pdev, struct al5_codec_desc *codec,
++		   const char *core_clk, const char *mcu_clk)
++{
++	struct device *dev = &pdev->dev;
++	struct xvcu_device *v = dev_get_drvdata(dev->parent);
++	u32 pll, core, mcu;
++	int err;
+ 
++	if (!v || !settings_match(v) || strcmp(core_clk, "vcu_core_enc") ||
++	    strcmp(mcu_clk, "vcu_mcu_enc"))
++		return -EINVAL;
++	codec->logicore_reg_ba = v->logicore_reg_ba;
++	/* Get parent DT clocks, tie references to this probe's lifetime. */
++	codec->pll_ref = devm_get_clk_from_child(dev, dev->parent->of_node, "pll_ref");
++	codec->core_clk = devm_get_clk_from_child(dev, dev->parent->of_node, core_clk);
++	codec->mcu_clk = devm_get_clk_from_child(dev, dev->parent->of_node, mcu_clk);
++	if (IS_ERR(codec->pll_ref)) return PTR_ERR(codec->pll_ref);
++	if (IS_ERR(codec->core_clk)) return PTR_ERR(codec->core_clk);
++	if (IS_ERR(codec->mcu_clk)) return PTR_ERR(codec->mcu_clk);
++
++	err = pin(dev, codec->pll_ref);
++	if (err) return err;
++	if (clk_get_rate(codec->pll_ref) != PLAN_REF || !all_off(v))
++		return -ERANGE;
++	if (clk_round_rate(codec->mcu_clk, PLAN_MCU) != PLAN_MCU ||
++	    clk_round_rate(codec->core_clk, PLAN_CORE) != PLAN_CORE)
++		return -ERANGE;
++	err = clk_set_rate(codec->mcu_clk, PLAN_MCU);
++	if (err) return err;
++	if (!all_off(v)) return -EBUSY;
++	err = clk_set_rate(codec->core_clk, PLAN_CORE);
++	if (err) return err;
++	err = pin(dev, codec->core_clk);
++	if (err) return err;
++	err = pin(dev, codec->mcu_clk);
++	if (err) return err;
++	/* Divider register layout matches the shipped xlnx_vcu provider.
++	 * Verify on gated branches, BEFORE clock-enable, not after overspeed.
++	 */
++	pll = readl(v->vcu_slcr_ba + 0x24);
++	core = readl(v->vcu_slcr_ba + 0x30);
++	mcu = readl(v->vcu_slcr_ba + 0x34);
++	if (!all_off(v) || FIELD_GET(GENMASK(14, 8), pll) != 85 ||
++	    FIELD_GET(GENMASK(18, 16), pll) != 1 ||
++	    !(core & BIT(0)) || !(mcu & BIT(0)) ||
++	    FIELD_GET(GENMASK(9, 4), core) != 2 ||
++	    FIELD_GET(GENMASK(9, 4), mcu) != 4 ||
++	    clk_get_rate(codec->core_clk) != PLAN_CORE ||
++	    clk_get_rate(codec->mcu_clk) != PLAN_MCU)
++		return -ERANGE;
++	err = turn_on(dev, codec->mcu_clk);
++	if (err) return err;
++	err = turn_on(dev, codec->core_clk);
++	if (!err)
++		dev_info(dev, "SC7F0 paired clock: ref %lu M85 core %lu MCU %lu\n",
++			 PLAN_REF, PLAN_CORE, PLAN_MCU);
+ 	return err;
+-
+ }
+ EXPORT_SYMBOL_GPL(xil_clk_set_up);
+ 
+ int xil_clk_clean_up(struct platform_device *pdev, struct al5_codec_desc *codec)
+ {
+-	clk_disable_unprepare(codec->core_clk);
+-	devm_clk_put(pdev->dev.parent, codec->core_clk);
+-
+-	clk_disable_unprepare(codec->mcu_clk);
+-	devm_clk_put(pdev->dev.parent, codec->mcu_clk);
+-
+-	clk_disable_unprepare(codec->pll_ref);
+-	devm_clk_put(pdev->dev.parent, codec->pll_ref);
+-
++	/* Child devres first gates both clocks, then releases exclusivity and
++	 * references on probe failure or removal. No live rate restoration. */
+ 	return 0;
+ }
+ EXPORT_SYMBOL_GPL(xil_clk_clean_up);
+-
+ #endif
--- a/petalinux/qpcie-zu4ev/project-spec/meta-user/recipes-kernel/linux/linux-xlnx_%.bbappend
+++ b/petalinux/qpcie-zu4ev/project-spec/meta-user/recipes-kernel/linux/linux-xlnx_%.bbappend
@@ -2,6 +2,7 @@
 
 SRC_URI:append = " file://bsp.cfg file://sc7f0-v4l2-capture.cfg file://sc7f0-hdmi-tx.cfg file://0001-sc7f0-vipp-frame-tap.patch file://0002-sc7f0-vcu-debug-probe.patch file://0003-sc7f0-si5319-ckin1-genlock.patch file://sc7f0-frame-tap.c file://sc7f0-frame-tap.h"
 KERNEL_FEATURES:append = " bsp.cfg sc7f0-v4l2-capture.cfg sc7f0-hdmi-tx.cfg"
+SRC_URI:append = " file://0004-sc7f0-gate-reset-vcu-before-provider.patch"
 
 do_patch:append() {
     install -m 0644 ${WORKDIR}/sc7f0-frame-tap.c ${S}/drivers/media/platform/xilinx/
--- /dev/null
+++ b/petalinux/qpcie-zu4ev/project-spec/meta-user/recipes-kernel/linux/linux-xlnx/0004-sc7f0-gate-reset-vcu-before-provider.patch
@@ -0,0 +1,44 @@
+--- a/drivers/clk/xilinx/xlnx_vcu.c
++++ b/drivers/clk/xilinx/xlnx_vcu.c
+@@ -751,7 +751,40 @@
+ 		dev_warn(&pdev->dev, "No reset gpio info from dts for vcu. This may lead to incorrect functionality if VCU isolation is removed post initialization.\n");
+ 	}
+ 
+-	regmap_write(xvcu->logicore_reg_ba, VCU_GASKET_INIT, VCU_GASKET_VALUE);
++	ret = regmap_write(xvcu->logicore_reg_ba, VCU_GASKET_INIT, VCU_GASKET_VALUE);
++	if (ret)
++		goto error_pll_ref;
++
++	/* Private 26112573 provider, before publishing ANY clock or child.
++	 * UG1087: reset leaf control = 0x1000 (gate open, mux 0);
++	 * PLL = reset/powerdown/bypass, postdivider /2. Never take over
++	 * live leaves or a non-reset PLL. No rate/mux changes in this step.
++	 */
++	{
++		u32 off, core, mcu, dec, pll;
++
++		ret = -EINVAL;
++		if (!xvcu->reset_gpio ||
++		    regmap_read(xvcu->logicore_reg_ba, VCU_CORE_CLK, &core) ||
++		    regmap_read(xvcu->logicore_reg_ba, VCU_MCU_CLK, &mcu) ||
++		    regmap_read(xvcu->logicore_reg_ba, VCU_DECODER_ENABLE, &dec) ||
++		    core != 708 || mcu != 354 || dec)
++			goto error_pll_ref;
++		pll = xvcu_read(xvcu->vcu_slcr_ba, VCU_PLL_CTRL);
++		ret = -EBUSY;
++		if (pll != 0x1510f)
++			goto error_pll_ref;
++		for (off = VCU_ENC_CORE_CTRL; off <= VCU_DEC_MCU_CTRL; off += 4)
++			if (xvcu_read(xvcu->vcu_slcr_ba, off) != BIT(12))
++				goto error_pll_ref;
++		for (off = VCU_ENC_CORE_CTRL; off <= VCU_DEC_MCU_CTRL; off += 4) {
++			xvcu_write(xvcu->vcu_slcr_ba, off, 0);
++			if (xvcu_read(xvcu->vcu_slcr_ba, off) != 0) {
++				ret = -EIO;
++				goto error_pll_ref;
++			}
++		}
++	}
+ 
+ 	ret = xvcu_register_clock_provider(xvcu);
+ 	if (ret) {
--- a/driver/qpcie_kms_v1.h
+++ b/driver/qpcie_kms_v1.h
@@ -7,7 +7,7 @@
 #include "../include/qpcie_overlay.h"
 
 /* Same signature was advertised by pre-epoch-fix prototypes. */
-#define QPCIE_KMS_FW 0x26112419U
+#define QPCIE_KMS_FW 0x26112573U
 
 static inline bool dp_epoch_supported(u32 fw)
 {
--- a/driver/tests/kms_v1.c
+++ b/driver/tests/kms_v1.c
@@ -53,7 +53,7 @@
 {
 	const dma_addr_t addr = UINT64_C(0x4200100000);
 	bool shown;
-	assert(dp_epoch_supported(0x26112419) && !dp_epoch_supported(0x26112408) && !dp_epoch_supported(0x26112405));
+	assert(dp_epoch_supported(0x26112573) && !dp_epoch_supported(0x26112419) && !dp_epoch_supported(0x26112408) && !dp_epoch_supported(0x26112405));
 	assert(!dp_epoch_supported(0x26112407) && !dp_epoch_supported(0x26112409));
 	assert(!dp_epoch_supported(0x26112406) && !dp_epoch_supported(U32_MAX));
 	assert(!dp_present(regs));
```
