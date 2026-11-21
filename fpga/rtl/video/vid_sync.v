// Triversity: video timing and line capture from the demodulated codes
// (40 MHz domain of C5 A), in colour (chroma.v).
//  - luma: moving sum of 8 codes (200 ns; also takes most of the chroma)
//  - sync slicer halfway between the measured sync tip and back porch
//  - H flywheel: a line counter that a qualified sync edge (low >= 2 us)
//    pulls in a +-1 us window, snaps to after losing lock, and free-runs
//    without one; V: a broad pulse (low >= 17.5 us) starts a field, line
//    count flywheel otherwise; PAL when 291..329 lines lie between two
//    broad pulses (counted apart from the flywheel, which wraps an NTSC
//    count before a PAL field ends)
//  - auto levels: gray = (y - porch) * 102 / (porch - tip), white at
//    +100 IRE for a sync of -40 IRE, whatever the VTX deviation
//  - colour: chroma.v gives luma, U and V; each pixel is
//    Y = (luma - porch) x k8 / 256 and the shift-add YUV -> RGB matrix,
//    U and V averaged with the line above (stored for every line): PAL's
//    delay line, and on NTSC half the chroma noise
//  - each active line (NTSC 240, PAL 288 with one in six dropped: 240) as
//    800 RGB565 pixels into line buffer half orow[0] (wr_gray: luma, for the DVR); at the next line start
//    the LCD domain gets a toggle with the line's row (lcd_out.v shows it twice)
//  - aspect signalling for the menu's Aspect Auto: CGMS-A (IEC 61880, NTSC
//    lines 20/283: start bits 1 0, 14 data bits with bit 1 = 16:9, CRC-6
//    X^6 + X + 1 preset to ones; only after an NTSC-length field) and WSS (EN 300 294,
//    PAL line 23: run-in, start code, group 1 = 1110 for 16:9 full format);
//    wide after two fields that say 16:9, back after two that say 4:3 or
//    64 fields without a code. Checked against a model of both waveforms
//    (sim/run_aspect_tb.py); not yet seen from a real FPV camera.
`default_nettype none
module vid_sync (
    input  wire        clk,
    input  wire        rst,
    input  wire [5:0]  code,          // 40 MS/s (20 MS/s unique) demodulator codes
    output reg         wr_en,
    output reg  [10:0] wr_addr,       // {orow[0], px[9:0]}
    output reg  [15:0] wr_data,       // RGB565
    output reg  [7:0]  wr_gray,       // luma 0..255
    output reg         line_tog,      // toggles at each line start
    output reg  [8:0]  line_info,     // {show, orow[7:0]} of the line just written; stable after line_tog
    output reg         field_tog,
    output reg         pal,
    output reg         locked,
    output reg  [15:0] sync_q,        // in-window sync edges in the last 100 ms
    output reg         wide,          // the camera signals 16:9 (CGMS-A / WSS)
    // HQ DVR (TRI_HQDVR build): 720 JPEG pixels a line, every active line (PAL all 288)
    output reg         d_valid,
    output reg  [9:0]  d_x,
    output reg  [8:0]  d_line,
    output reg  [7:0]  d_y, d_cb, d_cr,
    output reg         d_fstart,      // a field begins (one clock)
    output reg         d_parity       // the field's parity (vertical sync mid-line)
);
    // ---- luma -------------------------------------------------------------
    reg [5:0] c [0:7];
    reg [8:0] y = 9'd0;
    integer i;
    initial for (i = 0; i < 8; i = i + 1) c[i] = 6'd0;
    always @(posedge clk) begin
        c[0] <= code;
        for (i = 1; i < 8; i = i + 1) c[i] <= c[i-1];
        y <= y + code - c[7];
        if (rst) y <= 9'd0;
    end
    // ---- line counter -------------------------------------------------------
    wire [11:0] HT = pal ? 12'd2560 : 12'd2542;
    reg  [11:0] hc;
    reg  [3:0]  lock;
    // ---- levels (per line, smoothed) ------------------------------------------
    reg [15:0] tip_acc, porch_acc;          // sums of 64 / 128 samples
    reg [8:0]  tip, porch;                  // smoothed levels (y units)
    reg [12:0] tip_f, porch_f;              // x16 IIR state
    reg  [8:0] linemin, minprev;
    reg  [4:0] lev_n;                       // level updates so far (slicer on measured levels at 16)
    wire [8:0] slice = lev_n[4] ? (tip + porch) >> 1 : minprev + 9'd16;
    reg        seen;                        // an in-window edge this line
    // ---- edge qualification ------------------------------------------------------
    reg        low;
    reg [11:0] low_len, hc_cross;
    reg        qual_pend;
    // ---- field ----------------------------------------------------------------------
    reg [9:0]  vline, vguard, field_lines, bpl;
    wire [9:0] VSTART = pal ? 10'd20 : 10'd18;
    wire [9:0] VROWS  = pal ? 10'd288 : 10'd240;
    wire [9:0] VMAX   = pal ? 10'd313 : 10'd263;
    // ---- active line ----------------------------------------------------------------
    wire [11:0] HSTART = pal ? 12'd420 : 12'd376;
    wire [11:0] ACT    = pal ? 12'd2080 : 12'd2104;
    reg  [11:0] dda;
    reg  [9:0]  px;
    reg         act, show_cur;
    reg  [7:0]  orow_cur;
    reg  [9:0]  aidx;
    reg  [2:0]  m6;
    reg  [7:0]  orow_n;
    // ---- gain -----------------------------------------------------------------------
    reg  [15:0] k8;                          // 26112 / depth
    reg  [15:0] dv_q; reg [9:0] dv_rem; reg [8:0] dv_den; reg [4:0] dv_n; reg dv_run;
    // ---- quality window ---------------------------------------------------------------
    reg  [22:0] qtim; reg [15:0] qcnt;
    wire        dv_bit = (16'd26112 >> (dv_n - 5'd1)) & 16'd1;

    wire signed [12:0] e = (hc_cross > (HT >> 1)) ? $signed({1'b0, hc_cross}) - $signed({1'b0, HT}) : $signed({1'b0, hc_cross});
    wire inwin = e >= -13'sd40 && e <= 13'sd40;
    // ---- colour (chroma.v) and the pixel stage ----
    wire [9:0] cy8u; wire signed [9:0] cug, cvg;
    chroma u_chroma (.clk(clk), .rst(rst), .code(code), .hc(hc), .pal(pal), .y8u(cy8u), .ug(cug), .vg(cvg));
    reg        p_tick, p_show, p_row0;
    reg  [9:0] p_px, p_y;
    reg  signed [9:0] p_u, p_v;
    reg  [19:0] uvp [0:1023];                // U, V of the line above
    integer ui; initial for (ui = 0; ui < 1024; ui = ui + 1) uvp[ui] = 20'd0;
    reg  [19:0] uvq;
    wire signed [10:0] yd = $signed({1'b0, p_y}) - $signed({2'b0, porch});
    wire signed [27:0] gm = yd * $signed({1'b0, k8});
    wire signed [19:0] gy = gm >>> 8;
    wire signed [10:0] yg = gy > 20'sd511 ? 11'sd511 : gy < -20'sd256 ? -11'sd256 : gy[10:0];
    wire signed [9:0]  uq = uvq[19:10], vq = uvq[9:0];
    // with the line above: PAL's delay line, and half the chroma noise on NTSC too
    // ($signed: a concatenation is unsigned and >>> would shift in zeros)
    wire signed [10:0] usum = $signed({p_u[9], p_u}) + $signed({uq[9], uq});
    wire signed [10:0] vsum = $signed({p_v[9], p_v}) + $signed({vq[9], vq});
    wire signed [10:0] uo = usum >>> 1;
    wire signed [10:0] vo = vsum >>> 1;
    wire signed [12:0] rr = yg + vo + (vo >>> 3) + (vo >>> 6);
    wire signed [12:0] gg = yg - ((uo >>> 2) + (uo >>> 3) + (uo >>> 6)) - ((vo >>> 1) + (vo >>> 4) + (vo >>> 6));
    wire signed [12:0] bb = yg + (uo <<< 1) + (uo >>> 5);
    function [7:0] cl8; input signed [12:0] v; cl8 = v < 0 ? 8'd0 : v > 13'sd255 ? 8'd255 : v[7:0]; endfunction

    always @(posedge clk) begin
        p_tick <= 1'b0;
        if (rst) begin
            hc <= 12'd0; lock <= 4'd0; low <= 1'b0; low_len <= 12'd0; qual_pend <= 1'b0;
            tip <= 9'd120; porch <= 9'd168; tip_f <= 13'd1920; porch_f <= 13'd2688; lev_n <= 5'd0; seen <= 1'b0;
            linemin <= 9'h1ff; minprev <= 9'd100;
            vline <= 10'd0; vguard <= 10'd0; field_lines <= 10'd0; bpl <= 10'd0; pal <= 1'b0; locked <= 1'b0;
            line_tog <= 1'b0; field_tog <= 1'b0; line_info <= 9'd0; act <= 1'b0;
            k8 <= 16'd580; dv_q <= 16'd580; dv_run <= 1'b0; qtim <= 23'd0; qcnt <= 16'd0; sync_q <= 16'd0;
            aidx <= 10'd0; m6 <= 3'd0; orow_n <= 8'd0; show_cur <= 1'b0; orow_cur <= 8'd0;
        end else begin
            // line counter, with the flywheel correction below
            hc <= (hc >= HT - 12'd1) ? 12'd0 : hc + 12'd1;
            // ---- sync edges ----
            if (!low && y < slice) begin low <= 1'b1; low_len <= 12'd0; hc_cross <= hc; end
            else if (low && y >= slice + 9'd4) begin low <= 1'b0; qual_pend <= 1'b0; end
            else if (low && low_len != 12'hfff) low_len <= low_len + 12'd1;
            if (low && low_len == 12'd80) begin                      // a sync pulse (>= 2 us)
                if (lock != 4'd0 && inwin) begin
                    hc <= hc + 12'd1 - {e[12], e[12:2]};              // pull in by e/4
                    seen <= 1'b1;
                    qcnt <= qcnt + 16'd1;
                end else if (lock == 4'd0) begin
                    hc <= low_len + 12'd1;                            // snap: the edge was hc = 0
                    lock <= 4'd1; seen <= 1'b1;
                end
            end
            if (low && low_len == 12'd700 && vguard == 10'd0) begin    // broad pulse: vertical sync
                field_lines <= vline;
                pal <= bpl > 10'd290 && bpl < 10'd330;
                bpl <= 10'd0;
                vline <= 10'd0; vguard <= 10'd200;
                field_tog <= ~field_tog;
                aidx <= 10'd0; m6 <= 3'd0; orow_n <= 8'd0;
            end
            // ---- levels: tip 40..103 and porch 220..347 clocks after the line start ----
            if (hc == 12'd40) tip_acc <= y; else if (hc > 12'd40 && hc < 12'd104) tip_acc <= tip_acc + y;
            if (hc == 12'd220) porch_acc <= y; else if (hc > 12'd220 && hc < 12'd348) porch_acc <= porch_acc + y;
            if (y < linemin) linemin <= y;
            if (hc == 12'd400 && lock >= 4'd8) begin
                if (!lev_n[4]) lev_n <= lev_n + 5'd1;
                tip_f   <= tip_f - (tip_f >> 3) + (tip_acc[14:6] << 1);
                porch_f <= porch_f - (porch_f >> 3) + (porch_acc[15:7] << 1);
                tip <= tip_f[12:4]; porch <= porch_f[12:4];
            end
            // ---- line start ----
            if (hc == 12'd0) begin
                line_info <= {show_cur, orow_cur};
                line_tog <= ~line_tog;
                show_cur <= 1'b0;
                if (seen) begin if (lock != 4'd15) lock <= lock + 4'd1; end
                else if (lock != 4'd0) lock <= lock - 4'd1;
                seen <= 1'b0;
                minprev <= linemin; linemin <= 9'h1ff;
                locked <= lock >= 4'd8;
                if (vguard != 10'd0) vguard <= vguard - 10'd1;
                if (bpl != 10'h3ff) bpl <= bpl + 10'd1;
                if (vline >= VMAX + 10'd4) begin vline <= 10'd0; field_tog <= ~field_tog; aidx <= 10'd0; m6 <= 3'd0; orow_n <= 8'd0; end
                else vline <= vline + 10'd1;
                // the line that starts now: active?
                if (vline + 10'd1 >= VSTART && vline + 10'd1 < VSTART + VROWS) begin
                    act <= 1'b1; dda <= 12'd0; px <= 10'd0;
                    show_cur <= !(pal && m6 == 3'd5);
                    orow_cur <= orow_n;
                    if (!(pal && m6 == 3'd5)) orow_n <= orow_n + 8'd1;
                    m6 <= m6 == 3'd5 ? 3'd0 : m6 + 3'd1;
                    aidx <= aidx + 10'd1;
                end else act <= 1'b0;
            end
            // ---- active pixels ----
            if (act && hc >= HSTART && px < 10'd800) begin
                if (dda + 12'd800 >= ACT) begin
                    dda <= dda + 12'd800 - ACT;
                    p_tick <= 1'b1; p_show <= show_cur; p_row0 <= orow_cur[0]; p_px <= px;
                    p_y <= cy8u; p_u <= cug; p_v <= cvg;
                    px <= px + 10'd1;
                end else dda <= dda + 12'd800;
            end
            // ---- gain once per field: k8 = 26112 / max(porch - tip, 8), restoring division ----
            if (vline == 10'd5 && hc == 12'd0) begin
                dv_den <= (porch > tip + 9'd8) ? porch - tip : 9'd8;
                dv_q <= 16'd0; dv_rem <= 10'd0; dv_n <= 5'd16; dv_run <= 1'b1;
            end else if (dv_run) begin
                if ({dv_rem[8:0], dv_bit} >= {1'b0, dv_den}) begin
                    dv_rem <= {dv_rem[8:0], dv_bit} - {1'b0, dv_den};
                    dv_q <= {dv_q[14:0], 1'b1};
                end else begin
                    dv_rem <= {dv_rem[8:0], dv_bit};
                    dv_q <= {dv_q[14:0], 1'b0};
                end
                dv_n <= dv_n - 5'd1;
                if (dv_n == 5'd1) dv_run <= 1'b0;
            end else k8 <= dv_q;
            // ---- sync quality: in-window edges per 100 ms ----
            if (qtim == 23'd3999999) begin qtim <= 23'd0; sync_q <= qcnt; qcnt <= 16'd0; end
            else qtim <= qtim + 23'd1;
        end
    end
    // pixel stage, one clock after the tick: PAL average, matrix, line buffer
    wire [7:0] r8 = cl8(rr), g8 = cl8(gg), b8 = cl8(bb), y8 = cl8({{2{yg[10]}}, yg});
    always @(posedge clk) begin
        uvq <= uvp[px];                // at the tick px is the tick's pixel: uvq holds its line-above U, V next clock
        wr_en <= p_tick && p_show;
        if (p_tick) begin
            uvp[p_px] <= {p_u, p_v};
            wr_addr <= {p_row0, p_px};
            wr_data <= {r8[7:3], g8[7:2], b8[7:3]};
            wr_gray <= y8;
        end
    end
`ifdef TRI_HQDVR
    // ---- HQ DVR stream: a second DDA, 720 pixels over the active line; JPEG
    // Y = the display's luma, Cb = 128 + 1.146 U, Cr = 128 + 0.813 V (gray
    // units; dvr_hq.v's 4:2:0 averages each line pair, which also cancels
    // PAL's phase errors like the display's line-above average) ----
    reg  [11:0] d_dda; reg [9:0] d_px; reg d_act; reg [8:0] d_ln; reg [2:0] d_ft;
    reg         q_tick; reg [9:0] q_x; reg [8:0] q_ln; reg [9:0] q_y; reg signed [9:0] q_u, q_v;
    wire signed [10:0] qyd = $signed({1'b0, q_y}) - $signed({2'b0, porch});
    wire [35:0] qgm;
    mul18 u_qgm (.a({{7{qyd[10]}}, qyd}), .b({2'b0, k8}), .y(qgm));
    wire signed [19:0] qgy = $signed(qgm[27:0]) >>> 8;
    wire signed [10:0] q_uo = {q_u[9], q_u}, q_vo = {q_v[9], q_v};
    wire signed [12:0] q_cb = 13'sd128 + q_uo + (q_uo >>> 3) + (q_uo >>> 6) + (q_uo >>> 8);
    wire signed [12:0] q_cr = 13'sd128 + (q_vo >>> 1) + (q_vo >>> 2) + (q_vo >>> 4);
    function [7:0] clq; input signed [19:0] v; clq = v < 0 ? 8'd0 : v > 20'sd255 ? 8'd255 : v[7:0]; endfunction
    always @(posedge clk) begin
        d_ft <= {d_ft[1:0], field_tog};
        d_fstart <= d_ft[2] ^ d_ft[1];
        if (low && low_len == 12'd700 && vguard == 10'd0) d_parity <= hc >= (HT >> 1);
        // line: the main block set act and aidx at hc = 0
        if (hc == 12'd1) begin d_act <= act; d_ln <= aidx[8:0] - 9'd1; d_dda <= 12'd0; d_px <= 10'd0; end
        q_tick <= 1'b0;
        if (d_act && hc >= HSTART && d_px < 10'd720) begin
            if (d_dda + 12'd720 >= ACT) begin
                d_dda <= d_dda + 12'd720 - ACT;
                q_tick <= 1'b1; q_x <= d_px; q_ln <= d_ln; q_y <= cy8u; q_u <= cug; q_v <= cvg;
                d_px <= d_px + 10'd1;
            end else d_dda <= d_dda + 12'd720;
        end
        d_valid <= q_tick;
        if (q_tick) begin
            d_x <= q_x; d_line <= q_ln;
            d_y <= clq(qgy); d_cb <= clq({{7{q_cb[12]}}, q_cb}); d_cr <= clq({{7{q_cr[12]}}, q_cr});
        end
    end
`else
    always @(*) begin d_valid = 1'b0; d_x = 10'd0; d_line = 9'd0; d_y = 8'd0; d_cb = 8'd0; d_cr = 8'd0; d_fstart = 1'b0; d_parity = 1'b0; end
`endif
    // ---- aspect signalling ----------------------------------------------------------
    wire [8:0]  athr = porch + (porch - tip);            // ~ +40 IRE
    wire        ahi  = y > athr;
    reg  [76:0] wsr;                                     // WSS elements, 200 ns each
    reg  [6:0]  we_n;                                    // next WSS element
    reg  [21:0] cgs;                                     // CGMS: start 1, start 0, 14 data bits, 6 CRC bits
    reg  [4:0]  cg_n; reg [11:0] cg_at; reg [3:0] cg_fr; // next bit, its sample clock, x 0.1 clock
    function [5:0] crc6; input [13:0] d; integer k; reg [5:0] c; reg fb;
        begin c = 6'h3f; for (k = 0; k < 14; k = k + 1) begin fb = d[13 - k] ^ c[5]; c = {c[4:0], 1'b0} ^ (fb ? 6'b000011 : 6'b0); end crc6 = c; end
    endfunction
    reg         cg_pre;                                  // blank before the code
    reg         f_code, f_wide;                          // a code this field, and what it said
    reg  [1:0]  wcnt;
    reg  [5:0]  nocode;
    reg         ftp;
    wire [11:0] we_at = 12'd444 + {we_n, 3'd0};          // centre of WSS element we_n
    wire        cg_line = !pal && field_lines >= 10'd255 && field_lines <= 10'd270 && vline >= 10'd10 && vline <= 10'd18;
    wire        ws_line = pal && vline >= 10'd18 && vline <= 10'd26;
    // biphase group 1: bit k = elements 53 + 6k .. +5, 1 = 111000, 0 = 000111
    function bp; input [76:0] r; input [1:0] k; reg [6:0] b;
        begin b = 7'd53 + {k, 2'b0} + {k, 1'b0}; bp = r[b + 7'd1] & ~r[b + 7'd4]; end
    endfunction
    function bpok; input [76:0] r; input [1:0] k; reg [6:0] b;
        begin b = 7'd53 + {k, 2'b0} + {k, 1'b0}; bpok = r[b + 7'd1] ^ r[b + 7'd4]; end
    endfunction
    wire [3:0] g1 = {bp(wsr, 2'd0), bp(wsr, 2'd1), bp(wsr, 2'd2), bp(wsr, 2'd3)};       // b0..b3
    wire       ws_ok = wsr[8:0] == 9'b100011111                    // run-in 1 1111 0001 (element 0 = bit 0)
                       && wsr[52:29] == 24'b111110000011110001111000   // start code 0001 1110 0011 1100 0001 1111
                       && bpok(wsr, 2'd0) && bpok(wsr, 2'd1) && bpok(wsr, 2'd2) && bpok(wsr, 2'd3)
                       && ^g1;                                          // odd parity
    always @(posedge clk) begin
        if (rst) begin wide <= 1'b0; wcnt <= 2'd0; nocode <= 6'd0; f_code <= 1'b0; ftp <= 1'b0; we_n <= 7'd0; end
        else begin
            ftp <= field_tog;
            if (ftp != field_tog) begin                    // a field ended: what did it say?
                f_code <= 1'b0;
                if (f_code) begin
                    nocode <= 6'd0;
                    if (f_wide) begin if (wcnt != 2'd3) wcnt <= wcnt + 2'd1; end
                    else if (wcnt != 2'd0) wcnt <= wcnt - 2'd1;
                end else if (nocode == 6'd63) wcnt <= 2'd0;
                else nocode <= nocode + 6'd1;
            end
            wide <= wcnt >= 2'd2;
            // CGMS-A: 22 bits of 2.235 us (89.4 clocks) from 11.2 us after the sync edge
            if (hc == 12'd0) begin cg_pre <= 1'b1; we_n <= 7'd0; cg_n <= 5'd0; cg_at <= 12'd493; cg_fr <= 4'd0; end
            if (cg_line) begin
                if (hc == 12'd420 && ahi) cg_pre <= 1'b0;
                if (cg_n != 5'd22 && hc == cg_at) begin
                    cgs[cg_n] <= ahi; cg_n <= cg_n + 5'd1;
                    cg_at <= cg_at + (cg_fr >= 4'd6 ? 12'd90 : 12'd89);
                    cg_fr <= cg_fr >= 4'd6 ? cg_fr - 4'd6 : cg_fr + 4'd4;
                end
                if (hc == 12'd2500 && cg_pre && cgs[0] && !cgs[1] &&
                    crc6({cgs[2], cgs[3], cgs[4], cgs[5], cgs[6], cgs[7], cgs[8], cgs[9], cgs[10], cgs[11], cgs[12], cgs[13], cgs[14], cgs[15]})
                        == {cgs[16], cgs[17], cgs[18], cgs[19], cgs[20], cgs[21]})
                    begin f_code <= 1'b1; f_wide <= cgs[2]; end
            end
            // WSS: 77 elements from 11.0 us
            if (ws_line && we_n != 7'd77 && hc == we_at) begin wsr[we_n] <= ahi; we_n <= we_n + 7'd1; end
            if (ws_line && we_n == 7'd77 && hc == 12'd1100) begin
                we_n <= 7'd78;
                if (ws_ok) begin f_code <= 1'b1; f_wide <= g1 == 4'b1110; end
            end
        end
    end
endmodule
`default_nettype wire
