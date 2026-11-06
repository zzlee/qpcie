`default_nettype none
`timescale 1ns/1ps
// Observe already-accepted RX beats; deliberately NO upstream READY port.
// An admitted frame always finishes downstream. Overflow/stop/source gaps
// produce filler with error metadata, never an AXI reset or a truncated frame.
module sc7f0_frame_tap #(
    parameter FIFO_DEPTH=512, GAP_CYCLES=1500000
)(
    input wire s_clk,s_rst_n,input wire [95:0] s_data,
    input wire s_valid,s_sof,s_eol,
    input wire m_clk,m_rst_n,enable,input wire [15:0] width,height,
    input wire credit_valid,credit_clear,input wire [15:0] credit_add,
    output reg [31:0] started_count,
    output reg [95:0] m_data,output reg m_valid,m_sof,m_eol,input wire m_ready,
    output reg [159:0] meta_data,output reg meta_valid,input wire meta_ready,
    output wire busy,output wire [31:0] dropped_frames,
    output reg [63:0] ticks,output wire [63:0] ticks_gray
);
    (* DONT_TOUCH="TRUE" *) reg [63:0] gray_q;
    assign ticks_gray=gray_q;
    wire [63:0] next_tick=ticks+1'b1;
    always @(posedge m_clk)begin
        if(!m_rst_n)begin ticks<=0;gray_q<=0;end
        else begin ticks<=next_tick;gray_q<=next_tick^(next_tick>>1);end
    end
    // xpm_cdc_gray supports at most32 bits. This explicit64-bit Gray CDC
    // has no vendor blanket false-path, so board delay/skew constraints apply.
    wire [63:0] source_ticks;
    wire source_enable,want_source;
    sc7f0_gray64_sync u_source_time(
        .clk(s_clk),.rst_n(s_rst_n),.gray(ticks_gray),.binary(source_ticks));
    xpm_cdc_single #(.DEST_SYNC_FF(4),.SRC_INPUT_REG(1)) u_enable(
        .src_clk(m_clk),.src_in(want_source),.dest_clk(s_clk),.dest_out(source_enable));
    reg [31:0] source_id,source_drops;
    reg [21:0] source_index;
    reg admitted;
    wire [31:0] incoming_id=s_sof?source_id+1'b1:source_id;
    wire [21:0] incoming_index=s_sof?22'd0:source_index;
    wire pwready,hwready,pvalid,hvalid,ppop,hpop;
    wire [150:0] pdata;
    wire [95:0] hdata;
    wire accept_sof=s_valid&&s_sof&&source_enable&&pwready&&hwready;
    wire write_pixel=s_valid&&(accept_sof||(!s_sof&&admitted&&source_enable));
    always @(posedge s_clk)begin
        if(!s_rst_n)begin source_id<=0;source_drops<=0;source_index<=0;admitted<=0;end
        else if(s_valid)begin
            source_index<=incoming_index+1'b1;
            if(s_sof)begin
                source_id<=incoming_id;admitted<=accept_sof;
                if(source_enable&&!accept_sof)source_drops<=source_drops+1'b1;
            end else if(admitted&&(!pwready||!source_enable))begin
                admitted<=0;source_drops<=source_drops+1'b1;
            end
        end
    end
    sc7f0_dp_fifo #(.WIDTH(151),.DEPTH(FIFO_DEPTH),.MEMORY("block")) u_pixels(
        .wclk(s_clk),.wrst_n(s_rst_n),.wdata({incoming_id,incoming_index,s_eol,s_data}),
        .wvalid(write_pixel),.wready(pwready),.rclk(m_clk),.rrst_n(m_rst_n),
        .rdata(pdata),.rvalid(pvalid),.rready(ppop));
    sc7f0_dp_fifo #(.WIDTH(96),.DEPTH(16)) u_headers(
        .wclk(s_clk),.wrst_n(s_rst_n),.wdata({incoming_id,source_ticks}),
        .wvalid(accept_sof),.wready(hwready),.rclk(m_clk),.rrst_n(m_rst_n),
        .rdata(hdata),.rvalid(hvalid),.rready(hpop));
    wire [31:0] current_source;
    xpm_cdc_gray #(.WIDTH(32),.DEST_SYNC_FF(4),.REG_OUTPUT(1)) u_source_id(
        .src_clk(s_clk),.src_in_bin(source_id),.dest_clk(m_clk),.dest_out_bin(current_source));
    xpm_cdc_gray #(.WIDTH(32),.DEST_SYNC_FF(4),.REG_OUTPUT(1)) u_drop_count(
        .src_clk(s_clk),.src_in_bin(source_drops),.dest_clk(m_clk),.dest_out_bin(dropped_frames));
    wire source_reset;
    xpm_cdc_async_rst #(.DEST_SYNC_FF(4),.RST_ACTIVE_HIGH(1)) u_source_reset(
        .src_arst(!s_rst_n),.dest_clk(m_clk),.dest_arst(source_reset));
    reg active,all_queued,filling,out_last,retired_valid;
    reg [31:0] credits;
    assign want_source=enable&&(credits!=0||active);
    reg [31:0] frame_id,flags,out_flags,retired_id;
    reg [63:0] sof_ticks;
    reg [15:0] frame_width,frame_height,xword;
    reg [21:0] expected,total_words;
    reg [31:0] gap;
    wire slot=!m_valid||m_ready;
    wire [31:0] pixel_id=pdata[150:119];
    wire [21:0] pixel_index=pdata[118:97];
    wire signed [31:0] id_delta=$signed(pixel_id-frame_id);
    wire stale=pvalid&&(id_delta<0||(id_delta==0&&pixel_index<expected));
    wire real_word=pvalid&&id_delta==0&&pixel_index==expected;
    wire future_word=pvalid&&(id_delta>0||(id_delta==0&&pixel_index>expected));
    wire source_advanced=$signed(current_source-frame_id)>0;
    wire force_fill=filling||!enable||source_reset||future_word||gap>=GAP_CYCLES||(!pvalid&&source_advanced);
    wire generate_word=active&&!all_queued&&(real_word||force_fill);
    wire expected_eol=xword==(frame_width>>2)-1;
    wire mismatch=real_word&&!force_fill&&(pdata[96]!=expected_eol);
    wire [31:0] next_flags=flags|(force_fill?32'd1:32'd0)|(mismatch?32'd2:32'd0)|(!enable?32'd4:32'd0)|(source_reset?32'd8:32'd0);
    assign busy=active||m_valid;
    assign hpop=((!enable||credits==0)&&!active&&!m_valid)||
        (!active&&!m_valid&&enable&&!credit_clear&&credits!=0&&!source_reset&&(!meta_valid||meta_ready)&&
         width>=64&&width<=4096&&height>=64&&height<=2160&&width[1:0]==0);
    assign ppop=((!enable||credits==0)&&!active&&!m_valid)||
        (!active&&!m_valid&&retired_valid&&$signed(pixel_id-retired_id)<=0)||
        (active&&!all_queued&&slot&&(stale||(real_word&&!force_fill)));
    always @(posedge m_clk)begin
        if(!m_rst_n)begin
            active<=0;all_queued<=0;filling<=0;out_last<=0;frame_id<=0;flags<=0;out_flags<=0;
            retired_valid<=0;retired_id<=0;credits<=0;started_count<=0;
            sof_ticks<=0;frame_width<=0;frame_height<=0;xword<=0;expected<=0;total_words<=0;gap<=0;
            m_valid<=0;m_data<=0;m_sof<=0;m_eol<=0;meta_valid<=0;meta_data<=0;
        end else begin
            if(meta_valid&&meta_ready)meta_valid<=0;
            if(credit_clear)credits<=0;
            else if(credit_valid)credits<=credits+credit_add;
            if(source_reset||!enable)retired_valid<=0;
            if(!active&&!m_valid&&hvalid&&hpop&&(!enable||credits==0)&&!source_reset)begin
                retired_id<=hdata[95:64];retired_valid<=1;
            end
            if(source_reset&&active)begin flags<=flags|32'd8;filling<=1;end
            if(m_valid&&m_ready)begin
                m_valid<=0;
                if(out_last)begin
                    active<=0;all_queued<=0;
                    meta_data<={frame_height,frame_width,out_flags|flags|(source_reset?32'd8:32'd0)|(!enable?32'd4:32'd0),frame_id,sof_ticks};meta_valid<=1;
                    retired_id<=frame_id;retired_valid<=enable&&!source_reset&&!flags[3];
                end
            end
            if(!active&&!m_valid&&hvalid&&hpop&&enable&&credits!=0&&!credit_clear)begin
                credits<=credits+(credit_valid?credit_add:16'd0)-1'b1;started_count<=started_count+1'b1;
                active<=1;all_queued<=0;filling<=0;expected<=0;xword<=0;flags<=0;gap<=0;
                frame_id<=hdata[95:64];sof_ticks<=hdata[63:0];
                frame_width<=width;frame_height<=height;total_words<=({16'd0,width}*{16'd0,height})>>2;
            end
            if(active&&!all_queued&&slot)begin
                if(!generate_word)begin if(gap<GAP_CYCLES)gap<=gap+1'b1;end
                else begin
                    gap<=0;m_valid<=1;m_data<=force_fill?96'd0:pdata[95:0];
                    m_sof<=expected==0;m_eol<=expected_eol;
                    out_last<=expected==total_words-1;out_flags<=next_flags;flags<=next_flags;
                    if(force_fill)filling<=1;
                    if(expected==total_words-1)all_queued<=1;
                    else begin expected<=expected+1'b1;if(expected_eol)xword<=0;else xword<=xword+1'b1;end
                end
            end
        end
    end
endmodule
`default_nettype wire
