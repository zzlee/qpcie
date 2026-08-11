// ============================================================================
// Testbench: tb_pcie_tag_manager
// Description: Unit testbench for pcie_tag_manager module
// ============================================================================

`timescale 1ns / 1ps

module tb_pcie_tag_manager;

    parameter MAX_TAGS = 64;
    parameter TAG_WIDTH = 8;

    reg                 clk;
    reg                 rst_n;

    reg                 alloc_req;
    wire                alloc_valid;
    wire [TAG_WIDTH-1:0] alloc_tag;
    wire                tag_full;

    reg                 free_req;
    reg  [TAG_WIDTH-1:0] free_tag;
    wire [TAG_WIDTH-1:0] active_count;

    // Instantiate Tag Manager
    pcie_tag_manager #(
        .MAX_TAGS(MAX_TAGS),
        .TAG_WIDTH(TAG_WIDTH)
    ) uut (
        .clk(clk),
        .rst_n(rst_n),
        .alloc_req(alloc_req),
        .alloc_valid(alloc_valid),
        .alloc_tag(alloc_tag),
        .tag_full(tag_full),
        .free_req(free_req),
        .free_tag(free_tag),
        .active_count(active_count)
    );

    // Clock generation (100MHz)
    always #5 clk = ~clk;

    initial begin
        clk = 0;
        rst_n = 0;
        alloc_req = 0;
        free_req = 0;
        free_tag = 0;

        #20;
        rst_n = 1;
        #10;

        $display("[%0t] Starting Tag Manager Allocation Test...", $time);

        // Test 1: Allocate 5 tags
        repeat (5) begin
            @(posedge clk);
            alloc_req <= 1;
            @(posedge clk);
            alloc_req <= 0;
            #1;
            if (alloc_valid) begin
                $display("[%0t] Allocated Tag: %d (Active Count: %d)", $time, alloc_tag, active_count);
            end else begin
                $display("[%0t] ERROR: Allocation failed!", $time);
            end
        end

        #20;
        // Test 2: Free Tag 2 and Tag 4
        @(posedge clk);
        free_req <= 1;
        free_tag <= 2;
        @(posedge clk);
        free_tag <= 4;
        @(posedge clk);
        free_req <= 0;

        #20;
        // Test 3: Re-allocate - should pick lowest free tag (2, then 4)
        repeat (2) begin
            @(posedge clk);
            alloc_req <= 1;
            @(posedge clk);
            alloc_req <= 0;
            #1;
            $display("[%0t] Re-allocated Tag: %d (Active Count: %d)", $time, alloc_tag, active_count);
        end

        #30;
        $display("[%0t] SUCCESS: Tag Manager Test Completed!", $time);
        $finish;
    end

endmodule
