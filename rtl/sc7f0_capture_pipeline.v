`default_nettype none
`timescale 1ns/1ps
// Official PS capture chain. Control lanes:0=framebuffer,1=CSC,2=tap/GPIO.
// RX is an observer input: no connection can propagate downstream READY to RX.
module sc7f0_capture_pipeline(
    input wire csr_clk,csr_rst_n,mem_clk,mem_rst_n,rx_clk,rx_rst_n,
    input wire [95:0] rx_data,input wire rx_valid,rx_sof,rx_eol,
    input wire [95:0] s_awaddr,input wire [2:0] s_awvalid,output wire [2:0] s_awready,
    input wire [95:0] s_wdata,input wire [11:0] s_wstrb,input wire [2:0] s_wvalid,output wire [2:0] s_wready,
    output wire [5:0] s_bresp,output wire [2:0] s_bvalid,input wire [2:0] s_bready,
    input wire [95:0] s_araddr,input wire [2:0] s_arvalid,output wire [2:0] s_arready,
    output wire [95:0] s_rdata,output wire [5:0] s_rresp,output wire [2:0] s_rvalid,input wire [2:0] s_rready,
    output wire irq,
    output wire [63:0] awaddr,output wire [7:0] awlen,output wire [2:0] awsize,output wire [1:0] awburst,
    output wire awvalid,input wire awready,output wire [127:0] wdata,output wire [15:0] wstrb,
    output wire wlast,wvalid,input wire wready,input wire [1:0] bresp,input wire bvalid,output wire bready,
    output wire [63:0] araddr,output wire [7:0] arlen,output wire [2:0] arsize,output wire [1:0] arburst,
    output wire arvalid,input wire arready,input wire [127:0] rdata,input wire [1:0] rresp,
    input wire rlast,rvalid,output wire rready
);
    wire [63:0] ca,cd,crd,cra;
    wire [7:0] cws;
    wire [1:0] cav,car,cwv,cwr,cbv,cbrdy,crav,crar,crv,crrdy;
    wire [3:0] cbr,crr;
    genvar lane;
    generate for(lane=0;lane<2;lane=lane+1)begin:control_cdc
        axi_clock_converter_0 u_clock_converter(
            .s_axi_aclk(csr_clk),.s_axi_aresetn(csr_rst_n),
            .s_axi_awaddr(s_awaddr[lane*32+:32]),.s_axi_awprot(3'd0),
            .s_axi_awvalid(s_awvalid[lane]),.s_axi_awready(s_awready[lane]),
            .s_axi_wdata(s_wdata[lane*32+:32]),.s_axi_wstrb(s_wstrb[lane*4+:4]),
            .s_axi_wvalid(s_wvalid[lane]),.s_axi_wready(s_wready[lane]),
            .s_axi_bresp(s_bresp[lane*2+:2]),.s_axi_bvalid(s_bvalid[lane]),.s_axi_bready(s_bready[lane]),
            .s_axi_araddr(s_araddr[lane*32+:32]),.s_axi_arprot(3'd0),
            .s_axi_arvalid(s_arvalid[lane]),.s_axi_arready(s_arready[lane]),
            .s_axi_rdata(s_rdata[lane*32+:32]),.s_axi_rresp(s_rresp[lane*2+:2]),
            .s_axi_rvalid(s_rvalid[lane]),.s_axi_rready(s_rready[lane]),
            .m_axi_aclk(mem_clk),.m_axi_aresetn(mem_rst_n),
            .m_axi_awaddr(ca[lane*32+:32]),.m_axi_awprot(),.m_axi_awvalid(cav[lane]),.m_axi_awready(car[lane]),
            .m_axi_wdata(cd[lane*32+:32]),.m_axi_wstrb(cws[lane*4+:4]),.m_axi_wvalid(cwv[lane]),.m_axi_wready(cwr[lane]),
            .m_axi_bresp(cbr[lane*2+:2]),.m_axi_bvalid(cbv[lane]),.m_axi_bready(cbrdy[lane]),
            .m_axi_araddr(cra[lane*32+:32]),.m_axi_arprot(),.m_axi_arvalid(crav[lane]),.m_axi_arready(crar[lane]),
            .m_axi_rdata(crd[lane*32+:32]),.m_axi_rresp(crr[lane*2+:2]),.m_axi_rvalid(crv[lane]),.m_axi_rready(crrdy[lane]));
    end endgenerate
    wire enabled,writer_rst_n,csc_rst_n,tap_busy,credit_valid,credit_clear;
    wire [15:0] credit_add;
    wire [31:0] started_count;
    wire [15:0] width,height;
    wire [159:0] metadata;wire meta_valid,meta_ready;
    wire [31:0] drops;wire [63:0] ticks,ticks_gray;
    wire [95:0] tap_data;wire tv,ts,te,tr;
    sc7f0_tap_regs u_regs(
        .clk(csr_clk),.rst_n(csr_rst_n),.m_clk(mem_clk),.m_rst_n(mem_rst_n),
        .s_awaddr(s_awaddr[95:64]),.s_awvalid(s_awvalid[2]),.s_awready(s_awready[2]),
        .s_wdata(s_wdata[95:64]),.s_wstrb(s_wstrb[11:8]),.s_wvalid(s_wvalid[2]),.s_wready(s_wready[2]),
        .s_bresp(s_bresp[5:4]),.s_bvalid(s_bvalid[2]),.s_bready(s_bready[2]),
        .s_araddr(s_araddr[95:64]),.s_arvalid(s_arvalid[2]),.s_arready(s_arready[2]),
        .s_rdata(s_rdata[95:64]),.s_rresp(s_rresp[5:4]),.s_rvalid(s_rvalid[2]),.s_rready(s_rready[2]),
        .enable(enabled),.width(width),.height(height),.busy(tap_busy),.drops(drops),.ticks_gray(ticks_gray),
        .credit_valid(credit_valid),.credit_clear(credit_clear),.credit_add(credit_add),.started_count(started_count),
        .meta_data(metadata),.meta_valid(meta_valid),.meta_ready(meta_ready),
        .writer_rst_n(writer_rst_n),.csc_rst_n(csc_rst_n));
    sc7f0_frame_tap u_tap(
        .s_clk(rx_clk),.s_rst_n(rx_rst_n),.s_data(rx_data),.s_valid(rx_valid),.s_sof(rx_sof),.s_eol(rx_eol),
        .m_clk(mem_clk),.m_rst_n(mem_rst_n),.enable(enabled&&writer_rst_n&&csc_rst_n),.width(width),.height(height),
        .credit_valid(credit_valid),.credit_clear(credit_clear),.credit_add(credit_add),.started_count(started_count),
        .m_data(tap_data),.m_valid(tv),.m_sof(ts),.m_eol(te),.m_ready(tr),
        .meta_data(metadata),.meta_valid(meta_valid),.meta_ready(meta_ready),
        .busy(tap_busy),.dropped_frames(drops),.ticks(ticks),.ticks_gray(ticks_gray));
    wire [95:0] converted;wire cv,cs,ce,cready;wire [11:0] keep,strb;
    sc7f0_vpss_csc u_csc(
        .aclk(mem_clk),.aresetn(csc_rst_n),.s_axis_tdata(tap_data),.s_axis_tvalid(tv),.s_axis_tready(tr),
        .s_axis_tuser(ts),.s_axis_tlast(te),.s_axis_tkeep(12'hfff),.s_axis_tstrb(12'hfff),.s_axis_tid(1'b0),.s_axis_tdest(1'b0),
        .m_axis_tdata(converted),.m_axis_tvalid(cv),.m_axis_tready(cready),.m_axis_tuser(cs),.m_axis_tlast(ce),
        .m_axis_tkeep(keep),.m_axis_tstrb(strb),.m_axis_tid(),.m_axis_tdest(),
        .s_axi_ctrl_awaddr(ca[40:32]),.s_axi_ctrl_awvalid(cav[1]),.s_axi_ctrl_awready(car[1]),
        .s_axi_ctrl_wdata(cd[63:32]),.s_axi_ctrl_wstrb(cws[7:4]),.s_axi_ctrl_wvalid(cwv[1]),.s_axi_ctrl_wready(cwr[1]),
        .s_axi_ctrl_bresp(cbr[3:2]),.s_axi_ctrl_bvalid(cbv[1]),.s_axi_ctrl_bready(cbrdy[1]),
        .s_axi_ctrl_araddr(cra[40:32]),.s_axi_ctrl_arvalid(crav[1]),.s_axi_ctrl_arready(crar[1]),
        .s_axi_ctrl_rdata(crd[63:32]),.s_axi_ctrl_rresp(crr[3:2]),.s_axi_ctrl_rvalid(crv[1]),.s_axi_ctrl_rready(crrdy[1]));
    // 4PPC framebuffer uses vendor-recommended FB256; PS HP1 remains 128-bit.
    wire [63:0] fb_awaddr,fb_araddr;
    wire [7:0] fb_awlen,fb_arlen;
    wire [2:0] fb_awsize,fb_arsize;
    wire [1:0] fb_awburst,fb_arburst,fb_bresp,fb_rresp;
    wire fb_awvalid,fb_awready,fb_wvalid,fb_wready,fb_wlast,fb_bvalid,fb_bready;
    wire fb_arvalid,fb_arready,fb_rvalid,fb_rready,fb_rlast;
    wire [255:0] fb_wdata,fb_rdata;
    wire [31:0] fb_wstrb;
    sc7f0_frmbuf_wr u_writer(
        .ap_clk(mem_clk),.ap_rst_n(writer_rst_n),.interrupt(irq),
        .s_axis_video_TDATA(converted),.s_axis_video_TVALID(cv),.s_axis_video_TREADY(cready),
        .s_axis_video_TUSER(cs),.s_axis_video_TLAST(ce),.s_axis_video_TKEEP(keep),.s_axis_video_TSTRB(strb),
        .s_axis_video_TID(1'b0),.s_axis_video_TDEST(1'b0),
        .s_axi_CTRL_AWADDR(ca[6:0]),.s_axi_CTRL_AWVALID(cav[0]),.s_axi_CTRL_AWREADY(car[0]),
        .s_axi_CTRL_WDATA(cd[31:0]),.s_axi_CTRL_WSTRB(cws[3:0]),.s_axi_CTRL_WVALID(cwv[0]),.s_axi_CTRL_WREADY(cwr[0]),
        .s_axi_CTRL_BRESP(cbr[1:0]),.s_axi_CTRL_BVALID(cbv[0]),.s_axi_CTRL_BREADY(cbrdy[0]),
        .s_axi_CTRL_ARADDR(cra[6:0]),.s_axi_CTRL_ARVALID(crav[0]),.s_axi_CTRL_ARREADY(crar[0]),
        .s_axi_CTRL_RDATA(crd[31:0]),.s_axi_CTRL_RRESP(crr[1:0]),.s_axi_CTRL_RVALID(crv[0]),.s_axi_CTRL_RREADY(crrdy[0]),
        .m_axi_mm_video_AWADDR(fb_awaddr),.m_axi_mm_video_AWLEN(fb_awlen),.m_axi_mm_video_AWSIZE(fb_awsize),.m_axi_mm_video_AWBURST(fb_awburst),
        .m_axi_mm_video_AWVALID(fb_awvalid),.m_axi_mm_video_AWREADY(fb_awready),
        .m_axi_mm_video_WDATA(fb_wdata),.m_axi_mm_video_WSTRB(fb_wstrb),.m_axi_mm_video_WLAST(fb_wlast),
        .m_axi_mm_video_WVALID(fb_wvalid),.m_axi_mm_video_WREADY(fb_wready),
        .m_axi_mm_video_BRESP(fb_bresp),.m_axi_mm_video_BVALID(fb_bvalid),.m_axi_mm_video_BREADY(fb_bready),
        .m_axi_mm_video_ARADDR(fb_araddr),.m_axi_mm_video_ARLEN(fb_arlen),.m_axi_mm_video_ARSIZE(fb_arsize),.m_axi_mm_video_ARBURST(fb_arburst),
        .m_axi_mm_video_ARVALID(fb_arvalid),.m_axi_mm_video_ARREADY(fb_arready),
        .m_axi_mm_video_RDATA(fb_rdata),.m_axi_mm_video_RRESP(fb_rresp),.m_axi_mm_video_RLAST(fb_rlast),
        .m_axi_mm_video_RVALID(fb_rvalid),.m_axi_mm_video_RREADY(fb_rready));
    sc7f0_capture_width u_memory_width(
        .s_axi_aclk(mem_clk),
        .s_axi_aresetn(mem_rst_n),
        .s_axi_awid(1'b0),
        .s_axi_awaddr(fb_awaddr),
        .s_axi_awlen(fb_awlen),
        .s_axi_awsize(fb_awsize),
        .s_axi_awburst(fb_awburst),
        .s_axi_awlock(1'b0),
        .s_axi_awcache(4'b0011),
        .s_axi_awprot(3'b0),
        .s_axi_awregion(4'b0),
        .s_axi_awqos(4'b0),
        .s_axi_awvalid(fb_awvalid),
        .s_axi_awready(fb_awready),
        .s_axi_wdata(fb_wdata),
        .s_axi_wstrb(fb_wstrb),
        .s_axi_wlast(fb_wlast),
        .s_axi_wvalid(fb_wvalid),
        .s_axi_wready(fb_wready),
        .s_axi_bid(),
        .s_axi_bresp(fb_bresp),
        .s_axi_bvalid(fb_bvalid),
        .s_axi_bready(fb_bready),
        .s_axi_arid(1'b0),
        .s_axi_araddr(fb_araddr),
        .s_axi_arlen(fb_arlen),
        .s_axi_arsize(fb_arsize),
        .s_axi_arburst(fb_arburst),
        .s_axi_arlock(1'b0),
        .s_axi_arcache(4'b0011),
        .s_axi_arprot(3'b0),
        .s_axi_arregion(4'b0),
        .s_axi_arqos(4'b0),
        .s_axi_arvalid(fb_arvalid),
        .s_axi_arready(fb_arready),
        .s_axi_rid(),
        .s_axi_rdata(fb_rdata),
        .s_axi_rresp(fb_rresp),
        .s_axi_rlast(fb_rlast),
        .s_axi_rvalid(fb_rvalid),
        .s_axi_rready(fb_rready),
        .m_axi_awaddr(awaddr),
        .m_axi_awlen(awlen),
        .m_axi_awsize(awsize),
        .m_axi_awburst(awburst),
        .m_axi_awlock(),
        .m_axi_awcache(),
        .m_axi_awprot(),
        .m_axi_awregion(),
        .m_axi_awqos(),
        .m_axi_awvalid(awvalid),
        .m_axi_awready(awready),
        .m_axi_wdata(wdata),
        .m_axi_wstrb(wstrb),
        .m_axi_wlast(wlast),
        .m_axi_wvalid(wvalid),
        .m_axi_wready(wready),
        .m_axi_bresp(bresp),
        .m_axi_bvalid(bvalid),
        .m_axi_bready(bready),
        .m_axi_araddr(araddr),
        .m_axi_arlen(arlen),
        .m_axi_arsize(arsize),
        .m_axi_arburst(arburst),
        .m_axi_arlock(),
        .m_axi_arcache(),
        .m_axi_arprot(),
        .m_axi_arregion(),
        .m_axi_arqos(),
        .m_axi_arvalid(arvalid),
        .m_axi_arready(arready),
        .m_axi_rdata(rdata),
        .m_axi_rresp(rresp),
        .m_axi_rlast(rlast),
        .m_axi_rvalid(rvalid),
        .m_axi_rready(rready));
endmodule
`default_nettype wire
