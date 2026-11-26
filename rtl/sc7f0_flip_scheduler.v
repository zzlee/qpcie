`default_nettype none
module sc7f0_flip_scheduler #(parameter FRAME_BYTES=33177600)(
    input wire clk, rst_n, run_ok, mode, submit, blank,
    input wire [31:0] cookie, bytes, shown,
    input wire [63:0] addr,
    input wire [15:0] cap,
    input wire busy, debt, quiet, issue_idle, done, abort_evt,
    output reg [31:0] admitted, pending, active, retired, run_cookie,
    output reg [63:0] run_addr,
    output reg [15:0] run_cap,
    output reg go, fault, drained
);
    reg [63:0] next_addr;
    reg [15:0] next_cap;
    reg running, selected;
    reg epoch_ready;
    // FPGA configuration INIT, intentionally no PCIe, DMA or video reset.
    // Software may still own a mapping and the video side may still hold
    // its cookie when PCIe reports a fresh function. Never mint it again.
    initial admitted = 32'd0;
    wire epoch_lost = (admitted!=0) && !epoch_ready;
    wire accept = rst_n && epoch_ready && mode && run_ok && !abort_evt &&
                  !debt && !fault && submit && !pending && cookie>admitted &&
                  bytes==FRAME_BYTES && addr[4:0]==0 && cap[4:0]==0;
    always @(posedge clk) if (accept) admitted<=cookie;
    // GO is a maintained arm, not a pulse: ingress treats a falling GO as
    // abandonment. running covers the gap BEFORE busy rises.
    wire safe = !busy && !debt && quiet;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            epoch_ready<=0; pending<=0; active<=0; retired<=0; run_cookie<=0;
            run_addr<=0; run_cap<=0; next_addr<=0; next_cap<=0;
            running<=0; selected<=0; go<=0; fault<=0; drained<=0;
        end else begin
            drained<=0;
            if (!admitted) epoch_ready<=1;
            if (epoch_lost || ((mode || running) && !run_ok) || (go && (abort_evt || debt))) begin
                fault<=1; go<=0; running<=0;
            end else if (!mode && !fault) begin
                // Quiesce stops NEW issue combinationally when mode falls.
                // Keep GO/ingress selection while any encoder header or
                // accepted host read remains. A blocked RQ is not idle.
                if (issue_idle) begin go<=0; running<=0; end
                if (!running && !go && safe && issue_idle && run_ok) begin
                    drained<=1; pending<=0; active<=0; selected<=0;
                    run_cookie<=0;
                end
            end else if (mode && !fault) begin
                if (accept) begin
                    pending<=cookie; next_addr<=addr; next_cap<=cap;
                end
                if (done) begin running<=0; go<=0; end
                if (blank && safe && !running && (pending!=0 || active!=0)) begin
                    if (pending!=0 && !selected) begin
                        run_addr<=next_addr; run_cap<=next_cap;
                        run_cookie<=pending; selected<=1;
                    end
                    go<=1; running<=1;
                end
                if (selected && pending!=0 && shown==pending) begin
                    retired<=active; active<=pending; pending<=0; selected<=0;
                end
            end
        end
    end
endmodule
`default_nettype wire
