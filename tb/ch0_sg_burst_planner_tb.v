`timescale 1ns / 1ps
module ch0_sg_burst_planner_tb;
    reg [31:0] seg, frame;
    reg [11:0] page_offset;
    wire [15:0] burst;
    wire [10:0] dw;
    wire [4:0] beats;
    wire valid;

    ch0_sg_burst_planner dut (
        .segment_bytes_left(seg), .frame_bytes_left(frame),
        .page_offset(page_offset), .burst_bytes(burst),
        .burst_dw_len(dw), .burst_beats(beats), .valid(valid));

    task check(input [31:0] s, input [31:0] f, input [11:0] p,
               input [15:0] expected);
        begin
            seg=s; frame=f; page_offset=p; #1;
            if (burst !== expected || valid !== (expected != 0))
                $fatal(1, "seg=%0d frame=%0d off=0x%0h got=%0d valid=%b expected=%0d",
                       s,f,p,burst,valid,expected);
        end
    endtask

    initial begin
        check(512, 512, 12'h000, 256);
        check(300, 512, 12'h000, 256);
        check(44, 512, 12'h000, 44);
        check(192, 512, 12'h000, 128);
        check(80, 512, 12'h000, 64);
        check(12, 512, 12'h000, 12);
        check(8, 512, 12'h000, 8);
        check(3, 512, 12'h000, 0);
        check(512, 512, 12'hF00, 256);
        check(512, 512, 12'hF80, 128);
        check(512, 512, 12'hFC0, 64);
        check(512, 512, 12'hFF0, 16);
        check(512, 100, 12'h000, 100);
        $display("PASS: ch0 SG variable burst planner");
        $finish;
    end
endmodule
