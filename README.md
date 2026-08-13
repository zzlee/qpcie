# QPCIe Multi-Channel 4K60 Video & AES3 Audio PCIe Capture Card

High-performance, multi-channel 2D Video (V4L2) and AES3 Audio (ALSA) PCIe capture card implementation for AMD/Xilinx Kintex UltraScale+ FPGA (`xcku3p-ffva676-2-e`).

---

## 🚀 Key Features

* **FPGA Hardware (RTL)**:
  - Xilinx UltraScale+ PCIe Core (`pcie4_uscale_plus_0`) Gen3 x4 @ 256-bit AXI-Stream.
  - 4-Channel 2D Multi-Planar Video Stream Engine (YUV420M, NV12M, Mono, 32-bit AYUV/V444).
  - 4-Channel AES3 32-bit Subframe Audio Stream Engine (48kHz / 96kHz).
  - Xilinx Video Test Pattern Generator IP (`v_tpg_0`) running at **4 PPC 4K60** ($500.0\text{ Mpixel/s}$).
  - Hardware Audio Pattern Generator (`audio_pattern_gen`) with 1kHz Sine, 440Hz, Sawtooth, and Mute patterns.
  - Hardware Frame Rate Pacer (`pacer_clk_cnt`) for zero-jitter, microsecond-accurate FPS control (60, 59.94, 50, 30, 24 fps).
  - Timing 100% Closed (**WNS = `+1.441 ns`**, **TNS = `0.000 ns`**).

* **Linux Kernel Driver (`custom_pcie_av.ko`)**:
  - V4L2 Capture Subsystem Driver (`/dev/video0` .. `/dev/video3`) supporting MMAP, USERPTR, DMABUF, and EXPORTBUFFER modes.
  - Standard V4L2 Control Framework (`V4L2_CID_TEST_PATTERN`) & `VIDIOC_S_PARM` for TPG pattern and FPS selection.
  - ALSA Capture Subsystem Driver (`/dev/snd/pcmC0D0c` .. `/dev/snd/pcmC3D0c`) supporting 32-bit AES3 subframes (`S32_LE`).
  - Standard ALSA Control Mixer (`'Audio Pattern'`, `'PCM Volume'`).
  - Sysfs Device Attributes (`tpg_pattern`, `tpg_resolution`, `tpg_fps`, `aud_pattern`, `aud_volume`, `version`).

* **User-Mode Applications (`test_app/`)**:
  - `v4l2_test_app`: Comprehensive V4L2 video capture, memory mode testing, pattern selection, FPS control, and YUV saving.
  - `alsa_test_app`: ALSA AES3 audio capture, subframe preamble verification, RMS energy & 1kHz sine wave analysis.

---

## 📚 Project Documentation & Wiki

All comprehensive design documents, hardware specs, dataflow guides, and driver references have been organized under the [`wiki/`](wiki/Home.md) directory:

👉 **[Go to Project Wiki (`wiki/Home.md`)](wiki/Home.md)**

* **[AV Dataflow Wiki (TPG/AudioGen ➔ Host DDR RAM)](wiki/AV_DATAPATH_WIKI.md)**
* **[FPGA Build & Synthesis Guide](wiki/FPGA-Build-Guide.md)**
* **[Linux V4L2 & ALSA Driver Guide](wiki/Linux-V4L2-ALSA-Driver-Guide.md)**
* **[DMA Core Layer & Descriptor Structure](wiki/DMA-Core-Layer.md)**
* **[Verification & Simulation Guide](wiki/Verification-and-Simulation.md)**
