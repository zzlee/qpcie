// Exercise the ACTUAL custom_pcie_dma_top packet-boundary arbiter. Unrelated
// IPs are left unresolved by iverilog -i; only requester inputs/sink are forced.
`timescale 1ns/1ps
module sc7f0_packet_arb_tb;
    reg clk=0,rst=0;always #4 clk=~clk;
    reg packet=1,sg=0,audio=0;
    reg [3:0] videos=1;
    wire [3:0] audio_vector={3'd0,audio};
    reg ack=0;
    wire pack_ready,pack_ack;
    custom_pcie_dma_top #(.PCIE_DATA_WIDTH(256),.PCIE_KEEP_WIDTH(8),
        .NUM_VIDEO_CH(4),.NUM_AUDIO_CH(4),.VIDEO_DATA_WIDTH(128),.ENABLE_PACKET_C2H(1)) dut(
        .clk(clk),.rst_n(rst),.packet_req_valid(packet),.packet_req_addr(64'h3000),
        .packet_req_dw_len(11'd7),.packet_req_data(256'h1234),
        .packet_req_first_be(4'hf),.packet_req_last_be(4'h3),
        .packet_req_data_ready(pack_ready),.packet_req_ack(pack_ack));
    integer raw_count=0,packet_count=0,i;
    reg [7:0] owner;
    initial begin
        force dut.dma_rst_n=rst;
        force dut.sg_c2h_req_valid=sg;
        force dut.sg_c2h_req_addr=64'h1000;
        force dut.sg_c2h_req_dw_len=11'd4;
        force dut.sg_c2h_req_data=128'd0;
        force dut.sg_c2h_req_last=1'b1;
        force dut.v_c2h_req_valid=videos;
        force dut.v_c2h_req_addr=256'h2000;
        force dut.v_c2h_req_dw_len=44'd64;
        force dut.v_c2h_req_data=1024'h99;
        force dut.v_c2h_req_last=4'hf;
        force dut.a_c2h_req_valid=audio_vector;
        force dut.a_c2h_req_addr=256'h4000;
        force dut.a_c2h_req_dw_len=44'd4;
        force dut.a_c2h_req_data=512'd0;
        force dut.a_c2h_req_last=4'hf;
        force dut.c2h_req_data_ready_mux=1'b1;
        force dut.c2h_req_ack_mux=ack;
        repeat(3)@(negedge clk);rst=1;
        for(i=0;i<20;i=i+1)begin
            @(negedge clk);owner=dut.c2h_owner;
            if(owner!=2&&owner!=10)$fatal(1,"unexpected owner %d",owner);
            if(owner==10)begin
                if(!pack_ready||dut.c2h_last_be_mux!=3||dut.c2h_req_addr_mux!='h3000)$fatal(1,"packet mux");
                packet_count=packet_count+1;
            end else begin
                if(pack_ready||dut.c2h_last_be_mux!=15||dut.c2h_req_addr_mux!='h2000)$fatal(1,"raw mux");
                raw_count=raw_count+1;
            end
            repeat(3)begin @(negedge clk);if(dut.c2h_owner!=owner)$fatal(1,"mid-TLP preemption");end
            ack=1;
            #1;if(pack_ack!=(owner==10))$fatal(1,"ack routing");
            @(negedge clk);ack=0;
            @(negedge clk);
        end
        if(raw_count!=10||packet_count!=10)$fatal(1,"fairness raw=%d packet=%d",raw_count,packet_count);
        // Retire current owner, then make high-priority sources pending.
        sg=1;audio=1;ack=1;@(negedge clk);ack=0;@(negedge clk);
        if(dut.c2h_owner!=1||pack_ready)$fatal(1,"SG priority");
        sg=0;ack=1;@(negedge clk);ack=0;@(negedge clk);
        if(dut.c2h_owner!=6||pack_ready)$fatal(1,"audio priority");
        $display("PACKET_ARBITER_PASS: nonpreemptive, raw/packet fairness, SG/audio priority");$finish;
    end
    initial begin #10000;$fatal(1,"timeout");end
endmodule
