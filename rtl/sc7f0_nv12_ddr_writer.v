`default_nettype none
// Independent 4-PPC YUV444 -> NV12 PS-DDR capture. Input never backpressures
// HDMI/raw capture. Buffer overflow/malformed raster invalidates THIS frame;
// completion is not published until every accepted AXI write has a B response.
// CMD: Y64, UV64, {height16,width16}, stride32, cookie32, reserved32.
// DONE (low first): pts64, source_frame64, cookie32, status32, bytes32, reserved32.
`timescale 1ns/1ps
module sc7f0_nv12_ddr_writer(
    input wire clk,rst_n,
    input wire [127:0] video_data, input wire video_valid,video_sof,video_eol,
    input wire [255:0] cmd_data, input wire cmd_valid, output wire cmd_ready,
    output reg [255:0] done_data, output reg done_valid,input wire done_ready,
    output wire busy, output reg [31:0] dropped_frames,
    output reg [39:0] awaddr,output reg [7:0] awlen,output wire [2:0] awsize,
    output wire [1:0] awburst,output wire awvalid,input wire awready,
    output wire [127:0] wdata,output wire [15:0] wstrb,
    output wire wlast,wvalid,input wire wready,
    input wire [1:0] bresp,input wire bvalid,output wire bready
);
    reg owned,capturing,input_done;
    reg [15:0] width,height;
    reg [31:0] stride,cookie,status,byte_count,produced_bytes,expected_bytes;
    reg [39:0] ybase,uvbase,yline,uvline;
    reg [10:0] group_index;
    reg [15:0] row;
    reg [63:0] ticks,source_frames,frame_id,pts;
    reg p_valid,p_last;
    reg [9:0] p_group;
    reg p_odd;
    reg [39:0] p_yaddr,p_uvaddr;
    reg [31:0] p_y;
    reg [35:0] p_uv,previous_uv;
    (* ram_style="block" *) reg [35:0] chroma_line[0:1023];
    reg [95:0] ypack,uvpack;
    wire [15:0] cw=cmd_data[143:128],ch=cmd_data[159:144];
    wire [31:0] cs=cmd_data[191:160];
    wire [63:0] cy=cmd_data[63:0],cu=cmd_data[127:64];
    wire [47:0] yspan=cs*ch,uvspan=cs*(ch>>1);
    wire [64:0] yend={1'b0,cy}+yspan,uvend={1'b0,cu}+uvspan;
    wire config_ok=cw>=16 && cw<=4096 && !cw[3:0] &&
        ch>=2 && ch<=2160 && !ch[0] && cs>=cw && cs<=65520 && !cs[3:0] &&
        !cy[63:40] && !cu[63:40] && !cy[3:0] && !cu[3:0] &&
        yend<65'h10000000000 && uvend<65'h10000000000 &&
        (yend<={1'b0,cu} || uvend<={1'b0,cy}) && !cmd_data[255:224];
    assign busy=owned;
    assign cmd_ready=!owned && !done_valid;
    wire start=video_valid&&video_sof&&owned&&!capturing&&!input_done&&status==0;
    wire unexpected_sof=video_valid&&video_sof&&capturing;
    wire accept_pixel=video_valid&&(capturing||start)&&!unexpected_sof&&status==0;
    wire [10:0] g=start?11'd0:group_index;
    wire [15:0] r=start?16'd0:row;
    wire line_end=(g==((width>>2)-1));
    wire geometry_bad=accept_pixel&&(video_eol!=line_end);
    wire [8:0] su0={1'b0,video_data[15:8]}+{1'b0,video_data[47:40]};
    wire [8:0] sv0={1'b0,video_data[23:16]}+{1'b0,video_data[55:48]};
    wire [8:0] su1={1'b0,video_data[79:72]}+{1'b0,video_data[111:104]};
    wire [8:0] sv1={1'b0,video_data[87:80]}+{1'b0,video_data[119:112]};
    wire [9:0] au0={1'b0,p_uv[8:0]}+{1'b0,previous_uv[8:0]}+10'd2;
    wire [9:0] av0={1'b0,p_uv[17:9]}+{1'b0,previous_uv[17:9]}+10'd2;
    wire [9:0] au1={1'b0,p_uv[26:18]}+{1'b0,previous_uv[26:18]}+10'd2;
    wire [9:0] av1={1'b0,p_uv[35:27]}+{1'b0,previous_uv[35:27]}+10'd2;
    wire [31:0] uv_bytes={av1[9:2],au1[9:2],av0[9:2],au0[9:2]};
    wire word_end=p_valid&&p_group[1:0]==3;
    wire yf_full,uf_full,yf_empty,uf_empty;
    wire [176:0] yf_data,uf_data;
    wire [9:0] yf_count;
    wire [8:0] uf_count;
    wire overflow=word_end&&status==0&&(yf_full||(p_odd&&uf_full));
    wire push_y=word_end&&status==0&&!overflow;
    wire push_uv=push_y&&p_odd;
    wire [8:0] line_words_left=(width>>4)-(p_group>>2);
    wire [176:0] yentry={line_words_left,p_yaddr-40'd12,p_y,ypack};
    wire [176:0] uentry={line_words_left,p_uvaddr-40'd12,uv_bytes,uvpack};
    reg select_uv,last_uv;
    localparam IDLE=0,ADDR=1,DATA=2,RESP=3;
    reg [1:0] state;
    reg [4:0] beats_left;
    wire [176:0] selected_data=select_uv?uf_data:yf_data;
    wire take_w=wvalid&&wready;
    sc7f0_dp_sync_fifo #(.WIDTH(177),.DEPTH(512)) u_y(
        .clk(clk),.rst_n(rst_n),.din(yentry),.push(push_y),.full(yf_full),
        .dout(yf_data),.pop(take_w&&!select_uv),.empty(yf_empty),.count(yf_count));
    sc7f0_dp_sync_fifo #(.WIDTH(177),.DEPTH(256)) u_uv(
        .clk(clk),.rst_n(rst_n),.din(uentry),.push(push_uv),.full(uf_full),
        .dout(uf_data),.pop(take_w&&select_uv),.empty(uf_empty),.count(uf_count));
    assign awsize=3'd4; assign awburst=2'b01;
    assign awvalid=state==ADDR;
    assign wdata=selected_data[127:0]; assign wstrb=16'hffff;
    assign wvalid=state==DATA && !(select_uv?uf_empty:yf_empty);
    assign wlast=beats_left==1;
    assign bready=state==RESP;
    wire y_available=!yf_empty&&(yf_count>=16||input_done);
    wire uv_available=!uf_empty&&(uf_count>=16||input_done);
    wire choose_uv=uv_available&&(!y_available||!last_uv);
    wire [176:0] first_word=choose_uv?uf_data:yf_data;
    wire [9:0] available_words=choose_uv?{1'b0,uf_count}:yf_count;
    wire [8:0] page_words=9'd256-{1'b0,first_word[139:132]};
    reg [8:0] burst_words;
    always @* begin
        burst_words=16;
        if(first_word[176:168]<burst_words) burst_words=first_word[176:168];
        if(page_words<burst_words) burst_words=page_words;
        if(available_words<burst_words) burst_words=available_words;
    end
    // Sync BRAM read: odd-line chroma and associated pixel fields have the
    // same one-cycle latency. No asynchronous BRAM output into colour maths.
    always @(posedge clk) begin
        if(accept_pixel) begin
            if(!r[0]) chroma_line[g[9:0]]<={sv1,su1,sv0,su0};
            else previous_uv<=chroma_line[g[9:0]];
        end
    end
    always @(posedge clk) begin
        if(!rst_n) begin
            owned<=0;capturing<=0;input_done<=0;done_valid<=0;done_data<=0;
            width<=0;height<=0;stride<=0;cookie<=0;status<=0;byte_count<=0;produced_bytes<=0;expected_bytes<=0;
            ybase<=0;uvbase<=0;yline<=0;uvline<=0;group_index<=0;row<=0;
            ticks<=0;source_frames<=0;frame_id<=0;pts<=0;dropped_frames<=0;
            p_valid<=0;p_last<=0;p_group<=0;p_odd<=0;p_yaddr<=0;p_uvaddr<=0;
            p_y<=0;p_uv<=0;ypack<=0;uvpack<=0;
            state<=IDLE;awaddr<=0;awlen<=0;beats_left<=0;select_uv<=0;last_uv<=0;
        end else begin
            ticks<=ticks+1'b1;
            if(video_valid&&video_sof) begin
                source_frames<=source_frames+1'b1;
                if(!start) dropped_frames<=dropped_frames+1'b1;
            end
            if(done_valid&&done_ready) begin done_valid<=0;owned<=0;end
            if(cmd_valid&&cmd_ready) begin
                owned<=1;capturing<=0;input_done<=!config_ok;
                width<=cw;height<=ch;stride<=cs;cookie<=cmd_data[223:192];
                row<=0;group_index<=0;expected_bytes<=(cw*ch)*3/2;
                ybase<=cy[39:0];uvbase<=cu[39:0];yline<=cy[39:0];uvline<=cu[39:0];
                status<=config_ok?0:1;byte_count<=0;produced_bytes<=0;pts<=0;frame_id<=0;
                ypack<=0;uvpack<=0;
            end
            p_valid<=accept_pixel&&!geometry_bad;
            p_last<=0;
            if(start) begin capturing<=1;row<=0;pts<=ticks;frame_id<=source_frames;end
            if(accept_pixel&&!geometry_bad) begin
                p_group<=g[9:0];p_odd<=r[0];
                p_y<={video_data[103:96],video_data[71:64],video_data[39:32],video_data[7:0]};
                p_uv<={sv1,su1,sv0,su0};
                p_yaddr<=(start?ybase:yline)+{27'd0,g,2'b00};
                p_uvaddr<=uvline+{27'd0,g,2'b00};
                if(line_end) begin
                    group_index<=0;row<=r+1'b1;
                    yline<=(start?ybase:yline)+stride;
                    if(r[0]) uvline<=uvline+stride;
                    if(r==height-1) begin capturing<=0;p_last<=1;end
                end else group_index<=g+1'b1;
            end
            if(p_valid&&status==0) begin
                case(p_group[1:0])
                    0:begin ypack[31:0]<=p_y;if(p_odd)uvpack[31:0]<=uv_bytes;end
                    1:begin ypack[63:32]<=p_y;if(p_odd)uvpack[63:32]<=uv_bytes;end
                    2:begin ypack[95:64]<=p_y;if(p_odd)uvpack[95:64]<=uv_bytes;end
                    default:begin end
                endcase
            end
            if(push_y) produced_bytes<=produced_bytes+(push_uv?32:16);
            if(p_valid&&p_last) input_done<=1;
            if(unexpected_sof||geometry_bad||overflow) begin
                status<=status|32'd2|(overflow?32'd4:32'd0);
                capturing<=0;input_done<=1;p_valid<=0;
            end
            case(state)
                IDLE:if((y_available||uv_available)&&burst_words!=0)begin
                    select_uv<=choose_uv;last_uv<=choose_uv;
                    awaddr<=first_word[167:128];awlen<=burst_words-1'b1;
                    beats_left<=burst_words[4:0];state<=ADDR;
                end
                ADDR:if(awready)state<=DATA;
                DATA:if(take_w)begin
                    byte_count<=byte_count+16;
                    beats_left<=beats_left-1'b1;
                    if(beats_left==1)state<=RESP;
                end
                RESP:if(bvalid)begin
                    state<=IDLE;
                    if(bresp!=0)begin status<=status|32'd8;capturing<=0;input_done<=1;end
                end
            endcase
            if(owned&&input_done&&!p_valid&&yf_empty&&uf_empty&&state==IDLE&&byte_count==produced_bytes&&!done_valid)begin
                done_data<={32'd0,byte_count,
                    (status|((status==0&&byte_count!=expected_bytes)?32'd16:32'd0)),cookie,frame_id,pts};
                done_valid<=1;
            end
        end
    end
endmodule
`default_nettype wire
