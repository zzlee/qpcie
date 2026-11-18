`timescale 1ns / 1ps

module sc7f0_phase_cb_tb;
    reg clk = 0;
    always #4 clk = ~clk;

    reg rst_n = 0;

    // 1) Test sc7f0_axil_demux_1to2
    reg  [31:0] d_s_awaddr = 0, d_s_wdata = 0, d_s_araddr = 0;
    reg  [3:0]  d_s_wstrb = 4'hF;
    reg         d_s_awvalid = 0, d_s_wvalid = 0, d_s_bready = 0;
    reg         d_s_arvalid = 0, d_s_rready = 0;
    wire        d_s_awready, d_s_wready, d_s_bvalid, d_s_arready, d_s_rvalid;
    wire [1:0]  d_s_bresp, d_s_rresp;
    wire [31:0] d_s_rdata;

    wire [31:0] d_m0_awaddr, d_m0_wdata, d_m0_araddr;
    wire [3:0]  d_m0_wstrb;
    wire        d_m0_awvalid, d_m0_wvalid, d_m0_bready, d_m0_arvalid, d_m0_rready;
    reg         d_m0_awready = 1, d_m0_wready = 1, d_m0_bvalid = 0, d_m0_arready = 1, d_m0_rvalid = 0;
    reg  [31:0] d_m0_rdata = 32'h1111_0000;

    wire [31:0] d_m1_awaddr, d_m1_wdata, d_m1_araddr;
    wire [3:0]  d_m1_wstrb;
    wire        d_m1_awvalid, d_m1_wvalid, d_m1_bready, d_m1_arvalid, d_m1_rready;
    reg         d_m1_awready = 1, d_m1_wready = 1, d_m1_bvalid = 0, d_m1_arready = 1, d_m1_rvalid = 0;
    reg  [31:0] d_m1_rdata = 32'h5247_4231;

    sc7f0_axil_demux_1to2 u_demux (
        .clk(clk), .rst_n(rst_n),
        .s_awaddr(d_s_awaddr), .s_awvalid(d_s_awvalid), .s_awready(d_s_awready),
        .s_wdata(d_s_wdata),   .s_wstrb(d_s_wstrb),     .s_wvalid(d_s_wvalid),   .s_wready(d_s_wready),
        .s_bresp(d_s_bresp),   .s_bvalid(d_s_bvalid),   .s_bready(d_s_bready),
        .s_araddr(d_s_araddr), .s_arvalid(d_s_arvalid), .s_arready(d_s_arready),
        .s_rdata(d_s_rdata),   .s_rresp(d_s_rresp),     .s_rvalid(d_s_rvalid),   .s_rready(d_s_rready),
        .m0_awaddr(d_m0_awaddr), .m0_awvalid(d_m0_awvalid), .m0_awready(d_m0_awready),
        .m0_wdata(d_m0_wdata),   .m0_wstrb(d_m0_wstrb),     .m0_wvalid(d_m0_wvalid),   .m0_wready(d_m0_wready),
        .m0_bresp(2'b00),        .m0_bvalid(d_m0_bvalid),   .m0_bready(d_m0_bready),
        .m0_araddr(d_m0_araddr), .m0_arvalid(d_m0_arvalid), .m0_arready(d_m0_arready),
        .m0_rdata(d_m0_rdata),   .m0_rresp(2'b00),          .m0_rvalid(d_m0_rvalid),   .m0_rready(d_m0_rready),
        .m1_awaddr(d_m1_awaddr), .m1_awvalid(d_m1_awvalid), .m1_awready(d_m1_awready),
        .m1_wdata(d_m1_wdata),   .m1_wstrb(d_m1_wstrb),     .m1_wvalid(d_m1_wvalid),   .m1_wready(d_m1_wready),
        .m1_bresp(2'b00),        .m1_bvalid(d_m1_bvalid),   .m1_bready(d_m1_bready),
        .m1_araddr(d_m1_araddr), .m1_arvalid(d_m1_arvalid), .m1_arready(d_m1_arready),
        .m1_rdata(d_m1_rdata),   .m1_rresp(2'b00),          .m1_rvalid(d_m1_rvalid),   .m1_rready(d_m1_rready)
    );

    // 2) Test sc7f0_axil_mux_2to1
    reg  [31:0] m_s0_awaddr = 0, m_s0_wdata = 0, m_s0_araddr = 0;
    reg         m_s0_awvalid = 0, m_s0_wvalid = 0, m_s0_bready = 1, m_s0_arvalid = 0, m_s0_rready = 1;
    wire        m_s0_awready, m_s0_wready, m_s0_bvalid, m_s0_arready, m_s0_rvalid;
    wire [31:0] m_s0_rdata;

    reg  [31:0] m_s1_awaddr = 0, m_s1_wdata = 0, m_s1_araddr = 0;
    reg         m_s1_awvalid = 0, m_s1_wvalid = 0, m_s1_bready = 1, m_s1_arvalid = 0, m_s1_rready = 1;
    wire        m_s1_awready, m_s1_wready, m_s1_bvalid, m_s1_arready, m_s1_rvalid;
    wire [31:0] m_s1_rdata;

    wire [31:0] mux_awaddr, mux_wdata, mux_araddr;
    wire [3:0]  mux_wstrb;
    wire        mux_awvalid, mux_wvalid, mux_bready, mux_arvalid, mux_rready;
    reg         mux_awready = 1, mux_wready = 1, mux_bvalid = 0, mux_arready = 1, mux_rvalid = 0;
    reg  [31:0] mux_rdata = 32'hCAFE_BABE;

    sc7f0_axil_mux_2to1 u_mux (
        .clk(clk), .rst_n(rst_n),
        .s0_awaddr(m_s0_awaddr), .s0_awvalid(m_s0_awvalid), .s0_awready(m_s0_awready),
        .s0_wdata(m_s0_wdata),   .s0_wstrb(4'hF),           .s0_wvalid(m_s0_wvalid),   .s0_wready(m_s0_wready),
        .s0_bresp(),             .s0_bvalid(m_s0_bvalid),   .s0_bready(m_s0_bready),
        .s0_araddr(m_s0_araddr), .s0_arvalid(m_s0_arvalid), .s0_arready(m_s0_arready),
        .s0_rdata(m_s0_rdata),   .s0_rresp(),               .s0_rvalid(m_s0_rvalid),   .s0_rready(m_s0_rready),
        .s1_awaddr(m_s1_awaddr), .s1_awvalid(m_s1_awvalid), .s1_awready(m_s1_awready),
        .s1_wdata(m_s1_wdata),   .s1_wstrb(4'hF),           .s1_wvalid(m_s1_wvalid),   .s1_wready(m_s1_wready),
        .s1_bresp(),             .s1_bvalid(m_s1_bvalid),   .s1_bready(m_s1_bready),
        .s1_araddr(m_s1_araddr), .s1_arvalid(m_s1_arvalid), .s1_arready(m_s1_arready),
        .s1_rdata(m_s1_rdata),   .s1_rresp(),               .s1_rvalid(m_s1_rvalid),   .s1_rready(m_s1_rready),
        .m_awaddr(mux_awaddr),   .m_awvalid(mux_awvalid),   .m_awready(mux_awready),
        .m_wdata(mux_wdata),     .m_wstrb(mux_wstrb),       .m_wvalid(mux_wvalid),     .m_wready(mux_wready),
        .m_bresp(2'b00),         .m_bvalid(mux_bvalid),     .m_bready(mux_bready),
        .m_araddr(mux_araddr),   .m_arvalid(mux_arvalid),   .m_arready(mux_arready),
        .m_rdata(mux_rdata),     .m_rresp(2'b00),           .m_rvalid(mux_rvalid),     .m_rready(mux_rready)
    );

    // 3) Test interrupt_ctrl ovl_wr_done -> irq_top_status[8] & usr_irq_req
    reg  [31:0] irq_top_w1c = 0;
    wire [31:0] irq_top_status;
    reg         ovl_wr_done = 0;
    reg         usr_irq_ack = 0;
    wire        usr_irq_req;
    wire [7:0]  irq_req_code;
    wire        irq_req_valid;

    interrupt_ctrl u_irq (
        .clk(clk), .rst_n(rst_n),
        .reg_irq_ctrl(32'd0), .reg_irq_status_w1c(32'd0), .reg_irq_status(),
        .irq_top_status(irq_top_status), .irq_top_status_w1c(irq_top_w1c),
        .vch0_irq_status(), .vch0_irq_status_w1c(4'd0), .vch0_irq_en(1'b0),
        .vch1_irq_status(), .vch1_irq_status_w1c(4'd0), .vch1_irq_en(1'b0),
        .vch2_irq_status(), .vch2_irq_status_w1c(4'd0), .vch2_irq_en(1'b0),
        .vch3_irq_status(), .vch3_irq_status_w1c(4'd0), .vch3_irq_en(1'b0),
        .adev0_irq_status(), .adev0_irq_status_w1c(2'd0), .adev0_irq_en(1'b0),
        .h2c_done(1'b0), .c2h_done(1'b0),
        .v_done_ch(4'd0), .h2c_done_ch(3'd0), .a_done_irq(4'd0),
        .ovl_wr_done(ovl_wr_done),
        .v_overflow_ch(4'd0), .v_desc_err_ch(4'd0), .v_fifo_err_ch(4'd0),
        .a_xrun_ch(4'd0), .global_err(1'b0),
        .irq_req_valid(irq_req_valid), .irq_req_code(irq_req_code), .irq_req_ack(1'b0),
        .usr_irq_req(usr_irq_req), .usr_irq_ack(usr_irq_ack)
    );

    integer errs = 0;

    initial begin
        #20; rst_n = 1; #16;

        // Test Demux Read 0x4078 -> m1
        @(negedge clk);
        d_s_araddr = 32'h0000_4078; d_s_arvalid = 1; d_s_rready = 1;
        @(posedge clk); // latched rd_active=1, rd_sel=1
        @(negedge clk);
        if (!d_m1_arvalid || d_m0_arvalid) begin $display("FAIL demux m1 arvalid"); errs = errs + 1; end
        d_m1_rvalid = 1;
        #1;
        if (!d_s_rvalid || d_s_rdata !== 32'h5247_4231) begin $display("FAIL demux m1 rdata=%h", d_s_rdata); errs = errs + 1; end
        @(posedge clk);
        @(negedge clk);
        d_s_arvalid = 0; d_m1_rvalid = 0;

        // Test Demux Write 0x0010 -> m0
        @(negedge clk);
        d_s_awaddr = 32'h0000_0010; d_s_awvalid = 1; d_s_wdata = 32'hDEAD_BEEF; d_s_wvalid = 1; d_s_bready = 1;
        @(posedge clk);
        @(negedge clk);
        if (!d_m0_awvalid || d_m1_awvalid) begin $display("FAIL demux m0 awvalid"); errs = errs + 1; end
        d_m0_bvalid = 1;
        #1;
        if (!d_s_bvalid) begin $display("FAIL demux m0 bvalid"); errs = errs + 1; end
        @(posedge clk);
        @(negedge clk);
        d_s_awvalid = 0; d_s_wvalid = 0; d_m0_bvalid = 0;

        // Test Mux concurrent s0 & s1 write: s1 wins first, s0 waits cleanly
        @(negedge clk);
        m_s0_awaddr = 32'h0000_0004; m_s0_awvalid = 1; m_s0_wdata = 32'hAAAA_AAAA; m_s0_wvalid = 1;
        m_s1_awaddr = 32'h0000_4004; m_s1_awvalid = 1; m_s1_wdata = 32'hBBBB_BBBB; m_s1_wvalid = 1;
        @(posedge clk);
        @(negedge clk);
        if (!mux_awvalid || mux_wdata !== 32'hBBBB_BBBB) begin $display("FAIL mux s1 win"); errs = errs + 1; end
        mux_bvalid = 1;
        #1;
        if (!m_s1_bvalid || m_s0_bvalid) begin $display("FAIL mux s1 bvalid"); errs = errs + 1; end
        @(posedge clk);
        @(negedge clk);
        m_s1_awvalid = 0; m_s1_wvalid = 0; mux_bvalid = 0;
        @(posedge clk); // s0 wins now
        @(negedge clk);
        if (!mux_awvalid || mux_wdata !== 32'hAAAA_AAAA) begin $display("FAIL mux s0 next"); errs = errs + 1; end
        mux_bvalid = 1;
        @(posedge clk);
        @(negedge clk);
        m_s0_awvalid = 0; m_s0_wvalid = 0; mux_bvalid = 0;

        // Test interrupt_ctrl ovl_wr_done
        @(negedge clk); ovl_wr_done = 1;
        @(posedge clk);
        @(negedge clk); ovl_wr_done = 0;
        @(posedge clk); @(posedge clk);
        if (!irq_top_status[8] || !usr_irq_req || irq_req_code !== 8'h08) begin
            $display("FAIL irq top=%h req=%b code=%h", irq_top_status, usr_irq_req, irq_req_code);
            errs = errs + 1;
        end
        @(negedge clk); usr_irq_ack = 1; irq_top_w1c = 32'h0000_0100;
        @(posedge clk);
        @(negedge clk); usr_irq_ack = 0; irq_top_w1c = 0;
        @(posedge clk);
        if (irq_top_status[8] || usr_irq_req) begin
            $display("FAIL irq clear top=%h req=%b", irq_top_status, usr_irq_req);
            errs = errs + 1;
        end

        if (errs == 0)
            $display("PHASE_CB_RTL_TB_PASS");
        else
            $display("PHASE_CB_RTL_TB_FAIL errs=%0d", errs);
        $finish;
    end
endmodule
