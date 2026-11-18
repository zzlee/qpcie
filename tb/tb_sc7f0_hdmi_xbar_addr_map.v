`timescale 1ns/1ps
`ifndef SC7F0_XBAR_DBG
  `define SC7F0_XBAR_DBG 0
`endif
// -----------------------------------------------------------------------------
// SC7F0 HDMI AXI-Lite address-map probe (G8 root-cause / regression)
//
// Two tops, one probe core:
//   tb_hdmi_xbar_outer  -> axi_crossbar_hdmi            (our own IP, scripts/
//                         create_sc7f0_hdmi_crossbar.tcl, 1 SI x 10 MI, 32-bit
//                         slave address, 32-bit address field per master port)
//   tb_hdmi_xbar_inner  -> bd_d638_axi_crossbar_0       (the crossbar INSIDE
//                         v_hdmi_tx_ss_rgb: 17-bit slave address, M00 = TX core
//                         @0x00000+64K, M01 = v_tc (VTC) @0x10000+64K)
//
// Both are simulated from the *deployed post-synthesis netlists*, so what is
// measured here is the hardware that is on the board, not an intention.
//
// For every probe address the report prints:
//   * which master port the crossbar selected (none = crossbar DECERR)
//   * the full address field driven on that port (aliasing / bit loss shows up
//     here: a bit that never reaches the slave is a bit the slave cannot decode)
//   * the slave-side rresp as seen by the master (DECERR = nothing answered)
//
// The address list is the exact set measured on the card in
// build/g6g8-20261116T110140Z/{25,28..33}: the TX SS window 0xB0020000.. and the
// VTC window 0xB0030000.. that answered SIGBUS.
// -----------------------------------------------------------------------------

// The two DUTs differ in port widths, so each top instantiates its own DUT and
// carries a copy of the same probe logic (drive one AXI-Lite read, watch which
// master port answers and with which address).
module tb_hdmi_xbar_outer;
    // 26111602 (G8): scripts/create_sc7f0_hdmi_crossbar.tcl now builds the RGB
    // crossbar with ELEVEN masters, because the HDMI TX subsystem is decoded as
    // two 64 KiB slices (M02 = 0xB0020000, M10 = 0xB0030000) instead of one 128 KiB
    // slice.  The deployed netlist proves it: axi_crossbar_hdmi_stub.v declares
    // m_axi_araddr[351:0] and m_axi_awvalid[10:0].  With NS still at 10 this probe
    // silently truncated every m_axi_* vector to 320 bits, connected no responder
    // to port 10, and printed 0xB0030000 as "none" - which reads exactly like the
    // DECERR it is not.  NS is now read off the hardware, not remembered.
    localparam integer NS    = 11;
    localparam integer DBG_ON = `SC7F0_XBAR_DBG;
    localparam integer FAW   = 32;   // 352-bit m_axi_*addr vector / 11 ports

    reg  clk = 0, rstn = 0;
    always #5 clk = ~clk;

    reg  [31:0] s_awaddr = 0, s_araddr = 0, s_wdata = 0;
    reg         s_awvalid = 0, s_arvalid = 0, s_wvalid = 0, s_bready = 0, s_rready = 0;
    wire        s_awready, s_arready, s_wready, s_bvalid, s_rvalid;
    wire [1:0]  s_bresp, s_rresp;

    wire [NS*FAW-1:0] m_awaddr, m_araddr, m_wdata, m_rdata;
    wire [NS-1:0]     m_awvalid, m_awready, m_wvalid, m_wready, m_bvalid,
                      m_bready, m_arvalid, m_arready, m_rvalid, m_rready;
    wire [NS*4-1:0]   m_wstrb;
    wire [NS*3-1:0]   m_awprot, m_arprot;
    wire [NS*2-1:0]   m_bresp, m_rresp;

    axi_crossbar_hdmi dut (
        .aclk(clk), .aresetn(rstn),
        .s_axi_awaddr(s_awaddr), .s_axi_awprot(3'd0),
        .s_axi_awvalid(s_awvalid), .s_axi_awready(s_awready),
        .s_axi_wdata(s_wdata), .s_axi_wstrb(4'hf),
        .s_axi_wvalid(s_wvalid), .s_axi_wready(s_wready),
        .s_axi_bresp(s_bresp), .s_axi_bvalid(s_bvalid), .s_axi_bready(s_bready),
        .s_axi_araddr(s_araddr), .s_axi_arprot(3'd0),
        .s_axi_arvalid(s_arvalid), .s_axi_arready(s_arready),
        .s_axi_rdata(s_rdata), .s_axi_rresp(s_rresp),
        .s_axi_rvalid(s_rvalid), .s_axi_rready(s_rready),
        .m_axi_awaddr(m_awaddr), .m_axi_awprot(m_awprot),
        .m_axi_awvalid(m_awvalid), .m_axi_awready(m_awready),
        .m_axi_wdata(m_wdata), .m_axi_wstrb(m_wstrb),
        .m_axi_wvalid(m_wvalid), .m_axi_wready(m_wready),
        .m_axi_bresp(m_bresp), .m_axi_bvalid(m_bvalid), .m_axi_bready(m_bready),
        .m_axi_araddr(m_araddr), .m_axi_arprot(m_arprot),
        .m_axi_arvalid(m_arvalid), .m_axi_arready(m_arready),
        .m_axi_rdata(m_rdata), .m_axi_rresp(m_rresp),
        .m_axi_rvalid(m_rvalid), .m_axi_rready(m_rready)
    );

    // ---------------- slaves: always ready, answer one cycle later ----------
    genvar g;
    generate for (g = 0; g < NS; g = g + 1) begin : SLV
        reg rv = 0;
        reg [31:0] rd = 0;
        assign m_awready[g] = 1'b1;
        assign m_wready[g]  = 1'b1;
        assign m_arready[g] = 1'b1;
        assign m_rvalid[g]  = rv;
        assign m_rdata[g*32 +: 32] = rd;
        assign m_rresp[g*2 +: 2]   = 2'b00;
        assign m_bresp[g*2 +: 2]   = 2'b00;
        assign m_bvalid[g]         = rv;
        always @(posedge clk) begin
            rv <= (m_arvalid[g] & m_arready[g]) | (m_awvalid[g] & m_awready[g]
                 & m_wvalid[g] & m_wready[g]);
            rd <= 32'hA500_0000 | g;
        end
    end endgenerate

    // ---------------- capture what the crossbar actually drives -------------
    integer hit_port;  reg [31:0] hit_addr;  integer aw_port;  reg [31:0] aw_addr;
    integer i;
    always @(posedge clk) begin
        for (i = 0; i < NS; i = i + 1) begin
            if (m_arvalid[i] && m_arready[i]) begin
                hit_port = i;
                hit_addr = m_araddr[i*FAW +: 32];
            end
            if (m_awvalid[i] && m_awready[i]) begin
                aw_port = i;
                aw_addr = m_awaddr[i*FAW +: 32];
            end
        end
    end

    localparam integer NPROBE = 16;
    reg [31:0] probe [0:NPROBE-1];
    integer port_of [0:NPROBE-1];
    reg [31:0] addr_of [0:NPROBE-1];
    reg [1:0]  resp_of [0:NPROBE-1];
    integer errors;
    integer k, tries;  reg [1:0] resp;
    reg [8*7:1] rstr, pstr;

    function [8*7:1] portname(input integer p);
        case (p)
          0: portname = "M00"; 1: portname = "M01"; 2: portname = "M02";
          3: portname = "M03"; 4: portname = "M04"; 5: portname = "M05";
          6: portname = "M06"; 7: portname = "M07"; 8: portname = "M08";
          9: portname = "M09"; 10: portname = "M10";
          default: portname = "Mxx";
        endcase
    endfunction

    always @(posedge clk)
        if (DBG_ON)
            $display("t=%0t rstn=%b arvalid=%b arready=%b rvalid=%b rresp=%b m_arvalid=%b s_araddr=%08x",
                     $time, rstn, s_arvalid, s_arready, s_rvalid, s_rresp, m_arvalid, s_araddr);

    initial begin
        $display("=========================================================");
        $display(" tb_hdmi_xbar_outer : axi_crossbar_hdmi (deployed netlist)");
        $display("  slices (read out of this round's axi_crossbar_hdmi.xci):");
        $display("   M00 0xB0000000/4K   M01 0xB0010000/64K  M02 0xB0020000/64K");
        $display("   M03 0xB0040000/4K   M04 0xB0050000/4K   M05 0xB0060000/64K");
        $display("   M06 0xB0070000/4K   M07 0xB0080000/64K  M08 0xB0090000/4K");
        $display("   M09 0xB00A0000/4K   M10 0xB0030000/64K  (G8: TX SS upper half)");
        $display("=========================================================");
        probe[0]=32'hB000_0040; probe[1]=32'hB001_0040; probe[2]=32'hB001_FFF0;
        probe[3]=32'hB001_FFFC; probe[4]=32'hB002_0000; probe[5]=32'hB002_0040;
        probe[6]=32'hB002_0100; probe[7]=32'hB002_FFF0; probe[8]=32'hB002_FFFC;
        probe[9]=32'hB003_0000; probe[10]=32'hB003_0004; probe[11]=32'hB003_0100;
        probe[12]=32'hB003_01FC; probe[13]=32'hB003_FFFC; probe[14]=32'hB004_0000;
        probe[15]=32'hB00B_0000;
        repeat (10) @(posedge clk);
        rstn = 1;
        repeat (5) @(posedge clk);
        $display("  addr        | rresp | M-port | addr driven on that port");
        $display("--------------+-------+--------+-------------------------");
        for (k = 0; k < NPROBE; k = k + 1) begin
            hit_port = -1; hit_addr = 32'hx; resp = 2'b00;            @(posedge clk);
            s_araddr <= probe[k]; s_arvalid <= 1'b1; s_rready <= 1'b1;
            @(posedge clk);
            if (s_arready) s_arvalid <= 1'b0;
            else begin
                tries = 0;
                while (!s_arready && tries < 50) begin @(posedge clk); tries = tries+1; end
                s_arvalid <= 1'b0;
            end
            tries = 0;
            while (!s_rvalid && tries < 50) begin @(posedge clk); tries = tries+1; end
            resp = s_rresp;
            @(posedge clk); @(posedge clk);
            s_rready <= 1'b0;
            case (resp)
              2'b00: rstr = "OKAY  ";
              2'b11: rstr = "DECERR";
              2'b10: rstr = "SLVERR";
              2'b01: rstr = "EXOKAY";
              default: rstr = "XXXXXX";
            endcase
            if (hit_port < 0) pstr = "none"; else pstr = portname(hit_port);
            port_of[k] = hit_port; addr_of[k] = hit_addr; resp_of[k] = resp;
            $display("  %08x | %s | %s | %08x", probe[k], rstr, pstr, hit_addr);
        end
        // one write probe to show the write path decode is the same
        hit_port = -1; aw_port = -1; aw_addr = 32'hx;
        @(posedge clk);
        s_awaddr <= 32'hB003_0004; s_awvalid <= 1'b1;
        s_wdata  <= 32'h0000_1234; s_wvalid  <= 1'b1; s_bready <= 1'b1;
        @(posedge clk); s_awvalid <= 1'b0; s_wvalid <= 1'b0;
        tries = 0;
        while (!s_bvalid && tries < 50) begin @(posedge clk); tries = tries+1; end
        @(posedge clk); s_bready <= 1'b0;
        // aw_port, not hit_port: hit_port is the READ monitor. Printing hit_port
        // here reported the last read's port and made the write probe say nothing
        // about the write path - which is the one path 26111601 actually broke.
        if (aw_port < 0) pstr = "none"; else pstr = portname(aw_port);
        $display("  write 0xB0030004 -> %s addr=%08x bresp=%0b",
            pstr, aw_addr, s_bresp);
        $display("=========================================================");
        // The verdict, not just a table for a human to squint at.  Every row here
        // is a claim about the G8 fix; a row that silently regresses must stop the
        // round rather than get re-read next week.
        errors = 0;
        if (port_of[4]  == 2  && addr_of[4]  == 32'hB002_0000) $display("  PASS  0xB0020000 -> M02 (TX SS lower slice)");
        else begin $display("  FAIL  0xB0020000 -> %s %08x, expected M02 b0020000", portname(port_of[4]), addr_of[4]); errors = errors + 1; end
        if (port_of[8]  == 2  && addr_of[8]  == 32'hB002_FFFC) $display("  PASS  0xB002FFFC -> M02, so the lower slice really ends at +0xFFFF");
        else begin $display("  FAIL  0xB002FFFC -> %s %08x, expected M02 b002fffc (a 128 KiB M02 would still answer here)", portname(port_of[8]), addr_of[8]); errors = errors + 1; end
        if (port_of[9]  == 10 && addr_of[9]  == 32'hB003_0000 && resp_of[9] == 2'b00)
            $display("  PASS  0xB0030000 -> M10 with the full address and OKAY (26111601: DECERR)");
        else begin $display("  FAIL  0xB0030000 -> %s %08x resp=%0b, expected M10 b0030000 OKAY", portname(port_of[9]), addr_of[9], resp_of[9]); errors = errors + 1; end
        if (port_of[11] == 10 && addr_of[11] == 32'hB003_0100) $display("  PASS  0xB0030100 -> M10 unchanged (no 2 KiB/4 KiB alias in the upper half)");
        else begin $display("  FAIL  0xB0030100 -> %s %08x, expected M10 b0030100", portname(port_of[11]), addr_of[11]); errors = errors + 1; end
        if (port_of[13] == 10 && addr_of[13] == 32'hB003_FFFC) $display("  PASS  0xB003FFFC -> M10, so the upper slice really spans 64 KiB");
        else begin $display("  FAIL  0xB003FFFC -> %s %08x, expected M10 b003fffc", portname(port_of[13]), addr_of[13]); errors = errors + 1; end
        if (port_of[14] == 3  && addr_of[14] == 32'hB004_0000) $display("  PASS  0xB0040000 -> M03 (the slices did not shift the other windows)");
        else begin $display("  FAIL  0xB0040000 -> %s %08x, expected M03 b0040000", portname(port_of[14]), addr_of[14]); errors = errors + 1; end
        if (aw_port     == 10 && aw_addr     == 32'hB003_0004)
            $display("  PASS  a write to 0xB0030004 selects M10 and keeps the address (the 26111601 defect was exactly here)");
        else begin $display("  FAIL  write 0xB0030004 -> %s %08x, expected M10 b0030004", portname(aw_port), aw_addr); errors = errors + 1; end
        if (port_of[15] < 0)  $display("  PASS  0xB00B0000 still decodes to nothing (no window widening)");
        else begin $display("  FAIL  0xB00B0000 unexpectedly decoded to %s", portname(port_of[15])); errors = errors + 1; end
        if (errors == 0) $display("SC7F0_XBAR_MAP_OUTER_PASS slices=11 upper=0xB0030000->M10 rw+full-address ok");
        else             $display("SC7F0_XBAR_MAP_OUTER_FAIL errors=%0d", errors);
        $finish;
    end

    initial begin
        #200_000;
        $display("TIMEOUT waiting for crossbar responses");
        $finish;
    end
endmodule

module tb_hdmi_xbar_inner;
    localparam integer NS  = 2;
    localparam integer FAW = 17;   // 34-bit m_axi_*addr vector / 2 ports

    reg  clk = 0, rstn = 0;
    always #5 clk = ~clk;

    reg  [16:0] s_awaddr = 0, s_araddr = 0;
    reg  [31:0] s_wdata = 0;
    reg         s_awvalid = 0, s_arvalid = 0, s_wvalid = 0, s_bready = 0, s_rready = 0;
    wire        s_awready, s_arready, s_wready, s_bvalid, s_rvalid;
    wire [1:0]  s_bresp, s_rresp;
    wire [31:0] s_rdata;

    wire [33:0] m_awaddr, m_araddr, m_wdata, m_rdata;
    wire [1:0]  m_awvalid, m_awready, m_wvalid, m_wready, m_bvalid,
                m_bready, m_arvalid, m_arready, m_rvalid, m_rready;
    wire [7:0]  m_wstrb;
    wire [5:0]  m_awprot, m_arprot;
    wire [3:0]  m_bresp, m_rresp;

    // inside v_hdmi_tx_ss_rgb: M00 = v_hdmi_tx core (9 address pins),
    //                          M01 = v_tc ctrl   (9 address pins)
    bd_d638_axi_crossbar_0 dut (
        .aclk(clk), .aresetn(rstn),
        .s_axi_awaddr(s_awaddr), .s_axi_awprot(3'd0),
        .s_axi_awvalid(s_awvalid), .s_axi_awready(s_awready),
        .s_axi_wdata(s_wdata), .s_axi_wstrb(4'hf),
        .s_axi_wvalid(s_wvalid), .s_axi_wready(s_wready),
        .s_axi_bresp(s_bresp), .s_axi_bvalid(s_bvalid), .s_axi_bready(s_bready),
        .s_axi_araddr(s_araddr), .s_axi_arprot(3'd0),
        .s_axi_arvalid(s_arvalid), .s_axi_arready(s_arready),
        .s_axi_rdata(s_rdata), .s_axi_rresp(s_rresp),
        .s_axi_rvalid(s_rvalid), .s_axi_rready(s_rready),
        .m_axi_awaddr(m_awaddr), .m_axi_awprot(m_awprot),
        .m_axi_awvalid(m_awvalid), .m_axi_awready(m_awready),
        .m_axi_wdata(m_wdata), .m_axi_wstrb(m_wstrb),
        .m_axi_wvalid(m_wvalid), .m_axi_wready(m_wready),
        .m_axi_bresp(m_bresp), .m_axi_bvalid(m_bvalid), .m_axi_bready(m_bready),
        .m_axi_araddr(m_araddr), .m_axi_arprot(m_arprot),
        .m_axi_arvalid(m_arvalid), .m_axi_arready(m_arready),
        .m_axi_rdata(m_rdata), .m_axi_rresp(m_rresp),
        .m_axi_rvalid(m_rvalid), .m_axi_rready(m_rready)
    );

    genvar g;
    generate for (g = 0; g < NS; g = g + 1) begin : SLV
        reg rv = 0;
        assign m_awready[g] = 1'b1;
        assign m_wready[g]  = 1'b1;
        assign m_arready[g] = 1'b1;
        assign m_rvalid[g]  = rv;
        assign m_rdata[g*32 +: 32] = 32'hA500_0000 | g;
        assign m_rresp[g*2 +: 2]   = 2'b00;
        assign m_bresp[g*2 +: 2]   = 2'b00;
        assign m_bvalid[g]         = rv;
        always @(posedge clk) rv <= (m_arvalid[g] & m_arready[g])
                                  | (m_awvalid[g] & m_awready[g] & m_wvalid[g] & m_wready[g]);
    end endgenerate

    integer hit_port;  reg [32:0] hit_addr;  integer i;
    always @(posedge clk)
        for (i = 0; i < NS; i = i + 1)
            if (m_arvalid[i] && m_arready[i]) begin
                hit_port = i;  hit_addr = m_araddr[i*FAW +: 17];
            end

    localparam integer NPROBE = 10;
    reg [16:0] probe [0:NPROBE-1];
    integer k, tries;  reg [1:0] resp;
    reg [8*7:1] rstr, pstr;

    function [8*7:1] portname(input integer p);
        portname = (p == 0) ? "M00" : "M01";
    endfunction

    initial begin
        $display("=================================================================");
        $display(" tb_hdmi_xbar_inner : bd_d638_axi_crossbar_0 (inside v_hdmi_tx_ss)");
        $display("   SI address width 17 (128 KiB address space)");
        $display("   M00 = v_hdmi_tx reg0 @0x00000 +64K  (9 addr pins on the IP)");
        $display("   M01 = v_tc (VTC) ctrl @0x10000 +64K (9 addr pins on the IP)");
        $display("=================================================================");
        probe[0]=17'h00000; probe[1]=17'h00040; probe[2]=17'h00100;
        probe[3]=17'h01000; probe[4]=17'h0FFFC; probe[5]=17'h0FFFF;
        probe[6]=17'h10000; probe[7]=17'h10004; probe[8]=17'h10150;
        probe[9]=17'h1FFFC;
        repeat (10) @(posedge clk);
        rstn = 1;
        repeat (5) @(posedge clk);
        $display("  addr     | rresp | M-port | addr driven on that port");
        $display("-----------+-------+--------+-------------------------");
        for (k = 0; k < NPROBE; k = k + 1) begin
            hit_port = -1; hit_addr = 18'hx; resp = 2'b00;
            @(posedge clk);
            s_araddr <= probe[k]; s_arvalid <= 1'b1; s_rready <= 1'b1;
            @(posedge clk);
            if (s_arready) s_arvalid <= 1'b0;
            else begin
                tries = 0;
                while (!s_arready && tries < 50) begin @(posedge clk); tries=tries+1; end
                s_arvalid <= 1'b0;
            end
            tries = 0;
            while (!s_rvalid && tries < 50) begin @(posedge clk); tries=tries+1; end
            resp = s_rresp;
            @(posedge clk); @(posedge clk);
            s_rready <= 1'b0;
            case (resp)
              2'b00: rstr = "OKAY  ";
              2'b11: rstr = "DECERR";
              2'b10: rstr = "SLVERR";
              default: rstr = "XXXXXX";
            endcase
            if (hit_port < 0) pstr = "none"; else pstr = portname(hit_port);
            $display("  %05x | %s | %s | %05x", probe[k], rstr, pstr, hit_addr);
        end
        $display("=================================================================");
        $finish;
    end

    initial begin
        #200_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule

// ============================================================================
// tb_hdmi_txss_ctl_merge -- the 26111602 G8 fix, fabric half.
//
// The deployed 26111601 design published the HDMI TX subsystem as ONE 17-bit
// crossbar slice (0xB0020000 + 128 KiB) and on hardware every access with address
// bit 16 set returned DECERR, so the VTC at subsystem offset +0x10000 was
// unreachable (build/g6g8-20261116T110140Z/tx-ss-slice2-readprobe.txt).  The
// routed design also has no net at all for the write-channel bit 16 at the
// subsystem boundary, so a crossbar-carried bit 16 is exactly the thing that
// cannot be trusted here.
//
// 26111602 decodes two 64 KiB slices (0xB0020000 and 0xB0030000 -- the window
// class proven good on this card) and rtl/axil_arbiter_2to1.v re-merges them onto
// the subsystem's single control port, driving address bit 16 from the slice
// index.  This bench drives the merge exactly as the two crossbar slices would
// and checks what the subsystem-side 17-bit control port actually sees.
// ============================================================================
module tb_hdmi_txss_ctl_merge;
    reg clk = 0, rstn = 0;
    always #5 clk = ~clk;

    // ---- slice 2 (0xB0020000..0xB002FFFF): crossbar hands over addr[15:0] ----
    reg  [15:0] s0_addr = 0;
    reg  [31:0] s0_wdata = 0;
    reg         s0_awvalid = 0, s0_wvalid = 0, s0_bready = 1, s0_arvalid = 0, s0_rready = 1;
    wire        s0_awready, s0_wready, s0_bvalid, s0_arready, s0_rvalid;
    wire [31:0] s0_rdata;
    wire [1:0]  s0_bresp, s0_rresp;

    // ---- slice 10 (0xB0030000..0xB003FFFF) ----------------------------------
    reg  [15:0] s1_addr = 0;
    reg  [31:0] s1_wdata = 0;
    reg         s1_awvalid = 0, s1_wvalid = 0, s1_bready = 1, s1_arvalid = 0, s1_rready = 1;
    wire        s1_awready, s1_wready, s1_bvalid, s1_arready, s1_rvalid;
    wire [31:0] s1_rdata;
    wire [1:0]  s1_bresp, s1_rresp;

    // ---- subsystem side (v_hdmi_tx_ss S_AXI_CPU_IN, 17-bit address) ---------
    wire [16:0] m_awaddr, m_araddr;
    wire        m_awvalid, m_awready, m_wvalid, m_wready, m_bvalid, m_bready;
    wire        m_arvalid, m_arready, m_rvalid, m_rready;
    wire [31:0] m_wdata, m_rdata;
    wire [3:0]  m_wstrb;
    wire [1:0]  m_bresp, m_rresp;

    sc7f0_axil_merge_2to1 #(.ADDR_WIDTH(17), .DATA_WIDTH(32)) dut (
        .clk(clk), .rst_n(rstn),
        .s0_axil_awaddr({1'b0, s0_addr}), .s0_axil_awvalid(s0_awvalid),
        .s0_axil_awready(s0_awready), .s0_axil_wdata(s0_wdata), .s0_axil_wstrb(4'hf),
        .s0_axil_wvalid(s0_wvalid), .s0_axil_wready(s0_wready), .s0_axil_bresp(s0_bresp),
        .s0_axil_bvalid(s0_bvalid), .s0_axil_bready(s0_bready),
        .s0_axil_araddr({1'b0, s0_addr}), .s0_axil_arvalid(s0_arvalid),
        .s0_axil_arready(s0_arready), .s0_axil_rdata(s0_rdata), .s0_axil_rresp(s0_rresp),
        .s0_axil_rvalid(s0_rvalid), .s0_axil_rready(s0_rready),
        .s1_axil_awaddr({1'b1, s1_addr}), .s1_axil_awvalid(s1_awvalid),
        .s1_axil_awready(s1_awready), .s1_axil_wdata(s1_wdata), .s1_axil_wstrb(4'hf),
        .s1_axil_wvalid(s1_wvalid), .s1_axil_wready(s1_wready), .s1_axil_bresp(s1_bresp),
        .s1_axil_bvalid(s1_bvalid), .s1_axil_bready(s1_bready),
        .s1_axil_araddr({1'b1, s1_addr}), .s1_axil_arvalid(s1_arvalid),
        .s1_axil_arready(s1_arready), .s1_axil_rdata(s1_rdata), .s1_axil_rresp(s1_rresp),
        .s1_axil_rvalid(s1_rvalid), .s1_axil_rready(s1_rready),
        .m_axil_awaddr(m_awaddr), .m_axil_awvalid(m_awvalid), .m_axil_awready(m_awready),
        .m_axil_wdata(m_wdata), .m_axil_wstrb(m_wstrb), .m_axil_wvalid(m_wvalid),
        .m_axil_wready(m_wready), .m_axil_bresp(m_bresp), .m_axil_bvalid(m_bvalid),
        .m_axil_bready(m_bready), .m_axil_araddr(m_araddr), .m_axil_arvalid(m_arvalid),
        .m_axil_arready(m_arready), .m_axil_rdata(m_rdata), .m_axil_rresp(m_rresp),
        .m_axil_rvalid(m_rvalid), .m_axil_rready(m_rready)
    );

    txss_ctl_slave_17 txss (
        .aclk(clk), .aresetn(rstn),
        .awaddr(m_awaddr), .awvalid(m_awvalid), .awready(m_awready),
        .wdata(m_wdata), .wstrb(m_wstrb), .wvalid(m_wvalid), .wready(m_wready),
        .bvalid(m_bvalid), .bready(m_bready),
        .araddr(m_araddr), .arvalid(m_arvalid), .arready(m_arready),
        .rdata(m_rdata), .rvalid(m_rvalid), .rready(m_rready)
    );

    integer errors = 0;
    reg [31:0] got;

    task chk(input [8*56:1] name, input [31:0] exp, act);
        begin
            if (exp === act) $display("  PASS  %0s = %h", name, act);
            else begin
                $display("  FAIL  %0s expected %h got %h", name, exp, act);
                errors = errors + 1;
            end
        end
    endtask

    reg [31:0] rd0_data, rd1_data;
    reg [16:0] rd0_addr, rd1_addr;

    // Read through slice 0 / slice 1 and report the address the subsystem saw.
    task rd0(input [15:0] a); begin
        @(negedge clk); s0_arvalid = 1; s0_addr = a;
        // AXI4-Lite: hold arvalid through the posedge where arready is high, so
        // clear it one negedge after the grant is first observed.
        while (!s0_arready) @(negedge clk);
        @(negedge clk);
        s0_arvalid = 0;
        while (!s0_rvalid) @(negedge clk);
        rd0_data = s0_rdata; rd0_addr = txss.last_araddr;
        @(negedge clk);
    end endtask
    task rd1(input [15:0] a); begin
        @(negedge clk); s1_arvalid = 1; s1_addr = a;
        while (!s1_arready) @(negedge clk);
        @(negedge clk);
        s1_arvalid = 0;
        while (!s1_rvalid) @(negedge clk);
        rd1_data = s1_rdata; rd1_addr = txss.last_araddr;
        @(negedge clk);
    end endtask
    task wr1(input [15:0] a, input [31:0] d); begin
        @(negedge clk); s1_awvalid = 1; s1_wvalid = 1; s1_addr = a; s1_wdata = d;
        while (!(s1_awready && s1_wready)) @(negedge clk);
        @(negedge clk);
        s1_awvalid = 0; s1_wvalid = 0;
        while (!s1_bvalid) @(negedge clk);
        @(negedge clk);
    end endtask
    initial begin
        repeat (4) @(negedge clk); rstn = 1;
        repeat (2) @(negedge clk);

        $display("=== lower slice (0xB0020000) must reach the TX core: bit16 clear ===");
        rd0(16'h0000);
        chk("tx_core_id", 32'h2200_0100, rd0_data);
        chk("tx_core_araddr", 32'h00000, {15'd0, rd0_addr});
        if (rd0_addr[16] !== 1'b0) begin
            $display("  FAIL  lower slice drove subsystem bit16 = 1"); errors = errors + 1;
        end else $display("  PASS  subsystem address bit16 = 0 for 0xB0020000");

        $display("=== upper slice (0xB0030000) must reach the VTC: bit16 set ===");
        rd1(16'h0000);
        chk("vtc_reg", 32'h5654_4331, rd1_data);
        chk("vtc_araddr", 32'h10000, {15'd0, rd1_addr});
        if (rd1_addr[16] !== 1'b1) begin
            $display("  FAIL  upper slice drove subsystem bit16 = 0 (VTC unreachable)");
            errors = errors + 1;
        end else $display("  PASS  subsystem address bit16 = 1 for 0xB0030000");

        $display("=== VTC write then read back through the upper slice ===");
        wr1(16'h0150, 32'h0780_0B00);       // VTC VTOL1-style timing write
        rd1(16'h0150);
        chk("vtc_write_readback", 32'h0780_0B00, rd1_data);
        // The subsystem must see the write at 0x10150: bit16 set (VTC half) and
        // the low 16 bits preserved (VTC register offset 0x150).
        chk("vtc_awaddr", 32'h00010150, {15'd0, txss.last_awaddr});
        if (!txss.saw_vtc_write) begin
            $display("  FAIL  no VTC (bit16=1) write ever reached the subsystem");
            errors = errors + 1;
        end else $display("  PASS  VTC write decoded in the VTC half (26111601 could not do this)");

        $display("=== interleaving must not cross-talk between the two slices ===");
        rd0(16'h0000); rd1(16'h0000); rd0(16'h0000);
        chk("core_still_tx_id", 32'h2200_0100, rd0_data);
        chk("vtc_still_vtc",    32'h5654_4331, rd1_data);
        chk("core_no_vtc_leak", 32'h0, {31'd0, rd0_addr[16]});
        chk("vtc_bit16_kept",   32'h1, {31'd0, rd1_addr[16]});

        if (errors == 0) $display("SC7F0_TXSS_CTL_MERGE_PASS lower=core(bit16=0) upper=vtc(bit16=1) rw+isolation ok");
        else             $display("SC7F0_TXSS_CTL_MERGE_FAIL errors=%0d", errors);
        $finish;
    end


    initial begin
        #200000;
        $display("SC7F0_TXSS_CTL_MERGE_TIMEOUT");
        $finish;
    end
endmodule

module txss_ctl_slave_17 (input aclk, input aresetn,
                          input [16:0] awaddr, input awvalid, output reg awready,
                          input [31:0] wdata, input [3:0] wstrb, input wvalid, output reg wready,
                          output reg bvalid, input bready,
                          input [16:0] araddr, input arvalid, output reg arready,
                          output reg [31:0] rdata, output reg rvalid, input rready);
    reg [31:0] core_mem [0:63];
    reg [31:0] vtc_mem  [0:63];
    reg [16:0] last_araddr, last_awaddr;
    reg        saw_core_read, saw_vtc_read, saw_vtc_write;
    integer j;
    initial begin
        for (j = 0; j < 64; j = j + 1) begin core_mem[j] = 32'h0; vtc_mem[j] = 32'h0; end
        core_mem[0] = 32'h2200_0100;              // v_hdmi_tx TX core ID
        vtc_mem[0]  = 32'h5654_4331;              // stand-in for a VTC register
        last_araddr = 17'h1FFFF; last_awaddr = 17'h1FFFF;
        saw_core_read = 1'b0; saw_vtc_read = 1'b0; saw_vtc_write = 1'b0;
    end
    wire ar_fire = arvalid & arready;
    wire aw_fire = awvalid & awready;
    wire w_fire  = wvalid  & wready;
    always @(*) begin awready = ~bvalid; wready = 1'b1; arready = ~rvalid; end
    always @(posedge aclk) begin
        if (!aresetn) begin bvalid <= 1'b0; rvalid <= 1'b0; end
        else begin
            if (aw_fire && w_fire) begin
                last_awaddr <= awaddr;
                if (awaddr[16]) begin saw_vtc_write <= 1'b1; vtc_mem[awaddr[7:2]] <= wdata; end
                else core_mem[awaddr[7:2]] <= wdata;
                bvalid <= 1'b1;
            end else if (bvalid && bready) bvalid <= 1'b0;
            if (ar_fire) begin
                last_araddr <= araddr;
                if (araddr[16]) begin
                    saw_vtc_read <= 1'b1; rdata <= vtc_mem[araddr[7:2]];
                end else begin
                    saw_core_read <= 1'b1;
                    rdata <= (araddr == 17'h0) ? 32'h2200_0100 : core_mem[araddr[7:2]];
                end
                rvalid <= 1'b1;
            end else if (rvalid && rready) begin rvalid <= 1'b0; rdata <= 32'hdeadbeef; end
        end
    end
endmodule
