`timescale 1ns / 1ps

// Focused regression of the real AXI4->AXI4-Lite converter used between
// ZU4EV PS HPM0 and the shared BAR0 crossbar. The old direct connection
// returned RID=0 for ARID=0x002D, which wedged Linux despite valid RDATA.
module zu4ev_ps_axi_protocol_tb;
    reg clk = 0;
    always #5 clk = ~clk;
    reg resetn = 0;

    reg [15:0] awid = 0, arid = 0;
    reg [31:0] awaddr = 0, araddr = 0, wdata = 0;
    reg [3:0] wstrb = 4'hf;
    reg awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
    wire awready, wready, bvalid, arready, rvalid, rlast;
    wire [15:0] bid, rid;
    wire [1:0] bresp, rresp;
    wire [31:0] rdata;

    wire [31:0] lite_awaddr, lite_wdata, lite_araddr, lite_rdata;
    wire [3:0] lite_wstrb;
    wire [1:0] lite_bresp, lite_rresp;
    wire lite_awvalid, lite_awready, lite_wvalid, lite_wready;
    wire lite_bvalid, lite_bready, lite_arvalid, lite_arready;
    wire lite_rvalid, lite_rready;

    axi_protocol_converter_0 dut (
        .aclk(clk), .aresetn(resetn),
        .s_axi_awid(awid), .s_axi_awaddr(awaddr), .s_axi_awlen(8'd0),
        .s_axi_awsize(3'd2), .s_axi_awburst(2'b01), .s_axi_awlock(1'b0),
        .s_axi_awcache(4'd0), .s_axi_awprot(3'd0), .s_axi_awregion(4'd0),
        .s_axi_awqos(4'd0), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wlast(1'b1),
        .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bid(bid), .s_axi_bresp(bresp), .s_axi_bvalid(bvalid),
        .s_axi_bready(bready),
        .s_axi_arid(arid), .s_axi_araddr(araddr), .s_axi_arlen(8'd0),
        .s_axi_arsize(3'd2), .s_axi_arburst(2'b01), .s_axi_arlock(1'b0),
        .s_axi_arcache(4'd0), .s_axi_arprot(3'd0), .s_axi_arregion(4'd0),
        .s_axi_arqos(4'd0), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rid(rid), .s_axi_rdata(rdata), .s_axi_rresp(rresp),
        .s_axi_rlast(rlast), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .m_axi_awaddr(lite_awaddr), .m_axi_awprot(),
        .m_axi_awvalid(lite_awvalid), .m_axi_awready(lite_awready),
        .m_axi_wdata(lite_wdata), .m_axi_wstrb(lite_wstrb),
        .m_axi_wvalid(lite_wvalid), .m_axi_wready(lite_wready),
        .m_axi_bresp(lite_bresp), .m_axi_bvalid(lite_bvalid),
        .m_axi_bready(lite_bready),
        .m_axi_araddr(lite_araddr), .m_axi_arprot(),
        .m_axi_arvalid(lite_arvalid), .m_axi_arready(lite_arready),
        .m_axi_rdata(lite_rdata), .m_axi_rresp(lite_rresp),
        .m_axi_rvalid(lite_rvalid), .m_axi_rready(lite_rready)
    );

    // Single-outstanding AXI4-Lite register model: magic, version, scratch.
    reg aw_seen = 0, w_seen = 0;
    reg [31:0] pending_awaddr = 0, pending_wdata = 0, scratch = 0;
    reg lite_bvalid_q = 0, lite_rvalid_q = 0;
    reg [31:0] lite_rdata_q = 0;
    assign lite_awready = !aw_seen && !lite_bvalid_q;
    assign lite_wready = !w_seen && !lite_bvalid_q;
    assign lite_bvalid = lite_bvalid_q;
    assign lite_bresp = 2'b00;
    assign lite_arready = !lite_rvalid_q;
    assign lite_rvalid = lite_rvalid_q;
    assign lite_rdata = lite_rdata_q;
    assign lite_rresp = 2'b00;

    always @(posedge clk) begin
        if (!resetn) begin
            aw_seen <= 0;
            w_seen <= 0;
            lite_bvalid_q <= 0;
            lite_rvalid_q <= 0;
            scratch <= 0;
        end else begin
            if (lite_awvalid && lite_awready) begin
                pending_awaddr <= lite_awaddr;
                aw_seen <= 1;
            end
            if (lite_wvalid && lite_wready) begin
                pending_wdata <= lite_wdata;
                w_seen <= 1;
            end
            if (aw_seen && w_seen && !lite_bvalid_q) begin
                if (pending_awaddr == 32'hA0000008)
                    scratch <= pending_wdata;
                aw_seen <= 0;
                w_seen <= 0;
                lite_bvalid_q <= 1;
            end
            if (lite_bvalid_q && lite_bready)
                lite_bvalid_q <= 0;

            if (lite_arvalid && lite_arready) begin
                case (lite_araddr)
                    32'hA0000000: lite_rdata_q <= 32'h12ABE380;
                    32'hA0000004: lite_rdata_q <= 32'h26101203;
                    32'hA0000008: lite_rdata_q <= scratch;
                    default:       lite_rdata_q <= 32'hDEADDEAD;
                endcase
                lite_rvalid_q <= 1;
            end
            if (lite_rvalid_q && lite_rready)
                lite_rvalid_q <= 0;
        end
    end

    task automatic read_word(input [15:0] request_id,
                             input [31:0] address, input [31:0] expected);
        integer cycles;
        begin
            @(negedge clk);
            arid = request_id;
            araddr = address;
            arvalid = 1;
            rready = 1;
            for (cycles = 0; cycles < 200; cycles = cycles + 1) begin
                @(posedge clk);
                if (arready) break;
            end
            if (cycles == 200) $fatal(1, "AR timeout for %h", address);
            @(negedge clk);
            arvalid = 0;
            for (cycles = 0; cycles < 200; cycles = cycles + 1) begin
                @(posedge clk);
                if (rvalid) begin
                    if (rid !== request_id || rdata !== expected ||
                        rresp !== 2'b00 || rlast !== 1'b1)
                        $fatal(1, "READ mismatch: ARID=%h RID=%h RDATA=%h expected=%h RRESP=%b RLAST=%b",
                               request_id, rid, rdata, expected, rresp, rlast);
                    break;
                end
            end
            if (cycles == 200) $fatal(1, "R timeout for %h", address);
            @(negedge clk);
            rready = 0;
        end
    endtask

    task automatic write_word(input [15:0] request_id,
                              input [31:0] address, input [31:0] value);
        bit address_sent, data_sent;
        integer cycles;
        begin
            address_sent = 0;
            data_sent = 0;
            @(negedge clk);
            awid = request_id;
            awaddr = address;
            wdata = value;
            awvalid = 1;
            wvalid = 1;
            bready = 1;
            for (cycles = 0; cycles < 200 && !(address_sent && data_sent); cycles = cycles + 1) begin
                @(posedge clk);
                if (awvalid && awready) address_sent = 1;
                if (wvalid && wready) data_sent = 1;
                @(negedge clk);
                if (address_sent) awvalid = 0;
                if (data_sent) wvalid = 0;
            end
            if (!(address_sent && data_sent)) $fatal(1, "AW/W timeout");
            for (cycles = 0; cycles < 200; cycles = cycles + 1) begin
                @(posedge clk);
                if (bvalid) begin
                    if (bid !== request_id || bresp !== 2'b00)
                        $fatal(1, "WRITE mismatch: AWID=%h BID=%h BRESP=%b", request_id, bid, bresp);
                    break;
                end
            end
            if (cycles == 200) $fatal(1, "B timeout");
            @(negedge clk);
            bready = 0;
        end
    endtask

    initial begin
        repeat (12) @(negedge clk);
        resetn = 1;
        read_word(16'h002D, 32'hA0000000, 32'h12ABE380);
        read_word(16'h0031, 32'hA0000004, 32'h26101203);
        write_word(16'h0037, 32'hA0000008, 32'h11223344);
        read_word(16'h0042, 32'hA0000008, 32'h11223344);
        $display("TB_PASS: AXI4 nonzero ARID/RID, AWID/BID, RLAST and BAR0 read/write");
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "Global simulation watchdog timeout");
    end
endmodule
