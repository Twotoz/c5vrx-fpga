// Triversity: colour decoder (NTSC and PAL) on the demodulator codes, in the
// 40 MHz domain of C5 A, timed by vid_sync's line counter hc.
//  - NCO at the subcarrier, sin / cos table, code x sin / cos
//  - burst I/Q sums over the burst gate, CORDIC angle against the -U axis;
//    (sequential); NTSC: the phase error; PAL: the angle of the mean of two
//    successive bursts (their +-45 degrees cancel), the V switch from this
//    burst against that mean;
//    a PI loop on the NCO (Kp 1/4 turn per turn, Ki in phase per clock)
//  - saturation: burst amplitude (max + min / 2) smoothed over lines, gain
//    G = K / A by a sequential divider, colour off below a minimum burst
//  - U, V: two boxcars of two subcarrier periods (22 NTSC, 18 PAL clocks)
//  - luma: 16 x code minus the remodulated chroma, a 4-clock boxcar,
//    in vid_sync's units (sum of 8 codes)
// Bit-exact with fpga/model/chroma_model.hw_decode (fpga/sim/run_chroma_tb.py),
// outputs 6 clocks after the code they belong to.
`default_nettype none
module chroma (
    input  wire              clk,
    input  wire              rst,
    input  wire [5:0]        code,
    input  wire [11:0]       hc,
    input  wire              pal,
    input  wire              line_sync,
    output reg  [9:0]        y8u,        // luma, sum-of-8-codes units (vid_sync's y)
    output reg  signed [9:0] ug,         // U, V in gray units (255 = 100 IRE), V sign-corrected
    output reg  signed [9:0] vg
);
    localparam [31:0] INC_N = 32'd384350767, INC_P = 32'd476056188;
    // burst gate: a whole number of subcarrier periods (NTSC 5 = 55.9 samples -> 56,
    // PAL 7 = 63.2 -> 63), so the code's DC (the porch sits near code 20 on the board,
    // not 32) drops out of the burst sums; 64 samples (5.7 / 7.1 periods) let it leak
    // in with a sign that turns every NTSC line: A inflated, the burst PLL pulled
    // about, no colour. K and the kill level scale with the gate (56/64, 63/64).
    localparam [19:0] K_N = 20'd96679, K_P = 20'd172337;
    wire [15:0] KILL = pal ? 16'd591 : 16'd525;
    wire [11:0] BS = pal ? 12'd240 : 12'd232, BE = pal ? 12'd303 : 12'd288;
    // ---- NCO and table ----
    reg  [31:0] ph = 32'd0;
    reg  signed [20:0] fadj = 21'sd0;
    (* ram_style = "block" *) reg [15:0] sc_t [0:255];   // {sin, cos}: in a block RAM (in logic ~250 LUT)
`include "chroma_tab.vh"
    reg  [15:0] sc;                          // table at ph (read with the next phase)
    wire signed [7:0] s = sc[15:8], co = sc[7:0];
    reg  [31:0] ph_n;
    always @(posedge clk) sc <= sc_t[ph_n[31:24]];
    // ---- mixing ----
    wire signed [6:0] c = {1'b0, code} - 7'sd32;
    wire [17:0] mu, mv;
    mul9 u_mu (.a({{2{c[6]}}, c}), .b({s[7], s}), .y(mu));
    mul9 u_mv (.a({{2{c[6]}}, c}), .b({co[7], co}), .y(mv));
    wire signed [13:0] pu = mu[13:0], pv = mv[13:0];
    // ---- burst ----
    reg  signed [20:0] bi, bq;
    reg  signed [15:0] xq, yq;
    reg  [15:0] amp, acc_a;
    reg         valid_burst, valid_previous, previous_pal;
    reg         kill = 1'b1, sw = 1'b0;      // sw: V inverted on this line (PAL)
    // burst angles: a sequential vectoring CORDIC, bit-exact with rtl/rx/cordic_angle.v
    // (mrc_model.cordic_angle), run twice a line: this burst (pre-rotation at
    // BE + 1, steps BE + 2 .. 11) and the mean of it and the burst before
    // (BE + 12, steps BE + 13 .. 22); both angles are in by BE + 23
`include "tables.vh"
    reg signed [17:0] cx, cy; reg [15:0] ang, t_cur; reg [3:0] cn; reg crun;
    reg signed [15:0] xp, yp, xa, ya;
    wire burst_ok;
    wire        c_go = hc == BE + 12'd1 || hc == BE + 12'd12;
    wire signed [15:0] cxi = hc == BE + 12'd1 ? xq : xa, cyi = hc == BE + 12'd1 ? yq : ya;
    // the CORDIC's sums on ADDSUB carry chains (rtl/rx/addsub.v): pre-rotation 0 -/+ v,
    // steps x +/- y >> n, y -/+ x >> n, angle +/- atan
    wire [17:0] cx0, cy0, cxn, cyn; wire [15:0] angn;
    wire        cpos = cy > 0;
    addsub #(18) u_cx0 (.a(18'd0), .b({{2{cxi[15]}}, cxi}), .sub(cxi[15]), .y(cx0));
    addsub #(18) u_cy0 (.a(18'd0), .b({{2{cyi[15]}}, cyi}), .sub(cxi[15]), .y(cy0));
    addsub #(18) u_cxn (.a(cx), .b(cy >>> cn), .sub(~cpos), .y(cxn));
    addsub #(18) u_cyn (.a(cy), .b(cx >>> cn), .sub(cpos), .y(cyn));
    addsub #(16) u_ang (.a(ang), .b(atan_lut(cn)), .sub(~cpos), .y(angn));
    always @(posedge clk) begin
        if (rst) begin
            xp <= 0; yp <= 0;
            valid_burst <= 0; valid_previous <= 0; previous_pal <= 0;
        end else if (hc == BE + 12'd1) begin
            xa <= ($signed({xq[15], xq}) + $signed({xp[15], xp})) >>> 1;
            ya <= ($signed({yq[15], yq}) + $signed({yp[15], yp})) >>> 1;
            if (burst_ok) begin xp <= xq; yp <= yq; end
            valid_burst <= burst_ok && (!pal || (valid_previous && previous_pal == pal));
            valid_previous <= burst_ok;
            previous_pal <= pal;
        end
        if (hc == BE + 12'd12) t_cur <= ang;
        if (c_go) begin
            cx <= cx0; cy <= cy0; ang <= cxi[15] ? 16'd32768 : 16'd0;
            cn <= 4'd0; crun <= 1'b1;
        end else if (crun) begin
            cx <= cxn; cy <= cyn; ang <= angn;
            cn <= cn + 4'd1;
            if (cn == 4'd9) crun <= 1'b0;
        end
    end
    function signed [15:0] sat16; input signed [20:0] v;
        sat16 = v > 21'sd32767 ? 16'sd32767 : v < -21'sd32768 ? -16'sd32768 : v[15:0];
    endfunction
    wire signed [20:0] nbq = -bq;
    wire [15:0] ax, ay;
    addsub #(16) u_ax (.a(16'd0), .b(xq), .sub(xq[15]), .y(ax));
    addsub #(16) u_ay (.a(16'd0), .b(yq), .sub(yq[15]), .y(ay));
    wire [15:0] burst_amp = (ax > ay ? ax : ay) + ((ax > ay ? ay : ax) >> 1);
    assign burst_ok = line_sync && burst_amp >= KILL;
    // NTSC: the error is this burst's angle; PAL: the two-burst mean's, and the
    // V switch is this burst against the mean
    wire signed [15:0] t = pal ? ang : t_cur;
    wire signed [16:0] err = {t[15], t};
    wire [15:0] dcm = t_cur - ang;
    wire        swp = dcm != 16'd0 && !dcm[15];          // 0 < d < 32768
    wire        ev = hc == BE + 12'd24;
    wire        track = ev && valid_burst;
    wire signed [21:0] fsum = {fadj[20], fadj} - {{5{err[16]}}, err};
    wire signed [20:0] fadj_n = !track ? fadj : fsum > 22'sd1048575 ? 21'sd1048575 : fsum < -22'sd1048576 ? -21'sd1048576 : fsum[20:0];
    wire [31:0] corr = track ? -({{15{err[16]}}, err} << 14) : 32'd0;
    wire signed [16:0] adiff = (valid_burst ? {1'b0, amp} : 17'd0) - {1'b0, acc_a};
    wire [15:0] a_n = acc_a + {{3{adiff[16]}}, adiff[15:3]};
    wire colour_on = valid_burst && a_n >= KILL;
    // divider G = K / A
    reg  [19:0] dv_k; reg [15:0] dv_a; reg [20:0] dv_r; reg [10:0] dv_q; reg [4:0] dv_n; reg dv_run;
    reg  [10:0] gk;
    always @(*) ph_n = ph + (pal ? INC_P : INC_N) + {{11{fadj_n[20]}}, fadj_n} + corr;
    always @(posedge clk) begin
        if (rst) begin ph <= 32'd0; fadj <= 21'sd0; bi <= 21'sd0; bq <= 21'sd0; acc_a <= 16'd0; kill <= 1'b1; sw <= 1'b0; gk <= 11'd0; dv_run <= 1'b0; end
        else begin
            ph <= ph_n; fadj <= fadj_n;
            if (hc == 12'd0) begin bi <= 21'sd0; bq <= 21'sd0; end
            else if (hc >= BS && hc < BE) begin bi <= bi + pv; bq <= bq + pu; end
            if (hc == BE) begin
                xq <= sat16(nbq >>> 2); yq <= sat16(bi >>> 2);
            end
            if (hc == BE + 12'd1) amp <= burst_amp;
            if (ev) begin
                if (valid_burst) sw <= pal && !swp;
                acc_a <= a_n; kill <= !colour_on;
                dv_k <= pal ? K_P : K_N; dv_a <= a_n; dv_r <= 21'd0; dv_q <= 11'd0; dv_n <= 5'd20; dv_run <= colour_on;
                if (!colour_on) gk <= 11'd0;
            end else if (dv_run) begin                 // restoring division, one bit a clock
                if ({dv_r[19:0], dv_k[19]} >= {5'd0, dv_a}) begin dv_r <= {dv_r[19:0], dv_k[19]} - {5'd0, dv_a}; dv_q <= {dv_q[9:0], 1'b1}; end
                else begin dv_r <= {dv_r[19:0], dv_k[19]}; dv_q <= {dv_q[9:0], 1'b0}; end
                dv_k <= {dv_k[18:0], 1'b0};
                dv_n <= dv_n - 5'd1;
                if (dv_n == 5'd1) begin dv_run <= 1'b0; end
            end else if (dv_n == 5'd0 && !kill) gk <= dv_q;
        end
    end
    // ---- chroma filters: two boxcars of n (pipelined; filters restart on a standard change) ----
    // The delay lines are 32-entry RAM rings (registered reads, the
    // address one clock ahead). "Cleared" on a reset or a standard change:
    // a ring value older than that counts as 0 (age counters), exactly as the
    // shift registers' clear did.
    reg  signed [13:0] pu_r, pv_r;
    reg  signed [17:0] u1, v1;
    reg  signed [21:0] u2, v2;
    reg  [3:0]  palr;
    wire        p1 = palr[0];                       // pal of pu_r
    wire        chg1 = palr[0] != palr[1];          // standard changed at pu_r
    wire [4:0]  n1 = p1 ? 5'd18 : 5'd22;
    reg  [4:0]  wr = 5'd0;                          // ring write address (one entry a clock)
    reg  [4:0]  age1 = 5'd0, age2 = 5'd0;           // clocks since the stage's last clear (saturating)
    // Keep the small mixer delay in LUT RAM so the colour + HQ DVR build fits.
    (* ram_style = "distributed" *) reg [27:0] r1 [0:31]; // {pu_r, pv_r}
    (* ram_style = "block" *) reg [35:0] r2 [0:31]; // {u1, v1}
    (* ram_style = "block" *) reg [22:0] r0 [0:31]; // {c, s, co}
    reg  [27:0] q1; reg [35:0] q2; reg [22:0] q0;
    integer i0;
    initial begin
        palr = 4'd0; u1 = 18'sd0; v1 = 18'sd0; u2 = 22'sd0; v2 = 22'sd0; pu_r = 14'sd0; pv_r = 14'sd0;
        for (i0 = 0; i0 < 32; i0 = i0 + 1) begin r1[i0] = 28'd0; r2[i0] = 36'd0; r0[i0] = 23'd0; end
        q1 = 28'd0; q2 = 36'd0; q0 = 23'd0;
    end
    // next clock's pal (p1) and stage-2 pal (p2): the tap distances for the reads issued now
    wire [4:0] d1 = (pal ? 5'd18 : 5'd22) - 5'd1;   // stage 1 reads entry n1 - 1
    wire [4:0] d2 = (p1 ? 5'd18 : 5'd22) - 5'd1;    // stage 2 reads entry n2 - 1
    wire [4:0] d0 = p1 ? 5'd19 : 5'd23;             // stage 3: code / table at tap3
    // Explicit modulo-32 addresses, including reads that wrap below zero.
    wire [4:0] rd0 = wr - d0, rd1 = wr - d1, rd2 = wr - d2;
    always @(posedge clk) begin
        palr <= {palr[2:0], pal};
        pu_r <= rst ? 14'sd0 : pu;
        pv_r <= rst ? 14'sd0 : pv;
        wr <= wr + 5'd1;
        // ring k-entry of a shift register d (d[0] <= x each clock): d[k](t) = x(t - 1 - k),
        // written at wr(t - 1 - k) = wr(t - 1) - k: read now (wr) at wr - k for the next clock
        r0[wr] <= {c, s, co};
        r1[wr] <= rst ? 28'd0 : {pu_r, pv_r};
        r2[wr] <= rst ? 36'd0 : {u1, v1};
        q0 <= r0[rd0]; q1 <= r1[rd1]; q2 <= r2[rd2];
    end
    wire signed [13:0] dpu_n = age1 >= n1 ? $signed(q1[27:14]) : 14'sd0, dpv_n = age1 >= n1 ? $signed(q1[13:0]) : 14'sd0;
    // stage 1: u1 = sum of the last n pu (python u1[k] lands here at k + 2)
    always @(posedge clk) begin
        if (rst) begin
            u1 <= 18'sd0; v1 <= 18'sd0; age1 <= 5'd0;
        end else if (chg1) begin
            u1 <= pu_r; v1 <= pv_r; age1 <= 5'd1;
        end else begin
            u1 <= u1 + pu_r - dpu_n; v1 <= v1 + pv_r - dpv_n;
            if (age1 != 5'd31) age1 <= age1 + 5'd1;
        end
    end
    // stage 2: u2 (python u2[k] at k + 3)
    reg chg2 = 1'b0, p2 = 1'b0;
    wire [4:0] n2 = p2 ? 5'd18 : 5'd22;
    wire signed [17:0] du1_n = age2 >= n2 ? $signed(q2[35:18]) : 18'sd0, dv1_n = age2 >= n2 ? $signed(q2[17:0]) : 18'sd0;
    always @(posedge clk) begin
        chg2 <= chg1; p2 <= p1;
        if (rst) begin
            u2 <= 22'sd0; v2 <= 22'sd0; age2 <= 5'd0;
        end else if (chg2) begin
            u2 <= u1; v2 <= v1; age2 <= 5'd1;
        end else begin
            u2 <= u2 + u1 - du1_n; v2 <= v2 + v1 - dv1_n;
            if (age2 != 5'd31) age2 <= age2 + 5'd1;
        end
    end
    // stage 3 (k + 3): remodulation and U, V in gray units; table and code delayed by n - 1 + 3
    reg p3 = 1'b0; always @(posedge clk) p3 <= p2;
    // c[k - (n - 1)] at stage 3: the ring at tap 19 / 23 (dc[j] = c[k + 2 - j])
    wire signed [7:0] sd = q0[15:8], cod = q0[7:0];
    wire signed [17:0] u2s = u2 >>> 4, v2s = v2 >>> 4;
    wire [35:0] m_us, m_vc;
    mul18 u_us (.a(u2s), .b({{10{sd[7]}}, sd}), .y(m_us));
    mul18 u_vc (.a(v2s), .b({{10{cod[7]}}, cod}), .y(m_vc));
    wire signed [25:0] chr_ = $signed(m_us[25:0]) + $signed(m_vc[25:0]);
    function signed [17:0] sat18; input signed [25:0] v;
        sat18 = v > 26'sd131071 ? 18'sd131071 : v < -26'sd131072 ? -18'sd131072 : v[17:0];
    endfunction
    function signed [17:0] sat18w; input signed [21:0] v;
        sat18w = v > 22'sd131071 ? 18'sd131071 : v < -22'sd131072 ? -18'sd131072 : v[17:0];
    endfunction
    wire [35:0] m_ug, m_vg;
    mul18 u_ug (.a(sat18w(u2 >>> 2)), .b({7'd0, gk}), .y(m_ug));
    mul18 u_vg (.a(sat18w(v2 >>> 2)), .b({7'd0, gk}), .y(m_vg));
    wire signed [35:0] ugp = $signed(m_ug) >>> 14, vgp = $signed(m_vg) >>> 14;
    function signed [9:0] sat10; input signed [35:0] v;
        sat10 = v > 36'sd511 ? 10'sd511 : v < -36'sd512 ? -10'sd512 : v[9:0];
    endfunction
    reg  signed [17:0] chr_r;
    reg  signed [9:0]  ug3, vg3;
    reg  signed [6:0]  cd4;
    always @(posedge clk) begin
        chr_r <= sat18(chr_ >>> 7);
        ug3 <= kill ? 10'sd0 : sat10(ugp);
        vg3 <= kill ? 10'sd0 : (sw ? -sat10(vgp) : sat10(vgp));
        cd4 <= q0[22:16];
    end
    // stage 4 (k + 4): luma
    wire [35:0] m_ch;
    mul18 u_ch (.a(chr_r), .b(p3 ? 18'd103 : 18'd69), .y(m_ch));
    wire signed [35:0] ch16 = $signed(m_ch) >>> 13;
    reg  signed [17:0] yc, yc1, yc2, yc3;
    reg  signed [9:0]  ug4, vg4;
    always @(posedge clk) begin
        yc <= {{7{cd4[6]}}, cd4, 4'd0} - ch16[17:0];
        yc1 <= yc; yc2 <= yc1; yc3 <= yc2;
        ug4 <= ug3; vg4 <= vg3;
    end
    // stage 5 (k + 5): 4-clock boxcar; outputs from k + 6
    wire signed [19:0] y4 = {{2{yc[17]}}, yc} + {{2{yc1[17]}}, yc1} + {{2{yc2[17]}}, yc2} + {{2{yc3[17]}}, yc3};
    wire signed [19:0] y8s = (y4 >>> 3) + 20'sd256;
    always @(posedge clk) begin
        y8u <= y8s < 0 ? 10'd0 : y8s > 20'sd1023 ? 10'd1023 : y8s[9:0];
        ug <= ug4; vg <= vg4;
    end
endmodule
`default_nettype wire
