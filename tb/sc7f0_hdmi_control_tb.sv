`timescale 1ns/1ps
// Real production crossbar; mailbox RAMs stand in for HDMI register banks.
// Does NOT model HDMI IP semantics, PS hard block, or PHY serial links.
module sc7f0_hdmi_control_tb;
    reg clk=0; always #5 clk=~clk;
    reg rst_n=0, test_passed=0;
    reg [31:0] awaddr=0, araddr=0, wdata=0;
    reg awvalid=0,wvalid=0,bready=0,arvalid=0,rready=0;
    wire awready,wready,bvalid,arready,rvalid;
    wire [31:0] rdata;
    wire [1:0] bresp,rresp;
    wire [95:0] mawa,mara,mwd,mrd;
    wire [11:0] mws;
    wire [2:0] mawv,mawr,mwv,mwr,mbv,mbr,marv,marr,mrv,mrr;
    wire [5:0] mbp,mrp;
    axi_crossbar_hdmi dut (
        .aclk(clk),.aresetn(rst_n),
        .s_axi_awaddr(awaddr),.s_axi_awprot(3'b0),.s_axi_awvalid(awvalid),.s_axi_awready(awready),
        .s_axi_wdata(wdata),.s_axi_wstrb(4'hf),.s_axi_wvalid(wvalid),.s_axi_wready(wready),
        .s_axi_bresp(bresp),.s_axi_bvalid(bvalid),.s_axi_bready(bready),
        .s_axi_araddr(araddr),.s_axi_arprot(3'b0),.s_axi_arvalid(arvalid),.s_axi_arready(arready),
        .s_axi_rdata(rdata),.s_axi_rresp(rresp),.s_axi_rvalid(rvalid),.s_axi_rready(rready),
        .m_axi_awaddr(mawa),.m_axi_awprot(),.m_axi_awvalid(mawv),.m_axi_awready(mawr),
        .m_axi_wdata(mwd),.m_axi_wstrb(mws),.m_axi_wvalid(mwv),.m_axi_wready(mwr),
        .m_axi_bresp(mbp),.m_axi_bvalid(mbv),.m_axi_bready(mbr),
        .m_axi_araddr(mara),.m_axi_arprot(),.m_axi_arvalid(marv),.m_axi_arready(marr),
        .m_axi_rdata(mrd),.m_axi_rresp(mrp),.m_axi_rvalid(mrv),.m_axi_rready(mrr));
    for (genvar i=0;i<3;i=i+1) begin: banks
        qpcie_debug_mailbox bank (
            .clk(clk),.rst_n(rst_n),
            .s_axi_awaddr(mawa[i*32+:13]),.s_axi_awvalid(mawv[i]),.s_axi_awready(mawr[i]),
            .s_axi_wdata(mwd[i*32+:32]),.s_axi_wstrb(mws[i*4+:4]),.s_axi_wvalid(mwv[i]),.s_axi_wready(mwr[i]),
            .s_axi_bresp(mbp[i*2+:2]),.s_axi_bvalid(mbv[i]),.s_axi_bready(mbr[i]),
            .s_axi_araddr(mara[i*32+:13]),.s_axi_arvalid(marv[i]),.s_axi_arready(marr[i]),
            .s_axi_rdata(mrd[i*32+:32]),.s_axi_rresp(mrp[i*2+:2]),.s_axi_rvalid(mrv[i]),.s_axi_rready(mrr[i]));
    end
    task wr(input [31:0] addr,input [31:0] value,input [1:0] resp);
        @(negedge clk); awaddr=addr; awvalid=1;
        do @(posedge clk); while (!awready);
        @(negedge clk); awvalid=0;
        repeat(3) @(negedge clk);
        wdata=value; wvalid=1;
        do @(posedge clk); while (!wready);
        @(negedge clk); wvalid=0;
        wait(bvalid);
        repeat(3) begin
            @(negedge clk);
            if (!bvalid || bresp!==resp) $fatal(1,"write %h response %h",addr,bresp);
        end
        bready=1; @(negedge clk); bready=0;
    endtask
    task rd(input [31:0] addr,input [31:0] value,input [1:0] resp);
        @(negedge clk); araddr=addr; arvalid=1;
        do @(posedge clk); while (!arready);
        @(negedge clk); arvalid=0;
        wait(rvalid);
        repeat(3) begin
            @(negedge clk);
            if (!rvalid || rresp!==resp || (resp==0 && rdata!==value))
                $fatal(1,"read %h got=%h resp=%h",addr,rdata,rresp);
        end
        rready=1; @(negedge clk); rready=0;
    endtask
    initial begin #200000; $fatal(1,"control route timeout"); end
    initial begin
        repeat(8) @(negedge clk); rst_n=1;
        wr(32'hb0000080,32'h1111,0);
        wr(32'hb0010080,32'h2222,0);
        wr(32'hb0020080,32'h3333,0);
        rd(32'hb0000080,32'h1111,0);
        rd(32'hb0010080,32'h2222,0);
        rd(32'hb0020080,32'h3333,0);
        // End of the TX 128 KiB aperture must still select bank2.
        wr(32'hb003fffc,32'h44aa55ff,0);
        rd(32'hb003fffc,32'h44aa55ff,0);
        // Holes must complete with DECERR, not hang the PS.
        rd(32'hb0001000,0,3);
        wr(32'hb0040000,0,3);
        rd(32'hb0040000,0,3);
        $display("TB_PASS: HDMI three-bank routing, split AW/W, response stalls, TX upper range and DECERR holes");
        test_passed=1;
        $finish;
    end
endmodule
