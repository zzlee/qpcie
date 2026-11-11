`timescale 1ns/1ps
module sc7f0_dualpath_tb;
    reg csr_clk=0,mem_clk=0,pcie_clk=0,rst_n=0;
    reg test_pass=0;
    wire reset_test_pass;
    sc7f0_dp_fifo_reset_checker u_reset_checker(.test_pass(reset_test_pass));
    always #5 csr_clk=~csr_clk;
    always #3.333 mem_clk=~mem_clk;
    always #4 pcie_clk=~pcie_clk;
    reg [127:0] video_data=0;reg video_valid=0,video_sof=0,video_eol=0;
    reg [31:0] sa=0,sw=0,sra=0;reg sav=0,swv=0,srv=0;reg [3:0] ss=15;
    wire sar,swr,sbv,srr,srrv;wire [1:0] sbr,sresp;wire [31:0] srd;
    wire irq;
    wire [39:0] awaddr,araddr;wire [7:0] awlen,arlen;
    wire [2:0] awsize,arsize;wire [1:0] awburst,arburst;
    wire awvalid,wvalid,wlast,bready,arvalid,rready;
    wire [127:0] wdata;wire [15:0] wstrb;
    reg awready=0,wready=0,bvalid=0,arready=0,rvalid=0,rlast=0;
    reg [127:0] rdata=0;
    wire pv,pdr,pa;wire [63:0] paddr;wire [10:0] plen;
    wire [3:0] pfirst,plast;wire [255:0] pdata;
    wire [255:0] rqdata;wire rqvalid,rqlast;wire [61:0] rquser;wire [7:0] rqkeep;
    reg rqready=0;
    wire pkt_msi_pulse;
    integer msi_pulse_cnt=0;
    always @(posedge pcie_clk) begin
        if (!rst_n) msi_pulse_cnt <= 0;
        else if (pkt_msi_pulse) msi_pulse_cnt <= msi_pulse_cnt + 1;
    end
    wire [31:0] tb_pkt_sub_cnt, tb_pkt_done_cnt, tb_pkt_err_cnt, tb_pkt_msi_cnt;
    wire [31:0] tb_pkt_bytes_lo, tb_pkt_bytes_hi, tb_pkt_fsm_state, tb_pkt_last_len;
    wire [31:0] tb_pkt_last_pts_lo, tb_pkt_last_pts_hi;
    sc7f0_dualpath dut(
        .csr_clk(csr_clk),.csr_rst_n(rst_n),.mem_clk(mem_clk),.mem_rst_n(rst_n),
        .pcie_clk(pcie_clk),.pcie_rst_n(rst_n),.video_data(video_data),
        .video_valid(video_valid),.video_sof(video_sof),.video_eol(video_eol),
        .s_awaddr(sa),.s_awvalid(sav),.s_awready(sar),.s_wdata(sw),.s_wstrb(ss),
        .s_wvalid(swv),.s_wready(swr),.s_bresp(sbr),.s_bvalid(sbv),.s_bready(1'b1),
        .s_araddr(sra),.s_arvalid(srv),.s_arready(srr),.s_rdata(srd),
        .s_rresp(sresp),.s_rvalid(srrv),.s_rready(1'b1),.irq(irq),
        .awaddr(awaddr),.awlen(awlen),.awsize(awsize),.awburst(awburst),.awvalid(awvalid),.awready(awready),
        .wdata(wdata),.wstrb(wstrb),.wlast(wlast),.wvalid(wvalid),.wready(wready),
        .bresp(2'b00),.bvalid(bvalid),.bready(bready),
        .araddr(araddr),.arlen(arlen),.arsize(arsize),.arburst(arburst),.arvalid(arvalid),.arready(arready),
        .rdata(rdata),.rresp(2'b00),.rlast(rlast),.rvalid(rvalid),.rready(rready),
        .packet_valid(pv),.packet_addr(paddr),.packet_dw_len(plen),.packet_first_be(pfirst),
        .packet_last_be(plast),.packet_data(pdata),.packet_data_ready(pdr),.packet_ack(pa),
        .packet_done_msi_pulse(pkt_msi_pulse),
        .probe_pkt_submit_cnt(tb_pkt_sub_cnt),
        .probe_pkt_done_cnt(tb_pkt_done_cnt),
        .probe_pkt_err_cnt(tb_pkt_err_cnt),
        .probe_pkt_msi_cnt(tb_pkt_msi_cnt),
        .probe_pkt_bytes_lo(tb_pkt_bytes_lo),
        .probe_pkt_bytes_hi(tb_pkt_bytes_hi),
        .probe_pkt_fsm_state(tb_pkt_fsm_state),
        .probe_pkt_last_len(tb_pkt_last_len),
        .probe_pkt_last_pts_lo(tb_pkt_last_pts_lo),
        .probe_pkt_last_pts_hi(tb_pkt_last_pts_hi));
    rq_tx_encoder #(.DATA_WIDTH(256),.KEEP_WIDTH(8),.ENABLE_C2H_BYTE_ENABLE(1)) enc(
        .clk(pcie_clk),.rst_n(rst_n),.requester_id(16'h300),
        .m_axis_rq_tdata(rqdata),.m_axis_rq_tvalid(rqvalid),.m_axis_rq_tlast(rqlast),
        .m_axis_rq_tuser(rquser),.m_axis_rq_tkeep(rqkeep),.m_axis_rq_tready(rqready),
        .irq_req_valid(1'b0),.irq_req_code(8'd0),.irq_req_ack(),
        .desc_req_valid(1'b0),.desc_req_addr(64'd0),.desc_req_dw_len(11'd0),.desc_req_tag(8'd0),.desc_req_ack(),
        .sg_req_valid(1'b0),.sg_req_addr(64'd0),.sg_req_dw_len(11'd0),.sg_req_tag(8'd0),.sg_req_ack(),
        .h2c_req_valid(1'b0),.h2c_req_addr(64'd0),.h2c_req_dw_len(11'd0),.h2c_req_tag(8'd0),.h2c_req_ack(),
        .c2h_req_valid(pv),.c2h_req_addr(paddr),.c2h_req_dw_len(plen),.c2h_req_data(pdata),
        .c2h_req_last(1'b1),.c2h_req_first_be(pfirst),.c2h_req_last_be(plast),
        .c2h_req_data_ready(pdr),.c2h_req_ack(pa));
    byte unsigned ps_mem[0:16777215];
    byte unsigned host_mem[0:2097151];
    integer mc=0,pc=0,wrleft=0,rdleft=0,bdelay=0;
    reg [39:0] wa=0,ra=0;
    integer k;
    always @(posedge mem_clk)begin
        if(!rst_n)begin awready<=0;wready<=0;arready<=0;rvalid<=0;bvalid<=0;wrleft<=0;rdleft<=0;bdelay<=0;mc<=0;end
        else begin
            mc<=mc+1;
            awready<=wrleft==0&&!bvalid&&bdelay==0&&mc%7!=2;
            wready<=wrleft!=0&&mc%11!=3;
            arready<=rdleft==0&&!rvalid&&mc%5!=1;
            if(awvalid&&awready)begin
                if(awsize!=4||awburst!=1||awaddr[3:0]||awaddr+16*(awlen+1)>16777216 ||
                   awaddr[11:0]+16*(awlen+1)>4096)$fatal(1,"bad write burst");
                wrleft<=awlen+1;wa<=awaddr;awready<=0;
            end
            if(wvalid&&wready)begin
                if(wlast!=(wrleft==1))$fatal(1,"WLAST mismatch");
                for(k=0;k<16;k=k+1)if(wstrb[k])ps_mem[wa+k]<=wdata[k*8+:8];
                wa<=wa+16;wrleft<=wrleft-1;
                if(wlast)begin wready<=0;bdelay<=6;end
            end
            if(bdelay!=0)begin bdelay<=bdelay-1;if(bdelay==1)bvalid<=1;end
            if(bvalid&&bready)bvalid<=0;
            if(arvalid&&arready)begin
                if(arsize!=4||arburst!=1||araddr[3:0]||araddr+16*(arlen+1)>16777216 ||
                   araddr[11:0]+16*(arlen+1)>4096)$fatal(1,"bad read burst");
                rdleft<=arlen+1;ra<=araddr;arready<=0;
            end
            if(rvalid&&rready)begin rvalid<=0;rdleft<=rdleft-1;ra<=ra+16;end
            if(!rvalid&&rdleft!=0&&mc%9!=2)begin
                for(k=0;k<16;k=k+1)rdata[k*8+:8]<=ps_mem[ra+k];
                rvalid<=1;rlast<=rdleft==1;
            end
        end
    end
    always @(posedge pcie_clk)if(rst_n&&$time>1000&&dut.u_tx_cdc.hf_pop===1'bx)begin
        $display("BAD_HEAD active=%b pending=%b valid=%b empty=%b rb=%b rd_en=%b",dut.u_tx_cdc.active,dut.u_tx_cdc.pending,dut.u_tx_cdc.hf_valid,dut.u_tx_cdc.u_headers.empty,dut.u_tx_cdc.u_headers.rb,dut.u_tx_cdc.u_headers.rready);
        $fatal(1,"unknown header pop");
    end
    reg in_tlp=0;reg [63:0] host_addr;
    integer dws=0,dwindex=0,first_slot,total_tlps=0,enabled_bytes=0;
    reg [3:0] fb,lb,mask;
    integer q,z,slot,index;
    always @(posedge pcie_clk)begin
        pc<=pc+1;rqready<=rst_n&&pc%5!=2;
        if(rst_n&&rqvalid&&rqready)begin
            first_slot=0;
            if(!in_tlp)begin
                if(rqdata[78:75]!=1)$fatal(1,"not MWr");
                host_addr=rqdata[63:0];dws=rqdata[74:64];dwindex=0;
                fb=rquser[3:0];lb=rquser[7:4];first_slot=4;in_tlp=1;
                if(host_addr+dws*4>2097152||host_addr[11:0]+dws*4>4096)$fatal(1,"bad host boundary");
            end
            for(q=first_slot;q<8;q=q+1)if(rqkeep[q])begin
                if(dwindex>=dws)$fatal(1,"too many payload DWORDs");
                mask=dwindex==0?fb:dwindex==dws-1?lb:4'hf;
                for(z=0;z<4;z=z+1)if(mask[z])begin
                    host_mem[host_addr+dwindex*4+z]=rqdata[q*32+z*8+:8];enabled_bytes=enabled_bytes+1;
                end
                dwindex=dwindex+1;
            end
            if(rqlast)begin
                if(dwindex!=dws)$fatal(1,"short MWr");
                total_tlps=total_tlps+1;in_tlp=0;
            end
        end
    end
    task automatic put(input integer address,input reg [31:0] value);
        begin
            @(negedge csr_clk);sa=address;sw=value;sav=1;swv=1;
            fork
                begin do @(posedge csr_clk);while(!sar);@(negedge csr_clk);sav=0;end
                begin do @(posedge csr_clk);while(!swr);@(negedge csr_clk);swv=0;end
            join
            do @(posedge csr_clk);while(!sbv);
            if(sbr!=0)$fatal(1,"AXIL write rejected addr=%x resp=%x",address,sbr);
            @(negedge csr_clk);
        end
    endtask
    task automatic get(input integer address,output reg [31:0] value);
        begin
            @(negedge csr_clk);sra=address;srv=1;
            do @(posedge csr_clk);while(!srr);
            @(negedge csr_clk);srv=0;
            do @(posedge csr_clk);while(!srrv);
            if(sresp!=0)$fatal(1,"AXIL read rejected %x",address);
            value=srd;@(negedge csr_clk);
        end
    endtask
    task automatic wait_status(input integer bitno);
        reg [31:0] s;integer n;
        begin n=0;s=0;while(!s[bitno])begin get(8,s);n=n+1;if(n>100000)$fatal(1,"status timeout bit=%d",bitno);end end
    endtask
    task automatic arm_frame(input integer w,h,stride,ybase,uvbase);
        begin
            put('h40,ybase);put('h44,0);put('h48,uvbase);put('h4c,0);
            put('h50,(h<<16)|w);put('h54,stride);put('h58,'h12345678);put('h5c,0);put('hc,1);
            repeat(35)@(posedge mem_clk);
        end
    endtask
    task automatic raster(input integer w,h);
        integer x,y,p;reg [127:0] pixels;
        begin
            for(y=0;y<h;y=y+1)for(x=0;x<w;x=x+4)begin
                pixels=0;
                for(p=0;p<4;p=p+1)begin
                    pixels[p*32+:8]=(x+p+y)&255;
                    pixels[p*32+8+:8]=80+(x+p)%32;
                    pixels[p*32+16+:8]=100+y%32;
                end
                @(negedge mem_clk);video_valid=1;video_sof=(x==0&&y==0);video_eol=(x==w-4);video_data=pixels;
            end
            @(negedge mem_clk);video_valid=0;video_sof=0;video_eol=0;
        end
    endtask
    task automatic check_frame(input integer w,h,stride,ybase,uvbase);
        reg [31:0] v;integer x,y,expected;
        begin
            wait_status(2);get('h214,v);if(v!=0)$fatal(1,"capture status=%x",v);
            get('h210,v);if(v!='h12345678)$fatal(1,"capture cookie");
            get('h218,v);if(v!=w*h*3/2)$fatal(1,"capture byte count %d",v);
            for(y=0;y<h;y=y+1)for(x=0;x<w;x=x+1)
                if(ps_mem[ybase+y*stride+x]!==((x+y)&255))$fatal(1,"Y mismatch x=%d y=%d actual=%x",x,y,ps_mem[ybase+y*stride+x]);
            for(y=0;y<h/2;y=y+1)for(x=0;x<w;x=x+2)begin
                expected=81+x%32;
                if(ps_mem[uvbase+y*stride+x]!==expected[7:0])$fatal(1,"U mismatch x=%d y=%d got=%x",x,y,ps_mem[uvbase+y*stride+x]);
                expected=101+(y*2)%32;
                if(ps_mem[uvbase+y*stride+x+1]!==expected[7:0])$fatal(1,"V mismatch");
            end
            put('h10,1);$display("NV12_DDR_PASS %dx%d stride%d",w,h,stride);
        end
    endtask
    task automatic packet(input integer n);
        integer i;reg [31:0] v;
        begin
            for(i=0;i<n+32;i=i+1)ps_mem['hf00ff0+i]=(i*17+3)&255;
            for(i=0;i<n+16;i=i+1)host_mem['h100ff0+i]='ha5;
            put('h80,'hf00ff0);put('h84,0);put('h88,'h100ff0);put('h8c,0);
            put('h90,n);put('h94,n+16);put('h98,'h1ff000);put('h9c,0);
            put('ha0,'h55667788);put('ha4,'h11223344);put('ha8,0);put('hac,0);
            put('hb0,n);put('hb4,0);put('hb8,17);put('hbc,0);
            put('hc0,3);put('hc4,7);put('hc8,'h87654321);put('hcc,1);put('hd0,150000000);
            put('h14,1);wait_status(3);
            get('h244,v);if(v!=0)$fatal(1,"packet status=%x",v);
            for(i=0;i<n;i=i+1)if(host_mem['h100ff0+i]!==ps_mem['hf00ff0+i])$fatal(1,"packet %d byte %d mismatch",n,i);
            for(i=n;i<n+16;i=i+1)if(host_mem['h100ff0+i]!==8'ha5)$fatal(1,"packet tail overwritten %d",n);
            if({host_mem['h1ff003],host_mem['h1ff002],host_mem['h1ff001],host_mem['h1ff000]}!==32'h44504331)$fatal(1,"completion magic/order");
            if({host_mem['h1ff01f],host_mem['h1ff01e],host_mem['h1ff01d],host_mem['h1ff01c],host_mem['h1ff01b],host_mem['h1ff01a],host_mem['h1ff019],host_mem['h1ff018]}!==64'h1122334455667788)$fatal(1,"completion PTS");
            put('h18,1);$display("PACKET_PASS bytes=%d",n);
        end
    endtask
    initial begin
        #300;rst_n=1;repeat(40)@(posedge csr_clk);
        arm_frame(64,8,80,'h1000,'h8000);raster(64,8);check_frame(64,8,80,'h1000,'h8000);
        packet(1);packet(3);packet(4);packet(15);packet(16);packet(17);
        packet(255);packet(256);packet(257);packet(4095);packet(4096);packet(4097);
        arm_frame(3840,2160,3840,'h10000,'ha00000);
        fork raster(3840,2160);begin #10000;packet(65537);end join
        check_frame(3840,2160,3840,'h10000,'ha00000);
        begin
            reg [31:0] pv;
            get('h100, pv); if(pv != 13) $fatal(1, "Probe PKT_SUBMIT_CNT exp 13 got %0d", pv);
            get('h104, pv); if(pv != 13) $fatal(1, "Probe PKT_DONE_CNT exp 13 got %0d", pv);
            get('h108, pv); if(pv != 0)  $fatal(1, "Probe PKT_ERR_CNT exp 0 got %0d", pv);
            get('h10c, pv); if(pv != 13) $fatal(1, "Probe PKT_MSI_CNT exp 13 got %0d", pv);
            get('h110, pv); if(pv != 78649) $fatal(1, "Probe PKT_BYTES_LO exp 78649 got %0d", pv);
            get('h114, pv); if(pv != 0)  $fatal(1, "Probe PKT_BYTES_HI exp 0 got %0d", pv);
            get('h11c, pv); if(pv != 65537) $fatal(1, "Probe PKT_LAST_LEN exp 65537 got %0d", pv);
            get('h120, pv); if(pv != 32'h55667788) $fatal(1, "Probe PKT_LAST_PTS_LO exp 55667788 got %x", pv);
            get('h124, pv); if(pv != 32'h11223344) $fatal(1, "Probe PKT_LAST_PTS_HI exp 11223344 got %x", pv);
            if (msi_pulse_cnt != 13) $fatal(1, "packet_done_msi_pulse count exp 13 got %0d", msi_pulse_cnt);
            $display("SC7F0_PROBES_ALL_VERIFIED_PASS submit=13 done=13 msi=%0d bytes=78649", msi_pulse_cnt);
        end
        if(!reset_test_pass)$fatal(1,"FIFO reset checker did not pass");
        test_pass=1;$display("SC7F0_DUALPATH_SIM_PASS tlps=%d enabled_bytes=%d",total_tlps,enabled_bytes);$finish;
    end
    initial begin #30000000;$fatal(1,"global timeout");end
endmodule

// A PCIe link release must not directly clock-enable the 100MHz CSR FIFO.
// Verify independent clocks, off-edge reset pulses, flush and ordered reuse.
module sc7f0_dp_fifo_reset_checker(output reg test_pass=0);
    reg wc=0,rc=0,wn=0,rn=0,wv=0;
    reg [31:0] wd=0;
    wire ready,valid;wire [31:0] data;
    time last_read_edge=0;
    reg checking=0;
    always #3.333 wc=~wc;
    always #5 rc=~rc;
    always @(posedge rc)last_read_edge=$time;
    always @(posedge valid)if(checking && $time!=last_read_edge)
        $fatal(1,"FIFO VALID rose outside read clock edge");
    sc7f0_dp_fifo #(.WIDTH(32)) q(
        .wclk(wc),.wrst_n(wn),.wdata(wd),.wvalid(wv),.wready(ready),
        .rclk(rc),.rrst_n(rn),.rdata(data),.rvalid(valid),.rready(1'b0));
    task automatic send(input [31:0] v);
        begin
            @(negedge wc);wd=v;wv=1;
            do @(posedge wc);while(!ready);
            @(negedge wc);wv=0;
        end
    endtask
    initial begin
        #123;wn=1;rn=1;
        repeat(40)@(posedge rc);checking=1;
        send(32'h11223344);wait(valid);#1;
        if(data!==32'h11223344)$fatal(1,"FIFO initial data");
        @(negedge rc);#1;rn=0;#1;
        if(valid!==0)$fatal(1,"FIFO reset did not inhibit VALID");
        rn=1;
        // No immediate reappearance when an asynchronous reset is released.
        #1;if(valid!==0)$fatal(1,"FIFO async release leaked VALID");
        repeat(40)@(posedge rc);#1;
        if(valid!==0)$fatal(1,"FIFO stale entry survived flush");
        send(32'h55667788);wait(valid);#1;
        if(data!==32'h55667788)$fatal(1,"FIFO data after reset");
        test_pass=1;$display("DP_FIFO_RESET_PASS");
    end
endmodule
