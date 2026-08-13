# QPCIe V4L2 & ALSA User-Mode Test Applications

This directory contains standalone, high-performance C user-mode test applications for testing the **QPCIe Linux Kernel V4L2 Video Subsystem** and **ALSA Audio Subsystem** drivers.

---

## 📁 Applications Included

1. **`v4l2_test_app`**:
   - Tests V4L2 video capture pipeline (`/dev/video0`).
   - Supports **4 Memory Allocation Modes**:
     - `MMAP`: Kernel-allocated memory mapped into user space (`V4L2_MEMORY_MMAP`).
     - `USERPTR`: User-allocated aligned memory passed to driver (`V4L2_MEMORY_USERPTR`).
     - `DMABUF`: DMA-BUF zero-copy buffer sharing (`V4L2_MEMORY_DMABUF`).
     - `EXPBUF`: Exporting V4L2 buffer file descriptors (`VIDIOC_EXPBUF`).
   - Dynamically configures Xilinx Video TPG IP patterns via sysfs (`Color Bar`, `Zone Plate`, `Checkerboard`, etc.).
   - Computes per-frame checksums, capture FPS, and saves raw YUV/RGB frames to disk.

2. **`alsa_test_app`**:
   - Tests ALSA PCM audio capture pipeline (`/dev/snd/pcmC0D0c`).
   - Configures **32-bit AES3 Audio Subframes** (`S32_LE`) @ **48kHz Stereo**.
   - Parses 32-bit AES3 subframe preambles (`B/M/W`) and extracts 24-bit LSB-first PCM audio samples.
   - Computes Audio Signal RMS Energy and verifies 1kHz Sine Wave / Tone output from hardware.
   - Dynamically configures Audio Pattern Generator via sysfs (`1kHz Sine`, `Sawtooth`, `440Hz Tone`, `Mute`).

---

## 🛠️ Building the Test Applications

Simply run `make` inside the `test_app` directory:

```bash
cd test_app
make
```

This will produce the two binaries: `v4l2_test_app` and `alsa_test_app`.

---

## 🚀 Running V4L2 Video Tests

### 1. MMAP Mode (Default)
```bash
./v4l2_test_app --dev /dev/video0 --mode mmap --frames 60 --out frame.yuv
```

### 2. USERPTR Mode (User-allocated buffer)
```bash
./v4l2_test_app --dev /dev/video0 --mode userptr --frames 60
```

### 3. DMABUF Import Mode
```bash
./v4l2_test_app --dev /dev/video0 --mode dmabuf --frames 60
```

### 4. EXPORTBUFFER Export Mode
```bash
./v4l2_test_app --dev /dev/video0 --mode expbuf --frames 60
```

### 5. Switch Video TPG Pattern (Color Bars / Zone Plate)
```bash
./v4l2_test_app --dev /dev/video0 --mode mmap --pattern 9 --frames 30
```

---

## 🎧 Running ALSA Audio Tests

### 1. Capture 5 Seconds of 48kHz Stereo Audio
```bash
./alsa_test_app --dev /dev/snd/pcmC0D0c --rate 48000 --seconds 5 --out captured_audio.pcm
```

### 2. Switch Audio Pattern (1kHz Sine / Sawtooth)
```bash
./alsa_test_app --dev /dev/snd/pcmC0D0c --pattern 0 --seconds 5
```

---

## 📊 Expected Output Example

### V4L2 Capture Output:
```
=================================================================
 QPCIe V4L2 Capture Test Application
 Device: /dev/video0, Format: 1920x1080, Frames: 30
 Memory Mode: MMAP
=================================================================
[V4L2 Cap] Driver: qpcie_v4l2, Card: QPCIe Video Capture, Bus: PCI:0000:01:00.0
[V4L2 Format] Set Width: 1920, Height: 1080, SizeImage: 4147200
[V4L2 ReqBufs] Allocated 4 buffers
--> Stream Started Successfully. Capturing 30 frames...
  [Frame 001] Index: 0, Bytes: 4147200, Checksum (first 1K): 0x000F802A
    Saved Frame 1 to file frame.yuv
  [Frame 002] Index: 1, Bytes: 4147200, Checksum (first 1K): 0x000F802A
  ...
=================================================================
 Capture Finished: 30 frames in 500.12 ms (59.99 FPS)
=================================================================
```

### ALSA Capture Output:
```
=================================================================
 QPCIe ALSA Audio Capture Test Application
 Device: /dev/snd/pcmC0D0c, Channels: 2, Rate: 48000 Hz, Duration: 5 sec
 Format: 32-bit AES3 Subframe (S32_LE)
=================================================================
[ALSA Driver] Protocol Version: 2.0.15
--> ALSA HW Parameters Configured (Format: S32_LE, Channels: 2, Rate: 48000 Hz)
--> Capturing 5 seconds of AES3 Audio Data...
  [Progress] Captured 240000 / 240000 frames (100.0%)
=================================================================
 Audio Capture Finished: 240000 frames (5.00 sec)
 Captured Audio RMS Energy : 0.7071 (-3.01 dBFS)
 AES3 Signal Status        : ACTIVE 1kHz Sine/Pattern OK
=================================================================
```
