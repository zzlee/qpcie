// Elastic 4-PPC RGB byte-order R,G,B,X -> limited-range BT.709 Y,U,V,X.
// Three stages; bypass has identical latency. A common CE holds data and
// SOF/EOL stable under backpressure. Coefficients use Q8, rounded to nearest.
`timescale 1ns/1ps
module video_rgb_to_yuv709 (
    input wire clk, rst_n, enable,
    input wire [127:0] s_data,
    input wire s_valid, s_sof, s_eol,
    output wire s_ready,
    output wire [127:0] m_data,
    output wire m_valid, m_sof, m_eol,
    input wire m_ready
);
    reg [2:0] valid_q, sof_q, eol_q, enable_q;
    reg [127:0] bypass0, bypass1;
    wire advance = !valid_q[2] || m_ready;
    assign s_ready = advance;
    assign m_valid = valid_q[2];
    assign m_sof = sof_q[2];
    assign m_eol = eol_q[2];
    always @(posedge clk) begin
        if (!rst_n) begin
            valid_q <= 0; sof_q <= 0; eol_q <= 0; enable_q <= 0;
            bypass0 <= 0; bypass1 <= 0;
        end else if (advance) begin
            valid_q <= {valid_q[1:0], s_valid};
            sof_q <= {sof_q[1:0], s_sof};
            eol_q <= {eol_q[1:0], s_eol};
            enable_q <= {enable_q[1:0], enable};
            bypass0 <= s_data;
            bypass1 <= bypass0;
        end
    end
    genvar p;
    generate for (p=0; p<4; p=p+1) begin : pixel
        wire signed [8:0] r = $signed({1'b0, s_data[p*32 +: 8]});
        wire signed [8:0] g = $signed({1'b0, s_data[p*32+8 +: 8]});
        wire signed [8:0] b = $signed({1'b0, s_data[p*32+16 +: 8]});
        (* use_dsp = "yes" *) reg signed [18:0] yr, yg, yb, ur, ug, ub, vr, vg, vb;
        reg signed [19:0] y, u, v;
        reg [31:0] out_q;
        assign m_data[p*32 +: 32] = out_q;
        always @(posedge clk) begin
            if (!rst_n) begin
                yr<=0; yg<=0; yb<=0; ur<=0; ug<=0; ub<=0;
                vr<=0; vg<=0; vb<=0; y<=0; u<=0; v<=0; out_q<=0;
            end else if (advance) begin
                yr <= r * 9'sd47; yg <= g * 9'sd157; yb <= b * 9'sd16;
                ur <= r * -9'sd26; ug <= g * -9'sd86; ub <= b * 9'sd112;
                vr <= r * 9'sd112; vg <= g * -9'sd102; vb <= b * -9'sd10;
                y <= yr + yg + yb + 20'sd4224;
                u <= ur + ug + ub + 20'sd32896;
                v <= vr + vg + vb + 20'sd32896;
                out_q <= enable_q[1] ? {8'd0, v[15:8], u[15:8], y[15:8]} :
                                      bypass1[p*32 +: 32];
            end
        end
    end endgenerate
endmodule
