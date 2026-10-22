`timescale 1ns/1ps
// Unthrottleable HDMI 4K60: 960 active beats + 140 blank beats per line.
// Exercise the actual video FIFO, converter, request CDC and 256-bit RQ encoder.
module sc7f0_live_video_tb;
    reg rx_clk=0, capture_clk=0, pcie_clk=0, rst_n=0;
    always #3.367 rx_clk=~rx_clk;
    always #3.333 capture_clk=~capture_clk;
    always #4 pcie_clk=~pcie_clk;
    reg run_source=0;
    integer x=0, y=0, frame=0, overflow=0, old_overflow=0;
    wire active=run_source && x<960 && y<2160;
    wire sof=(x==0 && y==0);
    wire eol=(x==959);
    wire [127:0] pixels={4{32'hff332211}};
    wire ready, old_ready;
    integer tpg_sent=0, tpg_received=0;
    wire tpg_ready, tpg_valid, tpg_sof, tpg_eol;
    wire [127:0] tpg_data;
    video_axis_async_fifo #(.DEPTH(32), .MEMORY_TYPE("distributed")) tpg_cdc (
        .s_clk(pcie_clk), .s_rst_n(rst_n), .s_data({96'd0,tpg_sent}),
        .s_valid(run_source && tpg_sent<32), .s_sof(tpg_sent==0),
        .s_eol(tpg_sent==31), .s_ready(tpg_ready),
        .m_clk(capture_clk), .m_rst_n(rst_n), .m_data(tpg_data),
        .m_valid(tpg_valid), .m_sof(tpg_sof), .m_eol(tpg_eol), .m_ready(1'b1));
    always @(posedge pcie_clk)
        if(run_source && tpg_sent<32 && tpg_ready) tpg_sent<=tpg_sent+1;
    always @(posedge capture_clk) if(rst_n && tpg_valid) begin
        if(tpg_data!==tpg_received || tpg_sof!==(tpg_received==0) || tpg_eol!==(tpg_received==31))
            $fatal(1,"TPG CDC beat/marker mismatch at %0d",tpg_received);
        tpg_received<=tpg_received+1;
    end
    wire [127:0] data;
    wire valid, user, last, consume;
    wire busy, done;
    reg desc_valid=0;
    wire desc_ready;
    wire [31:0] errors;
    reg [3:0] format=1;
    integer completed=0, requests=0, payload_bytes=0, accepted=0;
    integer source_frames=0;

    always @(posedge rx_clk) if (run_source) begin
        if (active && !ready) overflow=overflow+1;
        if (active && !old_ready) old_overflow=old_overflow+1;
        if (x==1099) begin
            x<=0;
            if(y==2249) begin y<=0; frame<=frame+1; source_frames<=source_frames+1; end
            else y<=y+1;
        end else x<=x+1;
    end
    video_axis_async_fifo #(.DEPTH(1024)) ingress (
        .s_clk(rx_clk), .s_rst_n(rst_n), .s_data(pixels), .s_valid(active),
        .s_sof(sof), .s_eol(eol), .s_ready(ready),
        .m_clk(capture_clk), .m_rst_n(rst_n), .m_data(data),
        .m_valid(valid), .m_sof(user), .m_eol(last),
        .m_ready(!busy || consume));
    // Negative control: even an always-ready 125 MHz reader overruns 1024 beats.
    video_axis_async_fifo #(.DEPTH(1024)) old_ingress (
        .s_clk(rx_clk), .s_rst_n(rst_n), .s_data(pixels), .s_valid(active),
        .s_sof(sof), .s_eol(eol), .s_ready(old_ready),
        .m_clk(pcie_clk), .m_rst_n(rst_n), .m_data(),
        .m_valid(), .m_sof(), .m_eol(), .m_ready(1'b1));

    wire req_valid, req_ready, req_ack;
    wire [63:0] req_addr;
    wire [10:0] req_len;
    wire [127:0] req_data;
    nv12_capture_engine #(.PCIE_DATA_WIDTH(128), .FIFO_DEPTH(128),
        .MWR_PAYLOAD_BYTES(256)) engine (
        .clk(capture_clk), .rst_n(rst_n),
        .desc_valid(desc_valid), .desc_ready(desc_ready), .desc_format(format),
        .desc_sg_mode(1'b0), .plane_y_addr(64'h10000000), .plane_uv_addr(64'h14000000),
        .frame_width(16'd3840), .frame_height(16'd2160),
        .frame_stride(format==1 ? 16'd11520 : 16'd3840),
        .sgl_y_wr_en(1'b0), .sgl_y_wr_addr(64'd0), .sgl_y_wr_len(32'd0), .sgl_y_wr_flags(32'd0),
        .sgl_uv_wr_en(1'b0), .sgl_uv_wr_addr(64'd0), .sgl_uv_wr_len(32'd0), .sgl_uv_wr_flags(32'd0),
        .cur_y_sgl_count(), .cur_uv_sgl_count(), .sgl_y_pop_ready(), .sgl_uv_pop_ready(),
        .pacer_enable(1'b0), .frame_interval_clks(32'd0), .global_timestamp(64'd0),
        .s_axis_tdata(data), .s_axis_tvalid(valid), .s_axis_tlast(last),
        .s_axis_tuser(user), .s_axis_tready(consume),
        .c2h_req_valid(req_valid), .c2h_req_addr(req_addr), .c2h_req_dw_len(req_len),
        .c2h_req_data(req_data), .c2h_req_last(), .c2h_req_data_ready(req_ready),
        .c2h_req_ack(req_ack), .video_busy(busy), .video_frame_done(done),
        .frame_pts(), .protocol_error_count(errors));
    wire c_valid, c_ready, c_ack, c_done;
    wire [63:0] c_addr;
    wire [10:0] c_len;
    wire [255:0] c_data;
    video_req_cdc #(.DATA_WIDTH(256)) requests_cdc (
        .wr_clk(capture_clk), .wr_rst_n(rst_n), .s_req_valid(req_valid),
        .s_req_addr(req_addr), .s_req_dw_len(req_len), .s_req_data(req_data),
        .s_req_data_ready(req_ready), .s_req_ack(req_ack), .s_frame_done(done),
        .rd_clk(pcie_clk), .rd_rst_n(rst_n), .m_req_valid(c_valid),
        .m_req_addr(c_addr), .m_req_dw_len(c_len), .m_req_data(c_data),
        .m_req_data_ready(c_ready), .m_req_ack(c_ack), .m_frame_done(c_done),
        .m_fifo_empty(), .m_fifo_count());
    rq_tx_encoder #(.DATA_WIDTH(256), .KEEP_WIDTH(8)) encoder (
        .clk(pcie_clk), .rst_n(rst_n), .requester_id(16'h0300),
        .m_axis_rq_tdata(), .m_axis_rq_tvalid(), .m_axis_rq_tlast(),
        .m_axis_rq_tuser(), .m_axis_rq_tkeep(), .m_axis_rq_tready(1'b1),
        .irq_req_valid(1'b0), .irq_req_code(8'd0), .irq_req_ack(),
        .desc_req_valid(1'b0), .desc_req_addr(64'd0), .desc_req_dw_len(11'd0),
        .desc_req_tag(8'd0), .desc_req_ack(),
        .sg_req_valid(1'b0), .sg_req_addr(64'd0), .sg_req_dw_len(11'd0),
        .sg_req_tag(8'd0), .sg_req_ack(),
        .h2c_req_valid(1'b0), .h2c_req_addr(64'd0), .h2c_req_dw_len(11'd0),
        .h2c_req_tag(8'd0), .h2c_req_ack(),
        .c2h_req_valid(c_valid), .c2h_req_addr(c_addr), .c2h_req_dw_len(c_len),
        .c2h_req_data(c_data), .c2h_req_last(1'b0),
        .c2h_req_data_ready(c_ready), .c2h_req_ack(c_ack));
    always @(posedge capture_clk) if (rst_n && valid && consume) accepted<=accepted+1;
    always @(posedge pcie_clk) if (rst_n) begin
        if (c_ack) begin
            requests<=requests+1;
            payload_bytes<=payload_bytes+c_len*4;
        end
        if(c_done) completed<=completed+1;
    end
    initial begin
        if ($test$plusargs("NV12")) format=2;
        #100; rst_n=1;
        repeat(100) @(posedge capture_clk);
        @(negedge capture_clk); desc_valid=1;
        wait(desc_ready);
        @(negedge capture_clk); desc_valid=0;
        @(negedge rx_clk); run_source=1;
        wait(completed==1);
        if(errors || overflow) $fatal(1,"Live raster lost data: errors=%0d overflow=%0d",errors,overflow);
        if(payload_bytes != (format==1 ? 24883200 : 12441600))
            $fatal(1,"Bad payload size %0d",payload_bytes);
        if(accepted!=2073600) $fatal(1,"Bad accepted beat count %0d",accepted);
        if(tpg_received!=32) $fatal(1,"TPG CDC did not complete");
        if(!old_overflow) $fatal(1,"Negative control did not reproduce 125 MHz FIFO overflow");
        // Continue draining idle live video; rearm on a later source frame.
        wait(source_frames==2);
        @(negedge capture_clk); desc_valid=1;
        wait(desc_ready);
        @(negedge capture_clk); desc_valid=0;
        wait(completed==2);
        if(errors || overflow) $fatal(1,"Second capture failed: errors=%0d overflow=%0d",errors,overflow);
        if(payload_bytes != (format==1 ? 49766400 : 24883200)) $fatal(1,"Bad second payload size");
        $display("TB_PASS: live 4K60 format=%0d frames=%0d bytes=%0d; old 125MHz lost=%0d beats",format,completed,payload_bytes,old_overflow);
        $finish;
    end
    initial begin #70000000; $fatal(1,"Live video test timed out"); end
endmodule
