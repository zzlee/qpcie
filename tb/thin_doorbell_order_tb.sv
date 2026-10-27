`timescale 1ns/1ps
// A host publishes the two ring doorbells in distinct MMIO transactions.
// Neither plane may be prefetched before a frame owns both rings.
module thin_doorbell_order_tb;
    reg clk=0, rst_n=0, enable=0;
    always #4 clk=~clk;
    reg [3:0] format=2;
    reg [15:0] frame_width=256, frame_height=4, frame_stride0=256, frame_stride1=256;
    wire [63:0] global_timestamp=64'h1234;
    wire [63:0] ring0_base_addr=64'h1000, ring1_base_addr=64'h2000;
    wire [15:0] ring0_size=128, ring1_size=128;
    reg [15:0] ring0_tail=0, ring1_tail=0;
    wire [15:0] ring0_head, ring1_head;
    reg frame_done_in=0;
    wire [31:0] frame_count, drop_count;
    wire busy, mrd_req_valid;
    wire [63:0] mrd_req_addr;
    wire [10:0] mrd_req_dw_len;
    wire [7:0] mrd_req_tag;
    reg mrd_req_ack=0, cpld_valid=0, cpld_last=0;
    reg [127:0] cpld_data=0;
    reg [7:0] cpld_tag=0;
    wire sgl_y_wr_en, sgl_uv_wr_en;
    wire [63:0] sgl_y_wr_addr, sgl_uv_wr_addr;
    wire [31:0] sgl_y_wr_len, sgl_y_wr_flags, sgl_uv_wr_len, sgl_uv_wr_flags;
    wire sgl_y_almost_full=0, sgl_uv_almost_full=0;
    wire frame_launch_req;
    wire [244:0] frame_launch_bus;
    reg frame_launch_ack=0, capture_engine_busy=0;
    integer y_bytes=0, uv_bytes=0, launches=0, frame_index;
    integer y_target=1024, uv_target=512, y_descriptors=1, uv_descriptors=1;
    function [31:0] descriptor_bytes(input [63:0] address);
        integer index, remaining;
        begin
            if(address<ring1_base_addr) begin
                index=((address-ring0_base_addr)/16)%y_descriptors;
                remaining=y_target-index*1048576;
            end else begin
                index=((address-ring1_base_addr)/16)%uv_descriptors;
                remaining=uv_target-index*1048576;
            end
            descriptor_bytes=remaining>1048576 ? 1048576 : remaining;
        end
    endfunction
    thin_desc_fetch_engine dut(.*);
    always @(posedge clk) if(rst_n) begin
        mrd_req_ack<=mrd_req_valid && !mrd_req_ack;
        cpld_valid<=mrd_req_ack;
        cpld_last<=1;
        if(mrd_req_ack) begin
            cpld_tag<=mrd_req_tag;
            cpld_data<={32'd0, descriptor_bytes(mrd_req_addr), mrd_req_addr+64'h100000};
        end
        frame_launch_ack<=frame_launch_req && !frame_launch_ack;
        if(frame_launch_req && !frame_launch_ack) begin
            launches=launches+1;
            capture_engine_busy<=1;
        end
        if(sgl_y_wr_en) y_bytes=y_bytes+sgl_y_wr_len;
        if(sgl_uv_wr_en) uv_bytes=uv_bytes+sgl_uv_wr_len;
    end
    initial begin
        if($test$plusargs("NV16")) format=3;
        if($test$plusargs("UHD")) begin
            frame_width=3840; frame_height=2160; frame_stride0=3840; frame_stride1=3840;
        end
        y_target=frame_stride0*frame_height;
        uv_target=frame_stride1*(format==3 ? frame_height : frame_height/2);
        y_descriptors=(y_target+1048575)/1048576;
        uv_descriptors=(uv_target+1048575)/1048576;
        repeat(5) @(negedge clk); rst_n=1; enable=1;
        for(frame_index=1;frame_index<=3;frame_index=frame_index+1) begin
            if($test$plusargs("UV_FIRST")) ring1_tail=frame_index*uv_descriptors;
            else ring0_tail=frame_index*y_descriptors;
            // Long enough for an MRd + CplD, but the partner doorbell is absent.
            repeat(32) @(negedge clk);
            if(!$test$plusargs("LIVENESS_ONLY") &&
               (ring0_head!=(frame_index-1)*y_descriptors || ring1_head!=(frame_index-1)*uv_descriptors ||
                launches!=frame_index-1 || mrd_req_valid))
                $fatal(1,"prefetch escaped frame ownership: heads=%0d/%0d launches=%0d before partner doorbell",
                       ring0_head,ring1_head,launches);
            ring0_tail=frame_index*y_descriptors; ring1_tail=frame_index*uv_descriptors;
            wait(launches==frame_index && ring0_head==frame_index*y_descriptors &&
                 ring1_head==frame_index*uv_descriptors);
            repeat(5) @(negedge clk);
            if(y_bytes!=frame_index*y_target || uv_bytes!=frame_index*uv_target)
                $fatal(1,"lost/repeated plane bytes");
            frame_done_in=1;
            @(negedge clk); frame_done_in=0; capture_engine_busy=0;
            repeat(5) @(negedge clk);
            if(frame_count!=frame_index || drop_count || busy)
                $fatal(1,"frame did not retire cleanly");
        end
        $display("TB_PASS: staggered ring doorbells format=%0d UV_FIRST=%0d UHD=%0d, 3 empty/refill cycles",
                 format,$test$plusargs("UV_FIRST"),$test$plusargs("UHD"));
        $finish;
    end
    initial begin
        #100000;
        $fatal(1,"published frame lost: heads=%0d/%0d tails=%0d/%0d launches=%0d retired=%0d",
               ring0_head,ring1_head,ring0_tail,ring1_tail,launches,frame_count);
    end
endmodule
