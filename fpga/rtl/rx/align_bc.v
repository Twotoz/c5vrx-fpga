// Triversity: alignment of C5 B and C5 C to C5 A with one shared engine.
// The same method as align_b.v (one per C5 there): each C5's samples are
// written into a 64-entry buffer on its own clock and read on clk_a at a read
// pointer steered so that its sample lines up with A's; the metric is the
// low-passed cross product A * conj(B) at the lags -1, 0, +1.
// Here one set of three correlators serves both: 1024-sample windows go to B
// and C in turn (the low-passes settle in the first 256 samples of a window,
// which the window sums leave out). Each C5 keeps its own pointer, state and
// decisions, made at the end of its own windows: a decision every 2048
// samples as with align_b, acquisition over offsets 4..60 in ~3 ms. Acquisition compares the window sums of lag 0
// (align_b first compared the low-pass value at the window end, which
// follows the picture content more than the lag: it locked onto wrong
// offsets). sim/run_align_tb.py checks both on FM-modulated video.
`default_nettype none
module align_bc (
    input  wire       clk_b, clk_c,
    input  wire [7:0] raw_b_in, raw_c_in,   // captured in clk_b / clk_c
    input  wire       clk_a,
    input  wire       rst_a,
    input  wire [7:0] raw_a,                // current A sample (clk_a)
    output wire [7:0] raw_a_d,              // raw_a one clock later (pairs with raw_b, raw_c)
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
    generate for (s = 0; s < 2; s = s + 1) begin : st
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
        always @(posedge clk_a) begin bp <= mem[rp[s] + 6'd1]; b0 <= bp; bm <= b0; end
        assign tm[s] = bm; assign t0[s] = b0; assign tp[s] = bp;
    end endgenerate
    reg [7:0] a1;
    always @(posedge clk_a) a1 <= raw_a;
    assign raw_a_d = a1;
    assign raw_b = t0[0]; assign raw_c = t0[1];
    assign b_alive = alive[0]; assign c_alive = alive[1];

    // ---- the shared correlators on the C5 whose window this is ----
    reg sel;                                         // 0 B, 1 C
    function automatic signed [4:0] cv; input [3:0] nib; cv = {nib[3], nib} * 2 + 1; endfunction
    reg signed [19:0] xr [0:2];
    reg signed [19:0] xi [0:2];
    wire signed [4:0] ai = cv(a1[7:4]), aq = cv(a1[3:0]);
    wire [7:0] bsel [0:2];
    assign bsel[0] = tm[sel]; assign bsel[1] = t0[sel]; assign bsel[2] = tp[sel];
    genvar l;
    generate for (l = 0; l < 3; l = l + 1) begin : corr
        wire signed [4:0] bi_ = cv(bsel[l][7:4]), bq_ = cv(bsel[l][3:0]);
        // two 5 x 5 products per MULT18: (ai + aq * 1024) x b = ai b + aq b * 1024,
        // |ai b| < 512, so the low 10 bits are ai b (signed) and the rest aq b
        wire signed [17:0] apk = {{3{aq[4]}}, aq, 10'd0} + {{13{ai[4]}}, ai};
        wire [35:0] pbi, pbq;
        mul18 u_pi (.a(apk), .b({{13{bi_[4]}}, bi_}), .y(pbi));
        mul18 u_pq (.a(apk), .b({{13{bq_[4]}}, bq_}), .y(pbq));
        wire signed [9:0]  p_ii = pbi[9:0], p_iq = pbq[9:0];
        wire signed [9:0]  p_qi = $signed(pbi[19:10]) + $signed({9'd0, pbi[9]});
        wire signed [9:0]  p_qq = $signed(pbq[19:10]) + $signed({9'd0, pbq[9]});
        wire signed [10:0] pr = p_ii + p_qq;
        wire signed [10:0] pq = p_qi - p_iq;
        always @(posedge clk_a) begin
            if (rst_a) begin xr[l] <= 0; xi[l] <= 0; end
            else begin
                xr[l] <= xr[l] + pr - (xr[l] >>> 7);
                xi[l] <= xi[l] + pq - (xi[l] >>> 7);
            end
        end
    end endgenerate
    // magnitude ~ max + min / 2 of |re|, |im| (the absolute values on ADDSUB chains)
    wire [19:0] axr [0:2], axi [0:2], mg [0:2];
    generate for (l = 0; l < 3; l = l + 1) begin : mg_
        addsub #(20) u_r (.a(20'd0), .b(xr[l]), .sub(xr[l][19]), .y(axr[l]));
        addsub #(20) u_i (.a(20'd0), .b(xi[l]), .sub(xi[l][19]), .y(axi[l]));
        assign mg[l] = (axr[l] > axi[l]) ? axr[l] + (axi[l] >> 1) : axi[l] + (axr[l] >> 1);
    end endgenerate
    wire [19:0] mm = mg[0], m0 = mg[1], mp = mg[2];
    function automatic [7:0] sq5; input signed [4:0] c; reg [3:0] m; begin m = c[4] ? -c : c; sq5 = m * m; end endfunction
    reg [15:0] pa_acc, pb_acc;
    wire [8:0] pa = sq5(ai) + sq5(aq);
    wire signed [4:0] b0i = cv(bsel[1][7:4]), b0q = cv(bsel[1][3:0]);
    wire [8:0] pb = sq5(b0i) + sq5(b0q);
    always @(posedge clk_a) begin
        if (rst_a) begin pa_acc <= 0; pb_acc <= 0; end
        else begin pa_acc <= pa_acc + pa - (pa_acc >> 7); pb_acc <= pb_acc + pb - (pb_acc >> 7); end
    end

    // ---- windows and decisions ----
    localparam ACQ = 1'b0, TRK = 1'b1;
    reg [9:0]  win;                                  // 1024-sample windows, B and C in turn
    reg [1:0]  state;
    reg [5:0]  off [0:1], best_off [0:1];
    reg [26:0] best_mag [0:1];                    // acquisition: the best window sum of lag 0
    reg [3:0]  lost [0:1];
    reg [1:0]  en;
    reg [26:0] sm, s0, sp, spp;                      // window sums (768 samples of <= 17-bit values)
    wire       sum_on = win[9:8] != 2'd0;             // after the low-passes settled (256 samples)
    wire [26:0] sm_n = sm + (sum_on ? mm[16:0] : 17'd0), s0_n = s0 + (sum_on ? m0[16:0] : 17'd0),
                sp_n = sp + (sum_on ? mp[16:0] : 17'd0), spp_n = spp + (sum_on ? pa_acc + pb_acc : 17'd0);
    wire       coherent = s0_n > (spp_n >> 4);
    wire       wend = win == 10'd1023;
    integer k;
    always @(posedge clk_a) begin
        if (rst_a) begin
            win <= 10'd0; sel <= 1'b0; sm <= 0; s0 <= 0; sp <= 0; spp <= 0;
        end else begin
            win <= win + 10'd1;
            sm <= wend ? 27'd0 : sm_n; s0 <= wend ? 27'd0 : s0_n; sp <= wend ? 27'd0 : sp_n; spp <= wend ? 27'd0 : spp_n;
            if (wend) sel <= ~sel;
        end
        for (k = 0; k < 2; k = k + 1) begin
            if (rst_a || !alive[k]) begin
                state[k] <= ACQ; off[k] <= 6'd4; best_off[k] <= 6'd32; best_mag[k] <= 27'd0;
                en[k] <= 1'b0; lost[k] <= 4'd0; rp[k] <= wps[k] - 6'd4;
            end else if (state[k] == ACQ) begin
                rp[k] <= wps[k] - off[k];                // hold this offset
                if (wend && sel == k) begin
                    if (s0_n > best_mag[k]) begin best_mag[k] <= s0_n; best_off[k] <= off[k]; end
                    if (off[k] == 6'd60) begin
                        state[k] <= TRK;
                        rp[k] <= wps[k] - ((s0_n > best_mag[k]) ? off[k] : best_off[k]);
                    end else off[k] <= off[k] + 6'd1;
                end
            end else begin
                rp[k] <= rp[k] + 6'd1;                   // one sample per clock
                if (wend && sel == k) begin
                    if (sp_n > s0_n && sp_n >= sm_n) rp[k] <= rp[k] + 6'd2;   // the newer sample fits better
                    else if (sm_n > s0_n)            rp[k] <= rp[k];          // the older one
                    if (coherent) begin en[k] <= 1'b1; lost[k] <= 4'd0; end
                    else begin
                        en[k] <= 1'b0; lost[k] <= lost[k] + 4'd1;
                        if (lost[k] == 4'd15) begin state[k] <= ACQ; off[k] <= 6'd4; best_mag[k] <= 27'd0; end
                    end
                    if (wps[k] - rp[k] < 6'd3 || wps[k] - rp[k] > 6'd61) begin   // buffer edge: start over
                        state[k] <= ACQ; off[k] <= 6'd4; best_mag[k] <= 27'd0; en[k] <= 1'b0;
                    end
                end
            end
        end
    end
    assign en_b = en[0]; assign en_c = en[1];
    assign lag_b = wps[0] - rp[0]; assign lag_c = wps[1] - rp[1];
endmodule
`default_nettype wire
