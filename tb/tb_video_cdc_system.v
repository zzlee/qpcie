// ============================================================================
// Testbench: tb_video_cdc_system
// Description: Integration test for the 150 MHz NV12 capture pipeline inside
//              custom_pcie_dma_top:
//                descriptor fetch (125 MHz) -> xpm_cdc_handshake ->
//                nv12_capture_engine @150 MHz -> video_req_cdc -> RQ/PCIe.
//              Architecture mirrors tb_sg_dma_pipeline: pcie_7x_axi_bridge +
//              custom_pcie_dma_top, with a host BFM on the 7-series streams.
//              A TPG-like source feeds video_ch0 at 150 MHz; captured MWr
//              payloads are checked against the rounded 2x2 box-filter
//              golden model and the MSI completion is observed on the wire.
// ============================================================================
`timescale 1ns / 1ps

module tb_video_cdc_system;
    localparam WIDTH   = 1920;
    localparam HEIGHT  = 4;
    localparam STRIDE  = 1920;
    localparam [63:0] Y_BASE  = 64'h1000_0000;
    localparam [63:0] UV_BASE = 64'h1100_0000;
    // Y: 4 lines * (7*256B + 1*128B) = 32 pkts (7680 bytes)
    // UV: 2 lines * (7*256B + 1*128B) = 16 pkts (3840 bytes)
    // Total = 48 pkts (11520 bytes)
    localparam integer PAYLOAD_BYTES = WIDTH*HEIGHT*3/2;      // 11520
    localparam integer EXPECT_PKTS   = (HEIGHT * 8) + (HEIGHT/2 * 8); // 48

    reg clk = 0;          // 125 MHz PCIe user clock
    reg video_clk = 0;    // 150 MHz video clock (independent phase)
    reg rst_n = 0;
    always #4.0   clk       = ~clk;
    initial begin #3.33; forever #3.3333 video_clk = ~video_clk; end

    // Host BFM streams (7-Series native format)
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

    // Internal bridge<->dma_top streams
    wire [127:0] cq_tdata, cc_tdata, rq_tdata, rc_tdata;
    wire         cq_tvalid, cq_tvalid_w, cc_tvalid, rq_tvalid, rc_tvalid;
    wire         cq_tlast, cc_tlast, rq_tlast, rc_tlast;
    wire [87:0]  cq_tuser;
    wire [32:0]  cc_tuser;
    wire [61:0]  rq_tuser;
    wire [74:0]  rc_tuser;
    wire [15:0]  cq_tkeep, cc_tkeep, rq_tkeep, rc_tkeep;
    wire         cq_tready, cc_tready, rq_tready, rc_tready;

    // Video source registers (150 MHz domain)
    reg [127:0] v_tdata = 0;
    reg         v_tvalid = 0, v_tlast = 0, v_tuser = 0;
    wire        v_tready;

    wire        usr_irq_req;
    reg         usr_irq_seen = 0;

    integer pkt_cnt = 0;

    // Golden memories
    reg [7:0] y_mem  [0:(WIDTH*HEIGHT)-1];
    reg [7:0] uv_mem [0:(WIDTH*HEIGHT/2)-1];

    function [31:0] host_dw;
        input [31:0] v;
        begin host_dw = {v[7:0], v[15:8], v[23:16], v[31:24]}; end
    endfunction

    function [7:0] y_value; input integer r; input integer x;
        begin y_value = r * 32 + x; end
    endfunction
    function [7:0] u_value; input integer r; input integer x;
        begin u_value = 40 + r * 4 + x; end
    endfunction
    function [7:0] v_value; input integer r; input integer x;
        begin v_value = 100 + r * 4 + x; end
    endfunction
    function [31:0] pixel4; input integer r; input integer x;
        begin pixel4 = {8'h00, v_value(r, x), u_value(r, x), y_value(r, x)}; end
    endfunction

    // ------------------------------------------------------------------
    // DUT wiring: bridge (host side) + dma_top (engine side)
    // ------------------------------------------------------------------
    pcie_7x_axi_bridge #(
        .DATA_WIDTH(128)
    ) u_bridge (
        .clk(clk),
        .rst_n(rst_n),
        .cfg_bus_number(8'h04),
        .cfg_device_number(5'h01),
        .cfg_function_number(3'h0),
        .m_axis_rx_tdata(m_axis_rx_tdata),
        .m_axis_rx_tkeep(m_axis_rx_tkeep),
        .m_axis_rx_tlast(m_axis_rx_tlast),
        .m_axis_rx_tvalid(m_axis_rx_tvalid),
        .m_axis_rx_tready(m_axis_rx_tready),
        .m_axis_rx_tuser(m_axis_rx_tuser),
        .s_axis_tx_tdata(s_axis_tx_tdata),
        .s_axis_tx_tkeep(s_axis_tx_tkeep),
        .s_axis_tx_tlast(s_axis_tx_tlast),
        .s_axis_tx_tvalid(s_axis_tx_tvalid),
        .s_axis_tx_tready(s_axis_tx_tready),
        .s_axis_tx_tuser(s_axis_tx_tuser),
        .m_axis_cq_tdata(cq_tdata),
        .m_axis_cq_tvalid(cq_tvalid),
        .m_axis_cq_tlast(cq_tlast),
        .m_axis_cq_tuser(cq_tuser),
        .m_axis_cq_tkeep(cq_tkeep),
        .m_axis_cq_tready(cq_tready),
        .s_axis_cc_tdata(cc_tdata),
        .s_axis_cc_tvalid(cc_tvalid),
        .s_axis_cc_tlast(cc_tlast),
        .s_axis_cc_tuser(cc_tuser),
        .s_axis_cc_tkeep(cc_tkeep),
        .s_axis_cc_tready(cc_tready),
        .s_axis_rq_tdata(rq_tdata),
        .s_axis_rq_tvalid(rq_tvalid),
        .s_axis_rq_tlast(rq_tlast),
        .s_axis_rq_tuser(rq_tuser),
        .s_axis_rq_tkeep(rq_tkeep),
        .s_axis_rq_tready(rq_tready),
        .m_axis_rc_tdata(rc_tdata),
        .m_axis_rc_tvalid(rc_tvalid),
        .m_axis_rc_tlast(rc_tlast),
        .m_axis_rc_tuser(rc_tuser),
        .m_axis_rc_tkeep(rc_tkeep),
        .m_axis_rc_tready(rc_tready)
    );

    custom_pcie_dma_top #(
        .PCIE_DATA_WIDTH(128)
    ) u_dma_top (
        .clk(clk),
        .rst_n(rst_n),
        .s_axis_cq_tdata(cq_tdata),
        .s_axis_cq_tvalid(cq_tvalid),
        .s_axis_cq_tlast(cq_tlast),
        .s_axis_cq_tuser(cq_tuser),
        .s_axis_cq_tkeep(cq_tkeep),
        .s_axis_cq_tready(cq_tready),
        .m_axis_cc_tdata(cc_tdata),
        .m_axis_cc_tvalid(cc_tvalid),
        .m_axis_cc_tlast(cc_tlast),
        .m_axis_cc_tuser(cc_tuser),
        .m_axis_cc_tkeep(cc_tkeep),
        .m_axis_cc_tready(cc_tready),
        .m_axis_rq_tdata(rq_tdata),
        .m_axis_rq_tvalid(rq_tvalid),
        .m_axis_rq_tlast(rq_tlast),
        .m_axis_rq_tuser(rq_tuser),
        .m_axis_rq_tkeep(rq_tkeep),
        .m_axis_rq_tready(rq_tready),
        .s_axis_rc_tdata(rc_tdata),
        .s_axis_rc_tvalid(rc_tvalid),
        .s_axis_rc_tlast(rc_tlast),
        .s_axis_rc_tuser(rc_tuser),
        .s_axis_rc_tkeep(rc_tkeep),
        .s_axis_rc_tready(rc_tready),
        .m_axil_bar1_awready(1'b1),
        .m_axil_bar1_awaddr(),
        .m_axil_bar1_awvalid(),
        .m_axil_bar1_wdata(),
        .m_axil_bar1_wstrb(),
        .m_axil_bar1_wvalid(),
        .m_axil_bar1_wready(1'b1),
        .m_axil_bar1_bresp(2'b00),
        .m_axil_bar1_bvalid(1'b1),
        .m_axil_bar1_bready(),
        .m_axil_bar1_arready(1'b1),
        .m_axil_bar1_araddr(),
        .m_axil_bar1_arvalid(),
        .m_axil_bar1_rdata(32'd0),
        .m_axil_bar1_rresp(2'b00),
        .m_axil_bar1_rvalid(1'b1),
        .m_axil_bar1_rready(),
        .s_axis_video_tdata(128'd0),
        .s_axis_video_tvalid(4'b0),
        .s_axis_video_tlast(4'b0),
        .s_axis_video_tuser(4'b0),
        .s_axis_video_tready(),
        .video_clk(video_clk),
        .video_rst_n(rst_n),
        .video_ch0_tdata(v_tdata),
        .video_ch0_tvalid(v_tvalid),
        .video_ch0_tlast(v_tlast),
        .video_ch0_tuser(v_tuser),
        .video_ch0_tready(v_tready),
        .m_axis_video_tdata(), .m_axis_video_tvalid(),
        .m_axis_video_tlast(), .m_axis_video_tuser(),
        .m_axis_video_tready(4'b1111),
        .s_axis_audio_tdata(128'd0), .s_axis_audio_tvalid(4'b0),
        .s_axis_audio_tlast(4'b0), .s_axis_audio_tready(),
        .m_axis_audio_tdata(), .m_axis_audio_tvalid(),
        .m_axis_audio_tlast(), .m_axis_audio_tready(4'b1111),
        .video_pipeline_reset(),
        .usr_irq_req(usr_irq_req),
        .usr_irq_ack(1'b1)
    );

    always @(posedge clk) if (usr_irq_req) usr_irq_seen <= 1'b1;

    // Integration probes
    integer desc_mrd_cnt = 0;
    integer desc_accept_cnt = 0;
    integer dest_req_cnt = 0;
    reg prev_tx_valid = 0;
    always @(posedge clk) begin
        // descriptor fetch = MemWr-style detection won't work; count MRd fmt
        if (s_axis_tx_tvalid && !prev_tx_valid &&
            s_axis_tx_tdata[30:29] == 2'b01)
            desc_mrd_cnt <= desc_mrd_cnt + 1;
        prev_tx_valid <= s_axis_tx_tvalid;
    end
    always @(posedge clk)
        if (u_dma_top.nv12_desc_ready_v) begin
            desc_accept_cnt <= desc_accept_cnt + 1;
            $display("[%0t] PROBE engine accepted descriptor #%0d",
                     $time, desc_accept_cnt + 1);
        end
    always @(posedge video_clk)
        if (u_dma_top.hs_dest_req) begin
            dest_req_cnt <= dest_req_cnt + 1;
            $display("[%0t] PROBE desc-cdc dest_req #%0d",
                     $time, dest_req_cnt + 1);
        end

    // TX observer: log every transmission attempt
    reg tx_prev_valid = 0;
    always @(negedge clk) begin
        if (s_axis_tx_tvalid && !tx_prev_valid)
            $display("[%0t] TX start: fmt=%b type=%b len=%0d tdata=%h",
                     $time, s_axis_tx_tdata[30:29], s_axis_tx_tdata[28:24],
                     s_axis_tx_tdata[9:0], s_axis_tx_tdata);
        else if (s_axis_tx_tvalid)
            $display("[%0t] TX cont : tdata=%h", $time, s_axis_tx_tdata);
        tx_prev_valid <= s_axis_tx_tvalid;
    end

    // ------------------------------------------------------------------
    // Host BFM tasks (copied from tb_sg_dma_pipeline)
    // ------------------------------------------------------------------
    task mmio_write_bar0; input [31:0] reg_addr; input [31:0] reg_data;
        begin
            @(posedge clk);
            m_axis_rx_tvalid <= 1'b1; m_axis_rx_tlast <= 1'b0;
            m_axis_rx_tkeep  <= 16'hFFFF;
            m_axis_rx_tuser  <= 22'b0000000000000000000100; // BAR0
            m_axis_rx_tdata  <= {reg_addr, 32'h00000024, 32'h0000000F,
                                 32'h60000001};
            @(posedge clk);
            while (!m_axis_rx_tready) @(posedge clk);
            m_axis_rx_tvalid <= 1'b1; m_axis_rx_tlast <= 1'b1;
            m_axis_rx_tkeep  <= 16'h000F;
            m_axis_rx_tdata  <= {96'd0, host_dw(reg_data)};
            @(posedge clk);
            while (!m_axis_rx_tready) @(posedge clk);
            m_axis_rx_tvalid <= 1'b0; m_axis_rx_tlast <= 1'b0;
            #20;
        end
    endtask

    task send_nv12_descriptor;
        begin
            @(posedge clk);
            m_axis_rx_tvalid <= 1'b1; m_axis_rx_tlast <= 1'b0;
            m_axis_rx_tkeep  <= 16'hFFFF;
            m_axis_rx_tuser  <= 22'd0;
            // hdr0=CplD len16, hdr1=bytecount 64, hdr2=lower-addr/tag, DW0
            m_axis_rx_tdata  <= {host_dw(32'h00000000), 32'h00000000,
                                 32'h04000000, 32'h4A000010};
            @(posedge clk); while (!m_axis_rx_tready) @(posedge clk);
            // DW1..DW4: plane0_dst = {DW3 hi=0, DW2 lo=Y_BASE}, DW1/DW4 = 0
            m_axis_rx_tdata  <= {host_dw(32'h00000000), host_dw(32'h00000000),
                                 host_dw(Y_BASE[31:0]), host_dw(32'h00000000)};
            @(posedge clk); while (!m_axis_rx_tready) @(posedge clk);
            // DW5..DW8: plane1_dst = {DW7 hi=0, DW6 lo=UV_BASE}
            m_axis_rx_tdata  <= {host_dw(32'h00000000), host_dw(32'h00000000),
                                 host_dw(UV_BASE[31:0]), host_dw(32'h00000000)};
            @(posedge clk); while (!m_axis_rx_tready) @(posedge clk);
            // DW9..DW12 (DW12 = {line_count=4, line_width=1920})
            m_axis_rx_tdata  <= {host_dw(32'h00040780), host_dw(32'h00000000),
                                 host_dw(32'h00000000), host_dw(32'h00000000)};
            @(posedge clk); while (!m_axis_rx_tready) @(posedge clk);
            // DW13=strides {uv=1920, y=1920}, DW14={cnt=2,w=1920}, DW15={ctl=0B,pc=2,fmt=2}
            m_axis_rx_tlast  <= 1'b1;
            m_axis_rx_tdata  <= {32'h00000000, host_dw(32'h00000B22),
                                 host_dw(32'h00020780), host_dw(32'h07800780)};
            @(posedge clk); while (!m_axis_rx_tready) @(posedge clk);
            m_axis_rx_tvalid <= 1'b0; m_axis_rx_tlast <= 1'b0;
        end
    endtask

    // ------------------------------------------------------------------
    // Payload store helpers
    // ------------------------------------------------------------------
    task store_one; input [63:0] addr; input [31:0] d;
        integer off;
        begin
            if (addr >= Y_BASE && addr < Y_BASE + WIDTH*HEIGHT) begin
                off = addr - Y_BASE;
                y_mem[off]   <= d[7:0];
                y_mem[off+1] <= d[15:8];
                y_mem[off+2] <= d[23:16];
                y_mem[off+3] <= d[31:24];
            end else if (addr >= UV_BASE && addr < UV_BASE + WIDTH*HEIGHT/2) begin
                off = addr - UV_BASE;
                uv_mem[off]   <= d[7:0];
                uv_mem[off+1] <= d[15:8];
                uv_mem[off+2] <= d[23:16];
                uv_mem[off+3] <= d[31:24];
            end else begin
                $fatal(1, "MWr outside NV12M planes: addr=%h", addr);
            end
        end
    endtask

    // Capture one fully-resident MWr burst (64 DW / 256B or 32 DW / 128B) and route its payload.
    task capture_one_mwr;
        integer i, num_beats;
        reg [63:0] addr;
        reg [9:0]  dw_len;
        reg [31:0] d0, d1, d2, d3;
        begin
            @(posedge clk);
            while (!(s_axis_tx_tvalid && s_axis_tx_tdata[30:29] == 2'b11))
                @(posedge clk);
            dw_len = s_axis_tx_tdata[9:0];
            if ((dw_len !== 10'd64 && dw_len !== 10'd32) || s_axis_tx_tlast !== 1'b0)
                $fatal(1, "MWr header malformed len=%b(%0d) last=%b tdata=%h",
                       dw_len, dw_len, s_axis_tx_tlast, s_axis_tx_tdata);
            addr = {s_axis_tx_tdata[95:64], s_axis_tx_tdata[127:96]};
            
            // Critical 4 KiB boundary assertion: PCIe requests MUST NOT cross 4KB boundaries!
            if ((addr[11:0] + dw_len * 4) > 4096)
                $fatal(1, "CRITICAL ERROR: MWr crosses 4KB boundary! addr=%h len=%0d bytes",
                       addr, dw_len * 4);

            num_beats = dw_len / 4;
            pkt_cnt = pkt_cnt + 1;
            $display("[%0t] CAPTURE pkt%0d addr=%h len=%0d DW (%0d bytes, %0d beats)",
                     $time, pkt_cnt, addr, dw_len, dw_len*4, num_beats);

            for (i = 0; i < num_beats; i = i + 1) begin
                @(posedge clk);
                while (!s_axis_tx_tvalid) @(posedge clk);
                if (s_axis_tx_tlast !== (i == num_beats - 1))
                    $fatal(1, "packet %0d: TLAST wrong at beat %0d of %0d",
                           pkt_cnt, i, num_beats);
                d0 = host_dw(s_axis_tx_tdata[31:0]);
                d1 = host_dw(s_axis_tx_tdata[63:32]);
                d2 = host_dw(s_axis_tx_tdata[95:64]);
                d3 = host_dw(s_axis_tx_tdata[127:96]);
                store_one(addr + i*16 + 32'h00, d0);
                store_one(addr + i*16 + 32'h04, d1);
                store_one(addr + i*16 + 32'h08, d2);
                store_one(addr + i*16 + 32'h0C, d3);
            end
        end
    endtask

    // ------------------------------------------------------------------
    // Video source: one deterministic frame streamed at 150 MHz
    // ------------------------------------------------------------------
    integer r, c;
    task stream_frame;
        begin
            for (r = 0; r < HEIGHT; r = r + 1) begin
                for (c = 0; c < WIDTH/4; c = c + 1) begin
                    while (!v_tready) @(posedge video_clk);
                    @(negedge video_clk);
                    v_tdata  = {pixel4(r, c*4+3), pixel4(r, c*4+2),
                                pixel4(r, c*4+1), pixel4(r, c*4+0)};
                    v_tuser  = (r == 0 && c == 0);
                    v_tlast  = (c == WIDTH/4 - 1);
                    v_tvalid = 1'b1;
                    @(posedge video_clk);
                end
            end
            @(negedge video_clk);
            v_tvalid <= 1'b0; v_tuser <= 1'b0; v_tlast <= 1'b0;
        end
    endtask

    // ------------------------------------------------------------------
    // Main sequence
    // ------------------------------------------------------------------
    integer expv, i;
    initial begin
        $display(" VIDEO_CDC_TB_V2 BUILD MARKER");
        $display("=========================================================");
        $display(" Video CDC integration test:");
        $display("  desc@125 -> engine@150 -> req_cdc -> RQ@125");
        $display("=========================================================");
        m_axis_rx_tdata = 0; m_axis_rx_tkeep = 0;
        m_axis_rx_tlast = 0; m_axis_rx_tvalid = 0; m_axis_rx_tuser = 0;
        s_axis_tx_tready = 1'b1;
        for (i = 0; i < WIDTH*HEIGHT; i = i + 1)   y_mem[i]  = 8'hEE;
        for (i = 0; i < WIDTH*HEIGHT/2; i = i + 1) uv_mem[i] = 8'hEE;

        #30; rst_n = 1; #30;

        mmio_write_bar0(32'h08, 32'h00000000);           // ring base low
        mmio_write_bar0(32'h0C, 32'h00000000);           // ring base high
        mmio_write_bar0(32'h20, 32'h00000003);           // IRQ enable (both)
        mmio_write_bar0(32'h00, 32'h00000001);           // DMA run
        mmio_write_bar0(32'h10, (32'd1 << 16) | 32'd16); // tail=1,size=16

        @(posedge clk);
        while (!(s_axis_tx_tvalid && s_axis_tx_tdata[30:29] == 2'b01 &&
                 s_axis_tx_tdata[28:24] == 5'b00000)) @(posedge clk);
        $display("  [PASS] descriptor MRd issued");

        send_nv12_descriptor();

        // Packets hit the wire while later rows are still streaming, so the
        // capturer must run concurrently with the video source.
        fork
            begin
                #300;                   // allow descriptor CDC + engine accept
                stream_frame();
            end
            begin
                for (i = 0; i < EXPECT_PKTS; i = i + 1)
                    capture_one_mwr();
            end
        join
        #500;

        if (pkt_cnt != EXPECT_PKTS)
            $fatal(1, "captured %0d packets, expected %0d",
                   pkt_cnt, EXPECT_PKTS);

        for (r = 0; r < HEIGHT; r = r + 1)
            for (c = 0; c < WIDTH; c = c + 1)
                if (y_mem[r*STRIDE+c] !== y_value(r, c))
                    $fatal(1, "Y mismatch r=%0d c=%0d got=%02x exp=%02x",
                           r, c, y_mem[r*STRIDE+c], y_value(r, c));
        for (r = 0; r < HEIGHT/2; r = r + 1)
            for (c = 0; c < WIDTH/2; c = c + 1) begin
                expv = (u_value(r*2, c*2) + u_value(r*2, c*2+1) +
                        u_value(r*2+1, c*2) + u_value(r*2+1, c*2+1) + 2) >> 2;
                if (uv_mem[r*STRIDE+c*2] !== expv[7:0])
                    $fatal(1, "U mismatch r=%0d c=%0d got=%02x exp=%02x",
                           r, c, uv_mem[r*STRIDE+c*2], expv[7:0]);
                expv = (v_value(r*2, c*2) + v_value(r*2, c*2+1) +
                        v_value(r*2+1, c*2) + v_value(r*2+1, c*2+1) + 2) >> 2;
                if (uv_mem[r*STRIDE+c*2+1] !== expv[7:0])
                    $fatal(1, "V mismatch r=%0d c=%0d got=%02x exp=%02x",
                           r, c, uv_mem[r*STRIDE+c*2+1], expv[7:0]);
            end

        if (!usr_irq_seen) $fatal(1, "MSI completion never observed");
        #1000;
        if (desc_accept_cnt !== 1)
            $fatal(1, "Engine accepted descriptor %0d times (expected exactly 1)!", desc_accept_cnt);
        $display("  [PASS] Single descriptor acceptance verified (desc_accept_cnt = 1)");
        $display("SUCCESS: video CDC path verified (%0d packets, IRQ ok, Single Desc ok)",
                 pkt_cnt);
        $finish;
    end

    initial begin
        #2_000_000;
        $fatal(1, "Global timeout -- video CDC path hung");
    end

    // Debug heartbeat
    initial forever begin
        #250;
        $display("[%0t] DBG vreq: st=%0d empty=%b done=%0d started=%0d mreqv=%b full=%b | eng_reqv=%b eng_ack=%b busy=%b descv=%b capen=%b row=%0d req_addr=%h y_plane=%h y_send=%h uv_send=%h",
                 $time,
                 u_dma_top.u_video_req_cdc.rd_state,
                 u_dma_top.u_video_req_cdc.fifo_empty,
                 u_dma_top.u_video_req_cdc.rd_done_seen,
                 u_dma_top.u_video_req_cdc.rd_started,
                 u_dma_top.u_video_req_cdc.m_req_valid,
                 u_dma_top.u_video_req_cdc.fifo_full,
                 u_dma_top.eng_req_valid,
                 u_dma_top.eng_req_ack,
                 u_dma_top.eng_busy,
                 u_dma_top.eng_desc_valid,
                 u_dma_top.u_nv12_capture_engine.capture_enable,
                 u_dma_top.u_nv12_capture_engine.line_idx,
                 u_dma_top.eng_req_addr,
                 u_dma_top.u_nv12_capture_engine.plane_y_addr,
                 u_dma_top.u_nv12_capture_engine.y_send_addr,
                 u_dma_top.u_nv12_capture_engine.uv_send_addr);
    end
endmodule
