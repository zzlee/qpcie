`timescale 1ns / 1ps

module tb_cdc_sync_clks;
    reg clk = 0;
    reg rst_n = 0;

    // Both clocks are identical 125 MHz (8.000 ns)
    always #4.000 clk = ~clk; always @(posedge clk) begin if (dut.hdr_rd_en) $display("[%0t] HDR_POP: hdr_dout[75]=%b rd_started=%0d rd_completed=%0d rd_state=%0d", $time, dut.hdr_dout[75], dut.rd_started, dut.rd_completed, dut.rd_state); if (dut.m_frame_done) $display("[%0t] EVENT: m_frame_done pulsed high!", $time); end

    reg s_req_valid = 0;
    reg [63:0] s_req_addr = 0;
    reg [10:0] s_req_dw_len = 0;
    reg [127:0] s_req_data = 0;
    wire s_req_data_ready;
    wire s_req_ack;
    reg s_frame_done = 0;

    wire m_req_valid;
    wire [63:0] m_req_addr;
    wire [10:0] m_req_dw_len;
    wire [255:0] m_req_data;
    wire m_req_data_ready;
    reg m_req_ack = 0;
    wire m_frame_done;

    always @(posedge clk) if (m_frame_done) $display("[%0t] EVENT: m_frame_done pulsed high!", $time);

    always @(posedge clk) begin
        if ($time >= 1940000 && $time <= 2150000) begin
            $display("[%0t] TRACE: state=%0d vld=%b ack=%b rden=%b empty=%b d75=%b strt=%0d cmp=%0d",
                     $time, dut.rd_state, dut.m_req_valid, m_req_ack, dut.hdr_rd_en, dut.hdr_empty, dut.hdr_dout[75], dut.rd_started, dut.rd_completed);
        end
    end

    video_req_cdc #(
        .DATA_WIDTH(256),
        .MAX_DWORDS(64),
        .FIFO_DEPTH(512)
    ) dut (
        .wr_clk(clk),
        .wr_rst_n(rst_n),
        .s_req_valid(s_req_valid),
        .s_req_addr(s_req_addr),
        .s_req_dw_len(s_req_dw_len),
        .s_req_data(s_req_data),
        .s_req_data_ready(s_req_data_ready),
        .s_req_ack(s_req_ack),
        .s_frame_done(s_frame_done),

        .rd_clk(clk),
        .rd_rst_n(rst_n),
        .m_req_valid(m_req_valid),
        .m_req_addr(m_req_addr),
        .m_req_dw_len(m_req_dw_len),
        .m_req_data(m_req_data),
        .m_req_data_ready(m_req_data_ready),
        .m_req_ack(m_req_ack),
        .m_frame_done(m_frame_done),
        .m_fifo_empty(),
        .m_fifo_count()
    );

    // Requester simulation (like RQ TX encoder for 256-bit):
    // 256-byte TLP is 8 beats of 256-bit.
    // m_req_data_ready asserted for 8 beats, then m_req_ack pulsed.
    reg [3:0] rd_beat = 0;
    reg rd_streaming = 0;
    assign m_req_data_ready = rd_streaming;

    always @(posedge clk) begin
        m_req_ack <= 0;
        if (!rst_n) begin
            rd_beat <= 0;
            rd_streaming <= 0;
        end else begin
            if (m_req_valid && !rd_streaming) begin
                rd_streaming <= 1;
                rd_beat <= 0;
            end else if (rd_streaming) begin
                rd_beat <= rd_beat + 1;
                if (rd_beat == 7) begin
                    rd_streaming <= 0;
                    m_req_ack <= 1; // Ack on 8th beat
                end
            end
        end
    end

    integer pkt, beat;
    initial begin
        #100;
        @(posedge clk);
        rst_n = 1;
        #100;

        $display("[%0t] Starting packet transmission...", $time);
        // Send 10 packets back-to-back as nv12_capture_engine does
        for (pkt = 0; pkt < 10; pkt = pkt + 1) begin
            // nv12_capture_engine asserts c2h_req_valid
            @(posedge clk);
            s_req_valid <= 1;
            s_req_addr  <= 64'h1000 + pkt * 256;
            s_req_dw_len <= 11'd64;

            // Send 16 beats of 128-bit
            for (beat = 0; beat < 16; beat = beat + 1) begin
                s_req_data <= {64'hA5A5, pkt[15:0], beat[15:0], 32'h0};
                @(posedge clk);
                while (!s_req_data_ready) @(posedge clk);
            end

            // Wait for ack
            while (!s_req_ack) @(posedge clk);
            @(posedge clk);
            s_req_valid <= 0;
        end

        $display("[%0t] All 10 packets sent. Pulsing s_frame_done on NEXT cycle...", $time);
        @(posedge clk);
        s_frame_done <= 1;
        @(posedge clk);
        s_frame_done <= 0;

        // Monitor m_frame_done
        fork
            begin
                @(posedge m_frame_done);
                $display("[%0t] SUCCESS: m_frame_done asserted!", $time);
                #100;
                $finish;
            end
            begin
                #20000;
                $display("[%0t] TIMEOUT: m_frame_done never asserted!", $time);
                $display("dut wr_state=%0d eof_pending=%b hdr_empty=%b hdr_dout[75]=%b",
                         dut.wr_state, dut.eof_pending, dut.hdr_empty, dut.hdr_dout[75]);
                $display("dut rd_state=%0d rd_started=%0d rd_completed=%0d",
                         dut.rd_state, dut.rd_started, dut.rd_completed);
                $fatal(1);
            end
        join
    end
endmodule
