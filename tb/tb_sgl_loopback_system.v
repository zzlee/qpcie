// ============================================================================
// Testbench: tb_sgl_loopback_system
// Description: Full end-to-end reproduction of the driver's forced host-SGL
//              NV12M loopback on real hardware:
//                MMIO setup -> desc_fetch (tag 0 MRd) -> SGL table fetch
//                (tag 1 MRd, 2-slot chained Y table + Y/UV switch) ->
//                H2C walker -> H2C payload MRds (tags 2..17) -> reorder ->
//                loopback FIFO -> ch1 NV12 capture engine (RAW_INPUT) ->
//                C2H MWrs to the C2H SGL destination table.
//              The host BFM responds to every MRd (descriptor, SGL table,
//              H2C payload) with multi-beat CplDs in 7-series native format
//              and captures all C2H MWr payloads for a golden stream check.
//
//              The whole BFM is procedural (task-based), mirroring the
//              proven patterns of tb_pcie_7x_axi_bridge and
//              tb_video_cdc_system: MMIO writes and CplD responses are
//              driven beat-by-beat with m_axis_rx_tready handshakes, and a
//              single dispatcher loop services every request the FPGA issues
//              (MRd -> CplD response, MWr -> payload capture) in order.
//
//              Two phases mirror the driver's publish order:
//                Phase A: publish ONLY the H2C descriptor (tail=1).  Verifies
//                  the SGL fetch completes, desc_fetch advances (head=1), and
//                  H2C payload MRds flow (loopback FIFO fills -> H2C stalls,
//                  as designed, because no C2H capture is armed yet).
//                Phase B: publish the C2H descriptor (tail=2).  Verifies the
//                  capture engine drains the loopback and writes the full
//                  frame back: desc head reaches 2, the full payload is
//                  captured in order, C2H MWr addresses land on the C2H
//                  SGL destination table.
// ============================================================================
`timescale 1ns / 1ps

module tb_sgl_loopback_system;

    localparam integer WIDTH = 2048;
    localparam integer HEIGHT = 512;
    localparam integer Y_BYTES  = WIDTH * HEIGHT;              // 1,048,576
    localparam integer UV_BYTES = WIDTH * (HEIGHT/2);          // 524,288
    localparam integer TOTAL_BYTES = Y_BYTES + UV_BYTES;       // 1,572,864
    localparam integer TOTAL_DWS = TOTAL_BYTES / 4;            // 393,216
    localparam integer Y_DWS = Y_BYTES / 4;
    localparam integer Y_ENTRIES = Y_BYTES / 4096;             // 256 (255+1 -> chain)
    localparam integer UV_ENTRIES = UV_BYTES / 4096;           // 128

    // Address map (mirrors the driver's coherent allocations)
    localparam [63:0] RING_BASE    = 64'h0000_0000_FFFF_E000;
    localparam [63:0] H2C_Y_PAY    = 64'h0000_0000_1000_0000;
    localparam [63:0] H2C_UV_PAY   = 64'h0000_0000_1100_0000;
    localparam [63:0] H2C_Y_SLOT0  = 64'h0000_0000_2000_0000; // Y SGL slot0 (255 ent)
    localparam [63:0] H2C_Y_SLOT1  = 64'h0000_0000_2000_1000; // Y SGL slot1 (chain)
    localparam [63:0] H2C_UV_SLOT  = 64'h0000_0000_2000_2000; // UV SGL slot
    localparam [63:0] C2H_Y_SLOT0  = 64'h0000_0000_3000_0000;
    localparam [63:0] C2H_Y_SLOT1  = 64'h0000_0000_3000_1000;
    localparam [63:0] C2H_UV_SLOT  = 64'h0000_0000_3000_2000;
    localparam [63:0] C2H_Y_DST    = 64'h0000_0000_4000_0000;
    localparam [63:0] C2H_UV_DST   = 64'h0000_0000_4100_0000;

    // 7-Series native streams
    reg  [127:0] m_axis_rx_tdata;
    reg  [15:0]  m_axis_rx_tkeep;
    reg          m_axis_rx_tlast;
    reg          m_axis_rx_tvalid;
    reg  [21:0]  m_axis_rx_tuser;
    wire         m_axis_rx_tready;
    wire [127:0] s_axis_tx_tdata;
    wire [15:0]  s_axis_tx_tkeep;
    wire         s_axis_tx_tlast;
    wire         s_axis_tx_tvalid;
    reg          s_axis_tx_tready;
    wire [3:0]   s_axis_tx_tuser;

    reg [127:0] tx_tlp_data;
    reg         tx_tlp_last;
    reg [3:0]   tx_tlp_user;
    reg         phase_b_pub = 0;

    // Internal 128-bit streams
    wire [127:0] cq_tdata, cc_tdata, rq_tdata, rc_tdata;
    wire         cq_tvalid, cq_tlast, cq_tready;
    wire         cc_tvalid, cc_tlast, cc_tready;
    wire         rq_tvalid, rq_tlast, rq_tready;
    wire         rc_tvalid, rc_tlast, rc_tready;
    wire [87:0]  cq_tuser;
    wire [32:0]  cc_tuser;
    wire [61:0]  rq_tuser;
    wire [74:0]  rc_tuser;
    wire [15:0]  cq_tkeep, cc_tkeep, rq_tkeep, rc_tkeep;

    reg clk = 0;
    reg rst_n = 0;
    always #4.0 clk = ~clk;

    wire usr_irq_req;
    reg usr_irq_ack = 0;

    // RC-stream probe: dump the descriptor CplD beats (tag 0) for debugging
    integer rc_probe_cnt = 0;
    always @(posedge clk) begin
        if (rc_tvalid && rc_tready && rc_tdata[71:64] == 8'h00 && rc_probe_cnt < 24) begin
            $display("  [RC%0d] tag=%0d len=%0d data=%h keep=%h last=%b | nat=%h nat_valid=%b rx_state=%0d",
                     rc_probe_cnt, rc_tdata[71:64], rc_tdata[42:32],
                     rc_tdata, rc_tkeep, rc_tlast,
                     m_axis_rx_tdata, m_axis_rx_tvalid, u_bridge.rx_state);
            rc_probe_cnt = rc_probe_cnt + 1;
        end
    end

    // ------------------------------------------------------------------
    // Host memory models (32-bit DW arrays, true little-endian values)
    // ------------------------------------------------------------------
    reg [31:0] ring_mem    [0:255];       // 1 KB descriptor ring
    reg [31:0] sgl_h2c_mem [0:3071];      // 3 slots x 4 KB
    reg [31:0] sgl_c2h_mem [0:3071];
    reg [31:0] y_pay_mem   [0:(Y_BYTES/4)-1];
    reg [31:0] uv_pay_mem  [0:(UV_BYTES/4)-1];

    // C2H MWr capture
    reg [31:0] cap_mem [0:TOTAL_DWS-1];
    integer    cap_dw_cnt = 0;
    integer    cap_bad_addr = 0;
    integer    mwr_burst_cnt = 0;

    // Request observation counters
    integer    mrd_desc_cnt = 0;   // tag 0
    integer    mrd_sgl_cnt = 0;    // tag 1
    integer    mrd_h2c_cnt = 0;    // tag >= 2
    integer    mrd_dbg_cnt = 0;    // printed-MRd limiter

    // TX monitor queue: the PCIe link is full-duplex, so requester TLPs can be
    // emitted while the BFM is driving completions. Capture every FPGA->host
    // MRd/MWr beat here; the dispatcher below only pops queued MRds and sends
    // matching CplDs.
    localparam integer REQ_Q_DEPTH = 8192;
    reg [63:0] req_q_addr [0:REQ_Q_DEPTH-1];
    reg [7:0]  req_q_tag  [0:REQ_Q_DEPTH-1];
    reg [15:0] req_q_id   [0:REQ_Q_DEPTH-1];
    reg [10:0] req_q_len  [0:REQ_Q_DEPTH-1];
    integer req_q_wr = 0;
    integer req_q_rd = 0;

    reg        mon_mwr_active = 0;
    reg [63:0] mon_mwr_addr = 64'd0;
    integer    mon_mwr_beats_left = 0;
    integer    mon_mwr_beat_idx = 0;
    reg [9:0]  mon_mwr_len_dw;
    reg [63:0] mon_dst;
    reg [31:0] mon_d0, mon_d1, mon_d2, mon_d3;

    // ------------------------------------------------------------------
    // Byte-swap helper (7-series native payload DWs: PCIe byte 0 at [31:24])
    // ------------------------------------------------------------------
    function [31:0] host_dw;
        input [31:0] v;
        begin host_dw = {v[7:0], v[15:8], v[23:16], v[31:24]}; end
    endfunction

    function [31:0] mem_dw;
        input [63:0] a;
        begin
            if (a >= RING_BASE && a < RING_BASE + 64'h400)
                mem_dw = ring_mem[(a - RING_BASE) >> 2];
            else if (a >= H2C_Y_PAY && a < H2C_Y_PAY + Y_BYTES)
                mem_dw = y_pay_mem[(a - H2C_Y_PAY) >> 2];
            else if (a >= H2C_UV_PAY && a < H2C_UV_PAY + UV_BYTES)
                mem_dw = uv_pay_mem[(a - H2C_UV_PAY) >> 2];
            else if (a >= H2C_Y_SLOT0 && a < H2C_Y_SLOT0 + 64'h3000)
                mem_dw = sgl_h2c_mem[(a - H2C_Y_SLOT0) >> 2];
            else if (a >= C2H_Y_SLOT0 && a < C2H_Y_SLOT0 + 64'h3000)
                mem_dw = sgl_c2h_mem[(a - C2H_Y_SLOT0) >> 2];
            else
                mem_dw = 32'hDEAD_BEEF; // unexpected address => data check fails
        end
    endfunction

    always @(posedge clk) begin
        if (!rst_n) begin
            req_q_wr <= 0;
            mon_mwr_active <= 1'b0;
            mon_mwr_beats_left <= 0;
            mon_mwr_beat_idx <= 0;
        end else if (s_axis_tx_tvalid && s_axis_tx_tready) begin
            if (mon_mwr_active) begin
                mon_d0 = host_dw(s_axis_tx_tdata[31:0]);
                mon_d1 = host_dw(s_axis_tx_tdata[63:32]);
                mon_d2 = host_dw(s_axis_tx_tdata[95:64]);
                mon_d3 = host_dw(s_axis_tx_tdata[127:96]);
                mon_dst = mon_mwr_addr + mon_mwr_beat_idx*16;
                if (mon_dst >= C2H_Y_DST && mon_dst < C2H_Y_DST + Y_BYTES) begin
                    cap_mem[(mon_dst - C2H_Y_DST)/4 + 0] <= mon_d0;
                    cap_mem[(mon_dst - C2H_Y_DST)/4 + 1] <= mon_d1;
                    cap_mem[(mon_dst - C2H_Y_DST)/4 + 2] <= mon_d2;
                    cap_mem[(mon_dst - C2H_Y_DST)/4 + 3] <= mon_d3;
                end else if (mon_dst >= C2H_UV_DST && mon_dst < C2H_UV_DST + UV_BYTES) begin
                    cap_mem[Y_DWS + (mon_dst - C2H_UV_DST)/4 + 0] <= mon_d0;
                    cap_mem[Y_DWS + (mon_dst - C2H_UV_DST)/4 + 1] <= mon_d1;
                    cap_mem[Y_DWS + (mon_dst - C2H_UV_DST)/4 + 2] <= mon_d2;
                    cap_mem[Y_DWS + (mon_dst - C2H_UV_DST)/4 + 3] <= mon_d3;
                end else begin
                    cap_bad_addr = cap_bad_addr + 1;
                end
                cap_dw_cnt = cap_dw_cnt + 4;
                mon_mwr_beat_idx = mon_mwr_beat_idx + 1;
                if (mon_mwr_beats_left <= 1)
                    mon_mwr_active <= 1'b0;
                else
                    mon_mwr_beats_left = mon_mwr_beats_left - 1;
            end else if (s_axis_tx_tdata[30:29] == 2'b01 &&
                         s_axis_tx_tdata[28:24] == 5'b00000) begin
                req_q_addr[req_q_wr] <= {s_axis_tx_tdata[95:64], s_axis_tx_tdata[127:96]};
                req_q_tag[req_q_wr]  <= s_axis_tx_tdata[47:40];
                req_q_id[req_q_wr]   <= s_axis_tx_tdata[63:48];
                req_q_len[req_q_wr]  <= s_axis_tx_tdata[9:0];
                req_q_wr <= (req_q_wr + 1) % REQ_Q_DEPTH;
            end else if (s_axis_tx_tdata[30:29] == 2'b11 &&
                         s_axis_tx_tdata[28:24] == 5'b00000) begin
                mon_mwr_len_dw = s_axis_tx_tdata[9:0];
                if (mon_mwr_len_dw == 0 || (mon_mwr_len_dw % 4) != 0)
                    $fatal(1, "TX monitor: malformed MWr len=%0d tdata=%h", mon_mwr_len_dw, s_axis_tx_tdata);
                mon_mwr_addr = {s_axis_tx_tdata[95:64], s_axis_tx_tdata[127:96]};
                mon_mwr_beats_left = mon_mwr_len_dw / 4;
                mon_mwr_beat_idx = 0;
                mon_mwr_active <= 1'b1;
                mwr_burst_cnt = mwr_burst_cnt + 1;
            end
        end
    end

    // ------------------------------------------------------------------
    // DUT: bridge + dma_top (128-bit, clk == video_clk)
    // ------------------------------------------------------------------
    pcie_7x_axi_bridge #(.DATA_WIDTH(128)) u_bridge (
        .clk(clk), .rst_n(rst_n),
        .cfg_bus_number(8'h04), .cfg_device_number(5'h01), .cfg_function_number(3'h0),
        .m_axis_rx_tdata(m_axis_rx_tdata), .m_axis_rx_tkeep(m_axis_rx_tkeep),
        .m_axis_rx_tlast(m_axis_rx_tlast), .m_axis_rx_tvalid(m_axis_rx_tvalid),
        .m_axis_rx_tready(m_axis_rx_tready), .m_axis_rx_tuser(m_axis_rx_tuser),
        .s_axis_tx_tdata(s_axis_tx_tdata), .s_axis_tx_tkeep(s_axis_tx_tkeep),
        .s_axis_tx_tlast(s_axis_tx_tlast), .s_axis_tx_tvalid(s_axis_tx_tvalid),
        .s_axis_tx_tready(s_axis_tx_tready), .s_axis_tx_tuser(s_axis_tx_tuser),
        .m_axis_cq_tdata(cq_tdata), .m_axis_cq_tvalid(cq_tvalid),
        .m_axis_cq_tlast(cq_tlast), .m_axis_cq_tuser(cq_tuser),
        .m_axis_cq_tkeep(cq_tkeep), .m_axis_cq_tready(cq_tready),
        .s_axis_cc_tdata(cc_tdata), .s_axis_cc_tvalid(cc_tvalid),
        .s_axis_cc_tlast(cc_tlast), .s_axis_cc_tuser(cc_tuser),
        .s_axis_cc_tkeep(cc_tkeep), .s_axis_cc_tready(cc_tready),
        .s_axis_rq_tdata(rq_tdata), .s_axis_rq_tvalid(rq_tvalid),
        .s_axis_rq_tlast(rq_tlast), .s_axis_rq_tuser(rq_tuser),
        .s_axis_rq_tkeep(rq_tkeep), .s_axis_rq_tready(rq_tready),
        .m_axis_rc_tdata(rc_tdata), .m_axis_rc_tvalid(rc_tvalid),
        .m_axis_rc_tlast(rc_tlast), .m_axis_rc_tuser(rc_tuser),
        .m_axis_rc_tkeep(rc_tkeep), .m_axis_rc_tready(rc_tready)
    );

    custom_pcie_dma_top #(.PCIE_DATA_WIDTH(128)) u_dma_top (
        .clk(clk), .rst_n(rst_n),
        .s_axis_cq_tdata(cq_tdata), .s_axis_cq_tvalid(cq_tvalid),
        .s_axis_cq_tlast(cq_tlast), .s_axis_cq_tuser(cq_tuser),
        .s_axis_cq_tkeep(cq_tkeep), .s_axis_cq_tready(cq_tready),
        .m_axis_cc_tdata(cc_tdata), .m_axis_cc_tvalid(cc_tvalid),
        .m_axis_cc_tlast(cc_tlast), .m_axis_cc_tuser(cc_tuser),
        .m_axis_cc_tkeep(cc_tkeep), .m_axis_cc_tready(cc_tready),
        .m_axis_rq_tdata(rq_tdata), .m_axis_rq_tvalid(rq_tvalid),
        .m_axis_rq_tlast(rq_tlast), .m_axis_rq_tuser(rq_tuser),
        .m_axis_rq_tkeep(rq_tkeep), .m_axis_rq_tready(rq_tready),
        .s_axis_rc_tdata(rc_tdata), .s_axis_rc_tvalid(rc_tvalid),
        .s_axis_rc_tlast(rc_tlast), .s_axis_rc_tuser(rc_tuser),
        .s_axis_rc_tkeep(rc_tkeep), .s_axis_rc_tready(rc_tready),
        .m_axil_bar1_awready(1'b1), .m_axil_bar1_wready(1'b1),
        .m_axil_bar1_bresp(2'b00), .m_axil_bar1_bvalid(1'b1),
        .m_axil_bar1_arready(1'b1), .m_axil_bar1_rdata(32'd0),
        .m_axil_bar1_rresp(2'b00), .m_axil_bar1_rvalid(1'b1),
        .s_axis_video_tdata(128'd0), .s_axis_video_tvalid(4'b0),
        .s_axis_video_tlast(4'b0), .s_axis_video_tuser(4'b0),
        .s_axis_video_tready(),
        .video_clk(clk), .video_rst_n(rst_n),
        .video_ch0_tdata(128'd0), .video_ch0_tvalid(1'b0),
        .video_ch0_tlast(1'b0), .video_ch0_tuser(1'b0),
        .video_ch0_tready(),
        .m_axis_video_tdata(), .m_axis_video_tvalid(),
        .m_axis_video_tlast(), .m_axis_video_tuser(),
        .m_axis_video_tready(4'b1111),
        .s_axis_audio_tdata(128'd0), .s_axis_audio_tvalid(4'b0),
        .s_axis_audio_tlast(4'b0), .s_axis_audio_tready(),
        .m_axis_audio_tdata(), .m_axis_audio_tvalid(),
        .m_axis_audio_tlast(), .m_axis_audio_tready(4'b1111),
        .usr_irq_req(usr_irq_req), .usr_irq_ack(usr_irq_ack)
    );

    // ==================================================================
    // Procedural host BFM tasks
    // ==================================================================
    reg [31:0] mmio_addr_cur, mmio_data_cur;

    // 4-DW MWr (64-bit address) MMIO write: native beats, one per cycle,
    // handshaking on m_axis_rx_tready (identical to tb_pcie_7x_axi_bridge).
    task mmio_write_bar0;
        input [31:0] reg_addr;
        input [31:0] reg_data;
        begin
            // Keep FPGA->host TX always ready; a separate monitor captures TLPs
            // concurrently while this blocking MMIO writer drives RX beats.
            s_axis_tx_tready <= 1'b1;

            @(posedge clk);
            m_axis_rx_tvalid <= 1'b1;
            m_axis_rx_tlast  <= 1'b0;
            m_axis_rx_tkeep  <= 16'hFFFF;
            m_axis_rx_tuser  <= 22'b0000000000000000000100; // BAR0 hit (tuser[2])
            // Beat 0: DW3 = addr lo, DW2 = addr hi, DW1 = {req_id, tag, BE}, DW0 = 4-DW MWr len 1
            m_axis_rx_tdata  <= {reg_addr, 32'h00000000, 32'h0000000F, 32'h60000001};
            @(posedge clk);
            while (!m_axis_rx_tready) @(posedge clk);
            // Beat 1 presented the very next cycle (no idle gap): switch the
            // payload in immediately after beat 0's handshake completes.
            m_axis_rx_tvalid <= 1'b1;
            m_axis_rx_tlast  <= 1'b1;
            m_axis_rx_tkeep  <= 16'h000F;
            m_axis_rx_tuser  <= 22'b0000000000000000000100; // BAR0 hit
            m_axis_rx_tdata  <= {96'd0, host_dw(reg_data)};
            @(posedge clk);
            while (!m_axis_rx_tready) @(posedge clk);
            m_axis_rx_tvalid <= 1'b0;
            m_axis_rx_tlast  <= 1'b0;
            m_axis_rx_tdata  <= 128'd0;
            s_axis_tx_tready <= 1'b1;
        end
    endtask

    // Wait for the next FPGA->host TLP header on the native TX stream. Hold
    // tready low while waiting so the header is stable, sample it, then pulse
    // tready for exactly one clock to consume that beat.
    task wait_tx_tlp;
        begin
            s_axis_tx_tready = 1'b0;
            @(negedge clk);
            while (!s_axis_tx_tvalid) @(negedge clk);
            tx_tlp_data = s_axis_tx_tdata;
            tx_tlp_last = s_axis_tx_tlast;
            tx_tlp_user = s_axis_tx_tuser;
            s_axis_tx_tready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            s_axis_tx_tready = 1'b0;
        end
    endtask

    // Emit one CplD response for a host read.  mr_addr/tag/len_dw come from
    // the observed MRd; the payload is read back from the host memory model.
    // Beat 0 = CplD header (DW0 raw) + payload DW0 (byte-swapped, at [127:96]);
    // subsequent beats carry up to 4 payload DWs each (byte-swapped per lane).
    task respond_cpld;
        input [63:0] mr_addr;
        input [7:0]  mr_tag;
        input [15:0] mr_req_id;
        input [10:0] len_dw;                 // total payload DW count
        integer i;
        integer rem;
        integer bw;
        reg [31:0] d0, d1, d2, d3;
        begin
            // Keep FPGA->host TX always ready; a separate monitor captures TLPs
            // concurrently while this blocking completion responder drives RX.
            s_axis_tx_tready <= 1'b1;

            // Beat 0: header + first payload DW
            @(posedge clk);
            m_axis_rx_tvalid <= 1'b1;
            m_axis_rx_tlast  <= (len_dw <= 11'd1);
            m_axis_rx_tkeep  <= 16'hFFFF;
            m_axis_rx_tuser  <= 22'd0;
            m_axis_rx_tdata  <= {host_dw(mem_dw(mr_addr)),      // DW3: payload DW0
                                  {mr_req_id, mr_tag, 8'h00},   // DW2
                                  {19'd0, len_dw, 2'b00},       // DW1: byte count
                                  32'h4A000000 | {21'd0, len_dw}}; // DW0: CplD, fmt 3DW+data
            @(posedge clk);
            while (!m_axis_rx_tready) @(posedge clk);

            // Data beats: DWs 1..len_dw-1, 4 per beat, final beat partial.
            // Each beat's data is switched in immediately after the previous
            // beat's handshake (never leave tvalid high with stale data).
            i = 1;
            while (i < len_dw) begin
                rem = len_dw - i;
                bw  = (rem >= 4) ? 4 : rem;
                m_axis_rx_tvalid <= 1'b1;
                m_axis_rx_tlast  <= (i + bw >= len_dw);
                case (bw)
                    1: m_axis_rx_tkeep <= 16'h000F;
                    2: m_axis_rx_tkeep <= 16'h00FF;
                    3: m_axis_rx_tkeep <= 16'h0FFF;
                    default: m_axis_rx_tkeep <= 16'hFFFF;
                endcase
                m_axis_rx_tuser <= 22'd0;
                d0 = mem_dw(mr_addr + i*4);
                d1 = mem_dw(mr_addr + (i+1)*4);
                d2 = mem_dw(mr_addr + (i+2)*4);
                d3 = mem_dw(mr_addr + (i+3)*4);
                m_axis_rx_tdata <= {host_dw(d3), host_dw(d2),
                                    host_dw(d1), host_dw(d0)};
                @(posedge clk);
                while (!m_axis_rx_tready) @(posedge clk);
                i = i + bw;
            end
            m_axis_rx_tvalid <= 1'b0;
            m_axis_rx_tlast  <= 1'b0;
            m_axis_rx_tdata  <= 128'd0;
            s_axis_tx_tready <= 1'b1;
        end
    endtask

    // Capture one complete C2H MWr burst (4-DW MWr, 1 header beat + data beats)
    // and route its payload into cap_mem by absolute byte address. The caller has
    // already handshaken the MWr header in wait_tx_tlp(), so consume that current
    // header and then wait for the following payload beats.
    task capture_one_mwr;
        reg [63:0] addr;
        reg [9:0]  dw_len;
        integer    num_beats;
        integer    i;
        reg [31:0] d0, d1, d2, d3;
        reg [63:0] dst;
        begin
            dw_len = tx_tlp_data[9:0];
            addr   = {tx_tlp_data[95:64], tx_tlp_data[127:96]};
            mwr_burst_cnt = mwr_burst_cnt + 1;
            num_beats = dw_len / 4;
            if (num_beats < 1 || (dw_len % 4) != 0)
                $fatal(1, "capture_one_mwr: malformed MWr len=%0d tdata=%h tlast=%b tuser=%h tx_state=%0d",
                       dw_len, tx_tlp_data, tx_tlp_last, tx_tlp_user, u_bridge.tx_state);

            s_axis_tx_tready = 1'b1;
            for (i = 0; i < num_beats; i = i + 1) begin
                @(negedge clk);
                while (!s_axis_tx_tvalid) @(negedge clk);
                d0 = host_dw(s_axis_tx_tdata[31:0]);
                d1 = host_dw(s_axis_tx_tdata[63:32]);
                d2 = host_dw(s_axis_tx_tdata[95:64]);
                d3 = host_dw(s_axis_tx_tdata[127:96]);
                dst = addr + i*16;
                if (dst >= C2H_Y_DST && dst < C2H_Y_DST + Y_BYTES) begin
                    cap_mem[(dst - C2H_Y_DST)/4 + 0] <= d0;
                    cap_mem[(dst - C2H_Y_DST)/4 + 1] <= d1;
                    cap_mem[(dst - C2H_Y_DST)/4 + 2] <= d2;
                    cap_mem[(dst - C2H_Y_DST)/4 + 3] <= d3;
                end else if (dst >= C2H_UV_DST && dst < C2H_UV_DST + UV_BYTES) begin
                    cap_mem[Y_DWS + (dst - C2H_UV_DST)/4 + 0] <= d0;
                    cap_mem[Y_DWS + (dst - C2H_UV_DST)/4 + 1] <= d1;
                    cap_mem[Y_DWS + (dst - C2H_UV_DST)/4 + 2] <= d2;
                    cap_mem[Y_DWS + (dst - C2H_UV_DST)/4 + 3] <= d3;
                end else begin
                    cap_bad_addr = cap_bad_addr + 1;
                end
                cap_dw_cnt = cap_dw_cnt + 4;
                @(posedge clk);
            end
            @(negedge clk);
            s_axis_tx_tready = 1'b0;
        end
    endtask

    // ==================================================================
    // Golden data check
    // ==================================================================
    task check_captured;
        integer k;
        integer errs;
        begin
            errs = 0;
            if (cap_dw_cnt != TOTAL_DWS) begin
                $display("  [FAIL] captured %0d DWs, expected %0d", cap_dw_cnt, TOTAL_DWS);
                errs = errs + 1;
            end
            if (cap_bad_addr != 0) begin
                $display("  [FAIL] %0d C2H MWr bursts outside the C2H dst planes", cap_bad_addr);
                errs = errs + 1;
            end
            // Y plane carries values 0..Y_DWS-1; UV plane continues at
            // Y_DWS, so the global captured stream equals the index k.
            for (k = 0; k < TOTAL_DWS; k = k + 1) begin
                if (cap_mem[k] !== k[31:0]) begin
                    if (errs < 16)
                        $display("  [FAIL] DW[%0d] = 0x%08X, expected 0x%08X",
                                 k, cap_mem[k], k);
                    errs = errs + 1;
                end
            end
            if (errs == 0)
                $display("  [PASS] %0d C2H payload DWs match the H2C stream exactly", TOTAL_DWS);
            else
                $display("  [FAIL] data check found %0d errors", errs);
        end
    endtask

    // ==================================================================
    // Memory prefill
    // ==================================================================
    integer k, e;
    reg [63:0] tmp_addr;

    initial begin
        // Descriptor 0: H2C NV12M SGL (ctrl=0x69: dir=0, ch1<<6, 0x20 SG)
        ring_mem[0]  = 32'h2000_0000; // plane0_src lo = Y SGL slot
        ring_mem[1]  = 32'h0000_0000;
        ring_mem[2]  = 32'h0000_0000; // plane0_dst
        ring_mem[3]  = 32'h0000_0000;
        ring_mem[4]  = 32'h2000_2000; // plane1_src lo = UV SGL slot
        ring_mem[5]  = 32'h0000_0000;
        ring_mem[6]  = 32'h0000_0000; // plane1_dst
        ring_mem[7]  = 32'h0000_0000;
        ring_mem[8]  = 32'd0; ring_mem[9] = 32'd0;   // plane2
        ring_mem[10] = 32'd0; ring_mem[11] = 32'd0;
        ring_mem[12] = (HEIGHT << 16) | WIDTH;        // line_width/count
        ring_mem[13] = (WIDTH << 16) | WIDTH;         // strides
        ring_mem[14] = ((HEIGHT/2) << 16) | WIDTH;    // plane12 w/count
        ring_mem[15] = 32'h0000_6922;                 // [15:8] ctrl=0x69, [7:4] pc=2, [3:0] fmt=2

        // Descriptor 1: C2H NV12M SGL (ctrl=0x6B)
        ring_mem[16] = 32'h0000_0000; // plane0_src
        ring_mem[17] = 32'h0000_0000;
        ring_mem[18] = 32'h3000_0000; // plane0_dst lo = C2H Y SGL slot
        ring_mem[19] = 32'h0000_0000;
        ring_mem[20] = 32'h0000_0000; // plane1_src
        ring_mem[21] = 32'h0000_0000;
        ring_mem[22] = 32'h3000_2000; // plane1_dst lo = C2H UV SGL slot
        ring_mem[23] = 32'h0000_0000;
        ring_mem[24] = 32'd0; ring_mem[25] = 32'd0;
        ring_mem[26] = 32'd0; ring_mem[27] = 32'd0;
        ring_mem[28] = (HEIGHT << 16) | WIDTH;
        ring_mem[29] = (WIDTH << 16) | WIDTH;
        ring_mem[30] = ((HEIGHT/2) << 16) | WIDTH;
        ring_mem[31] = 32'h0000_6B22; // [15:8] ctrl=0x6B, pc=2, fmt=2

        // H2C payload data: stream index
        for (k = 0; k < Y_BYTES/4; k = k + 1)
            y_pay_mem[k] = k;
        for (k = 0; k < UV_BYTES/4; k = k + 1)
            uv_pay_mem[k] = Y_DWS + k;

        // ---- H2C Y SGL: slot0 = 255 entries, slot0[255] = chain, slot1 = 1 ----
        for (e = 0; e < Y_ENTRIES - 1; e = e + 1) begin
            tmp_addr = H2C_Y_PAY + e*4096;
            sgl_h2c_mem[e*4+0] = tmp_addr[31:0];
            sgl_h2c_mem[e*4+1] = tmp_addr[63:32];
            sgl_h2c_mem[e*4+2] = 32'd4096;
            sgl_h2c_mem[e*4+3] = 32'd0;
        end
        tmp_addr = H2C_Y_SLOT1;
        sgl_h2c_mem[255*4+0] = tmp_addr[31:0];
        sgl_h2c_mem[255*4+1] = tmp_addr[63:32];
        sgl_h2c_mem[255*4+2] = 32'd0;
        sgl_h2c_mem[255*4+3] = 32'h0000_0001; // SGL_FLAG_CHAIN_PTR
        tmp_addr = H2C_Y_PAY + (Y_ENTRIES-1)*4096;
        sgl_h2c_mem[1024*1+0] = tmp_addr[31:0];
        sgl_h2c_mem[1024*1+1] = tmp_addr[63:32];
        sgl_h2c_mem[1024*1+2] = 32'd4096;
        sgl_h2c_mem[1024*1+3] = 32'h0000_0002; // SGL_FLAG_LAST_SEG

        // ---- H2C UV SGL: 128 entries, single slot, last LAST_SEG ----
        for (e = 0; e < UV_ENTRIES; e = e + 1) begin
            tmp_addr = H2C_UV_PAY + e*4096;
            sgl_h2c_mem[2048 + e*4+0] = tmp_addr[31:0];
            sgl_h2c_mem[2048 + e*4+1] = tmp_addr[63:32];
            sgl_h2c_mem[2048 + e*4+2] = 32'd4096;
            sgl_h2c_mem[2048 + e*4+3] = (e == UV_ENTRIES-1) ? 32'h0000_0002 : 32'd0;
        end

        // ---- C2H Y SGL (dest 0x4000_0000) ----
        for (e = 0; e < Y_ENTRIES - 1; e = e + 1) begin
            tmp_addr = C2H_Y_DST + e*4096;
            sgl_c2h_mem[e*4+0] = tmp_addr[31:0];
            sgl_c2h_mem[e*4+1] = tmp_addr[63:32];
            sgl_c2h_mem[e*4+2] = 32'd4096;
            sgl_c2h_mem[e*4+3] = 32'd0;
        end
        tmp_addr = C2H_Y_SLOT1;
        sgl_c2h_mem[255*4+0] = tmp_addr[31:0];
        sgl_c2h_mem[255*4+1] = tmp_addr[63:32];
        sgl_c2h_mem[255*4+2] = 32'd0;
        sgl_c2h_mem[255*4+3] = 32'h0000_0001;
        tmp_addr = C2H_Y_DST + (Y_ENTRIES-1)*4096;
        sgl_c2h_mem[1024*1+0] = tmp_addr[31:0];
        sgl_c2h_mem[1024*1+1] = tmp_addr[63:32];
        sgl_c2h_mem[1024*1+2] = 32'd4096;
        sgl_c2h_mem[1024*1+3] = 32'h0000_0002;

        // ---- C2H UV SGL (dest 0x4100_0000) ----
        for (e = 0; e < UV_ENTRIES; e = e + 1) begin
            tmp_addr = C2H_UV_DST + e*4096;
            sgl_c2h_mem[2048 + e*4+0] = tmp_addr[31:0];
            sgl_c2h_mem[2048 + e*4+1] = tmp_addr[63:32];
            sgl_c2h_mem[2048 + e*4+2] = 32'd4096;
            sgl_c2h_mem[2048 + e*4+3] = (e == UV_ENTRIES-1) ? 32'h0000_0002 : 32'd0;
        end
    end

    // ==================================================================
    // Main test
    // ==================================================================
    reg [63:0] req_addr;
    reg [7:0]  req_tag;
    reg [15:0] req_id;
    reg [10:0] req_len;

    initial begin
        $display("===============================================================");
        $display(" SGL Loopback System Test (host SGL fetch, 2-slot chain, Y->UV)");
        $display(" Frame: %0dx%0d NV12M, Y=%0dB UV=%0dB (%0d DWs, Y %0d+%0d SGL entries)",
                 WIDTH, HEIGHT, Y_BYTES, UV_BYTES, TOTAL_DWS,
                 Y_ENTRIES-1, UV_ENTRIES);
        $display("===============================================================");

        m_axis_rx_tdata  = 128'd0; m_axis_rx_tkeep = 16'd0;
        m_axis_rx_tlast  = 1'b0; m_axis_rx_tvalid = 1'b0; m_axis_rx_tuser = 22'd0;
        s_axis_tx_tready = 1'b1;
        tx_tlp_data = 128'd0; tx_tlp_last = 1'b0; tx_tlp_user = 4'd0;
        req_q_rd = 0;
        cap_dw_cnt = 0; cap_bad_addr = 0; mwr_burst_cnt = 0;
        mrd_desc_cnt = 0; mrd_sgl_cnt = 0; mrd_h2c_cnt = 0;
        #30;
        rst_n = 1;
        #30;

        // ---- Config: ring base, size, DMA run ----
        mmio_write_bar0(32'h08, 32'hFFFF_E000); // ring base lo
        mmio_write_bar0(32'h0C, 32'h0000_0000); // ring base hi
        mmio_write_bar0(32'h20, 32'h0000_0003); // IRQ enable
        mmio_write_bar0(32'h00, 32'h0000_0001); // DMA run
        repeat (200) @(posedge clk);
        if (u_dma_top.reg_h2c_ring_addr !== 64'h0000_0000_FFFF_E000 ||
            u_dma_top.reg_dma_ctrl !== 32'h1 ||
            u_dma_top.reg_irq_ctrl !== 32'h3)
            $fatal(1, "MMIO config did not land: ring=%h ctrl=%h irq=%h",
                   u_dma_top.reg_h2c_ring_addr, u_dma_top.reg_dma_ctrl,
                   u_dma_top.reg_irq_ctrl);
        $display("  [PASS] MMIO config landed (ring=0x%h ctrl=0x%x irq=0x%x)",
                 u_dma_top.reg_h2c_ring_addr, u_dma_top.reg_dma_ctrl,
                 u_dma_top.reg_irq_ctrl);

        // ================================================================
        // PHASE A: publish only the H2C descriptor (tail=1).  The decoupled
        // fetch engine must complete the whole Y/UV SGL fetch and let
        // desc_fetch advance (head=1) even though the H2C engine stalls once
        // the 1 KB loopback FIFO fills (no C2H capture armed yet).
        // ================================================================
        $display("--- [Phase A] Publish H2C SGL descriptor (tail=1) ---");
        mmio_write_bar0(32'h10, (32'd1 << 16) | 32'd16);

        // PHASE B: once H2C is demonstrably flowing (SGL fetch done, head=1,
        // payload MRds issued past the 1 KB loopback FIFO), publish the C2H
        // descriptor so the capture engine drains the loopback and the full
        // frame flows to the C2H SGL destination table.
        while (cap_dw_cnt < TOTAL_DWS) begin
            // If Phase A quiesces after fetch completion (H2C is stalled on the
            // loopback FIFO), there may be no further TX TLP to wake the loop.
            // Poll the phase boundary while waiting for the next requester TLP.
            while (cap_dw_cnt < TOTAL_DWS && req_q_rd == req_q_wr) begin
                if (!phase_b_pub && u_dma_top.reg_h2c_head_ptr == 1 &&
                    mrd_h2c_cnt >= 4) begin
                    phase_b_pub = 1;
                    $display("  [PASS] Phase A: SGL fetch complete while H2C stalled");
                    $display("         (desc=%0d sgl=%0d h2c=%0d head=%0d)",
                             mrd_desc_cnt, mrd_sgl_cnt, mrd_h2c_cnt,
                             u_dma_top.reg_h2c_head_ptr);
                    $display("--- [Phase B] Publish C2H SGL descriptor (tail=2) ---");
                    mmio_write_bar0(32'h10, (32'd2 << 16) | 32'd16);
                end else begin
                    @(posedge clk);
                end
            end
            if (cap_dw_cnt < TOTAL_DWS) begin
                // Pop next queued MRd (4-DW): read tag, req_id, addr, length
                req_tag  = req_q_tag[req_q_rd];
                req_id   = req_q_id[req_q_rd];
                req_addr = req_q_addr[req_q_rd];
                req_len  = req_q_len[req_q_rd];
                req_q_rd = (req_q_rd + 1) % REQ_Q_DEPTH;
                if (mrd_dbg_cnt < 40) begin
                    $display("  [MRD] tag=%0d reqid=%04x addr=%016x len=%0d DW",
                             req_tag, req_id, req_addr, req_len);
                    mrd_dbg_cnt = mrd_dbg_cnt + 1;
                end
                case (req_tag)
                    8'h00: mrd_desc_cnt = mrd_desc_cnt + 1;
                    8'h01: mrd_sgl_cnt  = mrd_sgl_cnt + 1;
                    default: mrd_h2c_cnt = mrd_h2c_cnt + 1;
                endcase
                respond_cpld(req_addr, req_tag, req_id, req_len);
            end

            // Phase A/B boundary (checked once, when H2C is flowing)
            if (!phase_b_pub && u_dma_top.reg_h2c_head_ptr == 1 &&
                mrd_h2c_cnt >= 4) begin
                phase_b_pub = 1;
                $display("  [PASS] Phase A: SGL fetch complete while H2C stalled");
                $display("         (desc=%0d sgl=%0d h2c=%0d head=%0d)",
                         mrd_desc_cnt, mrd_sgl_cnt, mrd_h2c_cnt,
                         u_dma_top.reg_h2c_head_ptr);
                $display("--- [Phase B] Publish C2H SGL descriptor (tail=2) ---");
                mmio_write_bar0(32'h10, (32'd2 << 16) | 32'd16);
            end
        end

        // ---- Final checks ----
        repeat (2000) @(posedge clk);
        if (u_dma_top.reg_h2c_head_ptr != 2)
            $fatal(1, "desc head=%0d (expected 2 after C2H fetch)", u_dma_top.reg_h2c_head_ptr);
        if (u_dma_top.u_sg_dma_engine.completed_h2c_count != 1)
            $fatal(1, "H2C completions=%0d (expected 1)",
                   u_dma_top.u_sg_dma_engine.completed_h2c_count);
        $display("  [PASS] H2C frame completed, desc head=%0d (desc=%0d sgl=%0d h2c=%0d)",
                 u_dma_top.reg_h2c_head_ptr, mrd_desc_cnt, mrd_sgl_cnt, mrd_h2c_cnt);
        $display("  [PASS] C2H captured %0d DWs in %0d MWr bursts",
                 cap_dw_cnt, mwr_burst_cnt);

        check_captured();

        $display("===============================================================");
        $display(" SUCCESS: SGL loopback system verified end-to-end (host SGL fetch)");
        $display("===============================================================");
        $finish;
    end

    initial begin
        #6_000_000;
        $fatal(1, "Global timeout -- SGL loopback system hung (cap=%0d desc=%0d sgl=%0d h2c=%0d head=%0d tail=%0d fetch_busy=%b h2c_state=%0d is_uv=%b rem=%0d y_valid=%b y_left=%0d y_cnt=%0d uv_valid=%b uv_left=%0d uv_cnt=%0d)",
               cap_dw_cnt, mrd_desc_cnt, mrd_sgl_cnt, mrd_h2c_cnt,
               u_dma_top.reg_h2c_head_ptr, u_dma_top.reg_h2c_tail_ptr,
               u_dma_top.sg_fetch_busy,
               u_dma_top.u_sg_dma_engine.h2c_state,
               u_dma_top.u_sg_dma_engine.h2c_is_uv,
               u_dma_top.u_sg_dma_engine.h2c_rem_bytes,
               u_dma_top.u_sg_dma_engine.h2c_y_seg_valid,
               u_dma_top.u_sg_dma_engine.h2c_y_walker_bytes_left,
               u_dma_top.u_sg_dma_engine.h2c_y_sgl_count,
               u_dma_top.u_sg_dma_engine.h2c_uv_seg_valid,
               u_dma_top.u_sg_dma_engine.h2c_uv_walker_bytes_left,
               u_dma_top.u_sg_dma_engine.h2c_uv_sgl_count);
    end

endmodule
