`default_nettype none
`timescale 1ns/1ps
// Two read masters, one outstanding transaction. Buffered AR and locked R owner.
module sc7f0_axi_read_arbiter # (parameter AW=49)(
    input wire clk,rst_n,
    input wire [AW-1:0] s0_addr,input wire [7:0] s0_len,input wire [2:0] s0_size,input wire [1:0] s0_burst,
    input wire s0_valid,output wire s0_ready,output wire [127:0] s0_data,output wire [1:0] s0_resp,
    output wire s0_last,s0_rvalid,input wire s0_rready,
    input wire [AW-1:0] s1_addr,input wire [7:0] s1_len,input wire [2:0] s1_size,input wire [1:0] s1_burst,
    input wire s1_valid,output wire s1_ready,output wire [127:0] s1_data,output wire [1:0] s1_resp,
    output wire s1_last,s1_rvalid,input wire s1_rready,
    output reg [AW-1:0] m_addr,output reg [7:0] m_len,output reg [2:0] m_size,output reg [1:0] m_burst,
    output wire m_valid,input wire m_ready,input wire [127:0] m_data,input wire [1:0] m_resp,
    input wire m_last,m_rvalid,output wire m_rready
);
    reg [1:0] state;reg owner,previous;
    wire choose1=s1_valid&&(!s0_valid||!previous);
    assign s0_ready=rst_n&&state==0&&!choose1;
    assign s1_ready=rst_n&&state==0&&choose1;
    assign m_valid=state==1;
    assign s0_data=m_data;assign s1_data=m_data;
    assign s0_resp=m_resp;assign s1_resp=m_resp;
    assign s0_last=m_last;assign s1_last=m_last;
    assign s0_rvalid=state==2&&!owner&&m_rvalid;
    assign s1_rvalid=state==2&&owner&&m_rvalid;
    assign m_rready=state==2&&(owner?s1_rready:s0_rready);
    always @(posedge clk)begin
        if(!rst_n)begin state<=0;owner<=0;previous<=1;m_addr<=0;m_len<=0;m_size<=0;m_burst<=0;end
        else case(state)
            0:if(s0_valid||s1_valid)begin
                owner<=choose1;m_addr<=choose1?s1_addr:s0_addr;m_len<=choose1?s1_len:s0_len;
                m_size<=choose1?s1_size:s0_size;m_burst<=choose1?s1_burst:s0_burst;state<=1;
            end
            1:if(m_ready)state<=2;
            2:if(m_rvalid&&m_rready&&m_last)begin state<=0;previous<=owner;end
            default:state<=0;
        endcase
    end
endmodule
`default_nettype wire
