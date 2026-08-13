# QPCIe Multi-Channel Video & Audio Dataflow Wiki (TPG/AudioGen ➔ Host DDR RAM)

This document provides a comprehensive end-to-end architectural description of how Video (4K60 4 PPC) and Audio (32-bit AES3) streams are generated, packed, transferred over PCIe Gen3 x4, and delivered into Host DDR RAM buffers for consumption by Linux V4L2 and ALSA applications.

---

## 📑 Table of Contents
1. [End-to-End System Dataflow Diagram](#1-end-to-end-system-dataflow-diagram)
2. [Video Dataflow Pipeline (TPG ➔ Host DDR RAM)](#2-video-dataflow-pipeline-tpg--host-ddr-ram)
3. [Audio Dataflow Pipeline (AudioGen ➔ Host DDR RAM)](#3-audio-dataflow-pipeline-audiogen--host-ddr-ram)
4. [Memory Layout & Little-Endian Byte Order](#4-memory-layout--little-endian-byte-order)
5. [Interrupt & Buffer Completion Lifecycle](#5-interrupt--buffer-completion-lifecycle)
6. [BAR1 Control & Configuration Path](#6-bar1-control--configuration-path)

---

## 1. End-to-End System Dataflow Diagram

```
==================================================================================================
                                    FPGA HARDWARE LOGIC (xcku3p)
==================================================================================================

 [Video Source: Xilinx Video TPG]              [Audio Source: Audio Pattern Generator]
 4 PPC @ 125MHz (4K60 4:4:4)                   32-bit AES3 Subframe Stream @ 48kHz/96kHz
 96-bit AXI4-Stream (m_axis_video)             32-bit AXI4-Stream (m_axis_audio)
             │                                             │
             ▼                                             ▼
 [Pixel Packer (ku3p_pcie_card_top)]           [Direct Channel Mapping]
 Padded to 128-bit AYUV/V444                   Direct 32-bit Subframe Mapping
 [Pix3][Pix2][Pix1][Pix0]                      [Preamble][24-bit PCM][V][U][C][P]
             │                                             │
             ▼                                             ▼
 [2D Video Stream Engine]                      [Audio Stream Engine]
 (video_stream_engine.v)                       (audio_stream_engine.v)
 SOF (tuser) & EOL (tlast) Detection           Subframe Counter & Buffer Manager
             │                                             │
             └──────────────────────┬──────────────────────┘
                                    │ Internal AXI-Stream C2H Requests
                                    ▼
                     [Custom PCIe DMA Top Controller]
                     (custom_pcie_dma_top.v)
                                    │
                                    ▼
                     [PCIe RQ Encoder (rq_tx_encoder.v)]
                     Constructs PCIe 256-bit Memory Write (MWr) TLPs
                                    │
                                    ▼
                     [Xilinx PCIe Core (pcie4_uscale_plus_0)]
                     4 Lanes @ 8.0 GT/s (Gen3 x4, 3.2 GB/s Effective Throughput)
                                    │
====================================│=============================================================
                                    │ Physical PCIe Transceiver Lanes
====================================│=============================================================
                                    ▼
                               HOST COMPUTER
==================================================================================================
 [Host PCIe Root Complex & IOMMU System]
 Direct Memory Access (DMA) Memory Write TLPs into Host DDR RAM
                                    │
                                    ▼
 [Host DDR RAM Physical Memory Buffers]
 Allocated via dma_alloc_coherent() / vb2-dma-sg
 ├── Video Ring Buffers  : 3840x2160 AYUV / V444 Frames
 └── Audio Ring Buffers  : 32-bit AES3 PCM Subframes
                                    │
                                    ▼
 [Linux Kernel Driver Subsystem (custom_pcie_av.ko)]
 MSI Interrupt Handler (qpcie_irq_handler)
 ├── qpcie_v4l2.c : vb2_buffer_done() ➔ Signals Frame Completion to V4L2
 └── qpcie_alsa.c : snd_pcm_period_elapsed() ➔ Signals Audio Period to ALSA
                                    │
                                    ▼
 [User Space Applications & Multimedia Tools]
 ├── V4L2 App  : v4l2_test_app / GStreamer / FFmpeg / OBS Studio (via /dev/video0..3)
 └── ALSA App  : alsa_test_app / amixer / PulseAudio / PipeWire (via /dev/snd/pcmC0D0c)
```

---

## 2. Video Dataflow Pipeline (TPG ➔ Host DDR RAM)

### Step 2.1: Video Generation (`v_tpg_0` IP Core)
- **Clock Domain**: `pcie_user_clk` ($125.0\text{ MHz}$).
- **Configuration**: `SAMPLES_PER_CLOCK = 4` (4 PPC), `MAX_COLS = 3840`, `MAX_ROWS = 2160`.
- **Output Interface**: `m_axis_video` (96-bit TDATA, TVALID, TREADY, TLAST, TUSER, TKEEP, TSTRB).
- **Pixel Output Rate**: $125\text{ MHz} \times 4\text{ pixels/cycle} = \mathbf{500.0\text{ Mpixels/sec}}$, which covers 4K60 ($497.66\text{ Mpixels/sec}$) with zero clock bottlenecks.

### Step 2.2: Top-Level Pixel Packing (`ku3p_pcie_card_top.v`)
- The 96-bit 4 PPC stream (`tpg_axis_tdata[95:0]`) is padded with Alpha/Dummy bytes (`8'hFF`) to form a **128-bit AXI-Stream** (`s_video_tdata[127:0]`):
  ```verilog
  assign s_video_tdata[127:0] = {
      8'hFF, tpg_axis_tdata[95:72], // [127:96] -> Pixel 3 (32-bit AYUV)
      8'hFF, tpg_axis_tdata[71:48], // [95:64]  -> Pixel 2 (32-bit AYUV)
      8'hFF, tpg_axis_tdata[47:24], // [63:32]  -> Pixel 1 (32-bit AYUV)
      8'hFF, tpg_axis_tdata[23:0]   // [31:0]   -> Pixel 0 (32-bit AYUV)
  };
  ```

### Step 2.3: 2D Stream Engine Processing (`video_stream_engine.v`)
- Detects **SOF (Start of Frame)** via `tuser[0]` and **EOL (End of Line)** via `tlast`.
- Tracks current horizontal line index and vertical line count.
- Packs 128-bit stream cycles into **256-bit PCIe MWr payloads** (`c2h_req_data[255:0]`).

### Step 2.4: PCIe TLP Construction & Bus Transmission (`rq_tx_encoder.v` & `pcie4_uscale_plus_0`)
- Reads destination host physical memory address from active 64-Byte 2D Descriptor.
- Formats PCIe Gen3 x4 **64-bit Memory Write (MWr64)** Transaction Layer Packets (TLPs).
- Transmits over PCIe Gen3 x4 lanes ($3.2\text{ GB/s}$ effective bandwidth).

---

## 3. Audio Dataflow Pipeline (AudioGen ➔ Host DDR RAM)

### Step 3.1: Subframe Generation (`audio_pattern_gen.v`)
- **Clock Domain**: `pcie_user_clk` ($125.0\text{ MHz}$).
- **Sample Rate**: Divider logic (`REG_DIVISOR = 2604`) generates exact $48\text{ kHz}$ or $96\text{ kHz}$ sample ticks.
- **AES3 Subframe Encoding (32-bit)**:
  - `Bits [3:0]`   : Preamble (`4'hB` for Block Start, `4'hE` for Left/M, `4'hC` for Right/W).
  - `Bits [27:4]`  : 24-bit PCM Audio Sample (1kHz Sine Wave, Sawtooth, or 440Hz Tone).
  - `Bit 28`       : Validity Bit (V = 0).
  - `Bit 29`       : User Data Bit (U = 0).
  - `Bit 30`       : Channel Status Bit (C).
  - `Bit 31`       : Parity Bit (Even Parity P over Bits 4-30).

### Step 3.2: Audio Stream Engine & PCIe Transfer (`audio_stream_engine.v`)
- Transfers 32-bit subframes directly into Channel 0 Audio C2H DMA engine.
- Generates PCIe MWr TLPs targeting Host ALSA PCM ring buffers.

---

## 4. Memory Layout & Little-Endian Byte Order

When 128-bit video data (`s_video_tdata[127:0]`) is written to Host DDR RAM over Little-Endian PCIe MWr:

```
Host DDR RAM Memory Address (Increasing Offset ➔)
┌──────────────────┬──────────────────┬──────────────────┬──────────────────┐
│ Byte 0 .. 3      │ Byte 4 .. 7      │ Byte 8 .. 11     │ Byte 12 .. 15    │
├──────────────────┼──────────────────┼──────────────────┼──────────────────┤
│ Pixel 0 (32-bit) │ Pixel 1 (32-bit) │ Pixel 2 (32-bit) │ Pixel 3 (32-bit) │
│ [Comp0,1,2,Pad]  │ [Comp0,1,2,Pad]  │ [Comp0,1,2,Pad]  │ [Comp0,1,2,Pad]  │
└──────────────────┴──────────────────┴──────────────────┴──────────────────┘
```

- **Pixel Order**: Pixel 0 $\rightarrow$ Pixel 1 $\rightarrow$ Pixel 2 $\rightarrow$ Pixel 3 are stored **100% sequentially** in memory.
- **V4L2 Format Compatibility**: Maps directly to standard Linux V4L2 32-bit packed formats:
  - `V4L2_PIX_FMT_RGB32` / `V4L2_PIX_FMT_BGR32`
  - `V4L2_PIX_FMT_V444` (YUV 4:4:4 32-bit packed)

---

## 5. Hardware Video Frame Rate Pacer Mechanism

To deliver exact, zero-jitter frame rates (e.g. 60.00 fps, 59.94 fps, 50.00 fps, 30.00 fps, 24.00 fps), the 2D Video Stream Engine (`video_stream_engine.v`) integrates an active **Hardware Frame Rate Pacer** module.

### 5.1 Hardware Calculation & Pacing Formula
The total clock duration of each frame is governed by the 32-bit register `frame_interval_clks` (`REG_FRAME_INTERVAL_CLKS` at BAR1 Offset `0x0030`):

$$\text{REG\_FRAME\_INTERVAL\_CLKS} = \frac{F_{clk}}{\text{Target FPS}}$$

At FPGA Clock $F_{clk} = 125.0\text{ MHz}$, exact clock count values are configured as:

| Target Video Standard | Target FPS | `REG_FRAME_INTERVAL_CLKS` (125MHz) | Accuracy |
| :--- | :---: | :---: | :---: |
| **4K / 1080p Standard 60Hz** | **60.000 fps** | **`2,083,333`** | **99.999%** |
| **Broadcast NTSC 60Hz** | **59.940 fps** | **`2,085,417`** | **99.999%** |
| **European PAL 50Hz** | **50.000 fps** | **`2,500,000`** | **100.000%** |
| **Standard 30Hz** | **30.000 fps** | **`4,166,667`** | **100.000%** |
| **Broadcast NTSC 30Hz** | **29.970 fps** | **`4,170,833`** | **99.999%** |
| **Cinema 24Hz** | **24.000 fps** | **`5,208,333`** | **100.000%** |

### 5.2 RTL Finite State Machine (FSM) Implementation (`video_stream_engine.v`)
- **Timer Counter (`pacer_clk_cnt`)**: Resets to zero on Frame Start (`SOF`), counts up every clock cycle ($125\text{ MHz}$).
- **State Transition (`C2H_SEND` ➔ `C2H_PACE` ➔ `IDLE`)**:
  - Upon completing line transfers of a frame (`curr_line + 1 == line_count`), the state machine checks if `pacer_clk_cnt < frame_interval_clks`.
  - If true, it transitions to `C2H_PACE` to hold `video_frame_done` until `pacer_clk_cnt >= frame_interval_clks`.
  - This guarantees microsecond-accurate, zero-jitter frame spacing regardless of TPG burst processing speed!

```
 FSM States:
 [IDLE] ──► [C2H_LINE (Collect Line)] ──► [C2H_SEND (PCIe MWr)] ──► [C2H_PACE (Wait Clks)] ──► [IDLE (Frame Done)]
```

### 5.3 Driver & V4L2 Control API Integration
- **V4L2 Standard `VIDIOC_S_PARM` ioctl**:
  Calling `v4l2-ctl -d /dev/video0 --set-parm=60` calculates `target_clks = 125000000 / FPS` and writes directly to BAR1 `0x0030`.
- **Sysfs Node (`tpg_fps`)**:
  Reading `/sys/bus/pci/devices/.../tpg_fps` reports current FPS (e.g. `60 fps (Interval Clks: 2083333)`).
  Writing `echo 30 > /sys/bus/pci/devices/.../tpg_fps` updates pacing in real time.

---

## 6. Interrupt & Buffer Completion Lifecycle

```
 FPGA Hardware                                 Linux Kernel Driver (`custom_pcie_av.ko`)
 ─────────────                                 ──────────────────────────────────────────
 DMA Write Finished ──► MSI Interrupt ───────► qpcie_irq_handler()
                                                     │
                                                     ├──► qpcie_v4l2_irq_handler()
                                                     │    ├── Updates vb2_buffer timestamp
                                                     │    └── Calls vb2_buffer_done(VB2_BUF_STATE_DONE)
                                                     │        └── Wakes up select()/poll() in V4L2 App
                                                     │
                                                     └──► qpcie_alsa_irq_handler()
                                                          ├── Updates PCM period position
                                                          └── Calls snd_pcm_period_elapsed()
                                                              └── Wakes up read() in ALSA App
```

---

## 7. BAR1 Control & Configuration Path

User space applications configure hardware IP cores without direct MMIO by calling standard Linux kernel subsystem frameworks:

- **Video TPG Control Path**:
  - `v4l2-ctl --set-ctrl=test_pattern=3` ➔ `ioctl(VIDIOC_S_CTRL)` ➔ `qpcie_s_ctrl()` ➔ `iowrite32()` to BAR1 `0x0000 + 0x0020` (TPG Pattern ID).
- **Video Frame Pacer Control Path**:
  - `v4l2-ctl --set-parm=60` ➔ `ioctl(VIDIOC_S_PARM)` ➔ `qpcie_vidioc_s_parm()` ➔ `iowrite32()` to BAR1 `0x0000 + 0x0030` (Frame Pacer Clks).
- **Audio AudGen Control Path**:
  - `amixer set 'Audio Pattern' '1kHz Sine Wave'` ➔ `snd_ctl_elem_write` ➔ `qpcie_alsa_pattern_put()` ➔ `iowrite32()` to BAR1 `0x0100 + 0x0000` (AudGen Ctrl).

