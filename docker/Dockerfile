# ============================================================================
# QPCIe testbench Docker image
#
# Purpose:
#   Lightweight, license-free environment for running the QPCIe Verilog
#   testbenches (tb/*.v) with open-source EDA tools:
#
#     * iverilog / vvp   - Icarus Verilog 12  (primary Verilog simulator)
#     * verilator        - SystemVerilog linting + --timing simulation
#     * gtkwave          - VCD / FST waveform viewer (dumps to /work/out)
#     * make, g++        - for Verilator generated C++ models
#
# Usage:
#   docker build -t qpcie-tb:latest ./docker
#   docker run --rm -v "$PWD":/work qpcie-tb bash docker/run_tb.sh
#   docker run --rm -v "$PWD":/work qpcie-tb bash docker/run_tb.sh tb_cq_rx_decoder
#   docker run --rm -v "$PWD":/work qpcie-tb bash   # interactive shell
#
# Xilinx XPM (system-level TBs only):
#   tb_video_cdc_system / tb_pcie_dma_system / tb_sg_dma_pipeline instantiate
#   XPM primitives (xpm_fifo_async, xpm_cdc_handshake). Copy the simulation
#   sources from a Vivado install into ./docker/xpm/ to enable them:
#     cp /opt/Xilinx/Vivado/<ver>/data/ip/xpm/xpm_cdc/hdl/xpm_cdc.sv \
#        /opt/Xilinx/Vivado/<ver>/data/ip/xpm/xpm_fifo/hdl/xpm_fifo.sv \
#        /opt/Xilinx/Vivado/<ver>/data/ip/xpm/xpm_memory/hdl/xpm_memory.sv \
#        docker/xpm/
# ============================================================================

FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        iverilog \
        verilator \
        gtkwave \
        make \
        g++ \
        python3 \
        tcl \
        less \
        vim-tiny \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Keep the toolchain versions documented in one place.
RUN echo "iverilog: $(iverilog -V 2>&1 | head -1)" && \
    echo "verilator: $(verilator --version)" && \
    echo "gtkwave: $(gtkwave --version 2>&1 | head -1)"

WORKDIR /work
CMD ["/bin/bash"]