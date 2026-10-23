`timescale 1ns/1ps
module video_rgb_to_yuv709_tb;
    reg clk=0, rst_n=0, enable=0;
    always #3 clk=~clk;
    reg [127:0] s_data=0;
    reg s_valid=0, s_sof=0, s_eol=0, m_ready=0;
    wire s_ready, m_valid, m_sof, m_eol;
    wire [127:0] m_data;
    video_rgb_to_yuv709 dut(.*);
    reg [127:0] expected[0:2047];
    reg expected_sof[0:2047], expected_eol[0:2047];
    integer sent=0, received=0, cycle=0, p, n, r, g, b, y, u, v;
    reg [127:0] word_expected;
    // Deterministic pseudo-random pixel inputs include black, white and primaries.
    task make_input(input integer index);
        begin
            enable = index >= 512;
            for(p=0;p<4;p=p+1) begin
                n=index*4+p;
                r=(n*43)&255; g=(n*79)&255; b=(n*137)&255;
                case(n%16)
                    0: begin r=0;g=0;b=0;end
                    1: begin r=255;g=255;b=255;end
                    2: begin r=255;g=0;b=0;end
                    3: begin r=0;g=255;b=0;end
                    4: begin r=0;g=0;b=255;end
                endcase
                s_data[p*32+:32]={8'hff,b[7:0],g[7:0],r[7:0]};
                y=(47*r+157*g+16*b+4224)>>8;
                u=(-26*r-86*g+112*b+32896)>>8;
                v=(112*r-102*g-10*b+32896)>>8;
                word_expected[p*32+:32]=enable ? {8'd0,v[7:0],u[7:0],y[7:0]} : s_data[p*32+:32];
            end
            s_sof=(index%128==0); s_eol=(index%32==31);
        end
    endtask
    always @(posedge clk) if(rst_n) begin
        if(s_valid && s_ready) begin
            expected[sent]=word_expected;
            expected_sof[sent]=s_sof; expected_eol[sent]=s_eol;
            sent=sent+1;
        end
        if(m_valid && m_ready) begin
            if(received>=sent || m_data!==expected[received] ||
               m_sof!==expected_sof[received] || m_eol!==expected_eol[received])
                $fatal(1,"CSC/bypass/marker mismatch %0d got=%h expected=%h",received,m_data,expected[received]);
            received=received+1;
        end
    end
    initial begin
        repeat(4) @(negedge clk); rst_n=1;
        while(sent<1024) begin
            @(negedge clk);
            cycle=cycle+1; m_ready=(cycle%13<8);
            if(!s_valid || s_ready) begin
                make_input(sent); s_valid=(cycle%7!=0);
            end
        end
        @(negedge clk); s_valid=0; m_ready=1;
        wait(received==1024);
        @(negedge clk);
        $display("TB_PASS: BT709 CSC/bypass 1024 beats, colors, stalls, SOF/EOL");
        $finish;
    end
    initial begin #100000; $fatal(1,"timeout"); end
endmodule
