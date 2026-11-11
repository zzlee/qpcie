`timescale 1ns/1ps
module sc7f0_tap_stop_ack_tb;
  reg clk=0,mclk=0,run_mem=1,rst_n=0,mrst_n=0;
  always #5 clk=~clk;
  always #3.7 if(run_mem)mclk=~mclk;
  reg [31:0] awaddr=0,wdata=0,araddr=0;
  reg awv=0,wv=0,arv=0,br=1,rr=1; reg [3:0] strb=15;
  wire awr,wr,bv,arr,rv; wire [1:0] bresp,rresp; wire [31:0] rdata;
  reg busy=0;reg [31:0] started=0;reg [159:0] metadata=0;reg meta_valid=0;
  wire meta_ready,en;wire [15:0] width,height;wire cv,cc;wire [15:0] ca;
  reg inject_race=0;integer outstanding=0;reg [31:0] previous_ack=0;
  reg test_pass=0;
  sc7f0_tap_regs dut(.clk(clk),.rst_n(rst_n),.m_clk(mclk),.m_rst_n(mrst_n),
    .s_awaddr(awaddr),.s_awvalid(awv),.s_awready(awr),
    .s_wdata(wdata),.s_wstrb(strb),.s_wvalid(wv),.s_wready(wr),
    .s_bresp(bresp),.s_bvalid(bv),.s_bready(br),
    .s_araddr(araddr),.s_arvalid(arv),.s_arready(arr),
    .s_rdata(rdata),.s_rresp(rresp),.s_rvalid(rv),.s_rready(rr),
    .enable(en),.width(width),.height(height),.credit_valid(cv),.credit_clear(cc),.credit_add(ca),
    .busy(busy),.drops(32'd0),.started_count(started),.ticks_gray(64'd0),
    .meta_data(metadata),.meta_valid(meta_valid),.meta_ready(meta_ready),
    .writer_rst_n(),.csc_rst_n());
  always @(posedge mclk) begin
    if(inject_race&&dut.cv&&!dut.config_word[49]&&!dut.config_word[0])begin
      // Frame admission uses the pre-edge enable, exactly as the real tap.
      busy<=1;started<=started+1;outstanding<=1;inject_race<=0;
    end
    #0.1;
    if(mrst_n)begin
      if((dut.stop_ack_m-previous_ack)>32'd1)$fatal(1,"Non-Gray-safe ACK jump");
      if(dut.stop_ack_m!=previous_ack&&(busy||en||outstanding!=0))$fatal(1,"ACK before local quiescence");
      previous_ack=dut.stop_ack_m;
    end else previous_ack=0;
  end
  task put(input [31:0] addr,input [31:0] value,input [1:0] expected);
    reg ad,wd;integer n;
    begin
      @(negedge clk);awaddr=addr;wdata=value;awv=1;wv=1;ad=0;wd=0;n=0;
      while(!ad||!wd)begin
        @(posedge clk);if(awv&&awr)ad=1;if(wv&&wr)wd=1;
        @(negedge clk);if(ad)awv=0;if(wd)wv=0;
        n=n+1;if(n>100)$fatal(1,"Write address/data timeout");
      end
      n=0;while(!bv)begin @(negedge clk);n=n+1;if(n>100)$fatal(1,"Write response timeout");end
      if(bresp!==expected)$fatal(1,"Write %h=%h response %h expected %h req=%d ready=%b valid=%b loop=%d",addr,value,bresp,expected,dut.stop_requested,dut.ready,dut.valid,i);
      @(negedge clk);
    end
  endtask
  task get(input [31:0] addr,output [31:0] value);
    integer n;
    begin
      @(negedge clk);araddr=addr;arv=1;
      do @(posedge clk);while(!arr);
      @(negedge clk);arv=0;n=0;
      while(!rv)begin @(negedge clk);n=n+1;if(n>100)$fatal(1,"Read timeout");end
      if(rresp!==0 || ^rdata===1'bx)$fatal(1,"Invalid read");
      value=rdata;@(negedge clk);
    end
  endtask
  task expect_ack(input [31:0] expected);
    reg [31:0] v;integer n;
    begin
      n=0;get('h06c,v);
      while(v!=expected)begin get('h06c,v);n=n+1;if(n>200)$fatal(1,"ACK timeout got %d expected %d",v,expected);end
    end
  endtask
  task hold_ack(input [31:0] expected);
    reg [31:0] v;integer n;
    begin
      for(n=0;n<30;n=n+1)begin get('h06c,v);if(v!==expected)$fatal(1,"ACK advanced early %d",v);end
    end
  endtask
  task complete_dma_and_pop;
    reg [31:0] v;integer n;
    begin
      // Real integration POP must follow DMA AP_DONE / all write responses.
      @(negedge mclk);outstanding=0;meta_valid=1;
      do @(posedge mclk);while(!meta_ready);
      @(negedge mclk);meta_valid=0;n=0;
      get('h008,v);while(!v[2])begin get('h008,v);n=n+1;if(n>100)$fatal(1,"Metadata timeout");end
      put('h01c,1,0);
    end
  endtask
  reg [31:0] v;integer i,filled;
  initial begin
    repeat(8)@(negedge clk);rst_n=1;mrst_n=1;
    wait(dut.ready===1);repeat(4)@(negedge clk);
    get('h004,v);if(v!==32'h00010001)$fatal(1,"Wrong stop-barrier ABI");
    put('h00c,1,0);wait(en);@(negedge mclk);started=1;busy=1;outstanding=1;
    put('h00c,0,0);get('h068,v);if(v!==1)$fatal(1,"Missing request token");hold_ack(0);
    @(negedge mclk);busy=0;hold_ack(0); // tap finished, DMA still owns memory
    complete_dma_and_pop();expect_ack(1);
    @(negedge mclk);run_mem=0;
    put('h00c,1,0);put('h00c,0,0);
    get('h008,v);if(v[3]||v[0])$fatal(1,"Expected old idle status for negative control");
    get('h068,v);if(v!==2)$fatal(1,"Wrong stopped-clock request");hold_ack(1);
    run_mem=1;expect_ack(2);
    put('h00c,1,0);wait(en);inject_race=1;put('h00c,0,0);wait(!inject_race);
    hold_ack(2);@(negedge mclk);busy=0;hold_ack(2);
    complete_dma_and_pop();expect_ack(3);
    @(negedge mclk);run_mem=0;
    // Nominal XPM depth16/FWFT exposes15 usable slots. Obey READY instead
    // of inventing a credit; also verify useful capacity and full rejection.
    filled=0;get('h008,v);
    while(v[1] && filled<32)begin
      put('h00c,0,0);filled=filled+1;get('h008,v);
    end
    if(filled<4 || filled>16)$fatal(1,"Unexpected usable FIFO capacity %d",filled);
    put('h00c,0,2'b10);get('h068,v);if(v!==3+filled)$fatal(1,"Rejected command consumed token");
    hold_ack(3);run_mem=1;expect_ack(3+filled);
    // Coalescing must catch up in unit steps, never jump the binary ACK.
    get('h02c,v);if(v!==2)$fatal(1,"Wrong retirement accounting");
    test_pass=1;$display("SC7F0_STOP_ACK_PASS: stopped-clock stale idle, admission race, DMA drain, coalescing and full queue");$finish;
  end
  initial begin #1000000;$fatal(1,"Stop ACK test timeout");end
endmodule
