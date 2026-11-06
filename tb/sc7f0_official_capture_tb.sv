`timescale 1ns/1ps
// Actual Xilinx CSC and framebuffer IP, not behavioral replacements.
module sc7f0_official_capture_tb;
    reg clk=0,rst_n=0,test_pass=0;
    always #3.333 clk=~clk;
    reg [8:0] ca=0;reg [31:0] cd=0;reg cav=0,cwv=0;
    wire car,cwr,cbv;wire [1:0] cbr;
    reg [6:0] fa=0;reg [31:0] fd=0;reg fav=0,fwv=0;
    wire far,fwr,fbv;wire [1:0] fbr;
    reg [95:0] video=0;reg vv=0,vs=0,ve=0;wire vr;
    wire [95:0] conv;wire cv,cr,cs,ce;wire [11:0] ck,ct;
    sc7f0_vpss_csc csc(
        .aclk(clk),.aresetn(rst_n),.s_axis_tdata(video),.s_axis_tvalid(vv),
        .s_axis_tready(vr),.s_axis_tuser(vs),.s_axis_tlast(ve),
        .s_axis_tkeep(12'hfff),.s_axis_tstrb(12'hfff),.s_axis_tid(1'b0),.s_axis_tdest(1'b0),
        .m_axis_tdata(conv),.m_axis_tvalid(cv),.m_axis_tready(cr),
        .m_axis_tuser(cs),.m_axis_tlast(ce),.m_axis_tkeep(ck),.m_axis_tstrb(ct),
        .m_axis_tid(),.m_axis_tdest(),
        .s_axi_ctrl_awaddr(ca),.s_axi_ctrl_awvalid(cav),.s_axi_ctrl_awready(car),
        .s_axi_ctrl_wdata(cd),.s_axi_ctrl_wstrb(4'hf),.s_axi_ctrl_wvalid(cwv),.s_axi_ctrl_wready(cwr),
        .s_axi_ctrl_bresp(cbr),.s_axi_ctrl_bvalid(cbv),.s_axi_ctrl_bready(1'b1),
        .s_axi_ctrl_araddr(9'd0),.s_axi_ctrl_arvalid(1'b0),.s_axi_ctrl_arready(),
        .s_axi_ctrl_rdata(),.s_axi_ctrl_rresp(),.s_axi_ctrl_rvalid(),.s_axi_ctrl_rready(1'b1));
    wire [63:0] awaddr;wire [7:0] awlen;wire [2:0] awsize;wire [1:0] awburst;
    wire av,wv,wl,br,irq,arv;wire [127:0] wd;wire [15:0] ws;
    reg awready=0,wready=0,bvalid=0;
    sc7f0_frmbuf_wr writer(
        .ap_clk(clk),.ap_rst_n(rst_n),.interrupt(irq),
        .s_axis_video_TDATA(conv),.s_axis_video_TVALID(cv),.s_axis_video_TREADY(cr),
        .s_axis_video_TUSER(cs),.s_axis_video_TLAST(ce),.s_axis_video_TKEEP(ck),
        .s_axis_video_TSTRB(ct),.s_axis_video_TID(1'b0),.s_axis_video_TDEST(1'b0),
        .s_axi_CTRL_AWADDR(fa),.s_axi_CTRL_AWVALID(fav),.s_axi_CTRL_AWREADY(far),
        .s_axi_CTRL_WDATA(fd),.s_axi_CTRL_WSTRB(4'hf),.s_axi_CTRL_WVALID(fwv),.s_axi_CTRL_WREADY(fwr),
        .s_axi_CTRL_BRESP(fbr),.s_axi_CTRL_BVALID(fbv),.s_axi_CTRL_BREADY(1'b1),
        .s_axi_CTRL_ARADDR(7'd0),.s_axi_CTRL_ARVALID(1'b0),.s_axi_CTRL_ARREADY(),
        .s_axi_CTRL_RDATA(),.s_axi_CTRL_RRESP(),.s_axi_CTRL_RVALID(),.s_axi_CTRL_RREADY(1'b1),
        .m_axi_mm_video_AWADDR(awaddr),.m_axi_mm_video_AWLEN(awlen),
        .m_axi_mm_video_AWSIZE(awsize),.m_axi_mm_video_AWBURST(awburst),
        .m_axi_mm_video_AWVALID(av),.m_axi_mm_video_AWREADY(awready),
        .m_axi_mm_video_WDATA(wd),.m_axi_mm_video_WSTRB(ws),.m_axi_mm_video_WLAST(wl),
        .m_axi_mm_video_WVALID(wv),.m_axi_mm_video_WREADY(wready),
        .m_axi_mm_video_BRESP(2'b00),.m_axi_mm_video_BVALID(bvalid),.m_axi_mm_video_BREADY(br),
        .m_axi_mm_video_ARVALID(arv),.m_axi_mm_video_ARREADY(1'b1),
        .m_axi_mm_video_RDATA(128'd0),.m_axi_mm_video_RRESP(2'b00),
        .m_axi_mm_video_RLAST(1'b0),.m_axi_mm_video_RVALID(1'b0),.m_axi_mm_video_RREADY());
    byte unsigned mem[0:65535];
    integer cycle=0,left=0,delay_b=0,total=0;reg [63:0] addr=0;
    integer j;
    always @(posedge clk)begin
        if(!rst_n)begin cycle<=0;left<=0;awready<=0;wready<=0;bvalid<=0;delay_b<=0;total<=0;end
        else begin
            cycle<=cycle+1;
            awready<=left==0&&!bvalid&&delay_b==0&&cycle%7!=2;
            wready<=left!=0&&cycle%13!=4;
            if(arv)$fatal(1,"Unexpected read from framebuffer writer");
            if(av&&awready)begin
                if(awaddr+16*(awlen+1)>65536||awsize!=4||awburst!=1||
                   awaddr[11:0]+16*(awlen+1)>4096)$fatal(1,"Invalid AXI burst");
                addr<=awaddr;left<=awlen+1;awready<=0;
            end
            if(wv&&wready)begin
                if(wl!=(left==1))$fatal(1,"WLAST mismatch");
                for(j=0;j<16;j=j+1)if(ws[j])mem[addr+j]<=wd[j*8+:8];
                total<=total+$countones(ws);
                addr<=addr+16;left<=left-1;
                if(wl)begin wready<=0;delay_b<=4;end
            end
            if(delay_b!=0)begin delay_b<=delay_b-1;if(delay_b==1)bvalid<=1;end
            if(bvalid&&br)bvalid<=0;
        end
    end
    task automatic put(input bit c,input integer address,input [31:0] data);
        begin
            @(negedge clk);
            if(c)begin ca=address;cd=data;cav=1;cwv=1;end
            else begin fa=address;fd=data;fav=1;fwv=1;end
            fork
                begin do @(posedge clk);while(c?!car:!far);@(negedge clk);if(c)cav=0;else fav=0;end
                begin do @(posedge clk);while(c?!cwr:!fwr);@(negedge clk);if(c)cwv=0;else fwv=0;end
            join
            do @(posedge clk);while(c?!cbv:!fbv);
            if(c?cbr!=0:fbr!=0)$fatal(1,"AXI-Lite error");
        end
    endtask
    task automatic run_color(input [23:0] native_rgb,input integer ey,eu,ev);
        integer x,y,p,v;
        begin
            rst_n=0;repeat(20)@(negedge clk);rst_n=1;
            for(x=0;x<65536;x=x+1)mem[x]='ha5;
            repeat(20)@(negedge clk);
            // Register layout and BT.709 coefficients from 2023.2 kernel driver.
            put(1,'h10,0);put(1,'h18,3);put(1,'h20,64);put(1,'h28,64);
            put(1,'h50,1826*4096/10000);put(1,'h58,6142*4096/10000);put(1,'h60,620*4096/10000);
            // Explicit signed coefficients: an unsigned task argument otherwise
            // changes the context of SV division of negative expressions.
            put(1,'h68,-32'sd412);put(1,'h70,-32'sd1386);put(1,'h78,32'd1798);
            put(1,'h80,32'd1798);put(1,'h88,-32'sd1633);put(1,'h90,-32'sd165);
            put(1,'h98,16);put(1,'ha0,128);put(1,'ha8,128);put(1,'hb0,0);put(1,'hb8,255);
            put(0,'h10,64);put(0,'h18,64);put(0,'h20,96);put(0,'h28,19);
            put(0,'h30,'h1000);put(0,'h34,0);put(0,'h3c,'h4000);put(0,'h40,0);
            put(0,4,1);put(0,8,1);put(0,0,1);put(1,0,1);
            for(y=0;y<64;y=y+1)for(x=0;x<64;x=x+4)begin
                @(negedge clk);video={4{native_rgb}};vv=1;vs=(x==0&&y==0);ve=(x==60);
                do @(posedge clk);while(!vr);
            end
            @(negedge clk);vv=0;vs=0;ve=0;
            wait(irq);repeat(32)@(negedge clk);
            if(total!=6144)$fatal(1,"Unexpected enabled write byte count %d",total);
            for(y=0;y<64;y=y+1)for(x=0;x<96;x=x+1)begin
                v=mem['h1000+y*96+x];
                if(x>=64)begin if(v!='ha5)$fatal(1,"Y stride padding overwritten");end
                else if(v<ey-1||v>ey+1)$fatal(1,"Y mismatch got%d expected%d x%d y%d",v,ey,x,y);
            end
            for(y=0;y<32;y=y+1)for(x=0;x<96;x=x+1)begin
                v=mem['h4000+y*96+x];p=x%2?ev:eu;
                if(x>=64)begin if(v!='ha5)$fatal(1,"UV stride padding overwritten");end
                else if(v<p-1||v>p+1)$fatal(1,"UV mismatch got%d expected%d x%d y%d",v,p,x,y);
            end
            $display("OFFICIAL_RGB_NV12_COLOR_PASS native=%h",native_rgb);
        end
    endtask
    initial begin
        run_color(24'h000000,16,128,128);
        run_color(24'hff0000,63,102,240); // native R:B:G, red in upper byte
        run_color(24'hffffff,235,128,128);
        test_pass=1;$display("SC7F0_OFFICIAL_CAPTURE_SIM_PASS");$finish;
    end
    initial begin #10000000;$fatal(1,"Official capture simulation timeout");end
endmodule
