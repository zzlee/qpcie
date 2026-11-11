`default_nettype none
// One fully resident TLP at a time. Payload crosses an XPM async FIFO;
// descriptor publication follows payload writes, and read-side occupancy is
// checked before exposing VALID to the non-stallable PCIe packet encoder.
`timescale 1ns/1ps
module sc7f0_packet_cdc(
    input wire s_clk,s_rst_n,
    input wire s_valid,output wire s_ready,
    input wire [63:0] s_addr,input wire [10:0] s_dw_len,
    input wire [3:0] s_first_be,s_last_be,
    input wire [2047:0] s_payload,output wire s_done,
    input wire m_clk,m_rst_n,
    output wire m_valid,output wire [63:0] m_addr,
    output wire [10:0] m_dw_len,output wire [3:0] m_first_be,m_last_be,
    output wire [255:0] m_data,input wire m_data_ready,m_ack
);
    reg [1:0] s_state;
    reg [2047:0] payload;
    reg [82:0] header;
    reg [3:0] write_index,write_beats;
    wire df_ready,hf_ready,hf_valid,hf_pop;
    reg active,pending;
    wire [82:0] hf_data;
    wire data_full,data_empty,wb,rb,reset;
    wire [6:0] read_count;
    wire data_read;
    wire ack_source;
    assign s_ready=s_state==0 && df_ready && hf_ready;
    assign s_done=ack_source;
    sc7f0_dp_fifo #(.WIDTH(83),.DEPTH(16)) u_headers(
        .wclk(s_clk),.wrst_n(s_rst_n),.wdata(header),.wvalid(s_state==2),
        .wready(hf_ready),.rclk(m_clk),.rrst_n(m_rst_n),.rdata(hf_data),
        .rvalid(hf_valid),.rready(hf_pop));
    xpm_cdc_async_rst #(.DEST_SYNC_FF(4),.RST_ACTIVE_HIGH(1)) u_reset(
        .src_arst(!s_rst_n||!m_rst_n),.dest_clk(s_clk),.dest_arst(reset));
    assign df_ready=!reset&&!wb&&!data_full;
    xpm_fifo_async #(.FIFO_MEMORY_TYPE("block"),.FIFO_WRITE_DEPTH(64),
        .WRITE_DATA_WIDTH(256),.READ_DATA_WIDTH(256),.READ_MODE("fwft"),
        .FIFO_READ_LATENCY(0),.CDC_SYNC_STAGES(4),.USE_ADV_FEATURES("0404"),
        .WR_DATA_COUNT_WIDTH(7),.RD_DATA_COUNT_WIDTH(7),.SIM_ASSERT_CHK(1)) u_payload(
        .rst(reset),.wr_clk(s_clk),.din(payload[write_index*256+:256]),
        .wr_en(s_state==1&&df_ready),.full(data_full),.wr_rst_busy(wb),
        .rd_clk(m_clk),.dout(m_data),.rd_en(data_read),.empty(data_empty),
        .rd_rst_busy(rb),.rd_data_count(read_count),.wr_data_count(),
        .sleep(1'b0),.injectsbiterr(1'b0),.injectdbiterr(1'b0),
        .prog_full(),.prog_empty(),.overflow(),.underflow(),.almost_full(),
        .almost_empty(),.wr_ack(),.data_valid(),.dbiterr(),.sbiterr());
    always @(posedge s_clk) begin
        if(!s_rst_n)begin s_state<=0;payload<=0;header<=0;write_index<=0;write_beats<=0;end
        else case(s_state)
            0:if(s_valid&&s_ready)begin
                payload<=s_payload;header<={s_last_be,s_first_be,s_dw_len,s_addr};
                write_index<=0;write_beats<=(s_dw_len+7)>>3;s_state<=1;
            end
            1:if(df_ready)begin
                write_index<=write_index+1'b1;
                if(write_index+1==write_beats)s_state<=2;
            end
            2:if(hf_ready)s_state<=3;
            3:if(ack_source)s_state<=0;
        endcase
    end
    reg [82:0] active_header;
    reg [3:0] beats_remaining;
    wire [3:0] expected_beats=(active_header[74:64]+7)>>3;
    // Latch/pop the header first. Never feed a FWFT data-derived comparison
    // combinationally back into that same FIFO's rd_en.
    assign hf_pop=m_rst_n&&!active&&!pending&&hf_valid;
    assign m_valid=active;
    assign m_addr=active_header[63:0];assign m_dw_len=active_header[74:64];
    assign m_first_be=active_header[78:75];assign m_last_be=active_header[82:79];
    assign data_read=m_rst_n&&active&&m_data_ready&&beats_remaining!=0;
    wire retire=active&&m_ack;
    always @(posedge m_clk)begin
        if(!m_rst_n)begin active<=0;pending<=0;active_header<=0;beats_remaining<=0;end
        else begin
            if(hf_pop)begin pending<=1;active_header<=hf_data;end
            if(pending&&!rb&&!data_empty&&read_count>=expected_beats)begin
                active<=1;pending<=0;beats_remaining<=expected_beats;
            end
            if(data_read)beats_remaining<=beats_remaining-1'b1;
            if(retire)active<=0;
        end
    end
    xpm_cdc_pulse #(.DEST_SYNC_FF(4),.REG_OUTPUT(1),.RST_USED(1),.SIM_ASSERT_CHK(1)) u_ack(
        .src_clk(m_clk),.src_rst(!m_rst_n),.src_pulse(retire),
        .dest_clk(s_clk),.dest_rst(!s_rst_n),.dest_pulse(ack_source));
endmodule
`default_nettype wire
