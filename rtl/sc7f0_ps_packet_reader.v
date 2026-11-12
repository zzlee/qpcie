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
    reg last_chunk;
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
    // -----------------------------------------------------------------------
    // Chunk geometry.  300 MHz critical cone: the routed WNS holder of round
    // 26111202 was remaining_reg[10] -> tx_last_be_reg[2] (-0.225 ns, 12 logic
    // levels, 2 CARRY8), i.e. three serial 32-bit clamp compares feeding a set
    // of derived fields, all in one cycle.
    //
    // Contract is UNCHANGED: chunk = min(remaining, 256, 4096-source[11:0],
    //                                    4096-destination[11:0]).
    // Equivalent rewrite only:
    //  * the result is always <= 256, so clamping each 4 KiB room to 256 is
    //    lossless, and min() is associative/commutative -> three independent
    //    9-bit clamps plus a balanced min replace the serial 32-bit chain;
    //  * a room >= 256 is detected from the page offset without a subtract
    //    (4096-off >= 256  <=>  off[7:0]==0 || off[11:8]!=F), and the exact
    //    room for off in 0xF01..0xFFF is the 9-bit two's complement of
    //    off[8:0] because (4096-off) mod 512 == off[8:0] negated;
    //  * beat counts use the same identity in 16 byte units:
    //    ceil(min(x,y,z)/16)-1 == min(ceil(x/16)-1, ceil(y/16)-1, ...).
    //    A non-final chunk is always a multiple of 16 (all three caps are, and
    //    a non-multiple can only come from the `remaining` cap, which then ends
    //    the job), so source[3:0]==destination[3:0]==0 - already required by
    //    cmd_ok - is preserved for every cycle that reaches PREP/AR.
    // No state, no latency and no interface/protocol change is introduced.
    // -----------------------------------------------------------------------
    wire src_room_cap=!(|source[7:0])||(|(~source[11:8]));
    wire dst_room_cap=!(|destination[7:0])||(|(~destination[11:8]));
    wire [8:0] src_room=src_room_cap?9'd256:~source[8:0]+9'd1;
    wire [8:0] dst_room=dst_room_cap?9'd256:~destination[8:0]+9'd1;
    wire [8:0] rem_cap=|remaining[31:8]?9'd256:remaining[8:0];
    wire [8:0] room_min=src_room<dst_room?src_room:dst_room;
    wire [8:0] next_chunk=rem_cap<room_min?rem_cap:room_min;
    // beats-1 per clamp (ceil(c/16)-1); the room terms are saturated at 15,
    // which the outer min makes exact because the 256 byte cap is 16 beats.
    wire [4:0] rem_beats_m1=|remaining[31:9]?5'd15:
        remaining[8:4]-{4'd0,~(|remaining[3:0])};
    wire [7:0] src_k_inv=~source[11:4],dst_k_inv=~destination[11:4];
    // ceil(room/16)-1 = 255-k for page index k; saturate at 15 (the 256 byte
    // cap) whenever k <= 0xEF, i.e. whenever 255-k would exceed 15.
    wire [4:0] src_beats_m1=(|(~source[11:8]))?5'd15:{1'b0,src_k_inv[3:0]};
    wire [4:0] dst_beats_m1=(|(~destination[11:8]))?5'd15:{1'b0,dst_k_inv[3:0]};
    wire [4:0] room_beats_m1=src_beats_m1<dst_beats_m1?src_beats_m1:dst_beats_m1;
    wire [4:0] next_beats_m1=rem_beats_m1<room_beats_m1?rem_beats_m1:room_beats_m1;
    // ceil(chunk/4) as a carry-free sum: (cb+3)>>2 == cb[8:2] + |cb[1:0]
    wire [10:0] chunk_dw={2'd0,chunk_bytes[8:2]}+{10'd0,(|chunk_bytes[1:0])};
    wire [511:0] completion={job[671:640],job[639:608],job[607:576],job[575:544],
        job[543:512],transferred,job[383:320],job[319:256],job[511:448],job[447:384],
        error,32'h44504331}; // DPC1
    always @(posedge clk)begin
        if(!rst_n)begin
            state<=IDLE;job<=0;source<=0;destination<=0;remaining<=0;
            transferred<=0;error<=0;chunk_bytes<=0;read_beats<=0;read_index<=0;
            last_chunk<=0;sending_record<=0;araddr<=0;arlen<=0;tx_addr<=0;tx_dw_len<=0;
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
                    // PREP now produces only the chunk size and the AXI burst
                    // length, both straight off the parallel min.
                    chunk_bytes<=next_chunk;read_index<=0;tx_payload<=0;
                    araddr<=source[39:0];arlen<=next_beats_m1;
                    state<=AR;
                end
                AR:if(arready)begin
                    // Retimed, not redefined.  tx_* and read_beats are consumed
                    // no earlier than SEND (tx_valid=state==SEND, and READ needs
                    // at least one rvalid cycle), so they are registered one
                    // cycle later than before, from the *registered* chunk size
                    // instead of the combinational min chain.  The expressions
                    // are the previous ones, verbatim, with chunk_bytes/arlen in
                    // place of next_chunk: identical values, ~3 logic levels
                    // instead of 12.
                    read_beats<={1'b0,arlen[3:0]}+5'd1;
                    tx_addr<=destination;tx_dw_len<=chunk_dw;
                    tx_first_be<=chunk_bytes<4?((1<<chunk_bytes[1:0])-1):4'hf;
                    tx_last_be<=chunk_bytes<=4?0:chunk_bytes[1:0]==0?4'hf:((1<<chunk_bytes[1:0])-1);
                    // chunk_bytes == remaining, i.e. this packet ends the job.
                    // Captured while remaining/chunk_bytes are still untouched
                    // (both only change in WAIT), so it replaces the 32-bit
                    // compare that used to sit on the WAIT -> state decode.
                    last_chunk<=!(|remaining[31:9])&&remaining[8:0]==chunk_bytes;
                    state<=READ;
                end
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
                        state<=last_chunk?RECORD:PREP;
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
