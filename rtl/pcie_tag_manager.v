// ============================================================================
// Module: pcie_tag_manager
// Description: Manages PCIe Non-Posted (MRd) Tag allocation and recycling.
//              Supports up to MAX_TAGS outstanding read requests.
// ============================================================================

`timescale 1ns / 1ps

module pcie_tag_manager #(
    parameter MAX_TAGS = 64,
    parameter TAG_WIDTH = 8
)(
    input  wire                 clk,
    input  wire                 rst_n,

    // Allocation interface
    input  wire                 alloc_req,
    output reg                  alloc_valid,
    output reg  [TAG_WIDTH-1:0] alloc_tag,
    output wire                 tag_full,

    // Free/Recycle interface
    input  wire                 free_req,
    input  wire [TAG_WIDTH-1:0] free_tag,

    // Status
    output reg  [TAG_WIDTH-1:0] active_count
);

    // Tag busy bitmap
    reg [MAX_TAGS-1:0] tag_bitmap;

    // Find lowest available tag index
    integer i;
    reg [TAG_WIDTH-1:0] first_free_idx;
    reg                 found_free;

    always @(*) begin
        first_free_idx = {TAG_WIDTH{1'b0}};
        found_free     = 1'b0;
        for (i = 1; i < MAX_TAGS; i = i + 1) begin // Tag 0 reserved for Descriptor Fetch
            if (!tag_bitmap[i] && !found_free) begin
                first_free_idx = i[TAG_WIDTH-1:0];
                found_free     = 1'b1;
            end
        end
    end

    assign tag_full = !found_free;

    // Bitmap update & allocation logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tag_bitmap   <= {MAX_TAGS{1'b0}};
            alloc_valid  <= 1'b0;
            alloc_tag    <= {TAG_WIDTH{1'b0}};
            active_count <= {TAG_WIDTH{1'b0}};
        end else begin
            // Freeing tag
            if (free_req && free_tag < MAX_TAGS) begin
                tag_bitmap[free_tag] <= 1'b0;
            end

            // Allocating tag
            if (alloc_req && found_free) begin
                tag_bitmap[first_free_idx] <= 1'b1;
                // Handle simultaneous alloc & free of the same tag
                if (free_req && free_tag == first_free_idx) begin
                    tag_bitmap[first_free_idx] <= 1'b1;
                end
                alloc_valid <= 1'b1;
                alloc_tag   <= first_free_idx;
            end else begin
                alloc_valid <= 1'b0;
            end

            // Update active count
            case ({alloc_req && found_free, free_req && free_tag < MAX_TAGS})
                2'b10: active_count <= active_count + 1'b1;
                2'b01: active_count <= (active_count > 0) ? active_count - 1'b1 : {TAG_WIDTH{1'b0}};
                default: active_count <= active_count;
            endcase
        end
    end

endmodule
