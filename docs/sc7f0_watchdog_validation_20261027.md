# SC7F0 watchdog 板端驗收 — 2026-10-27

## 結論與版本

目前部署 **sc7f0-ps-watchdog-20261027-r2**；PL 仍為原本凍結的
**0x26102206**，MCU 仍為 **v1.1.15 / 0x1262010F**，未燒錄 MCU 候選韌體。
R1 已被本輪測試發現過早升級 reset 的缺陷，**不應再新部署 R1**。

通過的範圍：
- VERIFY → COMMIT → 獨立 eMMC SHA 讀回 → fresh PS boot_id／release marker。
- 真正停止餵 FPD watchdog 後，硬體路徑完成 PS/system reset 與 PL 重新配置，
  不需要活著的 Linux 發出 reboot。
- R2 daemon 無進展時，systemd 重啟該 daemon；guardian 留足恢復寬限，
  不再因此誤觸發全系統 reset。
- R2 下真實 HDMI NV12M 3840×2160、300 frames、59.846 fps 擷取，
  原生 raw/PNG 已檢查，確有正常山地道路影像，並非靜音／空畫面或 TPG 替代。

**未驗證**所有深層 NoC/MMIO hard-hang、WDT clock/power 失效、MCU WDT、
IT6663 自動復原、長時 A/V。未讀 disabled MMIO、未重試先前失敗的 combined I2C。
TPG NV16 格式切換仍有獨立 timeout，不能宣稱所有 video regression 通過。

## 實際 boot generation

x86 host 全程保持：
`812110b6-6e3f-4f78-9d9e-6ba1ddb6cb59`

| 階段 | 真正 PS kernel boot_id |
|---|---|
| 使用者重啟後 baseline，uptime 約320s | 124f5875-fa7e-456d-a838-7eadf5486cac |
| R1 正常部署 reboot | f14773fa-cef8-4799-bd73-42f2f816cd54 |
| R1 guardian 停餵後的硬體 WDT reset | 68316867-be89-431a-984d-c155f66ff906 |
| R2 正常部署 reboot／最終穩定運行 | 1cea52f1-4d7f-4d69-bc19-50c619410d73 |

卡端日期顯示 Nov08，與 x86 實際日期不同；判定使用 boot_id、monotonic uptime
及 host timestamp，不把錯誤 wall clock 當 reset 證據。

## R1 缺陷、硬體 reset 證據與 R2 修正

使用者明確同意完整 watchdog 故障驗收。先停 capture，清 PCIe COMMAND.BusMaster
（0406→0402）隔離可能殘留的 DMA；不在 COMMIT 期間故障注入。

1. SIGSTOP HDMI main PID608。
2. systemd 的20s watchdog 用 SIGABRT 結束舊 process，重啟為 PID688。
3. R1 `read_health()` 額外要求 `kill(pid,0)` 成功。舊 PID 消失至新 PID ready 的
   正常替換窗口，會立即使 guardian latch；**錯誤地繞過原有45s timestamp預算**。
4. guardian 在舊 PS uptime630828ms 記錄 LATCHED，停止硬體 pings。
5. 硬體之後真的 reset：PCI command 變0000、舊 mailbox失效；只做 host PCI
   remove/rescan 後確認新 PS boot_id68316867…、uptime105s、R1 marker與新 guardian ARMED。
   **這段測試沒有發出 SysRq、Linux reboot 或 qpcie_upgrade --reboot**。
   Host PERST/rescan 本來不能 reset PS；不是把枚舉成功當作 PS recovery。
6. 這證明停止餵狗→硬體 reset 路徑可用，但 R1 整體政策不合格。

R2 改成以 root-owned、正確 kernel boot_id 的**最近真實主迴圈進展時間**與既有
45s/240s預算判定。PID仍檢查合法範圍並保留稽核，但 daemon替換時舊 PID短暫不存在，
不再立即升級；若直到預算逾時仍沒有新進展，照樣 latch。沒有新增餵狗 thread。

新增 dead/replaced-PID grace 回歸；11個 watchdog unit cases、總56個 Python cases
通過。第一個 R2 build 被既有 test 的 `/tmp/opencode` 缺目錄問題擋下，完整保留失敗
目錄；修成標準 tempfile 後，在新目錄重跑並通過，沒有繞過 build gate。

## R2 板端重測

- 在 Linux uptime **125.58s** 才注入，已超過120s boot grace，避免假通過。
- 清 BusMaster，SIGSTOP HDMI PID617。
- systemd20s逾時後重啟為 PID664、NRestarts=1。
- 32s確認新 daemon active、health healthy、無 watchdog-latched。
- 再觀察60s，共約92s，超過先前20+60s誤 reset窗口。
- PS boot_id始終1cea52f1…；四服務 active，guardian無 LATCHED，
  watchdog0 active、timeout60s，host boot_id不變。
- 此次 clean R2 boot後沒有啟動 capture，因此結束後安全恢復 BusMaster0406。

沒有為了重複測試再單獨 SIGSTOP R2 guardian、製造另一個故障 reset。
R2 的 **pmufw.elf、zynqmp_fsbl.elf、Image.gz、system.dtb 與 R1 byte-identical**；
已觀測的硬體 timer/reset 基礎沒有更換。R2 改動的是升級判定寬限。

## 視訊／MCU 邊界

- MCU只發送已驗證的 runtime restart `w2@0x32 0x06 0x01`，
  不重燒 APROM。MCU管理 status 的已知 two-message read正常。
- Official RX回報 RGB8 3840×2160p60、594MHz、LPCM2，
  N5824/CTS563063。這不是音訊有效 PCM／可聽播放的證據。
- R1下 TPG RGB1800frames約53.738fps、NV121800frames約56.793fps；
  隨後 NV16格式切換 poll timeout／STREAMOFF drain失敗。
  當時 PS boot_id、四個daemon與guardian都正常，無PS reset；
  尚未歸因，不直接判定為 watchdog 引入的 RTL／driver regression。
- 隔離 DMA後才做故障試驗；其後的完整 PL reload已清除舊 capture狀態。
- R2下真實 HDMI NV12M300frames、5.013s、59.846fps、bytes3732480000，
  STREAMOFF drained=1、video_errors=0；raw/PNG為3840×2160，已目視檢查。
- 沒有宣稱 NV16切換、完整RGB/NV16實機回歸、audio rate mismatch／A/V已修復。

## 檔案與回滾

- Final release：
  `build/sc7f0-ps-watchdog-20261027-r2-release/`
- 本輪證據：
  `build/validation/sc7f0-watchdog-takeover-20261027.ECmVuY/`
- R1 host deployment：
  `/home/rd/sc7f0-ps-watchdog.AFFd40SH`
- R2 host deployment：
  `/home/rd/sc7f0-ps-watchdog-r2.QWISzXDA`
- 原rev06 eMMC備份：
  `/run/media/BOOT-mmcblk0p1/.backup_cli_pswdog_20261027T011722Z`
- R1額外備份路徑保存在 R2 host directory 的 `ps-backup-directory`；
  不應優先把有政策缺陷的R1當作rollback，原rev06四成員包仍保存。
- R2 eMMC SHA：
  - BOOT.BIN `12c8b2cf921fd5fbd09748a6356e72a354fc82a3fdc93c130b83fb1bbd4e24e1`
  - image.ub `3f5d74ab461a6b854e80af59890f9374e4a1536c776b1f0c4f9d5d9922c9c72e`
  - boot.scr `14c14ececc4b35eb6ac10253f06a0f3dad10b7750d7283a7892676288df3bad6`

`release.json`保留離線建置時的hardware_validated=false，不改寫凍結manifest；
本文件與 takeover evidence另記錄上述**有限範圍**板端驗收。
未重啟x86、未提交Git、未push；原video commit與audio/MCU WIP均保留。
