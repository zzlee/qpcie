# Linux V4L2 Driver 與 NV12M 測試指南

> 目前 A50T bring-up 只啟用一個 V4L2 capture node、MMAP 與 DMA-contiguous planes。ALSA、USERPTR、DMABUF import/export 及 video channel 1–3 暫停。舊文件中的多通道/零拷貝命令不代表目前已驗證能力。

## 1. Driver build/load

```bash
cd /home/zzlee/qpcie
make -C driver clean && make -C driver
sudo insmod driver/custom_pcie_av.ko
dmesg | tail -n 180
```

核心檔案：

- `driver/qpcie_main.c`：PCI probe、BAR map、IRQ、SG diagnostic、retained ring state。
- `driver/qpcie_v4l2.c`：V4L2/VB2、TPG controls、descriptors、STREAMON/OFF。
- `driver/qpcie_driver.h`：register map 與 64-byte descriptor wire format。

## 2. Current V4L2 capabilities

- Device：`/dev/video0`。
- Type：`V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE`。
- Pixel format：`V4L2_PIX_FMT_NV12M` (`NM12`)。
- Memory：`V4L2_MEMORY_MMAP`。
- Memory ops：`vb2_dma_contig_memops`。
- Planes：2。
- Modes：1920×1080@60、3840×2160@60。

```bash
v4l2-ctl -d /dev/video0 --list-formats-ext
```

## 3. Mode negotiation

Driver 實作 `ENUM_FRAMESIZES`、`ENUM_FRAMEINTERVALS`、`TRY_FMT`、`S_FMT`、`G_FMT`。只有 queue 尚未配置/streaming 時可切換 mode。

`S_FMT` 會 reset TPG/CDC FIFO、重新設定 width/height/pattern/YUV444/AUTO_RESTART 並驗證 readback。若失敗，ioctl 回傳 error，不允許繼續 capture。

## 4. VB2 buffer 與 descriptor

每個 MMAP buffer 有兩個 DMA-contiguous planes：

```text
1080p: Y=2,073,600, UV=1,036,800
4K:    Y=8,294,400, UV=4,147,200
```

`buf_prepare` 檢查 plane allocation size 並設定 bytesused。`buf_queue` 取得兩個 DMA addresses、填入 NV12M 64-byte descriptor，再用 `dma_wmb()` 發布 tail doorbell。

Linux API compatibility：

- `<6.8`：`min_buffers_needed=2`。
- `>=6.8`：`min_queued_buffers=2`。

## 5. Controls

### Test pattern

標準 `V4L2_CID_TEST_PATTERN` 提供 generated patterns。Color Bars menu value 3 映射到 hardware pattern 9；Zone Plate menu value 4 映射到 10。TPG 沒有 input stream，所以 pass-through item 0 被 skip。

### Pacer

Private `V4L2_CID_QPCIE_PACER_ENABLE`：

- 1：60 FPS paced correctness mode。
- 0：uncapped DMA benchmark。

一般應用只需 `VIDIOC_S_PARM=1/60`；private control 僅供 `v4l2_test_app --benchmark`。

## 6. Build test app

```bash
make -C test_app clean
make -C test_app v4l2_test_app
```

App 會驗證：capabilities、format、兩個 discrete modes、1/60 interval、plane sizes、sequence、bytesused、first-frame hashes/ranges、static-frame consistency、throughput 與 STREAMOFF ioctl。

## 7. 1080p tests

Control-only：

```bash
./test_app/v4l2_test_app --dev /dev/video0 \
  --width 1920 --height 1080 --probe --pattern 9 --fps 60
```

Paced correctness：

```bash
./test_app/v4l2_test_app --dev /dev/video0 \
  --width 1920 --height 1080 --frames 60 --pattern 9 --fps 60 \
  --out /tmp/qpcie-1080p-nv12.yuv
```

輸出大小應為 3,110,400 bytes。

## 8. 4K tests

Control/mode-switch probe：

```bash
./test_app/v4l2_test_app --dev /dev/video0 \
  --width 3840 --height 2160 --probe --pattern 9 --fps 60
```

Paced correctness：

```bash
./test_app/v4l2_test_app --dev /dev/video0 \
  --width 3840 --height 2160 --frames 60 --pattern 9 --fps 60 \
  --out /tmp/qpcie-4k-nv12.yuv
```

輸出大小應為 12,441,600 bytes。

600-frame benchmark：

```bash
./test_app/v4l2_test_app --dev /dev/video0 \
  --width 3840 --height 2160 --benchmark --frames 600 --pattern 9
```

門檻是 711.91 MiB/s。最新 4K checkpoint 尚待此實機驗證。

## 9. STREAMOFF 與 kernel log

Driver 會先關 pacer，最多等待 500 ms 讓 active descriptors、posted MWr、head/tail 全部 drain，再停止 DMA並 `synchronize_irq()`。

```bash
dmesg | grep 'NV12M STREAMOFF' | tail -2
dmesg | grep -Ei 'smmu|context fault|decode error|protocol errors'
```

必須看到 `drained=1`、head=tail、`video_errors=0`。V4L2 STREAMOFF ioctl 成功仍需搭配 kernel log 判定硬體 drain 狀態。

## 10. ALSA 狀態

Audio RTL/driver source 仍在 repository，但 A50T 視訊 bring-up 中不初始化 ALSA。完成 4K60 前，不把 ALSA 或多通道音訊列為已驗證功能。
