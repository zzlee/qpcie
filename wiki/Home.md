# QPCIe Project Wiki

Welcome to the **QPCIe Multi-Channel 4K60 Video & AES3 Audio PCIe Capture Card Wiki**.
This directory contains complete technical documentation covering FPGA RTL hardware logic, PCIe Gen3 x4 DMA engines, Vivado bitstream synthesis, Linux kernel drivers (V4L2 & ALSA), and user-mode test applications.

---

## 📑 Documentation Sitemap

### 1. 📘 System Overview & Build Guides
* **[Overview](Overview.md)** - Comprehensive project architecture, feature matrix, and technical highlights.
* **[FPGA Build Guide](FPGA-Build-Guide.md)** - Step-by-step Vivado batch compilation, bitstream synthesis, and XDC pinout constraints.

### 2. 🎬 Video & Audio Datapath Architecture
* **[AV Datapath & Hardware Architecture](AV_DATAPATH_WIKI.md)** - Complete end-to-end dataflow description for 4K60 4 PPC Video and 32-bit AES3 Audio from hardware IP cores down to Host DDR RAM.
* **[Artix UltraScale+ AU15P Cost-Down Feasibility Analysis](AU15P_FEASIBILITY.md)**
* **[Artix-7 A50T pg054 PCIe IP Migration & Reusability Analysis](A50T_MIGRATION.md)**
* **[Low-Latency Sub-5ms Capture & PCIe Interrupt Architecture](Low-Latency-Capture-Guide.md)**
* **[Multi-Channel Stream Architecture](Multi-Channel-Stream-Architecture.md)** - Architecture of 4-Channel 2D Video Engine (YUV420M, NV12M, Mono, AYUV) and 4-Channel AES3 Audio Engine.
* **[Multi-Channel Video & Audio Config](Multi-Channel-Video-Audio-Config.md)** - Hardware stream configurations, frame pacing, and clocking.

### 3. ⚡ FPGA RTL & PCIe DMA Core Layer
* **[DMA Core Layer](DMA-Core-Layer.md)** - 64-Byte 2D Multi-Planar Extended Descriptor structure and ring buffer logic.
* **[TLP Layer](TLP-Layer.md)** - PCIe Gen3 x4 256-bit TLP encoding, CQ/CC/RQ/RC decoders, and tag management.
* **[Control Layer](Control-Layer.md)** - BAR0 Register Space (DMA control, ring base addresses, Version ID, Git commit hash, build timestamp).
* **[BAR1 Interconnect & IP Cores](Controlling-Other-IP-Cores.md)** - BAR1 AXI-Lite 1x3 Crossbar routing to Video TPG IP (`0x0000`), Audio Pattern Gen (`0x0100`), and User Regs (`0x0200`).

### 4. 🐧 Linux Kernel Driver & User Applications
* **[Linux V4L2 & ALSA Driver Guide](Linux-V4L2-ALSA-Driver-Guide.md)** - Linux kernel driver (`custom_pcie_av.ko`), V4L2 Control Framework (`V4L2_CID_TEST_PATTERN`), ALSA Mixer Controls (`snd_kcontrol`), and Sysfs device attributes.
* **[Linux Driver Scatterlist & DMA Guide](Linux-Driver-Scatterlist-Guide.md)** - Coherent DMA ring allocations (`dma_alloc_coherent`), videobuf2 sg memory operations, and MSI interrupts.

### 5. 🧪 Simulation & Verification
* **[Verification and Simulation](Verification-and-Simulation.md)** - 11 Verilog Testbenches suite (`sim/run_sim.sh`) and verification methodology.
