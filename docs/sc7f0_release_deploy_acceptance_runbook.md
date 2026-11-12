# SC7F0 正式发布 → 部署 → 硬体验收 Runbook（B2 + GStreamer 5 分钟并发）

文件状态：**程序（procedure）**，不是验收记录。本文件写作于 2026-11-11/12 的本机
定稿轮次；写它的那次会话**没有** SSH、没有部署、没有烧录、没有装驱动、没有跑完整
build（见末尾「本文件写作轮次未执行的事」）。每一步的「执行/结果」栏留空，由真正
执行的人在设备上填，并把日志与本文件的版本一起存档。

适用范围：`scripts/build_sc7f0_vcu_release.sh` 产出、`scripts
/check_sc7f0_release_package.py` 判为 `RELEASE_GATE_PASS`（`release.json
deployable=true` 且存在 `gates/package.ok`、不存在 `NOT_DEPLOYABLE`）的完整升级包。

不适用：单独推一个 daemon、单独换 `image.ub`、从 BOOT 分区跑散档、或者拿上一轮的
验收记录当本轮证据。AGENTS.md 的授权（可直接更新固件/重启测试主机/MCU 烧录）不等于
本节步骤可以跳：授权解决的是「要不要每次问」，顺序与证据要求解决的是「会不会把卡变
成砖且回不去」。

---

## 0. 术语与硬事实（照实写，不美化）

| 项目 | 事实 | 来源 |
|---|---|---|
| 测试主机 | `rd@sc7f0-test.local`（严格主机密钥验证），PCIe `0000:03:00.0 [12ab:e380]`，driver `qpcie-dma` | `docs/sc7f0_bringup_progress_20261111.md` §4 |
| 卡端 BOOT 分区 | `/run/media/BOOT-mmcblk0p1`（vfat），三成员 `BOOT.BIN` / `image.ub` / `boot.scr` | `test_app/qpcie_upgrade_daemon.c`、`test_app/qpcie_backup_retention.h` |
| 升级工具 | `qpcie_upgrade --package <tar>`（VERIFY）→ `--commit`（唯一写 eMMC 的动作）→ `--reboot` | `test_app/qpcie_upgrade.c:413-416` |
| 升级包成员 | 严格 ustar：`BOOT.BIN`、`image.ub`、`boot.scr`、`manifest.sha256`（顺序固定） | `scripts/check_sc7f0_release_package.py` |
| 备份策略 | `.backup_upgrade/txn-*` → `gen-*`，保留 2 代，参照世代内容保护；空间不足在复制前拒绝 | `test_app/qpcie_backup_retention.h` |
| 已知遗留 | 2026-11-11 实测卡上 `.backup_upgrade` 三档 SHA **与现行档相同**，且无 `.backup_cli_*` → 该卡当时**没有任何可用的前一代** | A 报告 §7.2（`docs/sc7f0_bringup_progress_20261111.md`） |
| 三包比对 | 同机三包 `image.ub`/`boot.scr` 完全相同、`BOOT.BIN` 各不同 → 恢复必须绑定「现行 BOOT.BIN 所属那一包」整套使用 | A 报告 §3 |

> 两条硬结论：
> 1. **第一次 COMMIT 之前，卡上没有前一代**；新包里的备份修正对那一次 COMMIT 无效，
>    因为执行它的是**旧 daemon**（旧的 `rm -rf .backup_upgrade` 行为）。不允许「先换
>    daemon 再升级」：板上个别补档是被禁止的动作，而且换了 daemon 也换不掉正在跑的
>    那个进程。
> 2. 因此**唯一**的恢复资产是主机侧那份「与现行 BOOT.BIN 同包」的完整 tar。它必须在
>    COMMIT 之前取到并验算（步骤 R0）。

---

## 1. 事前检查（全部必须留下输出档）

工作目录记为 `$REL`（release 目录），`$TAR=$REL/release/upgrade-<version>.tar`。

```bash
cd "$REL"
sha256sum -c RELEASE.sha256                      # 套件自身完整性
python3 - "$REL" <<'PY'
import json,sys;from pathlib import Path
rel=Path(sys.argv[1]); rj=json.loads((rel/'release.json').read_text())
assert rj.get('deployable') is True, rj.get('deployable_reason')
assert (rel/'gates/package.ok').is_file() and not (rel/'NOT_DEPLOYABLE').exists()
print('PACKAGE_DEPLOYABLE', rj['version'])
PY
cat gates/release-gate.json | python3 -c 'import json,sys; d=json.load(sys.stdin); print("verdict",d["verdict"]); print("unit_tests",{k:(v["verdict"],v["ran"],v["skipped"]) for k,v in d["notes"]["unit_tests"].items()}); print("tolerated_not_evidence",d["notes"].get("tolerated_not_evidence",{}).get("tests"))'
```

必须同时成立，否则**停在这里**：

- [ ] `release.json` `deployable=true` 且 `gates/package.ok` 存在、`NOT_DEPLOYABLE` 不存在；
- [ ] `gates/release-gate.json` 三个 unit-test 记录皆 `UNIT_TESTS_GATE_PASS`、
      `required_tests_not_executed` 为空；
- [ ] `notes.tolerated_not_evidence.tests` 若列出 `test_sc7f0_mcu_app_image.*`，那是
      **范围声明**（MCU 影像稽核本轮不碰、且目前实质瘫痪），**不得**当成「MCU 已验证」；
- [ ] `fpga/version-identity.json` 的 `c_version` = 本包版本，`git_register_source`
      为 `dirty-content-fingerprint` 时如实写明工作树是脏的（不是冒充 clean commit）；
- [ ] `PS_IMAGE_MATCH.json` 的 XSA sha256 = `fpga/hardware.xsa`；
- [ ] 本包版本 ≠ 测试主机上现存的任何 `upgrade-*.tar` 版本（避免用同号覆盖旧认知）。

主机侧现存包清点（只读）：

```bash
ssh -o BatchMode=yes rd@sc7f0-test.local 'ls -l /home/rd/upgrade-*.tar; for t in /home/rd/upgrade-*.tar; do echo "== $t"; sha256sum "$t"; tar tvf "$t"; done' \
  | tee "host-tars-before-$(date -u +%Y%m%dT%H%M%SZ).txt"
```

---

## 2. R0：COMMIT 之前必须建立的恢复基线（**先做这个**）

目的：让「第一次 COMMIT」也有一条有依据的退路。**只读**（不写卡）。

```bash
STAMP=$(date -u +%Y%m%dT%H%M%SZ); mkdir -p "rollback-$STAMP"
ssh -o BatchMode=yes rd@sc7f0-test.local '
  b=/run/media/BOOT-mmcblk0p1
  find "$b" -maxdepth 3 \( -name ".backup_upgrade" -o -name ".backup_cli_*" \) -print
  for n in BOOT.BIN image.ub boot.scr; do sha256sum "$b/$n"; done
  df -B1 "$b" | tail -1
  ls -l "$b"
' | tee "rollback-$STAMP/live-card.txt"
```

把现行三档取回主机并逐位元组验算（不是只比前 8 码）：

```bash
for n in BOOT.BIN image.ub boot.scr; do
  scp -o BatchMode=yes "rd@sc7f0-test.local:/run/media/BOOT-mmcblk0p1/$n" "rollback-$STAMP/$n"
done
( cd "rollback-$STAMP" && sha256sum BOOT.BIN image.ub boot.scr > live-card.sha256 \
  && sha256sum -c live-card.sha256 )
```

**判定（决定本 runbook 能不能继续）**：

1. 找出这三档 `BOOT.BIN` 属于哪一个 tar：逐包解出 `BOOT.BIN` 比 sha256。
   ```bash
   for t in /home/rd/upgrade-*.tar; do
     tar xOf "$t" BOOT.BIN | sha256sum | sed "s#-#$t#"
   done
   ```
2. 若三档 SHA 与现行相同的那一包**就在主机上** → 恢复基线成立：把该 tar 的 sha256、
   解包后三档 sha256、与卡上实测 sha256 写进 `rollback-$STAMP/MANIFEST.txt`，
   并注明「恢复=用这一整包重走 VERIFY→COMMIT」。
3. 若**找不到**该包（只有零散档、或三包 BOOT.BIN 都不等于现行 BOOT.BIN）→
   **恢复基线不成立 = BLOCKED**。此时唯一诚实的做法是先建立可恢复性，再考虑升级：
   - 用当前卡上三档**重建一个完整升级包**（三档必须同源；不可把 A 包的 BOOT.BIN 配
     B 包的 image.ub —— `image.ub`/`boot.scr` 相同不代表 BOOT.BIN 可换），或
   - 走 SD installer 路线先取得一份已知可开机的镜像；
   - 这两条都需要人在现场决定，**不要凭猜测继续**。把 BLOCKED 写成文件，附上面三份
     sha256 输出，向上呈报。
4. 若卡上 `.backup_upgrade` 里三档 SHA 与现行档**相同**（已知遗留状态），那目录
   **不算**恢复资产（它只是现行的副本）。这一点要写进 MANIFEST，不要后来被误读成
   「有备份」。

> **R0 未完成 = 不允许进入第 3 节。** 本文件写作轮次**没有**执行 R0（无 SSH 授权），
> 因此截至本次交付，B2 的恢复能力状态是 **BLOCKED / 未证明**，不是「可回滚」。

---

## 3. 部署顺序（严格按用户给定顺序，一步一证）

### 3.1 上传完整包到测试主机

```bash
scp -o BatchMode=yes "$TAR" rd@sc7f0-test.local:/home/rd/
ssh rd@sc7f0-test.local "sha256sum /home/rd/$(basename "$TAR"); sha256sum -c <(echo '<expected-sha>  /home/rd/<tar>')"
```

- [ ] 主机端 tar sha256 = `$REL/RELEASE.sha256` 里的值（逐位元组，不是缩写）。
- [ ] **只上传这一包**；不推 daemon、不推 `sc7f0_vcud`、不推 `qpcie_debugd`。板上个别
      补档一律禁止（PS runtime 必须由 image.ub 内建提供，见
      `petalinux/.../recipes-core/images/petalinux-image-minimal.bbappend`）。

### 3.2 VERIFY（不写卡）

```bash
ssh rd@sc7f0-test.local "sudo /home/rd/qpcie_upgrade --package /home/rd/$(basename "$TAR")" 2>&1 | tee verify-$(date -u +%Y%m%dT%H%M%SZ).log
ssh rd@sc7f0-test.local 'sudo /home/rd/sc7f0ctl exec "sha256sum /run/media/BOOT-mmcblk0p1/{BOOT.BIN,image.ub,boot.scr}"'   # 必须仍等于 R0 值
```

- [ ] VERIFY 报 PASS 且 manifest 逐档对上新包字节；
- [ ] VERIFY 之后卡上现行三档 sha256 **未变**（VERIFY 不写 eMMC，必须验它真的没写）；
- [ ] 记录 `Upgrade Status` 为 `VERIFIED (awaiting --commit)`。

### 3.3 一次 COMMIT（**一次；结果不明不重试**）

```bash
ssh rd@sc7f0-test.local 'sudo /home/rd/qpcie_upgrade --commit' 2>&1 | tee commit-$(date -u +%Y%m%dT%H%M%SZ).log
```

COMMIT 前的即时读数（一次即可，用来事后判断「第一次 COMMIT 无前一代」是否仍成立）：

```bash
ssh rd@sc7f0-test.local 'journalctl -u qpcie-upgrade-daemon -n 60 --no-pager'
```

日志里必须出现（`test_app/qpcie_upgrade_daemon.c` 写死）：

- `COMMIT: <N> backup generation(s) recoverable before this write`；
  `N=0` 时后段是 `NONE: this card has no prior image to roll back to; the host must
  still hold the matching release tar` → 这条就是 R0 存在的原因，看到它不要惊讶，
  但**本轮之前 R0 必须已完成**；
  注意：如果这次 COMMIT 由**旧 daemon** 执行（旧 installer 首次升级），这条日志根本
  不会出现——那就更证明不能靠包内的新代码兜底。
- 或拒绝信息：`COMMIT: refused, no room for a backup generation` → 空间不足，**没有
  stage、没有删除任何东西**；处理方式是清 BOOT 分区或降低保留数，不是手删备份。

**一次 COMMIT 规则**：SSH 断线、超时、结果不明 → **不要重发 COMMIT**（COMMIT 一次消费
一个 VERIFIED 状态；重发或 reset DMA 去「收回内存」都可能把状态搞乱）。改用独立证据
判断：见 3.4 的 eMMC 读回与 3.5 的 boot-ID 检查。若确实无法判定，按 BLOCKED 上报。

### 3.4 独立 eMMC SHA（不依赖 daemon 的自我声明）

```bash
ssh rd@sc7f0-test.local 'sha256sum /run/media/BOOT-mmcblk0p1/{BOOT.BIN,image.ub,boot.scr}'
ssh rd@sc7f0-test.local 'ls -laR /run/media/BOOT-mmcblk0p1/.backup_upgrade'
```

- [ ] 三档 sha256 = 新包 manifest 的三档 sha256；
- [ ] `.backup_upgrade/` 出现新的 `gen-*`（不是 `txn-*` 卡住；`txn-*` 且有
      `state` 档内容为 `APPLYING`/`PREPARED` 表示中断，**不要删**，按 `qpcie_backup_retention.h`
      的语义上报：`qbr_recover_all` 会在下次开机解析，解析不了 daemon 会拒绝再刷）；
- [ ] 新 `gen-*` 内三档 sha256 = **R0 记录的现行旧三档**（这才叫有了前一代）。

### 3.5 重启 + 真正的身分确认（版本与 boot_id 都要新）

```bash
ssh rd@sc7f0-test.local 'cat /proc/sys/kernel/random/boot_id'      # 记为 OLD_BOOT_ID（若卡还活着）
ssh rd@sc7f0-test.local 'sudo /home/rd/qpcie_upgrade --reboot'
# 等待 PS 回来
ssh rd@sc7f0-test.local 'cat /proc/sys/kernel/random/boot_id; uname -a; is-system-running'
ssh rd@sc7f0-test.local 'cat /etc/sc7f0-recovery-release'          # PL_BASE_VERSION=0x<version>
ssh rd@sc7f0-test.local 'systemctl is-enabled sc7f0-vcud.service qpcie-debugd.service qpcie-upgrade-daemon.service; systemctl is-active sc7f0_vcud qpcie_debugd 2>/dev/null; systemctl status sc7f0-vcud --no-pager | head -12'
ssh rd@sc7f0-test.local 'strings /usr/bin/qpcie_debugd | grep "mailbox ABI h2c"'
ssh rd@sc7f0-test.local 'grep -m1 PL_BASE_VERSION /etc/sc7f0-recovery-release; sha256sum /run/media/BOOT-mmcblk0p1/{BOOT.BIN,image.ub,boot.scr}'
```

- [ ] `boot_id` **与重启前不同**（这是「真的重启了」的唯一廉价证明；相同就是没重启，
      后面的证据全部作废）；
- [ ] `/etc/sc7f0-recovery-release` 的 `PL_BASE_VERSION` = 本包版本；
- [ ] 主机侧 BAR0 版本（`qpcie_sanity_check` / `sc7f0ctl`）= 本包版本；
- [ ] `sc7f0_vcud`、`qpcie_debugd` 由 **`/usr/bin/...`** 的 systemd 单位带起
      （`ExecStart=/usr/bin/...`，不是 `/run/media/...` 或 `/tmp/...` 散档）；
- [ ] `qpcie_debugd` 内含 `qpcie_debugd mailbox ABI h2c=0x800`
      （0x800 信箱 ABI 标记；旧版 debugd 没有这串字，见 `test_app/qpcie_debugd.c`）；
- [ ] 不需要任何「主机推档」动作就让 encoder/debug 路径可用（重启后仍在 = 真入 image）。

任何一项不符：停止，不进入 3.6；依 `NOT_DEPLOYABLE` 的语义处理（见第 5 节恢复）。

### 3.6 主机 driver：在测试主机上从其自身 kernel headers 建立并安装/重载

**这是明确授权的合法主机安装**（host 侧驱动），与「板上个别补档禁止」是两件事。

```bash
ssh rd@sc7f0-test.local 'uname -r; dpkg -l "linux-headers-$(uname -r)" | tail -1; modinfo -F srcversion qpcie 2>/dev/null; cat /sys/module/qpcie/srcversion 2>/dev/null'
```

前置：**确认装置空闲**（没有任何抓流/编码在跑、没有 process 持有 video 节点）：

```bash
ssh rd@sc7f0-test.local 'fuser -v /dev/video0 /dev/video1 2>&1; pgrep -a gst-launch-1.0; pgrep -a qpcie_debugd'
ssh rd@sc7f0-test.local 'sudo /home/rd/sc7f0ctl status'
```

建立与载入：

```bash
scp -o BatchMode=yes "$REL/host-driver-src.tar.gz" rd@sc7f0-test.local:/home/rd/
ssh rd@sc7f0-test.local '
  set -e; cd /home/rd && rm -rf driver-build-'"$STAMP"' && mkdir driver-build-'"$STAMP"'
  tar xzf host-driver-src.tar.gz -C driver-build-'"$STAMP"'
  cd driver-build-'"$STAMP"'/driver
  make -C /lib/modules/$(uname -r)/build M=$PWD modules
  modinfo -F srcversion ./qpcie.ko
'
# 卸旧装新（只在装置空闲时）
ssh rd@sc7f0-test.local '
  set -e
  sudo rmmod qpcie
  sudo insmod /home/rd/driver-build-'"$STAMP"'/driver/qpcie.ko
  cat /sys/module/qpcie/srcversion
  ls -l /dev/video0 /dev/video1
  sudo dmesg | tail -30
'
```

- [ ] 编出来的 `qpcie.ko` 的 `srcversion` = `/sys/module/qpcie/srcversion`（载入的就是
      刚编的），并与旧的 `/home/rd/qpcie.ko`、`/lib/modules/.../extra/qpcie.ko` 的关系
      如实记录（A 报告曾出现 loaded 与磁盘不一致；不一致就写不一致）；
- [ ] `dmesg` 无 error/warn/overflow；
- [ ] 若 `rmmod` 失败（装置忙碌/被引用）→ **不要 `-f` 强卸**；先停掉使用者，或改在
      维护时段做。

### 3.7 才轮到验收测试（第 4 节）

顺序到此为止：完整包 → 上传 → VERIFY → 一次 COMMIT → 独立 eMMC SHA → 真 boot-ID
重启检查 → host driver 自建自装 → 测试端 GStreamer。任何前置步骤缺失或结果不明，
第 4 节即使「通过」也不构成部署验收。

---

## 4. GStreamer 5 分钟验收：video0 桌面全屏 ＋ video1 硬体 VCU H.264 mp4 并发

**状态：本文件只准备程序，未执行。** 执行前必须取得当时的实际工具/caps；下面写的是
**如何决定** pipeline，不是「某条已验证的指令」。仓库里出现过的
`v4l2src device=/dev/video0 num-buffers=600 ! NV12,3840x2160,60/1 ! fakesink`
（A 报告 §4.1）是**秒级短测＋fakesink**，明确**不能**当 fullscreen 证据。

### 4.1 执行前必须实测并写进记录的东西（不许猜）

```bash
ssh rd@sc7f0-test.local '
  loginctl show-session "$(loginctl --value --no-legend show-user "$USER" | head -1)" 2>/dev/null | head -20
  echo "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR WAYLAND_DISPLAY=$WAYLAND_DISPLAY DISPLAY=$DISPLAY"
  w; ls -l /run/user/$(id -u)/ 2>/dev/null | head
  gst-inspect-1.0 v4l2src >/dev/null && gst-inspect-1.0 v4l2sink >/dev/null && echo HAVE_v4l2sink || echo NO_v4l2sink
  for e in kmssink waylandsink wayfliersink gtksink glimagesink autovideosink ximagesink; do
     gst-inspect-1.0 "$e" >/dev/null 2>&1 && echo "SINK $e"; done
  gst-launch-1.0 v4l2src device=/dev/video0 num-buffers=1 ! fakesink 2>&1 | grep -E "caps|NV12|error" | head -5
  v4l2-ctl -d /dev/video0 --list-formats-ext | head -30
  v4l2-ctl -d /dev/video1 --list-formats-ext | head -20
'
```

- [ ] **真实桌面 session**：记录 display server（Wayland/X11）、`XDG_RUNTIME_DIR`、
      session id、当前活动座者（`w`）。若测试主机没有 GUI session → **不能宣称
      fullscreen**，必须以 `fakesink` 之外的真实显示汇流点失败收场并如实写 BLOCKED，
      **不可以 fakesink 冒充 fullscreen**。
- [ ] **解析度/HDMI 锁定**：卡端 IT6663 锁定状态 + 格式（例：3840x2160p、594 MHz、
      fmt `0x00800200`）；未锁定就不要开始（那是「无信号」，不是「显示失败」）。
- [ ] **driver 版本**：`/sys/module/qpcie/srcversion`；`qpcie_debugd` ABI 字串；
      `sc7f0_vcud` 单位 active。
- [ ] **起点计数**：`packet_stats` submit/done/err/msi、`ch0_drops`、
      `frame_drop_count`、`lspci -vvv` AER（`UESta/CESta`）、`dmesg` 行数、
      PS `boot_id`、`is-system-running`。

### 4.2 并发 pipeline（两个独立进程，队列隔离；长度以时间而非 num-buffers）

要点：
- **时长 300 秒靠 `timeout 305` 控制，不靠 `num-buffers` 估算**。`num-buffers` 只能保证
  帧数，无法证明稳态；300 秒稳态才是这项验收的对象。
- 显示端与编码端各有一段 `queue`（`leaky=downstream` 只在明确接受丢帧并把它计入指标时
  才用；否则 `leaky=0`，让背压显形）。
- 编码路径必须是**硬体 VCU**：`/dev/video1` 已经是 PS 端 VCU 编好的 H.264 位串
  （`h264parse ! mp4mux`）。**禁止**用 `x264enc`/`openh264` 之类软体编码器冒充；
  pipeline 中出现任何软编元件即视为该轮验收无效。
- mp4 需要正常 EOS 才写 `moov`；用 `SIGINT`/`GST_LAUNCH` 正常结束，然后验 `ffprobe`。

```bash
LOG=/tmp/sc7f0-accept-$STAMP; mkdir -p $LOG
# (A) video0 → 真实桌面全屏（sink 依 4.1 实测选择；此处以 kmssink/waylandsink 为例，
#     实际元件与属性必须由 4.1 输出决定，不得照抄）
timeout -s INT 305 gst-launch-1.0 -e \
  v4l2src device=/dev/video0 do-timestamp=true \
    ! 'video/x-raw,format=(string)NV12,width=(int)3840,height=(int)2160,framerate=(fraction)60/1' \
    ! queue max-size-buffers=8 \
    ! kmssink driver-name=v3d sync=true can-scale=false \
  > "$LOG/video0_display.log" 2>&1 &
PID_A=$!

# (B) video1（硬体 VCU H.264）→ mp4 档档
timeout -s INT 305 gst-launch-1.0 -e \
  v4l2src device=/dev/video1 do-timestamp=true \
    ! 'video/x-h264,stream-format=(string)byte-stream' \
    ! queue max-size-buffers=16 \
    ! h264parse config-interval=-1 \
    ! mp4mux faststart=false \
    ! filesink location="$LOG/vcu_5min.mp4" \
  > "$LOG/video1_encode.log" 2>&1 &
PID_B=$!
wait $PID_A; RC_A=$?; wait $PID_B; RC_B=$?
```

- [ ] 两个 `GST_RC` 都是 0（`-e` + SIGINT 正常 EOS；`mp4mux` 才会写完 `moov`）；
- [ ] 两个 log 都保留（连同 4.1 的 caps 输出）；**不许只留摘要**；
- [ ] 全屏那一侧：执行期间有人眼可见的全屏画面（或由 4.1 的显示后端证明画面有更新），
      且显示 sink 不是 `fakesink`；
- [ ] 记录两条 pipeline 实际使用的元件与 caps（从 log 摘出，不是从本文件抄）。

### 4.3 结束后的读回（全部要留 log）

```bash
ssh rd@sc7f0-test.local '<与 4.1 相同的计数读取>'      # 终点计数
ffprobe -v error -show_streams -show_packets "$LOG/vcu_5min.mp4" > "$LOG/ffprobe.log" 2>&1
ffprobe -v error -count_packets -select_streams v:0 -show_entries stream=nb_read_packets \
        -count_frames -show_entries stream=nb_read_frames "$LOG/vcu_5min.mp4" > "$LOG/ffprobe_counts.log" 2>&1
ffmpeg -v error -i "$LOG/vcu_5min.mp4" -f null - 2> "$LOG/ffmpeg_decode_errors.log"
wc -l < "$LOG/ffmpeg_decode_errors.log"                  # 必须数 error 行
```

判定（照 11-10 的教训：**只看 rc 会骗人**，`vcu_5min_test.mp4` 当时 891 行解码错误但
`ffmpeg_rc=0`）：

- [ ] `ffprobe`：h264、3840x2160、时长约 300 s、packet/frame 数与标称 fps×300 相符
      （允许明确解释的偏差，偏差要写原因）；
- [ ] `ffmpeg -v error` 的 error 行数 = **0**（不是 rc=0）；
- [ ] 起点/终点差值：`packet_stats` submit/done 增量与 video1 帧数对得上，
      `err_cnt` 增量为 0；`ch0_drops`、`frame_drop_count` 增量与显示端观感一致；
- [ ] AER（`UESta`/`CESta`）增量为 0；`dmesg` 新增行无 error/warn/overflow；
- [ ] PS `boot_id` 与测试前相同（测试期间没有偷偷重启）；
- [ ] `mp4mux` 档档大小 > 0 且可被 `mp4dump`/`ffprobe` 解析出完整 atom 链。

只有以上全绿，才能写「**video0 桌面全屏 ＋ 硬体 VCU H.264 mp4 并发 5 分钟，稳态**」，
并附：session 资讯、caps、两条 log、mp4、ffprobe/ffmpeg 输出、前后计数表。任何一项
缺失 → 写「部分通过 + 缺什么」，不写 PASS。

---

## 5. 恢复（recovery）—— 主路径与最后手段

### 5.1 主路径：用完整更新包回退（唯一走 gate 的路）

前提：R0 已确认「与现行 BOOT.BIN 同包」的那一整包在主机上、sha256 已验算。

```bash
ssh rd@sc7f0-test.local "sudo /home/rd/qpcie_upgrade --package /home/rd/upgrade-<old>.tar"   # VERIFY
ssh rd@sc7f0-test.local 'sudo /home/rd/qpcie_upgrade --commit'                                 # 一次
ssh rd@sc7f0-test.local 'sudo /home/rd/qpcie_upgrade --reboot'
```

然后重复 3.4／3.5 的读回与 boot-ID/版本确认。规则：**一次 COMMIT，结果不明不重试**。

### 5.2 新 daemon 也支持：直接把 `.backup_upgrade/gen-*` 用回去

`qbr_recover_all()` 会在开机时解析中断中的交易；已完成的 `gen-*` 是完整三档。
**没有** daemon 端的「回复第 N 代」指令（刻意不新增写路径，避免多一个能写砖的接口）。

### 5.3 最后手段（只有卡已无法开机、且 5.1 无法执行时才用；需人工决策）

同 vfat 分区内把三档复制回根，再 `sync`：

```bash
# 需要另一个开机途径（SD installer / 序列主控），因为此时 PCIe/PS 可能都不在
mount /dev/mmcblk0p1 /mnt/restore
newest=$(ls -1d /mnt/restore/.backup_upgrade/gen-* | sort | tail -1)
cat "$newest/state"                      # 内容必须是 COMMITTED 才能用
cp "$newest/BOOT.BIN" "$newest/image.ub" "$newest/boot.scr" /mnt/restore/
sync; umount /mnt/restore
```

警告（必须照抄进执行记录）：
- 这三档**必须来自同一包**（`BOOT.BIN` 与 `image.ub`/`boot.scr` 混包是已知风险：三包
  的 `image.ub`/`boot.scr` 相同但 `BOOT.BIN` 不同）；
- eMMC 是「BOOT 分区 + RAM initramfs」双轨，只恢复一半可能起不来；
- 这条路**不经过任何 gate**，事后必须补一份完整包重装，把状态拉回受管路径；
- 它不是常规流程，写在这里只因为「没有它就没有退路」这件事不该藏在程式码注释里。

### 5.4 什么时候必须停下并上报（不要自行尝试）

- `.backup_upgrade/*/state` 内容为 `APPLYING`/`PREPARED`（或 `state` 档消失＝`UNKNOWN`），
  且 `qtx_recover` 回报非 0；
- daemon 日志出现 `must not be reflashed until this is reviewed`；
- `COMMIT` 后独立 SHA 与预期都不同、且无法判定写过哪些档；
- R0 无法建立（找不到同包 BOOT.BIN）；
- 需要暂停 `sc7f0_vcud` 才能做的测试（历史曾造成 20 分钟以上 soft hang，需断电）。

---

## 6. 本文件写作轮次未执行的事（不得由本文件推得已完成）

- **未** full build、**未** `--stage preflight/fpga/ps/package`；
- **未** SSH、**未** R0、**未** VERIFY/COMMIT/reboot、**未** 烧录、**未** 装 driver；
- **未** 跑 GStreamer 验收（第 4 节只有程序）；
- **未** 动 MCU、**未** `git add/commit/push`；
- 因此：**恢复能力状态 = 未证明（BLOCKED）**，直到第 2 节 R0 在真机上完成并留下
  三份 sha256 输出与 MANIFEST。

同一轮在本机**实际跑过**的验证（离线）见
[`docs/sc7f0_full_package_rebuild_20261111.md`](sc7f0_full_package_rebuild_20261111.md)
的「本轮（package 定稿）」小节。
