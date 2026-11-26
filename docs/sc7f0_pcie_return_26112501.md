# SC7F0：透過 PCIe 回退至 PL 26112419 / PS 26112501

**PCIe 復原資格（73→19 已實機驗收，2026-11-26）**：唯一入口仍是
`scripts/sc7f0_flash.sh`。`PL_VERSION` 描述目標硬體，不代表只能更新 PS。
對已核准的 r2 release，入口會核對整份 `RELEASE.sha256` 的固定雜湊
（含 host tools、driver 原始碼和升級 tar），並比對現行 PS、BAR PL、
執行中的升級 daemon 以及 eMMC 三檔。73/73 → 01/19 必須是原始
73 candidate 的 eMMC 三檔、eMMC boot mode；SD recovery root 三檔不適用。
原始 19 沒有 PS release 檔，須另量測其封裝的 `sc7f0_vcud`。未知組合拒絕。

COMMIT 前須能從檔案核對執行中主機模組的 build ID 與 srcversion、保存
該模組，並以當前 kernel headers 從目標套件建出含 KMS 的模組。KMS
空閒切換至同一來源模組的管理模式，保持該模組直到卡重新啟動；確認目標
版本、PS/主機 boot ID 和 eMMC SHA 後才換目標 KMS。`--verify-only` 仍會
在閒置時暫時切換管理模式並還原，不能證明 reboot 或 DRM probe 成功。
COMMIT 後有任何不確定結果不要重試；保留 staging 的來源、模組與 readback
證據。此資格不准許反向燒錄 73，也不保證回復 SD 媒體可用。

本次測試機 staging `/home/rd/sc7f0/tmp/upgrade.3srUD7gu`：一次 COMMIT；
PS boot ID `346cc271-8d5c-4529-9e49-333585b7794d` →
`da510c3c-b678-4aea-ba5d-c4cc4c7fc82d`，主機未重啟，eMMC 三檔重啟前後
均相符。目標 PS `26112501`、PL `26112419`。`media-proof.Vc3pL16u/`
記錄打包的 KMS client 實際 flip 與 disable、HDMI RX 3840×2160p /
594 MHz 鎖定、HEVC CBR 40 Mbps 設定 ACK 43/43。六秒 smoke capture
323/323 張解碼；非長時間 60 fps 或實體 HDMI TX 的驗收。
