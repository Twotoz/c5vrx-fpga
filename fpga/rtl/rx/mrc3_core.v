// C5VRX by Twotoz and the C5VRX contributors: three-branch ("Tripleversity")
// combiner and demodulator. Pre-detection maximal-ratio combining of C5 A
// with up to two more C5s (3-bit I/Q each: the top three bits of their 4-bit
// lane), a cross-product phase tracker per extra branch, then the CORDIC FM
// discriminator. The arithmetic and pipeline of mrc_core.v, generalised;
// bit-exact with fpga/model/mrc3_model.py run(..., disc=True, valid=...)
// (fpga/sim/run_tb3.py). raw_b / raw_c must be aligned to raw_a (align_b.v).
// va/vb/vc: the sample of that C5 is IQ (0 while it sends a marker): weight 0,
// its moments hold, a tracker holds while its branch or C5 A is invalid.
// Discriminator: the D32-R2 rule on the combined 16-bit angle (1024 sectors,
// 50 ns step, 0.7 of a step outside the video window), one code per 50 ns.
`default_nettype none

// tracker and rotation of one extra branch k against A (the mrc_core.v B path)
module mrc3_trk (
    input  wire              clk,
    input  wire              rst,
    input  wire              run2,
    input  wire              upd2,                         // S2: this sample updates the tracker
    input  wire [6:0]        idx2,
    input  wire signed [4:0] ca_i1, ca_q1, ck_i1, ck_q1,   // S1 cells
    output reg  signed [12:0] rk_i3, rk_q3                 // S3: c_k rotated by theta_k
);
    reg [15:0] cs_rom [0:255];
`include "rom_cs_init.vh"
    wire [17:0] p_ii, p_qq, p_qi, p_iq;
    mul9 u_ii (.a({{4{ca_i1[4]}}, ca_i1}), .b({{4{ck_i1[4]}}, ck_i1}), .y(p_ii));
    mul9 u_qq (.a({{4{ca_q1[4]}}, ca_q1}), .b({{4{ck_q1[4]}}, ck_q1}), .y(p_qq));
    mul9 u_qi (.a({{4{ca_q1[4]}}, ca_q1}), .b({{4{ck_i1[4]}}, ck_i1}), .y(p_qi));
    mul9 u_iq (.a({{4{ca_i1[4]}}, ca_i1}), .b({{4{ck_q1[4]}}, ck_q1}), .y(p_iq));
    reg signed [10:0] pr2, pi2;
    reg signed [4:0]  ck_i2, ck_q2;
    always @(posedge clk) begin
        pr2 <= $signed(p_ii[10:0]) + $signed(p_qq[10:0]);
        pi2 <= $signed(p_qi[10:0]) - $signed(p_iq[10:0]);
        ck_i2 <= ck_i1; ck_q2 <= ck_q1;
    end
    reg signed [19:0] xr, xi;
    wire signed [19:0] xr_n = xr + pr2 - (xr >>> 7), xi_n = xi + pi2 - (xi >>> 7);
    reg               th_go;
    reg signed [19:0] th_x, th_y;
    wire [15:0] th_ang;
    wire        th_done;
    cordic_iter #(.W(20), .N(10)) u_th (.clk(clk), .start(th_go), .x_in(th_x), .y_in(th_y), .ang(th_ang), .done(th_done));
    reg  [7:0]        th_pend;
    reg  signed [7:0] cos_pend, sin_pend, cos_r, sin_r;
    wire [17:0] r_ic, r_qs, r_is, r_qc;
    mul9 u_ic (.a({{4{ck_i2[4]}}, ck_i2}), .b({cos_r[7], cos_r}), .y(r_ic));
    mul9 u_qs (.a({{4{ck_q2[4]}}, ck_q2}), .b({sin_r[7], sin_r}), .y(r_qs));
    mul9 u_is (.a({{4{ck_i2[4]}}, ck_i2}), .b({sin_r[7], sin_r}), .y(r_is));
    mul9 u_qc (.a({{4{ck_q2[4]}}, ck_q2}), .b({cos_r[7], cos_r}), .y(r_qc));
    always @(posedge clk) begin
        th_go <= 1'b0;
        if (rst) begin
            xr <= 0; xi <= 0; cos_r <= 8'sd63; sin_r <= 8'sd0;
        end else if (run2) begin
            if (upd2) begin xr <= xr_n; xi <= xi_n; end
            if (idx2[3:0] == 4'd15) begin
                cos_r <= cos_pend; sin_r <= sin_pend;
                th_x <= (upd2 ? xr_n : xr) >>> 4; th_y <= (upd2 ? xi_n : xi) >>> 4; th_go <= 1'b1;
            end
        end
        rk_i3 <= $signed(r_ic[12:0]) - $signed(r_qs[12:0]);
        rk_q3 <= $signed(r_is[12:0]) + $signed(r_qc[12:0]);
    end
    reg [15:0] cs_q;
    always @(posedge clk) cs_q <= cs_rom[th_pend];
    reg th_lut, th_lut2;
    always @(posedge clk) begin
        if (rst) begin
            th_pend <= 8'd0; cos_pend <= 8'sd63; sin_pend <= 8'sd0; th_lut <= 1'b0; th_lut2 <= 1'b0;
        end else begin
            th_lut <= th_done; th_lut2 <= th_lut;
            if (th_done) th_pend <= (th_ang + 16'd128) >> 8;
            if (th_lut2) begin cos_pend <= cs_q[15:8]; sin_pend <= cs_q[7:0]; end
        end
    end
endmodule

module mrc3_core #(parameter HAS_C = 1, parameter FAILOVER = 0,    // HAS_C 0: two C5s (A, B), C's tracker and products left out
                   parameter RS_WSH = 10, parameter [11:0] RS_K = 12'd2,    // rescue Auto: look-ahead 2^RS_WSH sample pairs, RS_K clicks
                   parameter RS_SSH = 12, parameter [6:0] RS_T = 7'd48) (   //   steady: RS_T of 64 sub-windows of 2^RS_SSH pairs with a click
    input  wire       clk,
    input  wire       rst,
    input  wire [5:0] raw_a,        // {I2 I1 I0, Q2 Q1 Q0}, two's complement per component
    input  wire [5:0] raw_b,
    input  wire [5:0] raw_c,
    input  wire       en_b,
    input  wire       en_c,
    input  wire       avail_b, avail_c, // live receiver & selected in the menu, independent of A alignment
    input  wire       va, vb, vc,   // per sample, with raw_*
    input  wire [1:0] rmode,        // rescue PLL: 0 off, 1 auto, 2 on, 3 experimental D3
    output reg  [5:0] code,
    output reg        ract,         // rescue PLL in use (for the code going out)
    output wire [1:0] d3_degrade,
    output wire       ref_lost,
    output wire [23:0] wts          // logger: the weights in use {C, B, A}
);
    reg [7:0] g_rom   [0:255];
    reg [7:0] isq_rom [0:511];
`include "rom_gi_init.vh"

    function automatic [7:0] sq3;    // (4 v + 2)^2 as a table: v signed 3 bit
        input [2:0] v;
        case (v)
            3'd0, 3'd7: sq3 = 8'd4;   3'd1, 3'd6: sq3 = 8'd36;
            3'd2, 3'd5: sq3 = 8'd100; default:    sq3 = 8'd196;
        endcase
    endfunction
    function automatic signed [4:0] cell3;   // 4 v + 2, -14..14
        input [2:0] v;
        begin cell3 = {v[2], v[2], v[2:0]} * 4 + 2; end
    endfunction

    // ---- R0 / S1 ----------------------------------------------------------------
    reg  [5:0] ra, rb, rc;
    reg  [2:0] v0, v1, v2, v3;
    reg  [6:0] idx0, idx1, idx2, idx3;
    reg        run0, run1, run2, run3;
    always @(posedge clk) begin
        if (rst) begin idx0 <= 7'd0; run0 <= 1'b0; end
        else begin
            ra <= raw_a; rb <= raw_b; rc <= raw_c; v0 <= {vc, vb, va};
            idx0 <= run0 ? idx0 + 7'd1 : 7'd0;
            run0 <= 1'b1;
        end
    end
    reg signed [4:0] ca_i1, ca_q1, cb_i1, cb_q1, cc_i1, cc_q1;
    always @(posedge clk) begin
        ca_i1 <= cell3(ra[5:3]); ca_q1 <= cell3(ra[2:0]);
        cb_i1 <= cell3(rb[5:3]); cb_q1 <= cell3(rb[2:0]);
        cc_i1 <= cell3(rc[5:3]); cc_q1 <= cell3(rc[2:0]);
        idx1 <= idx0; run1 <= run0 & ~rst; v1 <= v0;
    end

    // ---- S2: powers ------------------------------------------------------------
    reg [8:0] pa2, pb2, pc2;
    reg signed [4:0] ca_i2, ca_q2;
    always @(posedge clk) begin
        pa2 <= sq3(ca_i1[4:2]) + sq3(ca_q1[4:2]);
        pb2 <= sq3(cb_i1[4:2]) + sq3(cb_q1[4:2]);
        pc2 <= sq3(cc_i1[4:2]) + sq3(cc_q1[4:2]);
        ca_i2 <= ca_i1; ca_q2 <= ca_q1;
        idx2 <= idx1; run2 <= run1 & ~rst; v2 <= v1;
    end

    wire poor_a;

    // ---- trackers (B, C) -----------------------------------------------------------
    wire signed [12:0] rb_i3, rb_q3, rc_i3, rc_q3;
    mrc3_trk u_tb (.clk(clk), .rst(rst), .run2(run2), .upd2(v2[0] & v2[1] & ~poor_a), .idx2(idx2), .ca_i1(ca_i1), .ca_q1(ca_q1),
                   .ck_i1(cb_i1), .ck_q1(cb_q1), .rk_i3(rb_i3), .rk_q3(rb_q3));
    generate if (HAS_C) begin : tc
    mrc3_trk u_tc (.clk(clk), .rst(rst), .run2(run2), .upd2(v2[0] & v2[2] & ~poor_a), .idx2(idx2), .ca_i1(ca_i1), .ca_q1(ca_q1),
                   .ck_i1(cc_i1), .ck_q1(cc_q1), .rk_i3(rc_i3), .rk_q3(rc_q3));
    end else begin : notc
    assign rc_i3 = 13'sd0; assign rc_q3 = 13'sd0;
    end endgenerate

    // ---- S3: moments ------------------------------------------------------------
    reg [15:0] m2 [0:2];
    reg [24:0] m4 [0:2];
    wire [8:0] pk [0:2];
    assign pk[0] = pa2; assign pk[1] = pb2; assign pk[2] = pc2;
    wire [17:0] psq [0:2];
    genvar gk;
    generate for (gk = 0; gk < 3; gk = gk + 1) begin : mom
        mul9 #(.A_SIGNED(0), .B_SIGNED(0)) u_sq (.a(pk[gk]), .b(pk[gk]), .y(psq[gk]));
    end endgenerate
    reg [15:0] snap_m2 [0:2];
    reg [24:0] snap_m4 [0:2];
    reg        snap_go;
    reg signed [4:0] ca_i3, ca_q3;
    integer k, kw, ku;
    always @(posedge clk) begin
        snap_go <= 1'b0;
        if (rst) begin
            for (k = 0; k < 3; k = k + 1) begin m2[k] <= 0; m4[k] <= 0; end
        end else if (run2) begin
            for (k = 0; k < 3; k = k + 1) if (v2[k]) begin
                m2[k] <= m2[k] + pk[k] - (m2[k] >> 6);
                m4[k] <= m4[k] + psq[k] - (m4[k] >> 6);
            end
            if (idx2 == 7'd127) begin
                for (k = 0; k < 3; k = k + 1) begin
                    snap_m2[k] <= v2[k] ? m2[k] + pk[k] - (m2[k] >> 6) : m2[k];
                    snap_m4[k] <= v2[k] ? m4[k] + psq[k] - (m4[k] >> 6) : m4[k];
                end
                snap_go <= 1'b1;
            end
        end
        ca_i3 <= ca_i2; ca_q3 <= ca_q2;
        idx3 <= idx2; run3 <= run2 & ~rst; v3 <= v2;
    end

    // ---- weight engine: three branches in turn ------------------------------------
    // 20 clocks a branch (the products on DSP blocks): the weights are ready
    // well before the hand-over at idx3 == 127 of the next period.
    reg  [7:0]  w_use [0:2];
    reg  [7:0]  pend  [0:2];
    reg         have_pend;
    reg  [3:0]  st;
    reg  [1:0]  wj;
    reg  [40:0] num, dsh;
    reg  [31:0] den;
    reg  [9:0]  q;
    reg  [4:0]  bitn;
    reg  [8:0]  mi;
    reg  [31:0] mp_acc;
    reg  [7:0]  g_q, isq_q, g_addr;
    always @(posedge clk) begin g_q <= g_rom[g_addr]; isq_q <= isq_rom[mi]; end
    localparam S_IDLE = 0, S_LOAD = 1, S_SQ = 2, S_SH = 3, S_CHK = 4, S_DIV = 5, S_LUT = 6,
               S_LUT2 = 7, S_GM = 8, S_WR = 9, S_NEXT = 10, S_STORE = 11;
    wire [15:0] m2j = snap_m2[wj];
    // the weight engine's two products share one DSP multiplier (m2^2 in S_SQ, g x isq in S_WR)
    wire [35:0] sq_p; wire [17:0] gi_p = sq_p[17:0];
    wire        w_gi = st == S_WR;
    mul18 #(.A_SIGNED(0), .B_SIGNED(0)) u_sq2 (.a(w_gi ? {10'd0, g_q} : {2'b0, m2j}), .b(w_gi ? {10'd0, isq_q} : {2'b0, m2j}), .y(sq_p));
    wire [24:0] m4j = snap_m4[wj];
    wire [9:0]  rq  = (q > 10'd511) ? 10'd511 : (q < 10'd256) ? 10'd256 : q;
    wire [7:0]  w_new = (mp_acc[15:8] == 8'd0) ? 8'd1 : mp_acc[15:8];
    always @(posedge clk) begin
        if (rst) begin
            st <= S_IDLE; have_pend <= 1'b0;
            for (kw = 0; kw < 3; kw = kw + 1) pend[kw] <= 8'd1;
        end else case (st)
            S_IDLE: if (snap_go) begin wj <= 2'd0; st <= S_LOAD; end
            S_LOAD: begin
                num <= {2'b0, m4j, 14'd0};
                mi <= (m2j[15:6] > 10'd511) ? 9'd511 : m2j[14:6];
                q <= 10'd0; st <= S_SQ;
            end
            S_SQ: begin mp_acc <= sq_p[31:0]; st <= S_SH; end           // m2^2 (DSP)
            S_SH: begin den <= mp_acc; dsh <= {mp_acc, 9'd0}; bitn <= 5'd9; st <= S_CHK; end
            S_CHK: begin
                if (den == 0) begin pend[wj] <= 8'd1; st <= S_NEXT; end
                else if (num >= {dsh[39:0], 1'b0}) begin q <= 10'd1023; st <= S_LUT; end
                else st <= S_DIV;
            end
            S_DIV: begin
                if (num >= dsh) begin num <= num - dsh; q <= q | (10'd1 << bitn); end
                dsh <= dsh >> 1;
                if (bitn == 0) st <= S_LUT; else bitn <= bitn - 5'd1;
            end
            S_LUT:  begin g_addr <= rq[7:0]; st <= S_LUT2; end
            S_LUT2: st <= S_GM;
            S_GM:   st <= S_WR;
            S_WR:   begin mp_acc <= {16'd0, gi_p[15:0]}; st <= S_STORE; end   // g x isq (DSP)
            S_STORE: begin pend[wj] <= w_new; st <= S_NEXT; end
            S_NEXT: begin
                if (wj != 2'd2) begin wj <= wj + 2'd1; st <= S_LOAD; end
                else begin have_pend <= 1'b1; st <= S_IDLE; end
            end
            default: st <= S_IDLE;
        endcase
    end

    // Per-branch quality from the weight engine's scale-free M4/M2^2.
    // Maintain a deadband and require persistent evidence before re-entry.
    // This detects envelope variability, not absolute power or guaranteed RF validity.
    wire [2:0] good;
    generate if (FAILOVER) begin : quality
        reg [3:0] score [0:2];
        reg [2:0] stable;
        integer b;
        always @(posedge clk) begin
            if (rst) begin
                score[0] <= 4'd8;
                score[1] <= 4'd0;
                score[2] <= 4'd0;
            end else if (st == S_STORE) begin
                if (rq <= 10'd360 && m2j >= 16'd2048) begin
                    if (!(&score[wj])) score[wj] <= score[wj] + 1'b1;
                end else if (rq >= 10'd400 || m2j < 16'd2048) begin
                    if (score[wj] != 0) score[wj] <= score[wj] - 1'b1;
                end
            end
            if (rst) stable <= 3'b001;
            else for (b = 0; b < 3; b = b + 1)
                if (score[b] >= 4'd12) stable[b] <= 1'b1;
                else if (score[b] <= 4'd3) stable[b] <= 1'b0;
        end
        assign good = stable;
    end else begin : no_quality
        assign good = 3'b001;
    end endgenerate

    // ---- S4: combine ------------------------------------------------------------------
    reg signed [23:0] zi4, zq4;
    wire raw_b_ok = avail_b && v3[1] && good[1];
    wire raw_c_ok = HAS_C && avail_c && v3[2] && good[2];
    assign ref_lost = FAILOVER && !good[0] &&
        ((avail_b && good[1]) || (HAS_C && avail_c && good[2]));
    assign poor_a = ref_lost;
    // During a short A marker the existing rotated, aligned branches can
    // still carry the picture. If A loses RF, its rotations are unreliable;
    // select a proven B or C directly while A-based alignment reacquires.
    wire need_backup = FAILOVER && (poor_a ||
        (!v3[0] && !(en_b && v3[1]) && !(HAS_C && en_c && v3[2])));
    reg [1:0] source4;
    wire select_b = need_backup && raw_b_ok && (source4 != 2'd2 || !raw_c_ok);
    wire select_c = need_backup && raw_c_ok && !select_b;
    wire [1:0] source_n = select_b ? 2'd1 : select_c ? 2'd2 : 2'd0;
    reg signed [4:0] backup_i3, backup_q3, c_i3_raw, c_q3_raw, cb_i2, cb_q2, cc_i2, cc_q2;
    always @(posedge clk) begin
        cb_i2 <= cb_i1; cb_q2 <= cb_q1; cc_i2 <= cc_i1; cc_q2 <= cc_q1;
        backup_i3 <= cb_i2; backup_q3 <= cb_q2; c_i3_raw <= cc_i2; c_q3_raw <= cc_q2;
    end
    wire signed [4:0] raw_i = select_b ? backup_i3 : c_i3_raw;
    wire signed [4:0] raw_q = select_b ? backup_q3 : c_q3_raw;
    wire [7:0] wa_eff = v3[0] ? w_use[0] : 8'd0;
    assign wts = {w_use[2], w_use[1], w_use[0]};
    wire [7:0] wb_eff = en_b && v3[1] ? w_use[1] : 8'd0, wc_eff = en_c && v3[2] ? w_use[2] : 8'd0;
    wire [17:0] a_i, a_q;
    wire [35:0] b_i, b_q, c_i, c_q;
    mul9  u_ai (.a({1'b0, wa_eff}), .b({{4{ca_i3[4]}}, ca_i3}), .y(a_i));
    mul9  u_aq (.a({1'b0, wa_eff}), .b({{4{ca_q3[4]}}, ca_q3}), .y(a_q));
    mul18 u_bi (.a({10'd0, wb_eff}), .b({{5{rb_i3[12]}}, rb_i3}), .y(b_i));
    mul18 u_bq (.a({10'd0, wb_eff}), .b({{5{rb_q3[12]}}, rb_q3}), .y(b_q));
    generate if (HAS_C) begin : pc
    mul18 u_ci (.a({10'd0, wc_eff}), .b({{5{rc_i3[12]}}, rc_i3}), .y(c_i));
    mul18 u_cq (.a({10'd0, wc_eff}), .b({{5{rc_q3[12]}}, rc_q3}), .y(c_q));
    end else begin : nopc
    assign c_i = 36'd0; assign c_q = 36'd0;
    end endgenerate
    always @(posedge clk) begin
        if (rst) begin
            for (ku = 0; ku < 3; ku = ku + 1) w_use[ku] <= 8'd1;
        end else if (run3 && idx3 == 7'd127 && have_pend) begin
            for (ku = 0; ku < 3; ku = ku + 1) w_use[ku] <= pend[ku];
        end
        source4 <= rst ? 2'd0 : source_n;
        valid4 <= (wa_eff != 0 || wb_eff != 0 || wc_eff != 0 || source_n != 0) && !rst;
        zi4 <= source_n != 0 ? $signed({{7{raw_i[4]}}, raw_i, 12'd0}) : $signed({a_i[17:0], 6'd0}) + $signed(b_i[23:0]) + $signed(c_i[23:0]);
        zq4 <= source_n != 0 ? $signed({{7{raw_q[4]}}, raw_q, 12'd0}) : $signed({a_q[17:0], 6'd0}) + $signed(b_q[23:0]) + $signed(c_q[23:0]);
    end

    // ---- discriminator: D32-R2 rule on the combined angle (mrc3_model.disc50) ----
    reg valid4;
    reg [10:0] valid_d;
    reg [10:0] source_b_d, source_c_d;
    always @(posedge clk) begin
        valid_d <= {valid_d[9:0], valid4};
        source_b_d <= {source_b_d[9:0], source4 == 2'd1};
        source_c_d <= {source_c_d[9:0], source4 == 2'd2};
    end
    wire [15:0] phi_raw;
    wire [1:0] phi_src = {source_c_d[10], source_b_d[10]};
    reg [1:0] prior_src;
    reg [15:0] phase_bias, last_phi, last_step;
    wire seam = FAILOVER && phi_src != prior_src;
    wire [15:0] phi = seam ? last_phi + last_step : phi_raw + phase_bias;
    always @(posedge clk) begin
        if (rst || !run_d[11]) begin
            phase_bias <= 0; last_phi <= 0; last_step <= 0; prior_src <= 0;
        end else if (FAILOVER) begin
            if (seam) phase_bias <= phi - phi_raw;
            if (valid_d[10]) begin last_phi <= phi; last_step <= phi - last_phi; end
            prior_src <= phi_src;
        end
    end
    cordic_angle #(.W(18), .N(10)) u_phi (.clk(clk), .x_in(zi4[23:6]), .y_in(zq4[23:6]), .ang(phi_raw));
    // sample parity and run, carried along zi4 (1) and the CORDIC (N + 1 = 11)
    reg [11:0] ev_d, run_d;
    always @(posedge clk) begin
        ev_d  <= {ev_d[10:0], ~idx3[0]};
        run_d <= rst ? 12'd0 : {run_d[10:0], run3};
    end
    wire        ev_phi = ev_d[11] & run_d[11];
    wire [9:0]  tok = phi[15:6] ^ 10'h200;          // ((phi + 32768) >> 6) & 1023
    reg  [9:0]  st_s;
    reg         st_ok;
    wire signed [9:0]  d = tok - st_s;               // wrapped to -512..511
    // step and code per d from a table in block RAM (gen_tables.disc_rom: the same
    // arithmetic as mrc3_model.disc50); read at ev_phi, applied the clock after
    // (ev_phi comes every other clock, so st_s is updated before the next d)
    reg [15:0] disc [0:1023];
`include "disc_rom.vh"
    reg [15:0] dq; reg dv; reg [5:0] dcode;
    // rescue PLL on phi[15:4] (mrc3_model.rescue50): e = p - th, fo = F/128 + e/4,
    // F += e (saturating, 17 bits), th += fo (all from 0 at reset); its code is the
    // discriminator table's for d = (fo + fo[k-1]) / 4 (a second read port)
    reg  [11:0] th;
    reg  signed [16:0] F;
    reg  signed [10:0] fo_r;
    wire signed [11:0] e  = phi[15:4] - th;
    wire signed [10:0] fo = (F >>> 7) + (e >>> 2);
    wire signed [17:0] Fn = F + e;
    wire signed [11:0] fs = fo + fo_r;
    reg  [15:0] pq;
    always @(posedge clk) pq <= disc[fs[11:2]];
    wire        run_phi = run_d[11];
    always @(posedge clk) begin
        if (rst) begin th <= 12'd0; F <= 17'sd0; fo_r <= 11'sd0; end
        else if (run_phi) begin
            th <= th + {fo[10], fo};
            F <= Fn[17] != Fn[16] ? {Fn[17], {16{~Fn[17]}}} : Fn[16:0];
            fo_r <= fo;
        end
    end
    // disc50's out-of-window steps (clicks), one per sample pair
    wire        click = st_ok && (d < -10'sd312 || d > 10'sd384);
    reg         ckr;
    // the two candidate streams, one sample a clock: s_d the discriminator's code,
    // s_p the PLL's, s_f marks a pair's first sample, s_c that pair's click
    reg  [5:0]  s_d, s_p; reg s_f, s_c;
    always @(posedge clk) begin
        dq <= disc[$unsigned(d)];                 // d as its 10 bits (negative d at 512 .. 1023)
        dv <= 1'b0;
        if (rst) begin st_ok <= 1'b0; dcode <= 6'd25; ckr <= 1'b0; s_d <= 6'd25; s_p <= 6'd25; s_f <= 1'b0; s_c <= 1'b0; end
        else begin
            if (ev_phi) begin
                if (!st_ok) begin st_s <= tok; st_ok <= 1'b1; end
                else dv <= 1'b1;
                ckr <= click;
            end
            if (dv) begin st_s <= st_s + dq[15:6]; dcode <= dq[5:0]; end
            s_d <= dv ? dq[5:0] : dcode; s_p <= pq[5:0]; s_f <= dv; s_c <= ckr;
        end
    end
    // Auto, look-ahead (mrc3_model.rescue50): both streams wait 2^RS_WSH pairs in
    // block RAM; a pair goes out as the PLL's when the 2^(RS_WSH+1) pairs around it
    // (2^RS_WSH - 1 before, 2^RS_WSH after) hold RS_K clicks or more. Off and On go
    // through the same delay. Per pair: at its first sample the slots are read, at
    // its second written (the pair W before comes out of the RAM).
    // Steady clicks: every 64 sub-windows of 2^RS_SSH pairs the PLL goes on for
    // all pairs when RS_T of them held a click (a very weak signal), else off;
    // pairs are numbered from 1 (the first one sets the discriminator's start).
    localparam integer W = 1 << RS_WSH;
    reg  [17:0] lram [0:W-1];                     // {disc code, PLL first, PLL second}
    reg  [RS_WSH-1:0] la_wa;
    reg  [17:0] la_q, la_o;
    reg  [11:0] la_a; reg la_c;
    reg         la_sel, la_p;                 // la_p: a pair's first sample came, its second is next
    reg  [RS_SSH+5:0] st_pc;                      // pair number in the 64 sub-windows
    reg         st_occ, st_on;
    reg  [6:0]  st_n;
    always @(posedge clk) begin
        if (s_f) la_q <= lram[la_wa];
        if (!s_f && la_p) lram[la_wa] <= {la_a, s_p};
    end
    // Only the threshold matters, so keep the age of the last RS_K clicks
    // instead of a BSRAM bit for every pair in the 2W window.
    wire enough_clicks;
    generate if (RS_K == 0) begin : clicks_always
        assign enough_clicks = 1'b1;
    end else begin : clicks_recent
        localparam [RS_WSH+1:0] EXPIRED = 2 * W;
        reg [RS_WSH+1:0] age [0:RS_K-1];
        integer i;
        always @(posedge clk) begin
            if (rst) for (i = 0; i < RS_K; i = i + 1) age[i] <= EXPIRED;
            else if (!s_f && la_p) begin
                age[0] <= la_c ? 0 : age[0] == EXPIRED ? EXPIRED : age[0] + 1'b1;
                for (i = 1; i < RS_K; i = i + 1)
                    if (la_c) age[i] <= age[i-1] == EXPIRED ? EXPIRED : age[i-1] + 1'b1;
                    else if (age[i] != EXPIRED) age[i] <= age[i] + 1'b1;
            end
        end
        assign enough_clicks = age[RS_K-1] != EXPIRED;
    end endgenerate
    wire [5:0] d3_code;
    reg [15:0] d3_phi;
    reg d3_run, d3_valid, d3_even, d3_click, d3_steady;
    always @(posedge clk) begin
        d3_phi <= phi;
        d3_run <= run_phi && !rst;
        d3_valid <= valid_d[10];
        d3_even <= ev_phi;
        d3_click <= click && ev_phi && valid_d[10] && !seam;
        d3_steady <= st_on;
    end
    d3_fm u_d3 (.clk(clk), .rst(rst), .run(d3_run), .valid(d3_valid),
               .even_sample(d3_even), .phi(d3_phi), .click(d3_click),
               .steady(d3_steady), .degrade(d3_degrade), .code(d3_code));
    reg [5:0] rescue_code;
    always @* code = rmode == 2'd3 ? d3_code : rescue_code;
    wire        sel_n = rmode[1] || (rmode == 2'd1 && (enough_clicks || st_on));
    always @(posedge clk) begin
        if (rst) begin
            la_wa <= 0; la_o <= {3{6'd25}}; la_sel <= 1'b0; la_p <= 1'b0; la_c <= 1'b0;
            st_pc <= 1; st_occ <= 1'b0; st_on <= 1'b0; st_n <= 7'd0;
            rescue_code <= 6'd25; ract <= 1'b0;
        end else if (s_f) begin
            la_a <= {s_d, s_p}; la_c <= s_c; la_p <= 1'b1;
            rescue_code <= sel_n ? la_o[11:6] : la_o[17:12]; la_sel <= sel_n; ract <= sel_n && rmode != 2'd3;
        end else if (la_p) begin
            la_p <= 1'b0;
            la_wa <= la_wa + 1'b1;
            la_o <= la_q;
            st_pc <= st_pc + 1'b1;
            if (&st_pc[RS_SSH-1:0]) begin
                st_occ <= 1'b0;
                if (&st_pc[RS_SSH+5:RS_SSH]) begin st_on <= st_n + (st_occ | la_c) >= RS_T; st_n <= 7'd0; end
                else st_n <= st_n + (st_occ | la_c);
            end else st_occ <= st_occ | la_c;
            rescue_code <= la_sel ? la_o[5:0] : la_o[17:12];
        end
    end
endmodule
`default_nettype wire

// Causal D3 experiment, one estimator at 40 MS/s. Phase and frequency use
// 16-bit turn units (16 units per 12-bit phase cell). Four 512-pair buckets
// retain 1536..2047 causal pairs, saturating each bucket at four clicks.
module d3_fm (
    input wire clk, rst, run, valid, even_sample,
    input wire [15:0] phi,
    input wire click, steady,
    output wire [1:0] degrade,
    output wire [5:0] code
);
    reg [8:0] pos;
    reg [2:0] n0, n1, n2, n3;
    wire [4:0] nc = {2'b0, n0} + {2'b0, n1} + {2'b0, n2} + {2'b0, n3};
    wire [12:0] target = steady || nc >= 5'd4 ? 13'd4096 : {nc[1:0], 10'd0};
    reg [12:0] bad;
    wire [12:0] attack = target - bad, release_delta = bad - target;
    wire [6:0] gain_bad = bad[12:6];
    assign degrade = gain_bad >= 7'd56 ? 2'd3 : gain_bad >= 7'd32 ? 2'd2 : gain_bad >= 7'd12 ? 2'd1 : 2'd0;
    always @(posedge clk) begin
        if (rst || !run) begin
            pos <= 0; n0 <= 0; n1 <= 0; n2 <= 0; n3 <= 0; bad <= 0;
        end else begin
            if (even_sample) begin
                pos <= pos + 1'b1;
                if (&pos) begin
                    n3 <= n2; n2 <= n1; n1 <= n0 + (click && n0 < 3'd4); n0 <= 0;
                end else if (click && n0 < 3'd4) n0 <= n0 + 1'b1;
            end
            if (target > bad) bad <= bad + (attack >> 6) + (|attack[5:0]);
            else if (target < bad) bad <= bad - (release_delta >> 8) - (|release_delta[7:0]);
        end
    end

    reg [15:0] theta;
    reg signed [14:0] freq;
    reg signed [17:0] last_advance;
    reg [3:0] missed;
    reg [1:0] fresh;
    wire signed [15:0] innovation = phi - theta;
    wire [35:0] scaled_bits;
    mul18 u_correction (.a({{2{innovation[15]}}, innovation}), .b({11'd0, gain_bad}), .y(scaled_bits));
    wire signed [22:0] scaled = scaled_bits[22:0];
    wire signed [16:0] damp = scaled >>> 8;
    wire signed [17:0] phase_adjust = freq - damp - (damp <<< 1);
    wire signed [17:0] advance = innovation + phase_adjust;
    wire signed [15:0] freq_n = freq + ((scaled + 23'sd4096) >>> 13);
    wire signed [18:0] pair_advance = advance + last_advance;
    wire signed [12:0] pair_step = pair_advance >>> 6;
    reg signed [12:0] even_step;
    // Intermediate 25 ns estimate from the same loop. Interpolate the
    // pair-averaged advance with five multiplier-free gains.
    wire signed [13:0] step_delta = $signed({pair_step[12], pair_step}) - even_step;
    wire signed [13:0] half_delta = step_delta >>> 1;
    wire signed [13:0] quarter_delta = step_delta >>> 2;
    wire signed [13:0] odd_correction = gain_bad >= 7'd56 ? step_delta :
        gain_bad >= 7'd40 ? half_delta + quarter_delta :
        gain_bad >= 7'd24 ? half_delta : gain_bad >= 7'd8 ? quarter_delta : 14'sd0;
    reg signed [13:0] step;
    wire signed [13:0] limited = step > 14'sd511 ? 14'sd511 : step < -14'sd512 ? -14'sd512 : step;
    wire [9:0] address = limited[9:0];
    (* ram_style = "block" *) reg [15:0] disc [0:1023];
`include "disc_rom.vh"
    reg [5:0] result;
    assign code = result;
    always @(posedge clk) begin
        result <= disc[address][5:0];
        if (rst || !run) begin
            theta <= 0; freq <= 0; last_advance <= 0; missed <= 4'd9; fresh <= 0;
            even_step <= 0; step <= 0;
        end else if (!valid) begin
            fresh <= 0;
            if (missed < 4'd9) missed <= missed + 1'b1;
            if (missed < 4'd8) begin theta <= theta + freq; step <= freq >>> 5; end
            else step <= 0;  // neutral after 200 ns without any usable IQ
        end else if (missed == 4'd9) begin
            theta <= phi; freq <= 0; last_advance <= 0; missed <= 0; fresh <= 2'd1; step <= 0;
        end else begin
            missed <= 0;
            if (fresh < 2'd3) fresh <= fresh + 1'b1;
            // theta + wrapped innovation == phi modulo one turn.
            theta <= phi + phase_adjust[15:0];
            freq <= freq_n > 16'sd8192 ? 15'sd8192 : freq_n < -16'sd8192 ? -15'sd8192 : freq_n[14:0];
            last_advance <= advance;
            if (fresh == 0) begin even_step <= pair_step; step <= 0; end
            else if (even_sample) begin even_step <= pair_step; step <= pair_step; end
            else if (fresh >= 2) step <= even_step + odd_correction;
        end
    end
endmodule
