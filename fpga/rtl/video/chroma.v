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
    output reg  [9:0]        y8u,        // luma, sum-of-8-codes units (vid_sync's y)
    output reg  signed [9:0] ug,         // U, V in gray units (255 = 100 IRE), V sign-corrected
    output reg  signed [9:0] vg
);
    localparam [31:0] INC_N = 32'd384350767, INC_P = 32'd476056188;
    localparam [19:0] K_N = 20'd110490, K_P = 20'd175072;
    localparam [15:0] KILL = 16'd600;
    wire [11:0] BS = pal ? 12'd240 : 12'd232, BE = pal ? 12'd304 : 12'd296;
    // ---- NCO and table ----
    reg  [31:0] ph = 32'd0;
    reg  signed [20:0] fadj = 21'sd0;
    reg  signed [7:0] sin_t [0:255];
    reg  signed [7:0] cos_t [0:255];
`include "chroma_tab.vh"
    reg  signed [7:0] s, co;                 // table at ph (read with the next phase)
    reg  [31:0] ph_n;
    always @(posedge clk) begin s <= sin_t[ph_n[31:24]]; co <= cos_t[ph_n[31:24]]; end
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
    reg         kill = 1'b1, sw = 1'b0;      // sw: V inverted on this line (PAL)
    // burst angles: a sequential vectoring CORDIC, bit-exact with rtl/rx/cordic_angle.v
    // (mrc_model.cordic_angle), run twice a line: this burst (pre-rotation at
    // BE + 1, steps BE + 2 .. 11) and the mean of it and the burst before
    // (BE + 12, steps BE + 13 .. 22); both angles are in by BE + 23
`include "tables.vh"
    reg signed [17:0] cx, cy; reg [15:0] ang, t_cur; reg [3:0] cn; reg crun;
    reg signed [15:0] xp, yp, xa, ya;
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
        if (hc == BE + 12'd1) begin
            xa <= ($signed({xq[15], xq}) + $signed({xp[15], xp})) >>> 1;
            ya <= ($signed({yq[15], yq}) + $signed({yp[15], yp})) >>> 1;
            xp <= xq; yp <= yq;
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
    // NTSC: the error is this burst's angle; PAL: the two-burst mean's, and the
    // V switch is this burst against the mean
    wire signed [15:0] t = pal ? ang : t_cur;
    wire signed [16:0] err = {t[15], t};
    wire [15:0] dcm = t_cur - ang;
    wire        swp = dcm != 16'd0 && !dcm[15];          // 0 < d < 32768
    wire        ev = hc == BE + 12'd24;
    wire signed [21:0] fsum = {fadj[20], fadj} - {{5{err[16]}}, err};
    wire signed [20:0] fadj_n = !ev ? fadj : fsum > 22'sd1048575 ? 21'sd1048575 : fsum < -22'sd1048576 ? -21'sd1048576 : fsum[20:0];
    wire [31:0] corr = ev ? -({{15{err[16]}}, err} << 14) : 32'd0;
    wire signed [16:0] adiff = {1'b0, amp} - {1'b0, acc_a};
    wire [15:0] a_n = acc_a + {{3{adiff[16]}}, adiff[15:3]};
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
            if (hc == BE + 12'd1) amp <= (ax > ay ? ax : ay) + ((ax > ay ? ay : ax) >> 1);
            if (ev) begin
                sw <= pal && !swp;
                acc_a <= a_n; kill <= a_n < KILL;
                dv_k <= pal ? K_P : K_N; dv_a <= a_n; dv_r <= 21'd0; dv_q <= 11'd0; dv_n <= 5'd20; dv_run <= a_n >= KILL;
                if (a_n < KILL) gk <= 11'd0;
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
    reg  signed [13:0] pu_r, pv_r;
    reg  signed [13:0] dpu [0:23];
    reg  signed [13:0] dpv [0:23];
    reg  signed [17:0] u1, v1;
    reg  signed [17:0] du1 [0:23];
    reg  signed [17:0] dv1 [0:23];
    reg  signed [21:0] u2, v2;
    reg  [3:0]  palr;
    wire        p1 = palr[0];                       // pal of pu_r
    wire        chg1 = palr[0] != palr[1];          // standard changed at pu_r
    wire [4:0]  n1 = p1 ? 5'd18 : 5'd22;
    integer i, i2, i0;
    // delayed code and table values (python: c, s, co at k - (n - 1))
    reg  signed [6:0] dc [0:31];
    reg  signed [7:0] ds [0:31];
    reg  signed [7:0] dco [0:31];
    initial begin
        palr = 4'd0; u1 = 18'sd0; v1 = 18'sd0; u2 = 22'sd0; v2 = 22'sd0; pu_r = 14'sd0; pv_r = 14'sd0;
        for (i0 = 0; i0 < 24; i0 = i0 + 1) begin dpu[i0] = 14'sd0; dpv[i0] = 14'sd0; du1[i0] = 18'sd0; dv1[i0] = 18'sd0; end
        for (i0 = 0; i0 < 32; i0 = i0 + 1) begin dc[i0] = 7'sd0; ds[i0] = 8'sd0; dco[i0] = 8'sd0; end
    end
    always @(posedge clk) begin
        palr <= {palr[2:0], pal};
        pu_r <= pu; pv_r <= pv;
        dc[0] <= c; ds[0] <= s; dco[0] <= co;
        for (i = 1; i < 32; i = i + 1) begin dc[i] <= dc[i-1]; ds[i] <= ds[i-1]; dco[i] <= dco[i-1]; end
        // stage 1: u1 = sum of the last n pu (python u1[k] lands here at k + 2);
        // reset clears the integrators with their delay lines (they must agree)
        if (rst) begin
            for (i = 0; i < 24; i = i + 1) begin dpu[i] <= 14'sd0; dpv[i] <= 14'sd0; end
            u1 <= 18'sd0; v1 <= 18'sd0; pu_r <= 14'sd0; pv_r <= 14'sd0;
        end else if (chg1) begin
            for (i = 0; i < 24; i = i + 1) begin dpu[i] <= 14'sd0; dpv[i] <= 14'sd0; end
            dpu[0] <= pu_r; dpv[0] <= pv_r; u1 <= pu_r; v1 <= pv_r;
        end else begin
            dpu[0] <= pu_r; dpv[0] <= pv_r;
            for (i = 1; i < 24; i = i + 1) begin dpu[i] <= dpu[i-1]; dpv[i] <= dpv[i-1]; end
            u1 <= u1 + pu_r - dpu[n1 - 5'd1]; v1 <= v1 + pv_r - dpv[n1 - 5'd1];
        end
    end
    // stage 2: u2 (python u2[k] at k + 3)
    reg chg2 = 1'b0, p2 = 1'b0;
    always @(posedge clk) begin
        chg2 <= chg1; p2 <= p1;
        if (rst) begin
            for (i2 = 0; i2 < 24; i2 = i2 + 1) begin du1[i2] <= 18'sd0; dv1[i2] <= 18'sd0; end
            u2 <= 22'sd0; v2 <= 22'sd0;
        end else if (chg2) begin
            for (i2 = 0; i2 < 24; i2 = i2 + 1) begin du1[i2] <= 18'sd0; dv1[i2] <= 18'sd0; end
            du1[0] <= u1; dv1[0] <= v1; u2 <= u1; v2 <= v1;
        end else begin
            du1[0] <= u1; dv1[0] <= v1;
            for (i2 = 1; i2 < 24; i2 = i2 + 1) begin du1[i2] <= du1[i2-1]; dv1[i2] <= dv1[i2-1]; end
            u2 <= u2 + u1 - du1[(p2 ? 5'd18 : 5'd22) - 5'd1]; v2 <= v2 + v1 - dv1[(p2 ? 5'd18 : 5'd22) - 5'd1];
        end
    end
    // stage 3 (k + 3): remodulation and U, V in gray units; table and code delayed by n - 1 + 3
    reg p3 = 1'b0; always @(posedge clk) p3 <= p2;
    wire [4:0] tap3 = p2 ? 5'd19 : 5'd23;            // c[k - (n - 1)] at stage 3: dc[j] = c[k + 2 - j]
    wire signed [7:0] sd = ds[tap3], cod = dco[tap3];
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
        cd4 <= dc[tap3];
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
