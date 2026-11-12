`default_nettype none
`timescale 1ns/1ps
// AXI-Lite100MHz -> frame-tap150MHz. Ordered config, stable metadata head.
// GPIO bits are physical reset_n values:0 asserts,1 releases (active-low DT).
module sc7f0_tap_regs(
    input wire clk,rst_n,m_clk,m_rst_n,
    input wire [31:0] s_awaddr,input wire s_awvalid,output wire s_awready,
    input wire [31:0] s_wdata,input wire [3:0] s_wstrb,input wire s_wvalid,output wire s_wready,
    output reg [1:0] s_bresp,output reg s_bvalid,input wire s_bready,
    input wire [31:0] s_araddr,input wire s_arvalid,output wire s_arready,
    output reg [31:0] s_rdata,output reg [1:0] s_rresp,output reg s_rvalid,input wire s_rready,
    output reg enable,output reg [15:0] width,height,
    output wire credit_valid,credit_clear,output wire [15:0] credit_add,
    input wire busy,input wire [31:0] drops,started_count,input wire [63:0] ticks_gray,
    input wire [159:0] meta_data,input wire meta_valid,output wire meta_ready,
    output wire writer_rst_n,csc_rst_n
);
    reg [1:0] reset_n;
    // m_rst_n (memory clock domain) and the CSR-written reset_n bits (CSR clock
    // domain) are independent sources: each gets its own synchronizer into m_clk
    // before they are combined (rtl/sc7f0_reset_cdc.v, CDC-10 root cause).
    wire writer_all_n, csc_all_n;
    sc7f0_reset_sync #(.SOURCES(2)) u_writer_reset(
        .dest_clk(m_clk),.src_rst_n({reset_n[0],m_rst_n}),.dest_rst_n(writer_all_n));
    sc7f0_reset_sync #(.SOURCES(2)) u_csc_reset(
        .dest_clk(m_clk),.src_rst_n({reset_n[1],m_rst_n}),.dest_rst_n(csc_all_n));
    assign writer_rst_n=writer_all_n;assign csc_rst_n=csc_all_n;
    reg [15:0] staged_w,staged_h;
    reg [81:0] command;reg push,pop;
    reg [31:0] stop_requested,stop_target,stop_ack_m,retired_count;
    wire [31:0] retired_m,stop_ack_csr;
    wire ready,cv;wire [81:0] config_word;
    assign credit_valid=cv&&config_word[49];
    assign credit_add=config_word[48:33];
    assign credit_clear=cv&&!config_word[49]&&!config_word[0];
    sc7f0_dp_fifo #(.WIDTH(82)) u_config(
        .wclk(clk),.wrst_n(rst_n),.wdata(command),.wvalid(push),.wready(ready),
        .rclk(m_clk),.rrst_n(m_rst_n),.rdata(config_word),.rvalid(cv),.rready(1'b1));
    always @(posedge m_clk)begin
        if(!m_rst_n)begin
            enable<=0;width<=3840;height<=2160;stop_target<=0;stop_ack_m<=0;
        end else begin
            if(cv&&!config_word[49])begin
                enable<=config_word[0];width<=config_word[16:1];height<=config_word[32:17];
                if(!config_word[0])stop_target<=config_word[81:50];
            end
            // Acknowledge only in this coherent domain, after ALL admitted
            // frames really retired via DMA callback POP. No sampled enable/
            // busy combination is an ownership proof. Advance ONE per cycle
            // even when several stop commands were coalesced: Gray stays legal.
            if(!cv&&!enable&&!busy&&started_count==retired_m&&stop_ack_m!=stop_target)
                stop_ack_m<=stop_ack_m+1'b1;
        end
    end
    wire [159:0] head;wire valid;
    sc7f0_dp_fifo #(.WIDTH(160)) u_metadata(
        .wclk(m_clk),.wrst_n(m_rst_n),.wdata(meta_data),.wvalid(meta_valid),.wready(meta_ready),
        .rclk(clk),.rrst_n(rst_n),.rdata(head),.rvalid(valid),.rready(pop));
    xpm_cdc_gray #(.WIDTH(32),.DEST_SYNC_FF(4),.REG_OUTPUT(1)) u_retired(
        .src_clk(clk),.src_in_bin(retired_count),.dest_clk(m_clk),.dest_out_bin(retired_m));
    xpm_cdc_gray #(.WIDTH(32),.DEST_SYNC_FF(4),.REG_OUTPUT(1)) u_stop_ack(
        .src_clk(m_clk),.src_in_bin(stop_ack_m),.dest_clk(clk),.dest_out_bin(stop_ack_csr));
    // Approximate independent status levels only. STOP ownership uses ACK.
    wire [1:0] state_csr;
    xpm_cdc_array_single #(.WIDTH(2),.SRC_INPUT_REG(1),.DEST_SYNC_FF(4)) u_state(
        .src_clk(m_clk),.src_in({enable,busy}),.dest_clk(clk),.dest_out(state_csr));
    wire [31:0] drops_csr;
    xpm_cdc_gray #(.WIDTH(32),.DEST_SYNC_FF(4),.REG_OUTPUT(1)) u_drops(
        .src_clk(m_clk),.src_in_bin(drops),.dest_clk(clk),.dest_out_bin(drops_csr));
    // Same registered Gray source as RX timestamp sampling; XDC constrains bus.
    wire [63:0] ticks_csr;
    sc7f0_gray64_sync u_time(.clk(clk),.rst_n(rst_n),.gray(ticks_gray),.binary(ticks_csr));
    wire [31:0] started_csr;
    xpm_cdc_gray #(.WIDTH(32),.DEST_SYNC_FF(4),.REG_OUTPUT(1)) u_started(
        .src_clk(m_clk),.src_in_bin(started_count),.dest_clk(clk),.dest_out_bin(started_csr));
    reg [31:0] latched_high;
    reg ah,wh;reg [11:0] aw;reg [31:0] wd;reg [3:0] ws;
    assign s_awready=!ah&&!s_bvalid;assign s_wready=!wh&&!s_bvalid;assign s_arready=!s_rvalid;
    wire [11:0] ra=s_araddr[11:0];
    integer b;
    always @(posedge clk)begin
        if(!rst_n)begin
            ah<=0;wh<=0;aw<=0;wd<=0;ws<=0;s_bvalid<=0;s_bresp<=0;s_rvalid<=0;s_rresp<=0;s_rdata<=0;
            reset_n<=0;staged_w<=3840;staged_h<=2160;command<=0;push<=0;pop<=0;latched_high<=0;retired_count<=0;stop_requested<=0;
        end else begin
            push<=0;pop<=0;
            if(s_awvalid&&s_awready)begin ah<=1;aw<=s_awaddr[11:0];end
            if(s_wvalid&&s_wready)begin wh<=1;wd<=s_wdata;ws<=s_wstrb;end
            if(s_bvalid&&s_bready)s_bvalid<=0;
            if(ah&&wh&&!s_bvalid)begin
                ah<=0;wh<=0;s_bvalid<=1;s_bresp<=0;
                if(aw[1:0])s_bresp<=2'b11;
                else case(aw)
                    'h00c:if(ws[0]&&ready)begin
                        command<={(wd[0]?32'd0:stop_requested+32'd1),1'b0,16'd0,staged_h,staged_w,wd[0]};
                        if(!wd[0])stop_requested<=stop_requested+1'b1;
                        push<=1;
                    end else s_bresp<=2'b10;
                    'h010:for(b=0;b<2;b=b+1)if(ws[b])staged_w[b*8+:8]<=wd[b*8+:8];
                    'h014:for(b=0;b<2;b=b+1)if(ws[b])staged_h[b*8+:8]<=wd[b*8+:8];
                    'h01c:if(ws[0]&&wd[0]&&valid)begin pop<=1;retired_count<=retired_count+1'b1;end else s_bresp<=2'b10;
                    'h028:if(ws[0]&&ws[1]&&ready&&wd[15:0]!=0)begin command<={32'd0,1'b1,wd[15:0],33'd0};push<=1;end else s_bresp<=2'b10;
                    'h030:if(ws[0])reset_n<=wd[1:0];
                    'h034:if(ws[0])reset_n<=reset_n|wd[1:0];
                    'h038:if(ws[0])reset_n<=reset_n&~wd[1:0];
                    default:s_bresp<=2'b11;
                endcase
            end
            if(s_rvalid&&s_rready)s_rvalid<=0;
            if(s_arvalid&&s_arready)begin
                s_rvalid<=1;s_rresp<=0;s_rdata<=0;
                if(ra[1:0])s_rresp<=2'b11;
                else if(ra>='h040&&ra<='h050)begin
                    if(valid)s_rdata<=head[((ra-'h040)>>2)*32+:32];else s_rresp<=2'b10;
                end else case(ra)
                    'h000:s_rdata<=32'h54415031;
                    'h004:s_rdata<=32'h00010001;
                    'h008:s_rdata<={28'd0,state_csr[1],valid,ready,(state_csr[0]||started_csr!=retired_count)};
                    'h010:s_rdata<=staged_w;
                    'h014:s_rdata<=staged_h;
                    'h018:s_rdata<=300000000;
                    'h020:s_rdata<=drops_csr;
                    'h024:s_rdata<=started_csr;
                    'h02c:s_rdata<=retired_count;
                    'h030:s_rdata<=reset_n;
                    'h060:begin s_rdata<=ticks_csr[31:0];latched_high<=ticks_csr[63:32];end
                    'h064:s_rdata<=latched_high;
                    'h068:s_rdata<=stop_requested;
                    'h06c:s_rdata<=stop_ack_csr;
                    default:s_rresp<=2'b11;
                endcase
            end
        end
    end
endmodule
`default_nettype wire
