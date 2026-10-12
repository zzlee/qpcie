`timescale 1ns / 1ps
// Exercise real HP0 writer independently of PCIe and the AXIS clock converter.
module zu4ev_upg_writer_tb;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0, enable = 0, valid = 0;
    reg [127:0] data = 0;
    wire ready, done, irq;
    wire [31:0] bytes_written;
    wire [48:0] awaddr;
    wire [7:0] awlen;
    wire [2:0] awsize;
    wire [1:0] awburst;
    wire awvalid, wvalid, wlast, bready;
    wire [127:0] wdata;
    wire [15:0] wstrb;
    reg bvalid = 0;
    integer beats = 0, bursts = 0;

    h2c_ps_ddr_writer dut (
        .clk(clk), .rst_n(rst_n), .upg_enable(enable),
        .upg_dst_addr(49'h30000000), .upg_total_size(32'd4096),
        .upg_bytes_written(bytes_written), .upg_write_done(done),
        .upg_irq_pulse(irq), .s_axis_tdata(data),
        .s_axis_tvalid(valid), .s_axis_tlast(1'b0), .s_axis_tready(ready),
        .m_axi_awaddr(awaddr), .m_axi_awlen(awlen),
        .m_axi_awsize(awsize), .m_axi_awburst(awburst),
        .m_axi_awvalid(awvalid), .m_axi_awready(1'b1),
        .m_axi_wdata(wdata), .m_axi_wstrb(wstrb), .m_axi_wlast(wlast),
        .m_axi_wvalid(wvalid), .m_axi_wready(1'b1),
        .m_axi_bresp(2'b00), .m_axi_bvalid(bvalid), .m_axi_bready(bready)
    );

    always @(posedge clk) begin
        if (!rst_n) begin
            bvalid <= 0;
            beats <= 0;
            bursts <= 0;
        end else begin
            if (awvalid) begin
                if (awaddr !== 49'h30000000 + bursts * 256 || awlen !== 8'd15 ||
                    awsize !== 3'd4 || awburst !== 2'b01)
                    $fatal(1, "invalid HP0 AW: addr=%h len=%d", awaddr, awlen);
                bursts <= bursts + 1;
            end
            if (wvalid) begin
                if (wdata[31:0] !== beats || wstrb !== 16'hffff ||
                    wlast !== ((beats % 16) == 15))
                    $fatal(1, "invalid HP0 W: beat=%0d data=%h last=%b", beats, wdata, wlast);
                beats <= beats + 1;
            end
            if (bvalid && bready) bvalid <= 0;
            else if (wvalid && wlast) bvalid <= 1;
        end
    end

    initial begin
        repeat (5) @(negedge clk);
        rst_n = 1;
        enable = 1;
        for (int i=0; i<256; i++) begin
            @(negedge clk);
            while (!ready) @(negedge clk);
            valid = 1;
            data = {96'd0, i[31:0]};
            @(negedge clk);
            valid = 0;
        end
        fork : check_done
            wait (done);
            begin repeat (5000) @(negedge clk); $fatal(1, "writer stuck: beats=%0d bytes=%0d", beats, bytes_written); end
        join_any
        disable check_done;
        if (beats !== 256 || bursts !== 16 || bytes_written !== 4096)
            $fatal(1, "writer mismatch beats=%0d bursts=%0d bytes=%0d", beats, bursts, bytes_written);
        $display("TB_PASS: 4096 bytes to HP0, 16 bursts, 16 B responses");
        $finish;
    end
endmodule
