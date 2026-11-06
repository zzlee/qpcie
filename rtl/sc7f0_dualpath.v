`default_nettype none
// Hardware-only extension. PS AXI-Lite config/queues, independent HDMI NV12
// capture on HP1, and timestamped byte-packet C2H. No VCU/codec implementation.
`timescale 1ns/1ps
module sc7f0_dualpath #(parameter LEGACY_CAPTURE=1)(
    input wire csr_clk,csr_rst_n,mem_clk,mem_rst_n,pcie_clk,pcie_rst_n,
    input wire [127:0] video_data,input wire video_valid,video_sof,video_eol,
    input wire [31:0] s_awaddr,input wire s_awvalid,output wire s_awready,
    input wire [31:0] s_wdata,input wire [3:0] s_wstrb,input wire s_wvalid,output wire s_wready,
    output wire [1:0] s_bresp,output wire s_bvalid,input wire s_bready,
    input wire [31:0] s_araddr,input wire s_arvalid,output wire s_arready,
    output wire [31:0] s_rdata,output wire [1:0] s_rresp,output wire s_rvalid,input wire s_rready,
    output wire irq,
    output wire [39:0] awaddr,output wire [7:0] awlen,output wire [2:0] awsize,
    output wire [1:0] awburst,output wire awvalid,input wire awready,
    output wire [127:0] wdata,output wire [15:0] wstrb,
    output wire wlast,wvalid,input wire wready,
    input wire [1:0] bresp,input wire bvalid,output wire bready,
    output wire [39:0] araddr,output wire [7:0] arlen,output wire [2:0] arsize,
    output wire [1:0] arburst,output wire arvalid,input wire arready,
    input wire [127:0] rdata,input wire [1:0] rresp,input wire rlast,rvalid,output wire rready,
    output wire packet_valid,output wire [63:0] packet_addr,
    output wire [10:0] packet_dw_len,output wire [3:0] packet_first_be,packet_last_be,
    output wire [255:0] packet_data,input wire packet_data_ready,packet_ack,
    output wire packet_done_msi_pulse,
    output wire [31:0] probe_pkt_submit_cnt,
    output wire [31:0] probe_pkt_done_cnt,
    output wire [31:0] probe_pkt_err_cnt,
    output wire [31:0] probe_pkt_msi_cnt,
    output wire [31:0] probe_pkt_bytes_lo,
    output wire [31:0] probe_pkt_bytes_hi,
    output wire [31:0] probe_pkt_fsm_state,
    output wire [31:0] probe_pkt_last_len,
    output wire [31:0] probe_pkt_last_pts_lo,
    output wire [31:0] probe_pkt_last_pts_hi
);
    wire packet_reset;
    xpm_cdc_async_rst #(.DEST_SYNC_FF(4),.RST_ACTIVE_HIGH(1)) u_packet_reset(
        .src_arst(!mem_rst_n||!pcie_rst_n),.dest_clk(mem_clk),.dest_arst(packet_reset));
    wire packet_rst_n=!packet_reset;
    wire [255:0] fcw,fcr,fdw,fdr;
    wire fpush,fwr,fvalid,ftake,fdvalid,fdready,frvalid,frpop;
    wire [767:0] pcw,pcr;
    wire [511:0] pdw,pdr;
    wire ppush,pwr,pvalid,ptake,pdvalid,pdready,prvalid,prpop;
    wire cbusy,pbusy;
    wire [1:0] busy_csr;
    wire [31:0] dropped,dropped_csr;
    assign irq=frvalid||prvalid;

    wire r_done_pulse, r_err_pulse;
    wire [31:0] r_last_len;
    wire [63:0] r_last_pts;
    wire [7:0]  r_fsm_state;

    xpm_cdc_pulse #(.DEST_SYNC_FF(4),.RST_USED(1)) u_cdc_pkt_msi(
        .src_clk(mem_clk),.src_rst(!packet_rst_n),.src_pulse(r_done_pulse),
        .dest_clk(pcie_clk),.dest_rst(!pcie_rst_n),.dest_pulse(packet_done_msi_pulse));

    wire r_done_pulse_csr;
    xpm_cdc_pulse #(.DEST_SYNC_FF(4),.RST_USED(1)) u_cdc_pkt_done_csr(
        .src_clk(mem_clk),.src_rst(!packet_rst_n),.src_pulse(r_done_pulse),
        .dest_clk(csr_clk),.dest_rst(!csr_rst_n),.dest_pulse(r_done_pulse_csr));

    wire r_msi_pulse_csr;
    xpm_cdc_pulse #(.DEST_SYNC_FF(4),.RST_USED(1)) u_cdc_msi_csr(
        .src_clk(pcie_clk),.src_rst(!pcie_rst_n),.src_pulse(packet_done_msi_pulse),
        .dest_clk(csr_clk),.dest_rst(!csr_rst_n),.dest_pulse(r_msi_pulse_csr));

    wire [7:0] r_fsm_state_csr;
    xpm_cdc_array_single #(.WIDTH(8),.DEST_SYNC_FF(4),.SRC_INPUT_REG(1)) u_fsm_cdc(
        .src_clk(mem_clk),.src_in(r_fsm_state),.dest_clk(csr_clk),.dest_out(r_fsm_state_csr));

    reg [31:0] reg_pkt_submit_cnt, reg_pkt_done_cnt, reg_pkt_err_cnt, reg_pkt_msi_cnt;
    reg [63:0] reg_pkt_bytes;
    reg [31:0] reg_pkt_last_len;
    reg [63:0] reg_pkt_last_pts;
    reg r_prvalid_d;
    wire comp_arrived = prvalid && !r_prvalid_d;

    always @(posedge csr_clk) begin
        if (!csr_rst_n) begin
            reg_pkt_submit_cnt <= 32'd0;
            reg_pkt_done_cnt   <= 32'd0;
            reg_pkt_err_cnt    <= 32'd0;
            reg_pkt_msi_cnt    <= 32'd0;
            reg_pkt_bytes      <= 64'd0;
            reg_pkt_last_len   <= 32'd0;
            reg_pkt_last_pts   <= 64'd0;
            r_prvalid_d        <= 1'b0;
        end else begin
            r_prvalid_d <= prvalid;
            if (ppush)
                reg_pkt_submit_cnt <= reg_pkt_submit_cnt + 1'b1;
            if (r_done_pulse_csr)
                reg_pkt_done_cnt   <= reg_pkt_done_cnt + 1'b1;
            if (comp_arrived) begin
                reg_pkt_bytes    <= reg_pkt_bytes + pdr[351:320];
                reg_pkt_last_len <= pdr[351:320];
                reg_pkt_last_pts <= pdr[255:192];
                if (pdr[63:32] != 0)
                    reg_pkt_err_cnt <= reg_pkt_err_cnt + 1'b1;
            end
            if (r_msi_pulse_csr)
                reg_pkt_msi_cnt <= reg_pkt_msi_cnt + 1'b1;
        end
    end

    assign probe_pkt_submit_cnt  = reg_pkt_submit_cnt;
    assign probe_pkt_done_cnt    = reg_pkt_done_cnt;
    assign probe_pkt_err_cnt     = reg_pkt_err_cnt;
    assign probe_pkt_msi_cnt     = reg_pkt_msi_cnt;
    assign probe_pkt_bytes_lo    = reg_pkt_bytes[31:0];
    assign probe_pkt_bytes_hi    = reg_pkt_bytes[63:32];
    assign probe_pkt_fsm_state   = {24'd0, r_fsm_state_csr};
    assign probe_pkt_last_len    = reg_pkt_last_len;
    assign probe_pkt_last_pts_lo = reg_pkt_last_pts[31:0];
    assign probe_pkt_last_pts_hi = reg_pkt_last_pts[63:32];

    sc7f0_dualpath_regs #(.HAS_LEGACY_CAPTURE(LEGACY_CAPTURE)) u_regs(
        .clk(csr_clk),.rst_n(csr_rst_n),
        .s_awaddr(s_awaddr),.s_awvalid(s_awvalid),.s_awready(s_awready),
        .s_wdata(s_wdata),.s_wstrb(s_wstrb),.s_wvalid(s_wvalid),.s_wready(s_wready),
        .s_bresp(s_bresp),.s_bvalid(s_bvalid),.s_bready(s_bready),
        .s_araddr(s_araddr),.s_arvalid(s_arvalid),.s_arready(s_arready),
        .s_rdata(s_rdata),.s_rresp(s_rresp),.s_rvalid(s_rvalid),.s_rready(s_rready),
        .frame_cmd(fcw),.frame_push(fpush),.frame_ready(fwr),
        .frame_done(fdr),.frame_valid(frvalid),.frame_pop(frpop),
        .packet_cmd(pcw),.packet_push(ppush),.packet_ready(pwr),
        .packet_done(pdr),.packet_valid(prvalid),.packet_pop(prpop),
        .engine_busy(busy_csr),.dropped_frames(dropped_csr),
        .probe_pkt_submit_cnt(reg_pkt_submit_cnt),
        .probe_pkt_done_cnt(reg_pkt_done_cnt),
        .probe_pkt_err_cnt(reg_pkt_err_cnt),
        .probe_pkt_msi_cnt(reg_pkt_msi_cnt),
        .probe_pkt_bytes_lo(reg_pkt_bytes[31:0]),
        .probe_pkt_bytes_hi(reg_pkt_bytes[63:32]),
        .probe_pkt_fsm_state({24'd0, r_fsm_state_csr}),
        .probe_pkt_last_len(reg_pkt_last_len),
        .probe_pkt_last_pts_lo(reg_pkt_last_pts[31:0]),
        .probe_pkt_last_pts_hi(reg_pkt_last_pts[63:32]));
    generate if(LEGACY_CAPTURE)begin:legacy_queues
    sc7f0_dp_fifo #(.WIDTH(256)) u_frame_commands(
        .wclk(csr_clk),.wrst_n(csr_rst_n),.wdata(fcw),.wvalid(fpush),.wready(fwr),
        .rclk(mem_clk),.rrst_n(mem_rst_n),.rdata(fcr),.rvalid(fvalid),.rready(ftake));
    sc7f0_dp_fifo #(.WIDTH(256)) u_frame_completions(
        .wclk(mem_clk),.wrst_n(mem_rst_n),.wdata(fdw),.wvalid(fdvalid),.wready(fdready),
        .rclk(csr_clk),.rrst_n(csr_rst_n),.rdata(fdr),.rvalid(frvalid),.rready(frpop));
    end else begin:no_frame_queues
        assign fwr=0;assign fcr=0;assign fvalid=0;assign fdready=0;assign fdr=0;assign frvalid=0;
    end endgenerate
    sc7f0_dp_fifo #(.WIDTH(768)) u_packet_commands(
        .wclk(csr_clk),.wrst_n(csr_rst_n&&pcie_rst_n),.wdata(pcw),.wvalid(ppush),.wready(pwr),
        .rclk(mem_clk),.rrst_n(packet_rst_n),.rdata(pcr),.rvalid(pvalid),.rready(ptake));
    sc7f0_dp_fifo #(.WIDTH(512)) u_packet_completions(
        .wclk(mem_clk),.wrst_n(packet_rst_n),.wdata(pdw),.wvalid(pdvalid),.wready(pdready),
        .rclk(csr_clk),.rrst_n(csr_rst_n&&pcie_rst_n),.rdata(pdr),.rvalid(prvalid),.rready(prpop));
    xpm_cdc_array_single #(.WIDTH(2),.DEST_SYNC_FF(4),.SRC_INPUT_REG(1)) u_busy(
        .src_clk(mem_clk),.src_in({pbusy,cbusy}),.dest_clk(csr_clk),.dest_out(busy_csr));
    xpm_cdc_gray #(.WIDTH(32),.DEST_SYNC_FF(4),.REG_OUTPUT(1)) u_drops(
        .src_clk(mem_clk),.src_in_bin(dropped),.dest_clk(csr_clk),.dest_out_bin(dropped_csr));
    generate if(LEGACY_CAPTURE)begin:legacy_writer
    sc7f0_nv12_ddr_writer u_capture(
        .clk(mem_clk),.rst_n(mem_rst_n),.video_data(video_data),.video_valid(video_valid),
        .video_sof(video_sof),.video_eol(video_eol),.cmd_data(fcr),.cmd_valid(fvalid),.cmd_ready(ftake),
        .done_data(fdw),.done_valid(fdvalid),.done_ready(fdready),.busy(cbusy),.dropped_frames(dropped),
        .awaddr(awaddr),.awlen(awlen),.awsize(awsize),.awburst(awburst),.awvalid(awvalid),.awready(awready),
        .wdata(wdata),.wstrb(wstrb),.wlast(wlast),.wvalid(wvalid),.wready(wready),
        .bresp(bresp),.bvalid(bvalid),.bready(bready));
    end else begin:no_frame_writer
        assign ftake=0;assign fdw=0;assign fdvalid=0;assign cbusy=0;assign dropped=0;
        assign awaddr=0;assign awlen=0;assign awsize=4;assign awburst=1;assign awvalid=0;
        assign wdata=0;assign wstrb=0;assign wlast=0;assign wvalid=0;assign bready=0;
    end endgenerate
    wire tx_valid,tx_ready,tx_done;
    wire [63:0] tx_addr;wire [10:0] tx_dw_len;wire [3:0] tx_first,tx_last;
    wire [2047:0] tx_payload;
    sc7f0_ps_packet_reader u_reader(
        .clk(mem_clk),.rst_n(packet_rst_n),.cmd_data(pcr),.cmd_valid(pvalid),.cmd_ready(ptake),
        .done_data(pdw),.done_valid(pdvalid),.done_ready(pdready),.busy(pbusy),
        .araddr(araddr),.arlen(arlen),.arsize(arsize),.arburst(arburst),.arvalid(arvalid),.arready(arready),
        .rdata(rdata),.rresp(rresp),.rlast(rlast),.rvalid(rvalid),.rready(rready),
        .tx_valid(tx_valid),.tx_ready(tx_ready),.tx_addr(tx_addr),.tx_dw_len(tx_dw_len),
        .tx_first_be(tx_first),.tx_last_be(tx_last),.tx_payload(tx_payload),.tx_done(tx_done),
        .packet_done_pulse(r_done_pulse),.packet_err_pulse(r_err_pulse),
        .packet_last_len(r_last_len),.packet_last_pts(r_last_pts),
        .packet_fsm_state(r_fsm_state));
    sc7f0_packet_cdc u_tx_cdc(
        .s_clk(mem_clk),.s_rst_n(packet_rst_n),.s_valid(tx_valid),.s_ready(tx_ready),
        .s_addr(tx_addr),.s_dw_len(tx_dw_len),.s_first_be(tx_first),.s_last_be(tx_last),
        .s_payload(tx_payload),.s_done(tx_done),.m_clk(pcie_clk),.m_rst_n(pcie_rst_n),
        .m_valid(packet_valid),.m_addr(packet_addr),.m_dw_len(packet_dw_len),
        .m_first_be(packet_first_be),.m_last_be(packet_last_be),.m_data(packet_data),
        .m_data_ready(packet_data_ready),.m_ack(packet_ack));
endmodule
`default_nettype wire
