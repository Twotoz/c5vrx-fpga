// Triversity: video timing and line capture from the demodulated codes
// (40 MHz domain of C5 A). Monochrome first version.
//  - luma: moving sum of 8 codes (200 ns; also takes most of the chroma)
//  - sync slicer halfway between the measured sync tip and back porch
//  - H flywheel: a line counter that a qualified sync edge (low >= 2 us)
//    pulls in a +-1 us window, snaps to after losing lock, and free-runs
//    without one; V: a broad pulse (low >= 17.5 us) starts a field, line
//    count flywheel otherwise; PAL when a field holds more than 290 lines
//  - auto levels: gray = (y - porch) * 102 / (porch - tip), white at
//    +100 IRE for a sync of -40 IRE, whatever the VTX deviation
//  - each active line (NTSC 240, PAL 288 with one in six dropped: 240) as
//    800 gray pixels into line buffer half orow[0]; at the next line start
//    the LCD domain gets a toggle with the line's row (lcd_out.v shows it twice)
`default_nettype none
module vid_sync (
    input  wire        clk,
    input  wire        rst,
    input  wire [5:0]  code,          // 40 MS/s (20 MS/s unique) demodulator codes
    output reg         wr_en,
    output reg  [10:0] wr_addr,       // {orow[0], px[9:0]}
    output reg  [7:0]  wr_data,
    output reg         line_tog,      // toggles at each line start
    output reg  [8:0]  line_info,     // {show, orow[7:0]} of the line just written; stable after line_tog
    output reg         field_tog,
    output reg         pal,
    output reg         locked,
    output reg  [15:0] sync_q         // in-window sync edges in the last 100 ms
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
    reg [9:0]  vline, vguard, field_lines;
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
    wire signed [9:0] yd = $signed({1'b0, y}) - $signed({1'b0, porch});
    wire signed [26:0] gm = yd * $signed({1'b0, k8});
    wire [7:0] g8 = gm[26] ? 8'd0 : (|gm[25:16]) ? 8'd255 : gm[15:8];

    always @(posedge clk) begin
        wr_en <= 1'b0;
        if (rst) begin
            hc <= 12'd0; lock <= 4'd0; low <= 1'b0; low_len <= 12'd0; qual_pend <= 1'b0;
            tip <= 9'd120; porch <= 9'd168; tip_f <= 13'd1920; porch_f <= 13'd2688; lev_n <= 5'd0; seen <= 1'b0;
            linemin <= 9'h1ff; minprev <= 9'd100;
            vline <= 10'd0; vguard <= 10'd0; field_lines <= 10'd0; pal <= 1'b0; locked <= 1'b0;
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
                pal <= vline > 10'd290;
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
                    wr_en <= show_cur; wr_addr <= {orow_cur[0], px}; wr_data <= g8;
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
endmodule
`default_nettype wire
