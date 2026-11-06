`default_nettype none
// PS AXI-Lite extension @ 0xb0040000, ABI DPV1. Independent AW/W capture.
// Doorbells snapshot staging words atomically into ordered command queues.
// Completion heads stay stable across multiword reads until explicit POP.
`timescale 1ns/1ps
module sc7f0_dualpath_regs #(parameter HAS_LEGACY_CAPTURE=1)(
    input wire clk,rst_n,
    input wire [31:0] s_awaddr,input wire s_awvalid,output wire s_awready,
    input wire [31:0] s_wdata,input wire [3:0] s_wstrb,input wire s_wvalid,output wire s_wready,
    output reg [1:0] s_bresp,output reg s_bvalid,input wire s_bready,
    input wire [31:0] s_araddr,input wire s_arvalid,output wire s_arready,
    output reg [31:0] s_rdata,output reg [1:0] s_rresp,output reg s_rvalid,input wire s_rready,
    output reg [255:0] frame_cmd,output reg frame_push,input wire frame_ready,
    input wire [255:0] frame_done,input wire frame_valid,output reg frame_pop,
    output reg [767:0] packet_cmd,output reg packet_push,input wire packet_ready,
    input wire [511:0] packet_done,input wire packet_valid,output reg packet_pop,
    input wire [1:0] engine_busy,input wire [31:0] dropped_frames,
    input wire [31:0] probe_pkt_submit_cnt,
    input wire [31:0] probe_pkt_done_cnt,
    input wire [31:0] probe_pkt_err_cnt,
    input wire [31:0] probe_pkt_msi_cnt,
    input wire [31:0] probe_pkt_bytes_lo,
    input wire [31:0] probe_pkt_bytes_hi,
    input wire [31:0] probe_pkt_fsm_state,
    input wire [31:0] probe_pkt_last_len,
    input wire [31:0] probe_pkt_last_pts_lo,
    input wire [31:0] probe_pkt_last_pts_hi
);
    reg [31:0] frame_stage[0:7],packet_stage[0:23];
    reg aw_have,w_have;reg [11:0] aw;reg [31:0] wd;reg [3:0] ws;
    assign s_awready=!aw_have&&!s_bvalid;
    assign s_wready=!w_have&&!s_bvalid;
    assign s_arready=!s_rvalid;
    integer i,j;
    wire [11:0] ra=s_araddr[11:0];
    always @(posedge clk)begin
        if(!rst_n)begin
            aw_have<=0;w_have<=0;aw<=0;wd<=0;ws<=0;s_bresp<=0;s_bvalid<=0;
            s_rdata<=0;s_rresp<=0;s_rvalid<=0;frame_cmd<=0;packet_cmd<=0;
            frame_push<=0;packet_push<=0;frame_pop<=0;packet_pop<=0;
            for(i=0;i<8;i=i+1)frame_stage[i]<=0;
            for(i=0;i<24;i=i+1)packet_stage[i]<=0;
        end else begin
            frame_push<=0;packet_push<=0;frame_pop<=0;packet_pop<=0;
            if(s_awvalid&&s_awready)begin aw<=s_awaddr[11:0];aw_have<=1;end
            if(s_wvalid&&s_wready)begin wd<=s_wdata;ws<=s_wstrb;w_have<=1;end
            if(s_bvalid&&s_bready)s_bvalid<=0;
            if(aw_have&&w_have&&!s_bvalid)begin
                s_bvalid<=1;s_bresp<=0;aw_have<=0;w_have<=0;
                if(aw[1:0]!=0)s_bresp<=2'b11;
                else if(aw>=12'h040&&aw<12'h060)begin
                    for(j=0;j<4;j=j+1)if(ws[j])frame_stage[(aw-12'h040)>>2][j*8+:8]<=wd[j*8+:8];
                end else if(aw>=12'h080&&aw<12'h0e0)begin
                    for(j=0;j<4;j=j+1)if(ws[j])packet_stage[(aw-12'h080)>>2][j*8+:8]<=wd[j*8+:8];
                end else if(ws[0]&&wd[0])case(aw)
                    12'h00c:if(frame_ready)begin
                        for(i=0;i<8;i=i+1)frame_cmd[i*32+:32]<=frame_stage[i];
                        frame_push<=1;
                    end else s_bresp<=2'b10;
                    12'h010:if(frame_valid)frame_pop<=1;else s_bresp<=2'b10;
                    12'h014:if(packet_ready)begin
                        for(i=0;i<24;i=i+1)packet_cmd[i*32+:32]<=packet_stage[i];
                        packet_push<=1;
                    end else s_bresp<=2'b10;
                    12'h018:if(packet_valid)packet_pop<=1;else s_bresp<=2'b10;
                    default:s_bresp<=2'b11;
                endcase
                else s_bresp<=2'b10;
            end
            if(s_rvalid&&s_rready)s_rvalid<=0;
            if(s_arvalid&&s_arready)begin
                s_rvalid<=1;s_rresp<=0;s_rdata<=0;
                if(ra[1:0]!=0)s_rresp<=2'b11;
                else if(ra>=12'h040&&ra<12'h060)s_rdata<=frame_stage[(ra-12'h040)>>2];
                else if(ra>=12'h080&&ra<12'h0e0)s_rdata<=packet_stage[(ra-12'h080)>>2];
                else if(ra>=12'h200&&ra<12'h220)begin
                    if(frame_valid)s_rdata<=frame_done[((ra-12'h200)>>2)*32+:32];
                    else s_rresp<=2'b10;
                end else if(ra>=12'h240&&ra<12'h280)begin
                    if(packet_valid)s_rdata<=packet_done[((ra-12'h240)>>2)*32+:32];
                    else s_rresp<=2'b10;
                end else case(ra)
                    12'h000:s_rdata<=32'h44505631; // DPV1
                    12'h004:s_rdata<=32'h00010000;
                    12'h008:s_rdata<={26'd0,engine_busy,packet_valid,frame_valid,packet_ready,frame_ready};
                    12'h01c:s_rdata<=32'd150000000; // capture clock ticks/sec
                    12'h020:s_rdata<=dropped_frames;
                    12'h024:s_rdata<=HAS_LEGACY_CAPTURE?32'h00000007:32'h00000006; // legacy frame capture; packet DMA; host completion
                    12'h100:s_rdata<=probe_pkt_submit_cnt;
                    12'h104:s_rdata<=probe_pkt_done_cnt;
                    12'h108:s_rdata<=probe_pkt_err_cnt;
                    12'h10c:s_rdata<=probe_pkt_msi_cnt;
                    12'h110:s_rdata<=probe_pkt_bytes_lo;
                    12'h114:s_rdata<=probe_pkt_bytes_hi;
                    12'h118:s_rdata<=probe_pkt_fsm_state;
                    12'h11c:s_rdata<=probe_pkt_last_len;
                    12'h120:s_rdata<=probe_pkt_last_pts_lo;
                    12'h124:s_rdata<=probe_pkt_last_pts_hi;
                    default:s_rresp<=2'b11;
                endcase
            end
        end
    end
endmodule
`default_nettype wire
