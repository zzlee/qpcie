`default_nettype none
// PS-DDR contiguous-segment -> PCIe variable packet DMA. Source/destination
// starts are 16-byte aligned; byte length is arbitrary. Software can split
// host SG at aligned segment boundaries and preserve AU flags/sequence/PTS.
// Each job ends with a separate 64-byte host completion record, not a NAL header.
`timescale 1ns/1ps
module sc7f0_ps_packet_reader(
    input wire clk,rst_n,
    input wire [767:0] cmd_data,input wire cmd_valid,output wire cmd_ready,
    output reg [511:0] done_data,output reg done_valid,input wire done_ready,
    output wire busy,
    output reg [39:0] araddr,output reg [7:0] arlen,
    output wire [2:0] arsize,output wire [1:0] arburst,
    output wire arvalid,input wire arready,
    input wire [127:0] rdata,input wire [1:0] rresp,
    input wire rlast,rvalid,output wire rready,
    output wire tx_valid,input wire tx_ready,
    output reg [63:0] tx_addr,output reg [10:0] tx_dw_len,
    output reg [3:0] tx_first_be,tx_last_be,
    output reg [2047:0] tx_payload,input wire tx_done,
    output wire packet_done_pulse,
    output wire packet_err_pulse,
    output wire [31:0] packet_last_len,
    output wire [63:0] packet_last_pts,
    output wire [7:0]  packet_fsm_state
);
    localparam IDLE=0,PREP=1,AR=2,READ=3,SEND=4,WAIT=5,RECORD=6,REPORT=7;
    reg [3:0] state;
    reg [767:0] job;
    reg [63:0] source,destination;
    reg [31:0] remaining,transferred,error;
    reg [8:0] chunk_bytes;
    reg [4:0] read_beats,read_index;
    reg sending_record;
    wire [63:0] csrc=cmd_data[63:0],cdst=cmd_data[127:64],ccomp=cmd_data[255:192];
    wire [31:0] clen=cmd_data[159:128],ccap=cmd_data[191:160];
    wire [64:0] src_end={1'b0,csrc}+clen,dst_end={1'b0,cdst}+clen;
    wire [64:0] comp_end={1'b0,ccomp}+64;
    wire cmd_ok=!csrc[63:40]&&!csrc[3:0]&&!cdst[3:0]&&!ccomp[3:0]&&ccomp!=0 &&
        clen<=ccap&&clen<=32'h00800000 && src_end<65'h10000000000 &&
        !dst_end[64]&&!comp_end[64]&&(clen!=0||cmd_data[518]); // flags[6]=EOS
    assign cmd_ready=state==IDLE&&!done_valid;
    assign busy=state!=IDLE||done_valid;
    assign packet_done_pulse = (state == REPORT && !done_valid);
    assign packet_err_pulse  = (state == REPORT && !done_valid && (error != 0));
    assign packet_last_len   = transferred;
    assign packet_last_pts   = job[319:256];
    assign packet_fsm_state  = {1'b0, done_valid, cmd_ready, busy, state[3:0]};
    assign arsize=3'd4;assign arburst=2'b01;
    assign arvalid=state==AR;
    assign rready=state==READ;
    assign tx_valid=state==SEND;
    reg [31:0] next_chunk;
    always @* begin
        next_chunk=remaining;
        if(next_chunk>256)next_chunk=256;
        if(next_chunk>(4096-{20'd0,source[11:0]}))next_chunk=4096-{20'd0,source[11:0]};
        if(next_chunk>(4096-{20'd0,destination[11:0]}))next_chunk=4096-{20'd0,destination[11:0]};
    end
    wire [511:0] completion={job[671:640],job[639:608],job[607:576],job[575:544],
        job[543:512],transferred,job[383:320],job[319:256],job[511:448],job[447:384],
        error,32'h44504331}; // DPC1
    always @(posedge clk)begin
        if(!rst_n)begin
            state<=IDLE;job<=0;source<=0;destination<=0;remaining<=0;
            transferred<=0;error<=0;chunk_bytes<=0;read_beats<=0;read_index<=0;
            sending_record<=0;araddr<=0;arlen<=0;tx_addr<=0;tx_dw_len<=0;
            tx_first_be<=0;tx_last_be<=0;tx_payload<=0;done_data<=0;done_valid<=0;
        end else begin
            if(done_valid&&done_ready)done_valid<=0;
            case(state)
                IDLE:if(cmd_valid&&cmd_ready)begin
                    job<=cmd_data;source<=csrc;destination<=cdst;remaining<=clen;
                    transferred<=0;error<=cmd_ok?0:1;sending_record<=0;
                    // Invalid pointers never result in a host/DDR write.
                    state<=cmd_ok?(clen==0?RECORD:PREP):REPORT;
                end
                PREP:begin
                    chunk_bytes<=next_chunk[8:0];read_beats<=(next_chunk+15)>>4;
                    read_index<=0;tx_payload<=0;
                    araddr<=source[39:0];arlen<=((next_chunk+15)>>4)-1;
                    tx_addr<=destination;tx_dw_len<=(next_chunk+3)>>2;
                    tx_first_be<=next_chunk<4?((1<<next_chunk)-1):4'hf;
                    tx_last_be<=next_chunk<=4?0:next_chunk[1:0]==0?4'hf:((1<<next_chunk[1:0])-1);
                    state<=AR;
                end
                AR:if(arready)state<=READ;
                READ:if(rvalid)begin
                    if(read_index<16)tx_payload[read_index*128+:128]<=rdata;
                    if(rresp!=0)error<=error|2;
                    if(rlast!=(read_index+1==read_beats))error<=error|4;
                    read_index<=read_index+1'b1;
                    // Drain a short/long AXI response to RLAST before reporting.
                    if(rlast)begin
                        if(rresp!=0||error!=0||read_index+1!=read_beats)state<=RECORD;
                        else state<=SEND;
                    end
                end
                SEND:if(tx_ready)state<=WAIT;
                WAIT:if(tx_done)begin
                    if(sending_record)state<=REPORT;
                    else begin
                        transferred<=transferred+chunk_bytes;
                        remaining<=remaining-chunk_bytes;
                        source<=source+chunk_bytes;destination<=destination+chunk_bytes;
                        state<=remaining==chunk_bytes?RECORD:PREP;
                    end
                end
                RECORD:begin
                    sending_record<=1;tx_addr<=job[255:192];tx_dw_len<=16;
                    tx_first_be<=4'hf;tx_last_be<=4'hf;
                    tx_payload<={1536'd0,completion};state<=SEND;
                end
                REPORT:begin
                    if(!done_valid)begin done_data<=completion;done_valid<=1;end
                    if(done_valid&&done_ready)state<=IDLE;
                end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
