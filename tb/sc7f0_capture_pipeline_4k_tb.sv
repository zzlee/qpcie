`timescale 1ns/1ps
// Actual Xilinx CSC and framebuffer IP, not behavioral replacements.
module sc7f0_capture_pipeline_4k_tb;
    reg clk=0,rst_n=0,test_pass=0;
    always #3.333 clk=~clk;
    reg csr_clk=0,rx_clk=0;
    always #5 csr_clk=~csr_clk;
    always #3.367 rx_clk=~rx_clk;
    reg [95:0] video=0;reg vv=0,vs=0,ve=0;
    reg [95:0] wa=0,ww=0,ra=0;reg [2:0] wav=0,wwv=0,rav=0;
    wire [2:0] war,wwr,bv,rar,rv;wire [5:0] bresp_ctrl,rresp_ctrl;wire [95:0] rd_ctrl;
    wire [63:0] awaddr,araddr;wire [7:0] awlen;wire [2:0] awsize;wire [1:0] awburst;
    wire av,wv,wl,br,irq,arv;wire [127:0] wd;wire [15:0] ws;
    reg awready=0,wready=0,bvalid=0;
    sc7f0_capture_pipeline dut(
        .csr_clk(csr_clk),.csr_rst_n(rst_n),.mem_clk(clk),.mem_rst_n(rst_n),
        .rx_clk(rx_clk),.rx_rst_n(rst_n),.rx_data(video),.rx_valid(vv),.rx_sof(vs),.rx_eol(ve),
        .s_awaddr(wa),.s_awvalid(wav),.s_awready(war),.s_wdata(ww),.s_wstrb(12'hfff),
        .s_wvalid(wwv),.s_wready(wwr),.s_bresp(bresp_ctrl),.s_bvalid(bv),.s_bready(3'b111),
        .s_araddr(ra),.s_arvalid(rav),.s_arready(rar),.s_rdata(rd_ctrl),.s_rresp(rresp_ctrl),
        .s_rvalid(rv),.s_rready(3'b111),.irq(irq),
        .awaddr(awaddr),.awlen(awlen),.awsize(awsize),.awburst(awburst),.awvalid(av),.awready(awready),
        .wdata(wd),.wstrb(ws),.wlast(wl),.wvalid(wv),.wready(wready),.bresp(2'b00),.bvalid(bvalid),.bready(br),
        .araddr(araddr),.arlen(),.arsize(),.arburst(),.arvalid(arv),.arready(1'b1),
        .rdata(128'd0),.rresp(2'b00),.rlast(1'b0),.rvalid(1'b0),.rready());
    localparam W=3840,H=2160,Y_BASE=4096,UV_BASE=Y_BASE+W*H;
    localparam FRAME_BYTES=W*H*3/2;
    integer cycle=0,left=0,delay_b=0,total=0;reg [63:0] addr=0;
    reg ideal_ddr=0;
    integer source_words=0,tap_words=0,csc_words=0,tap_stalls=0,writer_stalls=0;
    integer aw_count=0,wbeats=0,ws4=0,ws8=0,ws16=0,axi_beats_requested=0;
    initial ideal_ddr=$test$plusargs("IDEAL_DDR");
    always @(posedge rx_clk)if(rst_n&&vv)begin
        source_words=source_words+1;
        if(dut.u_tap.write_pixel&&!dut.u_tap.pwready)begin
            $display("4K_FIRST_OVERFLOW time=%t source=%0d tap=%0d csc=%0d tap_stalls=%0d writer_stalls=%0d written=%0d ideal=%0d",$time,source_words,tap_words,csc_words,tap_stalls,writer_stalls,total,ideal_ddr);
            $display("4K_AXI_STATS aw=%0d requested_beats=%0d wbeats=%0d strobes4=%0d strobes8=%0d strobes16=%0d",aw_count,axi_beats_requested,wbeats,ws4,ws8,ws16);
            $fatal(1,"Passive 4K source FIFO overflow");
        end
    end
    always @(posedge clk)if(rst_n)begin
        if(dut.tv&&dut.tr)tap_words=tap_words+1;
        if(dut.cv&&dut.cready)csc_words=csc_words+1;
        if(dut.tv&&!dut.tr)tap_stalls=tap_stalls+1;
        if(dut.cv&&!dut.cready)writer_stalls=writer_stalls+1;
    end
    integer j;
    always @(posedge clk)begin
        if(!rst_n)begin cycle<=0;left<=0;awready<=0;wready<=0;bvalid<=0;delay_b<=0;total<=0;end
        else begin
            cycle<=cycle+1;
            awready<=left==0&&!bvalid&&delay_b==0&&(ideal_ddr||cycle%7!=2);
            wready<=left!=0&&(ideal_ddr||cycle%13!=4);
            if(arv)$fatal(1,"Unexpected read from framebuffer writer");
            if(av&&awready)begin
                if(awaddr+16*(awlen+1)>33554432||awsize!=4||awburst!=1||
                   awaddr[11:0]+16*(awlen+1)>4096)$fatal(1,"Invalid AXI burst");
                aw_count<=aw_count+1;axi_beats_requested<=axi_beats_requested+awlen+1;
                addr<=awaddr;left<=awlen+1;awready<=0;
            end
            if(wv&&wready)begin
                if(wl!=(left==1))$fatal(1,"WLAST mismatch");
                for(j=0;j<16;j=j+1)if(ws[j])begin
                    if(wd[j*8+:8] != ((addr+j<UV_BASE)?8'd16:8'd128))
                        $fatal(1,"4K black pixel mismatch address=%h byte=%d",addr+j,wd[j*8+:8]);
                end
                wbeats<=wbeats+1;
                if($countones(ws)==4)ws4<=ws4+1;
                if($countones(ws)==8)ws8<=ws8+1;
                if($countones(ws)==16)ws16<=ws16+1;
                total<=total+$countones(ws);
                addr<=addr+16;left<=left-1;
                if(wl)begin wready<=0;if(ideal_ddr)bvalid<=1;else delay_b<=11;end
            end
            if(delay_b!=0)begin delay_b<=delay_b-1;if(delay_b==1)bvalid<=1;end
            if(bvalid&&br)bvalid<=0;
        end
    end
    task automatic put(input integer target,address,input [31:0] data);
        begin
            @(negedge csr_clk);wa[target*32+:32]=address;ww[target*32+:32]=data;wav[target]=1;wwv[target]=1;
            fork
                begin do @(posedge csr_clk);while(!war[target]);@(negedge csr_clk);wav[target]=0;end
                begin do @(posedge csr_clk);while(!wwr[target]);@(negedge csr_clk);wwv[target]=0;end
            join
            do @(posedge csr_clk);while(!bv[target]);
            if(bresp_ctrl[target*2+:2]!=0)$fatal(1,"AXI-Lite write error");
        end
    endtask
    task automatic get(input integer target,address,output [31:0] data);
        begin
            @(negedge csr_clk);ra[target*32+:32]=address;rav[target]=1;
            do @(posedge csr_clk);while(!rar[target]);@(negedge csr_clk);rav[target]=0;
            do @(posedge csr_clk);while(!rv[target]);
            if(rresp_ctrl[target*2+:2]!=0)$fatal(1,"AXI-Lite read error");
            data=rd_ctrl[target*32+:32];
        end
    endtask
    task automatic run_color(input [23:0] native_rgb,input integer ey,eu,ev);
        integer x,y,p,v;reg [31:0] status_value,stop_token,stop_ack;
        begin
            rst_n=0;repeat(20)@(negedge clk);rst_n=1;
            repeat(20)@(negedge clk);
            put(2,'h30,3);put(2,'h10,W);put(2,'h14,H);
            repeat(30)@(negedge clk);
            // Register layout and BT.709 coefficients from 2023.2 kernel driver.
            put(1,'h10,0);put(1,'h18,3);put(1,'h20,W);put(1,'h28,H);
            put(1,'h50,1826*4096/10000);put(1,'h58,6142*4096/10000);put(1,'h60,620*4096/10000);
            // Explicit signed coefficients: an unsigned task argument otherwise
            // changes the context of SV division of negative expressions.
            put(1,'h68,-32'sd412);put(1,'h70,-32'sd1386);put(1,'h78,32'd1798);
            put(1,'h80,32'd1798);put(1,'h88,-32'sd1633);put(1,'h90,-32'sd165);
            put(1,'h98,16);put(1,'ha0,128);put(1,'ha8,128);put(1,'hb0,0);put(1,'hb8,255);
            put(0,'h10,W);put(0,'h18,H);put(0,'h20,W);put(0,'h28,19);
            put(0,'h30,Y_BASE);put(0,'h34,0);put(0,'h3c,UV_BASE);put(0,'h40,0);
            put(0,4,1);put(0,8,1);put(0,0,1);put(1,0,1);put(2,'h28,1);put(2,'h0c,1);
            repeat(50)@(negedge clk);
            for(y=0;y<H;y=y+1)begin
                for(x=0;x<W;x=x+4)begin
                @(negedge rx_clk);video={4{native_rgb}};vv=1;vs=(x==0&&y==0);ve=(x==W-4);
                // Passive tap: incoming physical 4K60 pixels cannot wait.
                end
                @(negedge rx_clk);vv=0;vs=0;ve=0;
                repeat(139)@(negedge rx_clk); // 560 horizontal blank pixels / 4PPC
            end
            @(negedge rx_clk);vv=0;vs=0;ve=0;
            wait(irq);#1;
            if(left!=0||bvalid||delay_b!=0||av||wv)$fatal(1,"Framebuffer IRQ before outstanding AXI writes drained");
            repeat(32)@(negedge clk);
            if(total!=FRAME_BYTES)$fatal(1,"4K enabled byte count %d expected %d",total,FRAME_BYTES);
            get(2,'h008,status_value);if(!status_value[2]||!status_value[0])$fatal(1,"Missing inflight metadata");
            get(2,'h04c,status_value);$display("4K_META_FLAGS=%h bytes=%0d cycle=%0d",status_value,total,cycle);if(status_value!=0)$fatal(1,"4K capture overflow/filler/EOL error");
            get(2,'h048,status_value);if(status_value!=1)$fatal(1,"Wrong source sequence");
            get(2,'h050,status_value);if(status_value!=((H<<16)|W))$fatal(1,"Wrong dimensions");
            get(2,'h040,status_value);if(status_value==0)$fatal(1,"Missing SOF ticks");
            put(2,'h01c,1);put(2,'h00c,0);
            get(2,'h068,stop_token);get(2,'h06c,stop_ack);p=0;
            while(stop_ack!=stop_token)begin
                get(2,'h06c,stop_ack);p=p+1;if(p>1000)$fatal(1,"Official pipeline stop barrier timeout");
            end
            get(2,'h008,status_value);if(status_value[0]||status_value[3])$fatal(1,"Tap did not drain/stop");
            $display("CAPTURE_PIPELINE_COLOR_PASS native=%h",native_rgb);
        end
    endtask
    initial begin
        run_color(24'h000000,16,128,128);
        test_pass=1;$display("SC7F0_CAPTURE_PIPELINE_4K_SIM_PASS");$finish;
    end
    initial begin #150000000;$fatal(1,"Official capture simulation timeout");end
endmodule
