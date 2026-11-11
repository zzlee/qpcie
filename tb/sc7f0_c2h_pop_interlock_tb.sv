// ============================================================================
// Regression: C2H arbitration grant vs. FWFT payload pop interlock.
//
// Reproduces the SC7F0 dual-stream "DPC1 mismatch" where a completion slot at
// comp_phys received the payload DWORDs of packet offset 17952, i.e. every TLP
// was shifted by exactly one 256-bit beat. The trigger is a thin descriptor
// fetch MRd offered in the same window as a pending packet C2H TLP that keeps
// VALID asserted through the cycle after its own ack, which is exactly what
// rtl/thin_desc_fetch_engine.v does (mrd_req_valid clears a cycle after
// mrd_req_ack).
//
// Instantiates the REAL custom_pcie_dma_top packet arbiter and the REAL
// rq_tx_encoder (256-bit DWORD-aligned mode). Unrelated IPs are left
// unresolved with iverilog -i and their requester inputs are forced inactive.
// The packet source mirrors the sc7f0_packet_cdc read side: one resident TLP,
// FWFT payload, level VALID, irreversible pop on data_ready, retire on ack.
// ============================================================================
`timescale 1ns/1ps

module sc7f0_c2h_pop_interlock_tb;
    localparam integer NVID = 4, NAUD = 4, WIDTH = 256;
    localparam [7:0] PACKET_OWNER = 8'd2 + NVID + NAUD;
    localparam integer NPKT = 48;

    reg clk = 0, rst = 0;
    always #4 clk = ~clk;

    // ------------------------------------------------------------------------
    // Golden payload. DWORD j of packet p carries its own identity:
    // [31:16] = packet index, [15:0] = DWORD offset, so a mismatch reports
    // exactly which offset landed in which slot (the reverse lookup the board
    // evidence required).
    // ------------------------------------------------------------------------
    function [31:0] golden_dw;
        input integer p, j;
        golden_dw = {p[15:0], j[15:0]};
    endfunction

    reg  [255:0] beat_mem  [0:511];
    integer      b_first   [0:NPKT-1];
    integer      b_count   [0:NPKT-1];
    integer      p_dwlen   [0:NPKT-1];
    reg  [3:0]   p_last_be [0:NPKT-1];
    reg  [63:0]  p_exp_addr[0:NPKT-1];
    integer      total_beats;
    integer      pi, j, dw;

    initial begin
        total_beats = 0;
        for (pi = 0; pi < NPKT; pi = pi + 1) begin
            b_count[pi] = 1 + ((pi * 7 + 3) % 5);          // 1..5 source beats
            p_dwlen[pi] = b_count[pi] * 8 - ((pi % 3) * 3); // sometimes a short tail
            p_exp_addr[pi] = 64'h0000_013b_4150_0000 + pi * 64'h4000;
            for (j = 0; j < b_count[pi] * 8; j = j + 1)
                beat_mem[total_beats + (j/8)][(j%8)*32 +: 32] =
                    (j < p_dwlen[pi]) ? golden_dw(pi, j) : 32'h0;
            b_first[pi] = total_beats;
            total_beats = total_beats + b_count[pi];
            dw = p_dwlen[pi] % 8;
            p_last_be[pi] = (dw == 0) ? 4'hf : (dw <= 2 ? 4'h3 : 4'hf);
        end
    end

    // ------------------------------------------------------------------------
    // DUT + packet source model
    // ------------------------------------------------------------------------
    wire [WIDTH-1:0] rq_tdata;
    wire             rq_tvalid, rq_tlast;
    wire [61:0]      rq_tuser;
    wire [7:0]       rq_tkeep;
    reg              rq_tready = 1;

    integer rp = 0, bp = 0, gap = 0, pop_count = 0;
    reg     src_valid = 0;
    reg     [255:0] src_data = 0;
    wire    src_ready, src_ack;

    always @(*) src_data = beat_mem[b_first[rp] + bp];

    custom_pcie_dma_top #(
        .PCIE_DATA_WIDTH(WIDTH), .PCIE_KEEP_WIDTH(8),
        .NUM_VIDEO_CH(NVID), .NUM_AUDIO_CH(NAUD),
        .VIDEO_DATA_WIDTH(128), .ENABLE_PACKET_C2H(1)
    ) dut (
        .clk(clk), .rst_n(rst), .requester_id(16'h0001),
        .packet_req_valid(src_valid),
        .packet_req_addr(p_exp_addr[rp]),
        .packet_req_dw_len(p_dwlen[rp][10:0]),
        .packet_req_data(src_data),
        .packet_req_first_be(4'hf),
        .packet_req_last_be(p_last_be[rp]),
        .packet_req_data_ready(src_ready),
        .packet_req_ack(src_ack),
        .m_axis_rq_tdata(rq_tdata), .m_axis_rq_tvalid(rq_tvalid),
        .m_axis_rq_tlast(rq_tlast), .m_axis_rq_tuser(rq_tuser),
        .m_axis_rq_tkeep(rq_tkeep), .m_axis_rq_tready(rq_tready)
    );

    // Only the packet requester is live; the desc MRd comes from the stimulus.
    initial begin
        force dut.dma_rst_n           = rst;
        force dut.sg_c2h_req_valid    = 1'b0;
        force dut.a_c2h_req_valid     = 1'b0;
        force dut.v_c2h_req_valid     = 1'b0;
        force dut.sg_req_valid        = 1'b0;
        force dut.sg_h2c_req_valid    = 1'b0;
        force dut.thin_mrd_req_addr   = 64'h0000_0000_2000_0000;
        force dut.thin_mrd_req_dw_len = 11'd2;
        force dut.thin_mrd_req_tag    = 8'h11;
    end

    // ------------------------------------------------------------------------
    // Thin descriptor fetch model: registered VALID that clears a full cycle
    // after its ack, so the ack/valid overlap window is always offered to the
    // encoder while a packet C2H is pending.
    // ------------------------------------------------------------------------
    reg desc_valid = 0;
    integer lcg = 1, dk;
    initial force dut.thin_mrd_req_valid = desc_valid;
    initial begin
        desc_valid = 0;
        wait (rst === 1'b1);
        forever begin
            lcg = (lcg * 31 + 7) % 4096;
            for (dk = 0; dk < (lcg % 4); dk = dk + 1) @(negedge clk);
            desc_valid = 1;
            while (dut.thin_mrd_req_ack !== 1'b1) @(negedge clk);
            @(negedge clk);          // still asserted during/after the ack cycle
            desc_valid = 0;
        end
    end

    // Random RQ backpressure.
    integer tseed = 7;
    initial forever begin
        @(negedge clk);
        tseed = (tseed * 31 + 7) % 4096;
        rq_tready <= (tseed % 10) > 2;
    end

    // ------------------------------------------------------------------------
    // Source side: irreversible pop accounting + residue check on retire.
    // ------------------------------------------------------------------------
    integer errors = 0;

    always @(posedge clk) if (rst === 1'b1) begin
        if (src_ready === 1'b1) begin
            pop_count = pop_count + 1;
            // Requirement: data_ready may only reach the committed owner.
            if (dut.c2h_owner !== PACKET_OWNER) begin
                $display("FAIL t=%0t packet pop in undecided arbitration window (c2h_owner=%0d)",
                         $time, dut.c2h_owner);
                errors = errors + 1;
            end
            bp = bp + 1;
            if (bp > b_count[rp]) begin
                $display("FAIL t=%0t packet %0d over-popped (%0d/%0d beats)",
                         $time, rp, bp, b_count[rp]);
                errors = errors + 1;
            end
        end
        if (src_ack === 1'b1) begin
            // A beat left in the FIFO is what a later packet (or a completion
            // record write) would then consume: the 32-byte shift signature.
            if (bp !== b_count[rp]) begin
                $display("FAIL t=%0t packet %0d retired with %0d/%0d beats popped (residue beat)",
                         $time, rp, bp, b_count[rp]);
                errors = errors + 1;
            end
            src_valid <= 1'b0;
            gap       <= 2;               // sc7f0_packet_cdc header reload
            rp = rp + 1;
            bp = 0;
            if (rp >= NPKT) begin
                if (errors == 0)
                    $display("PKT_POP_INTERLOCK_PASS: %0d packets byte-exact, %0d beats popped, 0 residue",
                             NPKT, pop_count);
                else
                    $display("FAIL PKT_POP_INTERLOCK: errors=%0d", errors);
                $finish;
            end
        end
    end

    always @(negedge clk) if (rst === 1'b1 && !src_valid && rp < NPKT) begin
        if (gap == 0) src_valid <= 1'b1;
        else          gap       <= gap - 1;
    end

    // ------------------------------------------------------------------------
    // RQ sink: a TLP boundary is defined by TLAST, not by re-decoding DW2 (the
    // encoder overwrites the whole beat with payload after the header beat).
    // Rebuild the payload DWORD stream and compare it byte-exactly.
    // ------------------------------------------------------------------------
    integer ck, dws, exp_pkt = 0, dw_idx = 0;
    reg in_tlp = 0, is_mwr = 0, first;
    reg [31:0] got, exp;
    always @(posedge clk) if (rst === 1'b1 && rq_tvalid === 1'b1 &&
                              rq_tready === 1'b1) begin
        first = !in_tlp;
        if (first) begin
            is_mwr = (rq_tdata[78:75] === 4'b0001);
            if (rq_tdata[78:75] !== 4'b0001 && rq_tdata[78:75] !== 4'b0000) begin
                $display("FAIL t=%0t unexpected RQ req_type %b", $time, rq_tdata[78:75]);
                errors = errors + 1;
            end
            if (is_mwr) begin
                if (rq_tdata[63:0] !== p_exp_addr[exp_pkt]) begin
                    $display("FAIL t=%0t TLP addr %h != packet %0d addr %h",
                             $time, rq_tdata[63:0], exp_pkt, p_exp_addr[exp_pkt]);
                    errors = errors + 1;
                end
                if (rq_tdata[74:64] !== p_dwlen[exp_pkt][10:0]) begin
                    $display("FAIL t=%0t TLP dw_len %0d != packet %0d dw_len %0d",
                             $time, rq_tdata[74:64], exp_pkt, p_dwlen[exp_pkt]);
                    errors = errors + 1;
                end
                dw_idx = 0;
            end
        end else if (!is_mwr) begin
            $display("FAIL t=%0t continuation beat of a non-MWr TLP", $time);
            errors = errors + 1;
        end
        if (is_mwr) begin
            // The DW-aligned header beat carries 4 header DWORDs ahead of payload.
            dws = 0;
            for (ck = 0; ck < 8; ck = ck + 1)
                if (rq_tkeep[ck] === 1'b1) dws = dws + 1;
            if (first) dws = dws - 4;
            for (ck = 0; ck < dws; ck = ck + 1) begin
                got = first ? rq_tdata[128 + ck*32 +: 32] : rq_tdata[ck*32 +: 32];
                exp = golden_dw(exp_pkt, dw_idx);
                if (got !== exp) begin
                    $display("FAIL t=%0t packet %0d offset %0d holds packet %0d offset %0d (exp %h got %h)",
                             $time, exp_pkt, dw_idx*4, got[31:16], got[15:0]*4, exp, got);
                    errors = errors + 1;
                end
                dw_idx = dw_idx + 1;
            end
        end
        if (rq_tlast === 1'b1) begin
            if (is_mwr && dw_idx !== p_dwlen[exp_pkt]) begin
                $display("FAIL t=%0t packet %0d ended with %0d/%0d payload DWORDs",
                         $time, exp_pkt, dw_idx, p_dwlen[exp_pkt]);
                errors = errors + 1;
            end
            if (is_mwr) exp_pkt = exp_pkt + 1;
            in_tlp = 0;
            dw_idx = 0;
        end else in_tlp = 1;
    end

    initial begin
        repeat (4) @(negedge clk);
        rst = 1;
    end
    initial begin
        #600000;
        $display("FAIL timeout: %0d/%0d packets delivered, errors=%0d", exp_pkt, NPKT, errors);
        $finish;
    end
endmodule
