`timescale 1ns/1ps
// An encoder can own an MRd before ingress 'outstanding' has incremented.
// Exercise that window on the real 256-bit encoder and the real ingress.
module sc7f0_flip_rq_drain_tb;
    reg clk=0,mclk=0,rst=0,mode=0,submit=0,blank=0,ready=0,cpl=0;
    always #4 clk=!clk;
    always #1.667 mclk=!mclk;
    wire req,ack,rqvalid,go,debt,quiet,busy,done,abort_evt,drained,fault;
    wire [63:0] a,run_addr; wire [10:0] dw; wire [7:0] tag;
    wire [3:0] first_be,last_be; wire [5:0] outstanding;
    wire [255:0] rq; wire [15:0] run_cap;
    reg [7:0] return_tag;
    wire mux=mode || go || fault;
    sc7f0_flip_scheduler #(.FRAME_BYTES(256)) sched (
        .clk(clk),.rst_n(rst),.run_ok(1'b1),.mode(mode),.submit(submit),.blank(blank),
        .cookie(32'd77),.bytes(32'd256),.shown(32'd0),.addr(64'h1000),.cap(16'd32),
        .busy(busy),.debt(debt),.quiet(quiet && !req),.issue_idle(!req && outstanding==0 && !debt),
        .done(done),.abort_evt(abort_evt),.run_addr(run_addr),.run_cap(run_cap),
        .go(go),.drained(drained),.fault(fault));
    sc7f0_overlay_ingress ingress (
        .clk(clk),.rst_n(rst),.epoch_rst_n(rst),.ovl_enable(mux && !fault),
        .ovl_go(go),.quiesce(mux && !mode),.discard_pending(1'b0),
        .ovl_src_addr(run_addr),.ovl_xfer_bytes(32'd256),.ovl_max_bytes_per_req(run_cap),
        .src_cookie(32'd77),.mrd_req_valid(req),.mrd_req_ack(ack),
        .mrd_req_addr(a),.mrd_req_dw_len(dw),.mrd_req_tag(tag),
        .mrd_req_first_be(first_be),.mrd_req_last_be(last_be),
        .ovl_cpl_valid(cpl),.ovl_cpl_data(256'd0),.ovl_cpl_dw_count(4'd8),
        .ovl_cpl_tag(return_tag),.ovl_cpl_last(1'b1),.ovl_outstanding(outstanding),
        .ovl_busy(busy),.ovl_quiesced(quiet),.ovl_quarantined(debt),
        .ovl_done_pulse(done),.ovl_abort_evt(abort_evt),.mem_clk(mclk),
        .mem_rst_n(rst),.m_axis_tready(1'b0));
    rq_tx_encoder #(.DATA_WIDTH(256),.ENABLE_OVL_REQ(1)) enc (
        .clk(clk),.rst_n(rst),.requester_id(16'h123),
        .irq_req_valid(1'b0),.desc_req_valid(1'b0),.sg_req_valid(1'b0),
        .h2c_req_valid(1'b0),.c2h_req_valid(1'b0),.c2h_req_dw_len(11'd0),
        .m_axis_rq_tready(ready),.m_axis_rq_tvalid(rqvalid),.m_axis_rq_tdata(rq),
        .ovl_req_valid(req),.ovl_req_ack(ack),.ovl_req_addr(a),.ovl_req_dw_len(dw),
        .ovl_req_tag(tag),.ovl_req_first_be(first_be),.ovl_req_last_be(last_be));
    integer accepted=0;
    always @(posedge clk) if(rqvalid && ready) accepted=accepted+1;
    initial begin
        repeat(40) @(negedge clk);rst=1;repeat(30) @(negedge clk);
        mode=1;submit=1;@(negedge clk);submit=0;blank=1;@(negedge clk);blank=0;
        wait(rqvalid); @(negedge clk);
        if(outstanding!=0 || rq[63:0]!=64'h1000 || rq[74:64]!=8) $fatal;
        return_tag=rq[103:96]; mode=0;
        repeat(40) begin @(negedge clk);if(!req || !go || drained || fault) $fatal;end
        ready=1;@(negedge clk);ready=0;wait(outstanding==1);
        repeat(20) begin @(negedge clk);if(!go || drained || fault) $fatal;end
        cpl=1;@(negedge clk);cpl=0;wait(drained);
        repeat(40) begin @(negedge clk);if(!drained || rqvalid || req || fault) $fatal;end
        if(accepted!=1) $fatal;
        $display("FLIP_RQ_DRAIN_PASS: 1 stalled header, 1 returned MRd, zero reads after DRAINED");$finish;
    end
    initial begin #15000;$fatal(1,"watchdog");end
endmodule
