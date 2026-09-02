// Bounded H2C completion reorder buffer. Tags 2..9 map directly to eight
// response slots; completed requests retire strictly in issue order.
`timescale 1ns / 1ps

module h2c_reorder_buffer #(
    parameter DATA_WIDTH = 128,
    parameter DEPTH = 8,
    parameter MAX_DWORDS = 128
)(
    input  wire                  clk,
    input  wire                  rst_n,

    output wire                  alloc_ready,
    output wire [7:0]            alloc_tag,
    input  wire                  alloc_commit,
    input  wire [10:0]           alloc_dw_len,
    input  wire                  alloc_frame_first,
    input  wire                  alloc_frame_last,

    input  wire                  cpl_valid,
    input  wire [7:0]            cpl_tag,
    input  wire [DATA_WIDTH-1:0] cpl_data,
    input  wire [2:0]            cpl_dw_count,

    output reg  [DATA_WIDTH-1:0] m_axis_tdata,
    output reg                   m_axis_tvalid,
    output reg                   m_axis_tlast,
    output reg                   m_axis_tuser,
    input  wire                  m_axis_tready,

    output reg                   retire_valid,
    output reg  [10:0]           retire_dw_len,
    output reg                   retire_frame_last,
    output reg                   error_valid
);
    localparam SLOT_WIDTH = $clog2(DEPTH);
    localparam WORDS_PER_SLOT = MAX_DWORDS / 4;
    localparam RAM_ADDR_WIDTH = $clog2(DEPTH * WORDS_PER_SLOT);

    reg [DEPTH-1:0] slot_valid;
    reg [DEPTH-1:0] slot_complete;
    reg [10:0] slot_dw_len [0:DEPTH-1];
    reg [10:0] slot_recv_dw [0:DEPTH-1];
    reg [5:0] slot_write_word [0:DEPTH-1];
    reg [1:0] slot_pack_count [0:DEPTH-1];
    reg [95:0] slot_pack_data [0:DEPTH-1];
    reg [DEPTH-1:0] slot_frame_first;
    reg [DEPTH-1:0] slot_frame_last;
    reg [SLOT_WIDTH-1:0] alloc_slot;
    reg [SLOT_WIDTH-1:0] retire_slot;
    reg [5:0] retire_word;

    (* ram_style = "block" *) reg [DATA_WIDTH-1:0] payload_ram
        [0:DEPTH*WORDS_PER_SLOT-1];
    reg [DATA_WIDTH-1:0] ram_read_data;
    reg read_pending;

    wire cpl_tag_valid = cpl_tag >= 8'd2 && cpl_tag < (DEPTH + 2);
    wire [SLOT_WIDTH-1:0] cpl_slot = cpl_tag - 2;
    wire [127:0] cpl_masked_data =
        (cpl_dw_count == 1) ? {96'd0, cpl_data[31:0]} :
        (cpl_dw_count == 2) ? {64'd0, cpl_data[63:0]} :
        (cpl_dw_count == 3) ? {32'd0, cpl_data[95:0]} : cpl_data;
    wire [3:0] cpl_total_dw = cpl_tag_valid ?
        slot_pack_count[cpl_slot] + cpl_dw_count : 0;
    wire [223:0] cpl_combined = cpl_tag_valid ?
        ({128'd0, slot_pack_data[cpl_slot]} |
         ({96'd0, cpl_masked_data} << (slot_pack_count[cpl_slot] * 32))) : 0;
    wire cpl_write = cpl_valid && cpl_tag_valid &&
                     slot_valid[cpl_slot] && cpl_total_dw >= 4;
    wire [RAM_ADDR_WIDTH-1:0] cpl_write_addr =
        {cpl_slot, slot_write_word[cpl_slot][4:0]};

    assign alloc_ready = !slot_valid[alloc_slot];
    assign alloc_tag = {5'd0, alloc_slot} + 8'd2;

    wire output_accept = m_axis_tvalid && m_axis_tready;
    wire output_last_word = retire_word == ((slot_dw_len[retire_slot] >> 2) - 1'b1);
    wire start_read = !read_pending && slot_valid[retire_slot] &&
                      slot_complete[retire_slot] &&
                      (!m_axis_tvalid || (output_accept && !output_last_word));
    wire [5:0] next_read_word = output_accept ? retire_word + 1'b1 : retire_word;
    wire [RAM_ADDR_WIDTH-1:0] read_addr = {retire_slot, next_read_word[4:0]};

    integer i;
    always @(posedge clk) begin
        if (cpl_write)
            payload_ram[cpl_write_addr] <= cpl_combined[127:0];
        if (start_read)
            ram_read_data <= payload_ram[read_addr];
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            slot_valid <= 0;
            slot_complete <= 0;
            slot_frame_first <= 0;
            slot_frame_last <= 0;
            alloc_slot <= 0;
            retire_slot <= 0;
            retire_word <= 0;
            read_pending <= 0;
            m_axis_tdata <= 0;
            m_axis_tvalid <= 0;
            m_axis_tlast <= 0;
            m_axis_tuser <= 0;
            retire_valid <= 0;
            retire_dw_len <= 0;
            retire_frame_last <= 0;
            error_valid <= 0;
            for (i = 0; i < DEPTH; i = i + 1) begin
                slot_dw_len[i] <= 0;
                slot_recv_dw[i] <= 0;
                slot_write_word[i] <= 0;
                slot_pack_count[i] <= 0;
                slot_pack_data[i] <= 0;
            end
        end else begin
            retire_valid <= 0;
            retire_frame_last <= 0;
            error_valid <= 0;

            if (alloc_commit && alloc_ready) begin
                slot_valid[alloc_slot] <= 1;
                slot_complete[alloc_slot] <= 0;
                slot_dw_len[alloc_slot] <= alloc_dw_len;
                slot_recv_dw[alloc_slot] <= 0;
                slot_write_word[alloc_slot] <= 0;
                slot_pack_count[alloc_slot] <= 0;
                slot_pack_data[alloc_slot] <= 0;
                slot_frame_first[alloc_slot] <= alloc_frame_first;
                slot_frame_last[alloc_slot] <= alloc_frame_last;
                alloc_slot <= alloc_slot + 1'b1;
            end else if (alloc_commit) begin
                error_valid <= 1;
            end

            if (cpl_valid) begin
                if (!cpl_tag_valid || !slot_valid[cpl_slot] || cpl_dw_count == 0 ||
                    slot_recv_dw[cpl_slot] + cpl_dw_count > slot_dw_len[cpl_slot]) begin
                    error_valid <= 1;
                end else begin
                    slot_recv_dw[cpl_slot] <= slot_recv_dw[cpl_slot] + cpl_dw_count;
                    if (cpl_total_dw >= 4) begin
                        slot_write_word[cpl_slot] <= slot_write_word[cpl_slot] + 1'b1;
                        slot_pack_data[cpl_slot] <= cpl_combined[223:128];
                        slot_pack_count[cpl_slot] <= cpl_total_dw - 4;
                    end else begin
                        slot_pack_data[cpl_slot] <= cpl_combined[95:0];
                        slot_pack_count[cpl_slot] <= cpl_total_dw[1:0];
                    end
                    if (slot_recv_dw[cpl_slot] + cpl_dw_count == slot_dw_len[cpl_slot]) begin
                        if (cpl_total_dw != 4)
                            error_valid <= 1;
                        else
                            slot_complete[cpl_slot] <= 1;
                    end
                end
            end

            if (start_read)
                read_pending <= 1;
            else if (read_pending) begin
                m_axis_tdata <= ram_read_data;
                m_axis_tvalid <= 1;
                m_axis_tuser <= slot_frame_first[retire_slot] && (retire_word == 0);
                m_axis_tlast <= slot_frame_last[retire_slot] && output_last_word;
                read_pending <= 0;
            end

            if (output_accept) begin
                m_axis_tvalid <= 0;
                if (output_last_word) begin
                    retire_valid <= 1;
                    retire_dw_len <= slot_dw_len[retire_slot];
                    retire_frame_last <= slot_frame_last[retire_slot];
                    slot_valid[retire_slot] <= 0;
                    slot_complete[retire_slot] <= 0;
                    retire_slot <= retire_slot + 1'b1;
                    retire_word <= 0;
                end else begin
                    retire_word <= retire_word + 1'b1;
                end
            end
        end
    end
endmodule
