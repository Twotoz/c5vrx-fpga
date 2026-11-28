// Align B and C to a delayed copy of A. Centering A in the FIFO's search
// range lets a receiver lead or lag A. Sum magnitudes of short complex
// correlations so a relative carrier offset does not average away the peak.
// The same engine serves both receivers in alternate windows.
`default_nettype none
module align_bc #(parameter HAS_C = 1) (
    input  wire       clk_b, clk_c,
    input  wire [7:0] raw_b_in, raw_c_in,   // captured in clk_b / clk_c
    input  wire       clk_a,
    input  wire       rst_a,
    input  wire       ref_lost,              // independent evidence of an A fade; keep the FIFO moving
    input  wire [7:0] raw_a,                // current A sample (clk_a)
    output wire [7:0] raw_a_d,              // A delayed to the centre of the search range
    output wire [7:0] raw_b, raw_c,
    output wire       en_b, en_c,
    output wire       b_alive, c_alive,
    output wire [5:0] lag_b, lag_c
);
    // ---- per C5: buffer, write pointer into clk_a, alive, read taps ----
    wire [5:0] wps [0:1];
    reg  [5:0] rp [0:1];
    wire [7:0] tm [0:1], t0 [0:1], tp [0:1];
    wire [1:0] alive;
    genvar s;
    generate for (s = 0; s < 1 + HAS_C; s = s + 1) begin : st
        wire       wclk = s == 0 ? clk_b : clk_c;
        wire [7:0] din  = s == 0 ? raw_b_in : raw_c_in;
        reg  [7:0] mem [0:63];
        integer    mi;
        initial for (mi = 0; mi < 64; mi = mi + 1) mem[mi] = 8'd0;
        reg  [5:0] wp = 6'd0, wp_gray = 6'd0;
        always @(posedge wclk) begin
            mem[wp] <= din;
            wp      <= wp + 6'd1;
            wp_gray <= (wp + 6'd1) ^ ((wp + 6'd1) >> 1);
        end
        reg [5:0] g1 = 6'd0, g2 = 6'd0, wq = 6'd0, wq_prev;
        reg [6:0] still; reg al;
        wire [5:0] bin = {g2[5], g2[5] ^ g2[4], ^g2[5:3], ^g2[5:2], ^g2[5:1], ^g2[5:0]};
        always @(posedge clk_a) begin
            g1 <= wp_gray; g2 <= g1; wq <= bin; wq_prev <= wq;
            if (rst_a) begin still <= 7'd0; al <= 1'b0; end
            else if (wq == wq_prev) begin
                if (still != 7'd127) still <= still + 7'd1;
                if (still >= 7'd63) al <= 1'b0;
            end else begin still <= 7'd0; al <= 1'b1; end
        end
        assign wps[s] = wq; assign alive[s] = al;
        // lags -1, 0, +1: one read port at rp + 1 and a shift register (as align_b)
        reg [7:0] bm = 8'd0, b0 = 8'd0, bp = 8'd0;
        wire [5:0] next_rp = rp[s] + 6'd1;
        always @(posedge clk_a) begin bp <= mem[next_rp]; b0 <= bp; bm <= b0; end
        assign tm[s] = bm; assign t0[s] = b0; assign tp[s] = bp;
    end
    if (!HAS_C) begin : no_c
        assign wps[1] = 0;
        assign alive[1] = 0;
        assign tm[1] = 0;
        assign t0[1] = 0;
        assign tp[1] = 0;
    end
    endgenerate
    reg [7:0] a_history [0:31];
    integer a_init;
    initial for (a_init = 0; a_init < 32; a_init = a_init + 1)
        a_history[a_init] = 8'd0;
    reg [4:0] aw = 0;
    wire [4:0] a_read = aw + 5'd1;
    reg [7:0] a1 = 8'd0;
    always @(posedge clk_a) begin
        a_history[aw] <= raw_a;
        a1 <= a_history[a_read];
        aw <= a_read;
    end
    assign raw_a_d = a1;
    assign raw_b = t0[0]; assign raw_c = t0[1];
    assign b_alive = alive[0]; assign c_alive = alive[1];

    // ---- the shared correlators on the C5 whose window this is ----
    reg sel;                                         // 0 B, 1 C
    function automatic signed [4:0] cv;
        input [3:0] nib;
        cv = {nib[3:1], 2'b10};
    endfunction
    reg [9:0] win;
    wire block_start = win[4:0] == 0;
    reg signed [14:0] xr [0:2];
    reg signed [14:0] xi [0:2];
    wire signed [4:0] ai = cv(a1[7:4]), aq = cv(a1[3:0]);
    wire [7:0] bsel [0:2];
    assign bsel[0] = tm[sel]; assign bsel[1] = t0[sel]; assign bsel[2] = tp[sel];
    genvar l;
    generate for (l = 0; l < 3; l = l + 1) begin : corr
        wire signed [4:0] bi_ = cv(bsel[l][7:4]), bq_ = cv(bsel[l][3:0]);
        wire [17:0] p_ii, p_qq, p_qi, p_iq;
        mul9 u_ii (.a({{4{ai[4]}}, ai}), .b({{4{bi_[4]}}, bi_}), .y(p_ii));
        mul9 u_qq (.a({{4{aq[4]}}, aq}), .b({{4{bq_[4]}}, bq_}), .y(p_qq));
        mul9 u_qi (.a({{4{aq[4]}}, aq}), .b({{4{bi_[4]}}, bi_}), .y(p_qi));
        mul9 u_iq (.a({{4{ai[4]}}, ai}), .b({{4{bq_[4]}}, bq_}), .y(p_iq));
        wire signed [10:0] pr = $signed(p_ii[10:0]) + $signed(p_qq[10:0]);
        wire signed [10:0] pq = $signed(p_qi[10:0]) - $signed(p_iq[10:0]);
        always @(posedge clk_a) begin
            xr[l] <= block_start ? pr : xr[l] + pr;
            xi[l] <= block_start ? pq : xi[l] + pq;
        end
    end endgenerate
    // magnitude ~ max + min / 2 of |re|, |im| (the absolute values on ADDSUB chains)
    wire [14:0] axr [0:2], axi [0:2], mg [0:2];
    generate for (l = 0; l < 3; l = l + 1) begin : mg_
        addsub #(15) u_r (.a(15'd0), .b(xr[l]), .sub(xr[l][14]), .y(axr[l]));
        addsub #(15) u_i (.a(15'd0), .b(xi[l]), .sub(xi[l][14]), .y(axi[l]));
        assign mg[l] = (axr[l] > axi[l]) ? axr[l] + (axi[l] >> 1) : axi[l] + (axr[l] >> 1);
    end endgenerate
    wire [14:0] mm = mg[0], m0 = mg[1], mp = mg[2];
    function automatic [7:0] sqn;    // cv(nib)^2 as a table
        input [3:0] nib;
        case (nib[3] ? ~nib[2:1] : nib[2:1])
            2'd0: sqn = 8'd4;  2'd1: sqn = 8'd36;
            2'd2: sqn = 8'd100; default: sqn = 8'd196;
        endcase
    endfunction
    reg [14:0] p_acc;
    wire [8:0] pa = sqn(a1[7:4]) + sqn(a1[3:0]);
    wire [8:0] pb = sqn(bsel[1][7:4]) + sqn(bsel[1][3:0]);
    always @(posedge clk_a) begin
        p_acc <= (block_start ? 15'd0 : p_acc) + pa + pb;
    end

    // ---- windows and decisions ----
    localparam ACQ = 1'b0, TRK = 1'b1;
    reg [1:0]  state;
    reg [5:0]  off [0:1], best_off [0:1];
    reg [15:0] best_mag [0:1], best_power [0:1];
    reg [3:0] lost [0:1];
    reg [1:0] good [0:1];
    reg [1:0]  en;
    reg [19:0] sm, s0, sp, spp;
    // Discard the first block after changing the receiver or read pointer.
    wire sum_on = block_start && win >= 10'd64;
    wire [19:0] sm_n = sm + mm, s0_n = s0 + m0, sp_n = sp + mp, spp_n = spp + p_acc;
    wire       wend = win == 10'd1023;

    // Noise and a wrong delay can still correlate within a short block.
    // Require a repeatable phase advance over eight blocks, independent of
    // the carrier difference.
    wire [8:0] block_r = xr[1][14:6], block_i = xi[1][14:6], block_p = p_acc[14:6];
    reg [26:0] phase_history [0:7];
    wire [2:0] phase_addr = win[7:5];
    wire [8:0] prev_r, prev_i, prev_p;
    assign {prev_r, prev_i, prev_p} = phase_history[phase_addr];
    wire [17:0] rr, ii, ir, ri, pp;
    mul9 u_rr (.a(block_r), .b(prev_r), .y(rr));
    mul9 u_ii (.a(block_i), .b(prev_i), .y(ii));
    mul9 u_ir (.a(block_i), .b(prev_r), .y(ir));
    mul9 u_ri (.a(block_r), .b(prev_i), .y(ri));
    mul9 #(.A_SIGNED(0), .B_SIGNED(0)) u_pp (.a(block_p), .b(prev_p), .y(pp));
    reg signed [22:0] phase_r, phase_i;
    reg [22:0] phase_power;
    always @(posedge clk_a) begin
        if (rst_a || wend || ref_lost) begin
            phase_r <= 0; phase_i <= 0; phase_power <= 0;
        end else if (sum_on) begin
            phase_history[phase_addr] <= {block_r, block_i, block_p};
            if (win >= 10'd320) begin
                phase_r <= phase_r + $signed(rr) + $signed(ii);
                phase_i <= phase_i + $signed(ir) - $signed(ri);
                phase_power <= phase_power + pp;
            end
        end
    end
    wire [22:0] ar = phase_r[22] ? -phase_r : phase_r;
    wire [22:0] ai_abs = phase_i[22] ? -phase_i : phase_i;
    wire [22:0] stable_phase = ar > ai_abs ? ar + (ai_abs >> 1) : ai_abs + (ar >> 1);
    wire coherent = s0 > (spp >> 3) && stable_phase > (phase_power >> 5);
    wire qualified = s0 > (spp >> 2) && stable_phase > (phase_power >> 4);
    // Each candidate is measured at a different time. Rank normalized
    // correlations so a rise in signal level cannot masquerade as better lag.
    wire [15:0] current_mag = stable_phase[22:7], current_power = phase_power[22:7];
    wire [35:0] current_score, best_score;
    mul18 #(.A_SIGNED(0), .B_SIGNED(0)) u_cur_score (
        .a({2'b0, current_mag}), .b({2'b0, best_power[sel]}), .y(current_score));
    mul18 #(.A_SIGNED(0), .B_SIGNED(0)) u_best_score (
        .a({2'b0, best_mag[sel]}), .b({2'b0, current_power}), .y(best_score));
    wire better = coherent && (best_power[sel] == 0 || current_score > best_score);
    integer k;
    always @(posedge clk_a) begin
        if (rst_a) begin
            win <= 10'd0; sel <= 1'b0; sm <= 0; s0 <= 0; sp <= 0; spp <= 0;
        end else begin
            win <= win + 10'd1;
            if (wend || ref_lost) begin
                sm <= 0; s0 <= 0; sp <= 0; spp <= 0;
            end else if (sum_on) begin
                sm <= sm_n; s0 <= s0_n; sp <= sp_n; spp <= spp_n;
            end
            if (wend && HAS_C) sel <= ~sel;
            if (ref_lost) win <= 0;
        end
        for (k = 0; k < 2; k = k + 1) begin
            if (rst_a || !alive[k]) begin
                state[k] <= ACQ; off[k] <= 6'd4; best_off[k] <= 6'd32; best_mag[k] <= 0; best_power[k] <= 0;
                en[k] <= 1'b0; lost[k] <= 4'd0; good[k] <= 0; rp[k] <= wps[k] - 6'd4;
            end else if (ref_lost) begin
                en[k] <= 1'b0;
                good[k] <= 0;
                // Stay on the same sample cadence during a fade. Recentre
                // only at a FIFO edge; then reacquire alignment on recovery.
                rp[k] <= rp[k] + 6'd1;
                if (wps[k] - rp[k] < 6'd3 || wps[k] - rp[k] > 6'd61) begin
                    rp[k] <= wps[k] - 6'd32;
                    state[k] <= ACQ; off[k] <= 6'd4; best_power[k] <= 0;
                end
            end else if (state[k] == ACQ) begin
                rp[k] <= wps[k] - off[k];                // hold this offset
                if (wend && sel == k) begin
                    if (better) begin best_mag[k] <= current_mag; best_power[k] <= current_power; best_off[k] <= off[k]; end
                    if (off[k] == 6'd60) begin
                        state[k] <= TRK;
                        rp[k] <= wps[k] - (better ? off[k] : best_power[k] != 0 ? best_off[k] : 6'd32);
                    end else off[k] <= off[k] + 6'd1;
                end
            end else begin
                rp[k] <= rp[k] + 6'd1;                   // one sample per clock
                if (wend && sel == k) begin
                    if (sp > s0 && sp >= sm) rp[k] <= rp[k] + 6'd2;   // the newer sample fits better
                    else if (sm > s0)            rp[k] <= rp[k];          // the older one
                    if (qualified || (en[k] && coherent)) begin
                        if (good[k] != 3) good[k] <= good[k] + 1'b1;
                        if (good[k] >= 2) en[k] <= 1'b1;
                        lost[k] <= 0;
                    end else begin
                        good[k] <= 0;
                        if (lost[k] != 0) en[k] <= 1'b0;
                        lost[k] <= lost[k] + 4'd1;
                        if (lost[k] == 4'd15) begin state[k] <= ACQ; off[k] <= 6'd4; best_power[k] <= 0; end
                    end
                    if (wps[k] - rp[k] < 6'd3 || wps[k] - rp[k] > 6'd61) begin   // buffer edge: start over
                        state[k] <= ACQ; off[k] <= 6'd4; best_power[k] <= 0; en[k] <= 1'b0; good[k] <= 0;
                    end
                end
            end
        end
    end
    assign en_b = en[0]; assign en_c = en[1];
    assign lag_b = wps[0] - rp[0]; assign lag_c = wps[1] - rp[1];
endmodule
`default_nettype wire
