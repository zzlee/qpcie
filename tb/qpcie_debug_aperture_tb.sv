`timescale 1ns/1ps
// Real production Xilinx 2x3 crossbar, two masters, three isolated targets.
// CSR/environment targets are mailbox-shaped test slaves only; this tests
// routing/arbitration, not their register semantics or the PS hard block.
module qpcie_debug_aperture_tb;
    reg clk=0; always #5 clk=~clk;
    reg resetn=0;
    reg [63:0] awaddr=0,araddr=0,wdata=0;
    reg [1:0] awvalid=0,wvalid=0,bready=0,arvalid=0,rready=0;
    wire [1:0] awready,wready,bvalid,arready,rvalid;
    wire [3:0] bresp,rresp;
    wire [63:0] rdata;
    wire [95:0] ma,md,mra,mrd;
    wire [11:0] ms;
    wire [2:0] mav,mar,mwv,mwr,mbv,mbr,mrav,mrar,mrv,mrr;
    wire [5:0] mbresp,mrresp;
    axi_crossbar_1 crossbar (
        .aclk(clk), .aresetn(resetn),
        .s_axi_awaddr(awaddr), .s_axi_awprot(6'b0),
        .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(8'hff),
        .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arprot(6'b0),
        .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp),
        .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .m_axi_awaddr(ma), .m_axi_awprot(),
        .m_axi_awvalid(mav), .m_axi_awready(mar),
        .m_axi_wdata(md), .m_axi_wstrb(ms),
        .m_axi_wvalid(mwv), .m_axi_wready(mwr),
        .m_axi_bresp(mbresp), .m_axi_bvalid(mbv), .m_axi_bready(mbr),
        .m_axi_araddr(mra), .m_axi_arprot(),
        .m_axi_arvalid(mrav), .m_axi_arready(mrar),
        .m_axi_rdata(mrd), .m_axi_rresp(mrresp),
        .m_axi_rvalid(mrv), .m_axi_rready(mrr)
    );
    for (genvar n=0;n<3;n=n+1) begin: targets
        wire [12:0] wa = n==2 ? ma[n*32+:13] : {1'b0,ma[n*32+:12]};
        wire [12:0] ra = n==2 ? mra[n*32+:13] : {1'b0,mra[n*32+:12]};
        qpcie_debug_mailbox target (
            .clk(clk),.rst_n(resetn),
            .s_axi_awaddr(wa),.s_axi_awvalid(mav[n]),.s_axi_awready(mar[n]),
            .s_axi_wdata(md[n*32+:32]),.s_axi_wstrb(ms[n*4+:4]),
            .s_axi_wvalid(mwv[n]),.s_axi_wready(mwr[n]),
            .s_axi_bresp(mbresp[n*2+:2]),.s_axi_bvalid(mbv[n]),.s_axi_bready(mbr[n]),
            .s_axi_araddr(ra),.s_axi_arvalid(mrav[n]),.s_axi_arready(mrar[n]),
            .s_axi_rdata(mrd[n*32+:32]),.s_axi_rresp(mrresp[n*2+:2]),
            .s_axi_rvalid(mrv[n]),.s_axi_rready(mrr[n])
        );
    end
    task automatic put(input integer s,input [31:0] address,input [31:0] data);
        begin
            @(negedge clk); awaddr[s*32+:32]=address & 32'h000fffff;
            wdata[s*32+:32]=data; awvalid[s]=1;
            do @(posedge clk); while(!awready[s]);
            @(negedge clk); awvalid[s]=0; repeat(2) @(negedge clk);
            wvalid[s]=1;
            do @(posedge clk); while(!wready[s]);
            @(negedge clk); wvalid[s]=0;
            wait(bvalid[s]);
            if(bresp[s*2+:2]!==0) $fatal(1,"write decode error %x",address);
            repeat(3) @(negedge clk);
            bready[s]=1; @(negedge clk); bready[s]=0;
        end
    endtask
    task automatic get(input integer s,input [31:0] address,input [31:0] expected,input [1:0] resp);
        begin
            @(negedge clk); araddr[s*32+:32]=address & 32'h000fffff; arvalid[s]=1;
            do @(posedge clk); while(!arready[s]);
            @(negedge clk); arvalid[s]=0;
            wait(rvalid[s]); repeat(3) begin
                @(negedge clk);
                if(!rvalid[s] || rresp[s*2+:2]!==resp ||
                   (resp==0 && rdata[s*32+:32]!==expected))
                    $fatal(1,"read %x expected %x got %x resp %x",address,expected,rdata[s*32+:32],rresp[s*2+:2]);
            end
            rready[s]=1; @(negedge clk); rready[s]=0;
        end
    endtask
    initial begin #1000000; $fatal(1,"timeout"); end
    initial begin
        repeat(20) @(negedge clk); resetn=1; repeat(20) @(negedge clk);
        put(0,32'h0008,32'haaaa0000);
        put(0,32'h1008,32'hbbbb0001);
        put(1,32'ha0002008,32'hcccc0002);
        get(0,32'h0008,32'haaaa0000,0);
        get(1,32'ha0001008,32'hbbbb0001,0);
        get(0,32'h2008,32'hcccc0002,0);
        // Both requesters hit the same BRAM concurrently, split AW/W.
        fork
            put(0,32'h2400,32'h12345678);
            put(1,32'ha0003ffc,32'h87654321);
        join
        fork
            get(1,32'ha0002400,32'h12345678,0);
            get(0,32'h3ffc,32'h87654321,0);
        join
        get(0,32'h4000,0,3); // unmapped DECERR, never silent
        get(1,32'ha0000008,32'haaaa0000,0); // no debug/CSR alias
        $display("TB_PASS: production debug crossbar routing, concurrent host/PS, no alias, DECERR");
        $finish;
    end
endmodule
