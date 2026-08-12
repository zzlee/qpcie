# Wiki - Linux V4L2 (MMAP/USERPTR/DMABUF/EXPBUF) 與 ALSA PCIe 驅動程式指南

本專案之 Linux V4L2 視訊驅動程式在 [`driver/qpcie_v4l2.c`](file:///home/zzlee/qpcie/driver/qpcie_v4l2.c) 中完整實作並支援四大記憶體傳輸模式：

1. **`MMAP` (Memory-Mapped)**：驅動程式 Kernel 空間分配記憶體並映射給 User 空間。
2. **`USERPTR` (User Pointer)**：User 空間應用程式 (如 malloc / posix_memalign) 分配記憶體指標，由驅動進行 IOMMU 映射。
3. **`DMABUF` (DMA-BUF Import)**：匯入其他硬體驅動 (如 GPU / DRM / VPU) 導出之 `dma-buf` file descriptor (fd)。
4. **`EXPBUF` (Export Buffer)**：本驅動程式作為 exporter，將內部分配的 buffer 導出為 `dma-buf` fd 供 GPU / DRM 零拷貝 (Zero-Copy) 存取。

---

## 1. 驅動程式實作細節 (`io_modes` 與 `vidioc_*` IOCTLs)

### 1.1 Videobuf2 佇列設定 (`vb2_queue_init`)
```c
vch->queue.type     = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
vch->queue.io_modes = VB2_MMAP | VB2_USERPTR | VB2_DMABUF; /* 啟用 MMAP, USERPTR, DMABUF */
vch->queue.ops      = &qpcie_vb2_ops;
vch->queue.mem_ops  = &vb2_dma_sg_memops;
```

### 1.2 支持之 IOCTLs (`qpcie_v4l2_ioctl_ops`)
```c
.vidioc_reqbufs     = vb2_ioctl_reqbufs,
.vidioc_querybuf    = vb2_ioctl_querybuf,
.vidioc_qbuf        = vb2_ioctl_qbuf,
.vidioc_dqbuf       = vb2_ioctl_dqbuf,
.vidioc_prepare_buf = vb2_ioctl_prepare_buf,
.vidioc_create_bufs = vb2_ioctl_create_bufs,

/* 導出 DMA-BUF fd IOCTL */
.vidioc_expbuf      = vb2_ioctl_expbuf,
```

---

## 2. 四大模式 `v4l2-ctl` 測試命令列範例

### 2.1 測試 MMAP 模式 (Memory-Mapped)

```bash
v4l2-ctl -d /dev/video0 \
  --set-fmt-video=width=1920,height=1080,pixelformat=YUV420M \
  --stream-mmap \
  --stream-count=100
```

### 2.2 測試 USERPTR 模式 (User Pointer)

```bash
v4l2-ctl -d /dev/video0 \
  --set-fmt-video=width=1920,height=1080,pixelformat=YUV420M \
  --stream-user \
  --stream-count=100
```

### 2.3 測試 DMABUF / EXPBUF 模式 (DMA-BUF 零拷貝)

```bash
# Export buffer 並透過 dma-buf 傳遞串流
v4l2-ctl -d /dev/video0 \
  --set-fmt-video=width=1920,height=1080,pixelformat=NV12M \
  --stream-dmabuf \
  --stream-count=100
```

---

## 3. GStreamer / FFmpeg 零拷貝 (Zero-Copy) Pipeline 範例

### GStreamer DMA-BUF 零拷貝管線：
```bash
gst-launch-1.0 v4l2src device=/dev/video0 io-mode=dmabuf ! \
  video/x-raw,format=NV12,width=1920,height=1080 ! \
  waylandsink sync=false
```

### FFmpeg MMAP 擷取：
```bash
ffmpeg -f v4l2 -input_format YUV420M -video_size 1920x1080 -i /dev/video0 output.mp4
```
