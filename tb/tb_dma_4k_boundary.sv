`timescale 1ns / 1ps

module tb_dma_4k_boundary;
    reg clk_video = 0; // 150 MHz
    reg clk_pcie  = 0; // 125 MHz
    reg rst_n = 0;

    always #3.333 clk_video = ~clk_video;
    always #4.000 clk_pcie  = ~clk_pcie;

    // Stream inputs to nv12_capture_engine
    reg desc_valid = 0;
    wire desc_ready;
    reg [127:0] s_axis_tdata = 0;
    reg         s_axis_tvalid = 0;
    reg         s_axis_tlast = 0;
    reg         s_axis_tuser = 0;
    wire        s_axis_tready;

    // Engine to CDC wires
    wire c2h_req_valid, c2h_req_data_ready, c2h_req_ack, c2h_req_last;
    wire [63:0] c2h_req_addr;
    wire [10:0] c2h_req_dw_len;
    wire [127:0] c2h_req_data;
    wire video_busy, video_frame_done;

    // SGL walker inputs
    reg sgl_y_wr_en = 0;
    reg [63:0] sgl_y_wr_addr = 0;
    reg [31:0] sgl_y_wr_len = 0;
    reg [31:0] sgl_y_wr_flags = 0;
    wire sgl_y_pop_ready;

    nv12_capture_engine #(
        .MAX_WIDTH(4096),
        .PCIE_DATA_WIDTH(128),
        .FIFO_DEPTH(512),
        .MWR_PAYLOAD_BYTES(256)
    ) u_engine (
        .clk(clk_video),
        .rst_n(rst_n),
        .desc_valid(desc_valid),
        .desc_ready(desc_ready),
        .desc_format(4'd1), // RGB24
        .desc_sg_mode(1'b1),
        .plane_y_addr(64'd0),
        .plane_uv_addr(64'd0),
        .frame_width(16'd11520), // 3840 * 3
        .frame_height(16'd2),    // 2 lines for quick test
        .frame_stride(16'd11520),
        .sgl_y_wr_en(sgl_y_wr_en),
        .sgl_y_wr_addr(sgl_y_wr_addr),
        .sgl_y_wr_len(sgl_y_wr_len),
        .sgl_y_wr_flags(sgl_y_wr_flags),
        .sgl_uv_wr_en(1'b0),
        .sgl_uv_wr_addr(64'd0),
        .sgl_uv_wr_len(32'd0),
        .sgl_uv_wr_flags(32'd0),
        .cur_y_sgl_count(),
        .cur_uv_sgl_count(),
        .sgl_y_pop_ready(sgl_y_pop_ready),
        .sgl_uv_pop_ready(),
        .pacer_enable(1'b0),
        .frame_interval_clks(32'd0),
        .global_timestamp(64'd0),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tlast(s_axis_tlast),
        .s_axis_tuser(s_axis_tuser),
        .s_axis_tready(s_axis_tready),
        .c2h_req_valid(c2h_req_valid),
        .c2h_req_addr(c2h_req_addr),
        .c2h_req_dw_len(c2h_req_dw_len),
        .c2h_req_data(c2h_req_data),
        .c2h_req_last(c2h_req_last),
        .c2h_req_data_ready(c2h_req_data_ready),
        .c2h_req_ack(c2h_req_ack),
        .video_busy(video_busy),
        .video_frame_done(video_frame_done),
        .frame_pts(),
        .protocol_error_count()
    );

    // CDC to PCIe wires
    wire m_cdc_valid;
    wire [63:0] m_cdc_addr;
    wire [10:0] m_cdc_dw_len;
    wire [255:0] m_cdc_data;
    wire m_cdc_data_ready;
    wire m_cdc_ack;
    wire m_cdc_frame_done;

    video_req_cdc #(
        .MAX_DWORDS(64),
        .FIFO_DEPTH(512),
        .WR_DATA_WIDTH(128),
        .DATA_WIDTH(256)
    ) u_cdc (
        .wr_clk(clk_video),
        .wr_rst_n(rst_n),
        .s_req_valid(c2h_req_valid),
        .s_req_addr(c2h_req_addr),
        .s_req_dw_len(c2h_req_dw_len),
        .s_req_data(c2h_req_data),
        .s_req_data_ready(c2h_req_data_ready),
        .s_req_ack(c2h_req_ack),
        .s_frame_done(video_frame_done),
        .rd_clk(clk_pcie),
        .rd_rst_n(rst_n),
        .m_req_valid(m_cdc_valid),
        .m_req_addr(m_cdc_addr),
        .m_req_dw_len(m_cdc_dw_len),
        .m_req_data(m_cdc_data),
        .m_req_data_ready(m_cdc_data_ready),
        .m_req_ack(m_cdc_ack),
        .m_frame_done(m_cdc_frame_done),
        .m_fifo_empty(),
        .m_fifo_count()
    );

    // RQ Encoder (256-bit)
    wire [255:0] m_axis_rq_tdata;
    wire m_axis_rq_tvalid, m_axis_rq_tlast;
    wire [7:0] m_axis_rq_tkeep;
    reg m_axis_rq_tready = 1;

    rq_tx_encoder #(
        .DATA_WIDTH(256),
        .KEEP_WIDTH(8)
    ) u_rq_enc (
        .clk(clk_pcie),
        .rst_n(rst_n),
        .requester_id(16'h0001),
        .m_axis_rq_tdata(m_axis_rq_tdata),
        .m_axis_rq_tvalid(m_axis_rq_tvalid),
        .m_axis_rq_tlast(m_axis_rq_tlast),
        .m_axis_rq_tuser(),
        .m_axis_rq_tkeep(m_axis_rq_tkeep),
        .m_axis_rq_tready(m_axis_rq_tready),
        .irq_req_valid(1'b0), .irq_req_code(8'd0), .irq_req_ack(),
        .desc_req_valid(1'b0), .desc_req_addr(64'd0), .desc_req_dw_len(11'd0), .desc_req_tag(8'd0), .desc_req_ack(),
        .sg_req_valid(1'b0), .sg_req_addr(64'd0), .sg_req_dw_len(11'd0), .sg_req_tag(8'd0), .sg_req_ack(),
        .h2c_req_valid(1'b0), .h2c_req_addr(64'd0), .h2c_req_dw_len(11'd0), .h2c_req_tag(8'd0), .h2c_req_ack(),
        .c2h_req_valid(m_cdc_valid),
        .c2h_req_addr(m_cdc_addr),
        .c2h_req_dw_len(m_cdc_dw_len),
        .c2h_req_data(m_cdc_data),
        .c2h_req_last(1'b1),
        .c2h_req_data_ready(m_cdc_data_ready),
        .c2h_req_ack(m_cdc_ack)
    );

    // Host Memory Model to capture writes
    reg [7:0] host_mem [0:65535];
    reg [63:0] cur_mwr_addr = 0;
    reg [10:0] cur_mwr_len = 0;
    reg in_mwr = 0;

    always @(posedge clk_pcie) begin
        if (m_axis_rq_tvalid && m_axis_rq_tready) begin
            if (!in_mwr) begin
                // Beat 0: Header in [127:0], first 16 bytes of data in [255:128]
                cur_mwr_addr = m_axis_rq_tdata[63:0];
                cur_mwr_len  = m_axis_rq_tdata[74:64];
                $display("[%0t] PCIe MWr START: Addr=0x%08x, Len=%0d DW (%0d Bytes)", 
                         $time, cur_mwr_addr, cur_mwr_len, cur_mwr_len*4);
                
                // Write first 16 bytes
                for (int b = 0; b < 16; b++) begin
                    host_mem[cur_mwr_addr + b] = m_axis_rq_tdata[128 + b*8 +: 8];
                end
                cur_mwr_addr = cur_mwr_addr + 16;
                if (!m_axis_rq_tlast) in_mwr <= 1;
            end else begin
                // Subsequent beats
                int num_bytes = m_axis_rq_tlast ? 16 : 32;
                for (int b = 0; b < num_bytes; b++) begin
                    host_mem[cur_mwr_addr + b] = m_axis_rq_tdata[b*8 +: 8];
                end
                cur_mwr_addr = cur_mwr_addr + num_bytes;
                if (m_axis_rq_tlast) begin
                    $display("[%0t] PCIe MWr END: Final Addr=0x%08x", $time, cur_mwr_addr);
                    in_mwr <= 0;
                end
            end
        end
    end

    // Pixel generator: sequential pixel counter so each pixel has unique bytes!
    reg [23:0] pixel_counter = 0;
    integer beat_in_line = 0;
    integer line_in_frame = 0;

    initial begin
        #100;
        rst_n = 1;
        #100;

        // Issue descriptor
        @(negedge clk_video);
        desc_valid = 1;
        wait(desc_ready);
        @(negedge clk_video);
        desc_valid = 0;

        // Push SGL segments
        @(posedge clk_video);
        sgl_y_wr_en    <= 1;
        sgl_y_wr_addr  <= 64'h0000;
        sgl_y_wr_len   <= 32'd65536;
        sgl_y_wr_flags <= 32'd1;
        @(posedge clk_video);
        sgl_y_wr_en    <= 0;

        #100;
        $display("[%0t] Starting video input...", $time);

        // Feed 960 beats per line (4 pixels per beat = 3840 pixels per line)
        for (line_in_frame = 0; line_in_frame < 2; line_in_frame++) begin
            for (beat_in_line = 0; beat_in_line < 960; beat_in_line++) begin
                @(posedge clk_video);
                while (!s_axis_tready) @(posedge clk_video);
                s_axis_tvalid <= 1;
                s_axis_tuser  <= (line_in_frame == 0 && beat_in_line == 0);
                s_axis_tlast  <= (beat_in_line == 959);
                // 4 pixels: P0, P1, P2, P3 (each 24 bits + 8 bit padding = 32 bits, 4*32=128)
                s_axis_tdata  <= {8'h00, 24'(pixel_counter + 24'd3),
                                  8'h00, 24'(pixel_counter + 24'd2),
                                  8'h00, 24'(pixel_counter + 24'd1),
                                  8'h00, 24'(pixel_counter)};
                pixel_counter <= pixel_counter + 24'd4;
            end
        end
        @(posedge clk_video);
        s_axis_tvalid <= 0;
        s_axis_tlast  <= 0;
        s_axis_tuser  <= 0;

        // Wait for frame to finish
        #10000;

        $display("\n========================================================");
        $display("SCANNING HOST MEMORY FOR FIRST MISMATCH");
        $display("========================================================");
        begin
            int mismatch_count = 0;
            for (int addr = 0; addr < 11520; addr += 3) begin
                reg [23:0] pix;
                int expected_pix_idx = addr / 3;
                pix = {host_mem[addr+2], host_mem[addr+1], host_mem[addr]};
                if (pix !== expected_pix_idx) begin
                    $display("MISMATCH at addr %0d (0x%04x): Got Pixel 0x%06x (bytes %02x %02x %02x) | Expected 0x%06x | Diff=%0d",
                             addr, addr, pix, host_mem[addr], host_mem[addr+1], host_mem[addr+2], expected_pix_idx, pix - expected_pix_idx);
                    mismatch_count++;
                    if (mismatch_count > 30) break;
                end
            end
            if (mismatch_count == 0)
                $display("ALL BYTES MATCH PERFECTLY!");
        end
        $finish;
    end
endmodule
