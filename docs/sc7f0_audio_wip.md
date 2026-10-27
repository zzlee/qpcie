# SC7F0 audio WIP（刻意不包含在 NV12/NV16 視訊 commit）

## 最新部署（2026-10-27）

26102702 已完成eMMC部署與真正PS reboot，預設buffers（參數2、GStreamer初始4）下10分鐘A/V資料/時間線驗證通過，**8-buffer workaround已移除**。
新版20次ALSA重開及9次視訊格式測試通過；TPG兩次primary drain依賴video sub-reset成功恢復，仍列剩餘問題。
實際可聽／lip-sync未確認，audio/recovery仍未commit/push。詳見 [新版實機報告](sc7f0_audio_26102702_validation.md)。

以下保留先前階段紀錄，不能把舊「尚未持久部署」當成目前狀態。

## 版本界線

- Git 的 NV12M/NV16M 視訊基線是已實機驗證的 **0x26102204**。
- Working tree 保留後續 **0x26102206 音訊基底**。2026-10-27已通過正式DEV1實際PCM長錄與重開；有聲desktop A/V及lip-sync仍未驗收。詳見 [最新音訊實測](sc7f0_audio_validation_20261027.md)。
- 同一檔的視訊／音訊修改已拆開提交。因此 top-level RTL、build scripts 與兩份
  `.xsa` 在視訊 commit 後仍顯示 modified 是預期狀態；不是遺漏，也不要直接 restore。

## 保留的主要音訊工作

- `rtl/hdmi_rx_pcm_converter.v`、`rtl/audio_stream_engine.v`
- `rtl/zu4ev_pcie_card_top.v`、`rtl/custom_pcie_dma_top.v` 的 PCM 接線、仲裁與控制
- `rtl/axil_reg_space.v`、`rtl/qpcie_csr_reg_space.v` 的音訊 CSR
- `driver/qpcie_alsa.c`、`driver/qpcie_driver.h`
- `test_app/qpcie_hdmi_daemon.c`、`test_app/qpcie_hdmi_audio.h`
- `tb/sc7f0_hdmi_pcm_tb.sv`、`tb/sc7f0_audio_dma_tb.sv`、`tb/qpcie_hdmi_audio_tb.c`
- `tb/sc7f0_csr_cdc_tb.sv`、`scripts/test_sc7f0_audio.tcl`、CSR wrapper drift test
- `scripts/sc7f0_build.sh`／Vivado build script 的新增音訊測試及來源
- `scripts/sc7f0_av_preview.py`、`docs/sc7f0_hdmi_audio_host_plan.md`
- Working-tree XSAs 與 PetaLinux metadata 仍對應音訊候選，不是已提交的 rev04。

`AGENTS.md` 及 `docs/sc7f0_system_architecture.md` 是另外保留的文件修改，亦未併入視訊 commit。

## 最新實測／安全界線（2026-10-27）

使用者解除來源靜音後，實際counter約48k/s，官方PS資訊為8ch LPCM。修正parser/host guard，
如實保留source8ch、抽取TID0/1 Front L/R到stereo S32_LE（不是downmix）。正式DEV1通過
120秒/5760000frames、20次重開，同時native NV12 6000幀59.996fps；所有rate/non-audio guards保留。

預設buffer配置下video仍可能在4–6buffers後卡住。已用單元測試重現thin engine雙ring doorbell競態，
候選修正僅在frame_active時fetch。實機8-buffer workaround＋capture slave-method=none後，
**10分鐘嚴格A/V資料/時間線長測通過**：36002rendered frames/59.989fps、DMA drops0/GUI drops4、
28804096audio frames，PTS jumps/gaps0、總時長誤差1ns。這不是永久RTL已部署；可聽／lip-sync未確認。
完整候選`build/sc7f0-audio-doorbell-26102702-r1`背景建置中，來源凍結；成功後僅自動離線package，不flash。
本輪只有runtime daemon/module替換，eMMC R2未改；新軟體尚未做持久套件及重啟驗證。

先前384k/零payload與agent-induced PS MMIO hang是保留的歷史，不是目前PS仍無回應。
PS已由後續operator reboot恢復並部署watchdog R2，四services健康。最新紀錄：
`docs/sc7f0_audio_validation_20261027.md`、`docs/sc7f0_watchdog_validation_20261027.md`。
不要讀未驗證／未啟用的PS MMIO，也不要重試被拒絕的combined I2C診斷。
**PCIe存在、READY=1或cached lock不證明PS存活；非零PCM也不等於實際可聽。**

## 整理與備份

本輪完整整理備份：`build/git-sort-20261023.kgUKYN/`。

- `before/unstaged.patch`：整理前所有tracked變更，含binary patch。
- `before/untracked.tar.gz`／`untracked.list0`：整理前全部untracked檔案。
- `root-experiments/`：20個根目錄臨時build/PCM腳本與完成摘要，內容原樣歸檔，未刪除。
- `archived-root-files.json`：原路徑、歸檔路徑及SHA。
- `validated04-proof.json`／`video-regression.log`：視訊分離與驗證證據。

舊 `scripts/sc7f0_audio_dump.c`、`sc7f0_capture_raw_audio.sh`、`build_audio_pcm.sh`、
`end_to_end_test.sh` 等暫保留原路徑，以免破壞先前source snapshot，但不是可信音訊驗證入口；
例如從video節點mmap讀音訊、TPG capture或假定B/9/C preamble，都不能證明HDMI PCM成功。
