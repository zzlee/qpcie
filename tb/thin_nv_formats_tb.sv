`timescale 1ns/1ps
module thin_nv_formats_tb;
    reg clk=0, rst_n=0, enable=0;
    always #4 clk=~clk;
    reg [3:0] format=2;
    wire [15:0] frame_width=256, frame_height=4, frame_stride0=256, frame_stride1=256;
    wire [63:0] global_timestamp=64'h1234;
    wire [63:0] ring0_base_addr=64'h1000, ring1_base_addr=64'h2000;
    wire [15:0] ring0_size=16, ring1_size=16, ring0_tail=1, ring1_tail=2;
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
    reg sgl_y_almost_full=1, sgl_uv_almost_full=1;
    wire frame_launch_req;
    wire [244:0] frame_launch_bus;
    reg frame_launch_ack=0, capture_engine_busy=0;
    integer y_bytes=0, uv_bytes=0, launches=0;
    thin_desc_fetch_engine dut(.*);
    always @(posedge clk) if(rst_n) begin
        mrd_req_ack<=mrd_req_valid && !mrd_req_ack;
        cpld_valid<=mrd_req_ack;
        cpld_last<=1;
        if(mrd_req_ack) begin
            cpld_tag<=mrd_req_tag;
            cpld_data<={32'd0, mrd_req_addr<ring1_base_addr ? 32'd1024 : 32'd512, mrd_req_addr+64'h100000};
        end
        frame_launch_ack<=frame_launch_req && !frame_launch_ack;
        if(frame_launch_req && !frame_launch_ack) begin
            launches=launches+1;
            if(frame_launch_bus[244:241]!==format || frame_launch_bus[143:128]!==16'd256)
                $fatal(1,"launch format/geometry mismatch");
            capture_engine_busy<=1;
        end
        if(sgl_y_wr_en) y_bytes=y_bytes+sgl_y_wr_len;
        if(sgl_uv_wr_en) uv_bytes=uv_bytes+sgl_uv_wr_len;
    end
    initial begin
        if($test$plusargs("NV16")) format=3;
        repeat(5) @(negedge clk); rst_n=1; enable=1;
        wait(launches==1);
        repeat(10) @(negedge clk);
        if(mrd_req_valid) $fatal(1,"SGL backpressure ignored");
        sgl_y_almost_full=0; sgl_uv_almost_full=0;
        wait(ring0_head==1 && ring1_head==(format==3 ? 2 : 1));
        repeat(12) @(negedge clk);
        if(y_bytes!=1024 || uv_bytes!=(format==3 ? 1024 : 512) || launches!=1)
            $fatal(1,"wrong plane target: y=%0d uv=%0d launches=%0d",y_bytes,uv_bytes,launches);
        frame_done_in=1;
        @(negedge clk); frame_done_in=0; enable=0;
        if(frame_count!=1 || drop_count) $fatal(1,"bad frame retirement");
        $display("TB_PASS: thin format=%0d Y=%0d UV=%0d heads=%0d/%0d",format,y_bytes,uv_bytes,ring0_head,ring1_head);
        $finish;
    end
    initial begin #100000; $fatal(1,"thin timeout"); end
endmodule
