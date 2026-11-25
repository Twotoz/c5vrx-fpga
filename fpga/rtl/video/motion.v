// Triversity: whole-picture motion per field for the 90 Hz output's Smooth
// mode (TRI_HDMI90, fbuf.v). Measured on the pixels as they are written, luma
// taken as green (6 bits):
//  - horizontal, in four bands of rows: per band a column profile (sums of
//    2-pixel bins, 360 bins) of this field against the previous one;
//  - vertical, over the whole width: a row profile against the field two back
//    (the same parity: interlaced fields sit half a line apart).
// After the last line of a field the search compares the profiles' slopes
// (p[i] - p[i-1]: brightness changes do not move them) at shifts -12..12 by
// the sum of absolute differences and takes the best shift if it stands out
// (best <= 3/4 of the average over all shifts), 0 otherwise. Results:
// vh[b] in bins (2 px) a field, + = the picture moves right; vv in half source
// lines a field (rows over two fields), + = down. The search takes ~36k clocks
// (< 1 ms) and fits between the last line of a field and the first of the next.
`default_nettype none
module motion (
    input  wire        clk,
    input  wire        rst,
    input  wire        pal,
    input  wire        px_we,          // a pixel of a shown line
    input  wire [9:0]  px_x,
    input  wire [5:0]  px_g,
    input  wire [8:0]  row,            // the line being written (lines done this field)
    input  wire        row_done,       // the line `row` is complete (one clock)
    input  wire        field_ev,       // a field starts
    output reg  signed [5:0] vh0, vh1, vh2, vh3,
    output reg  signed [5:0] vv,
    output reg         valid
);
    wire [8:0] nrow = pal ? 9'd288 : 9'd240;
    wire [8:0] bh   = pal ? 9'd72 : 9'd60;            // rows a band
    // band of the row being written, and whether it is the band's first row
    wire [1:0] band = row >= 3 * bh ? 2'd3 : row >= 2 * bh ? 2'd2 : row >= bh ? 2'd1 : 2'd0;
    wire       bfirst = row == 9'd0 || row == bh || row == 2 * bh || row == 3 * bh;
    // ---- profiles ----
    reg [15:0] colA [0:2047], colB [0:2047];           // {band, bin}
    reg [15:0] rowA [0:511], rowB [0:511], rowC [0:511];
    reg        csel;                                   // column profile of this field: 0 colA, 1 colB
    reg [1:0]  rsel;                                   // row profile of this field: 0 rowA, 1 rowB, 2 rowC
    reg [10:0] ca_r, cb_r; reg [15:0] ca_q, cb_q;      // read ports
    reg [8:0]  ra_r, rb_r, rc_r; reg [15:0] ra_q, rb_q, rc_q;
    reg        cw_a, cw_b; reg [10:0] cw_addr; reg [15:0] cw_d;
    reg        rw; reg [8:0] rw_addr; reg [15:0] rw_d;
    always @(posedge clk) begin
        if (cw_a) colA[cw_addr] <= cw_d;
        if (cw_b) colB[cw_addr] <= cw_d;
        ca_q <= colA[ca_r]; cb_q <= colB[cb_r];
        if (rw && rsel == 2'd0) rowA[rw_addr] <= rw_d;
        if (rw && rsel == 2'd1) rowB[rw_addr] <= rw_d;
        if (rw && rsel == 2'd2) rowC[rw_addr] <= rw_d;
        ra_q <= rowA[ra_r]; rb_q <= rowB[rb_r]; rc_q <= rowC[rc_r];
    end
    // ---- accumulation: a bin's two pixels, then read-modify-write ----
    reg  [5:0]  pg;
    reg  [2:0]  ag;                                    // stages: address, data, write
    reg  [10:0] aa0, aa1, aa2; reg [6:0] av0, av1, av2; reg ac0, ac1, ac2;
    reg  [15:0] rsum;
    // ---- search ----
    localparam S_IDLE = 2'd0, S_RUN = 2'd1, S_END = 2'd2;
    reg  [1:0]  st;
    reg         vert;                                  // the vertical search (after the four bands)
    reg  [1:0]  b;
    reg  signed [4:0] s;                               // -12..12
    reg  [8:0]  i;                                     // index addressed next
    reg  [2:0]  pv, pf;                                // pipeline valid / first-index flags
    reg  [2:0]  flush;
    reg  [15:0] c1, p1;                                // the previous samples (slopes)
    reg  signed [17:0] dc, dp;
    reg  [27:0] sad, best; reg [31:0] tot;
    reg  signed [4:0] bs;
    wire [8:0]  i0 = 9'd12;
    wire [8:0]  i1 = vert ? nrow - 9'd13 : 9'd347;
    wire [8:0]  ip = i - {{4{s[4]}}, s};               // the same place in the reference profile
    wire [1:0]  rref = rsel == 2'd2 ? 2'd0 : rsel + 2'd1;   // the field two back
    wire [15:0] qc = vert ? (rsel == 2'd0 ? ra_q : rsel == 2'd1 ? rb_q : rc_q) : (csel ? cb_q : ca_q);
    wire [15:0] qp = vert ? (rref == 2'd0 ? ra_q : rref == 2'd1 ? rb_q : rc_q) : (csel ? ca_q : cb_q);
    wire signed [18:0] dd = dc - dp;
    wire [18:0] adiff = dd[18] ? -dd : dd;
    wire        issue = st == S_RUN && flush == 3'd0;
    // best * 100 <= tot * 3: the best shift stands out of the average
    wire        sure = tot != 32'd0 && ({4'd0, best, 6'd0} + {5'd0, best, 5'd0} + {8'd0, best, 2'd0}) <= ({5'd0, tot, 1'b0} + {6'd0, tot});
    wire signed [5:0] res = sure ? {bs[4], bs} : 6'sd0;
    reg         fdone;
    always @(posedge clk) begin
        cw_a <= 1'b0; cw_b <= 1'b0; rw <= 1'b0;
        if (rst) begin
            csel <= 1'b0; rsel <= 2'd0; st <= S_IDLE; valid <= 1'b0; fdone <= 1'b0; rsum <= 16'd0; ag <= 3'd0;
            vh0 <= 6'sd0; vh1 <= 6'sd0; vh2 <= 6'sd0; vh3 <= 6'sd0; vv <= 6'sd0; pv <= 3'd0; pf <= 3'd0;
        end else begin
            // ---- accumulate (only while no search runs: it reads the same profiles) ----
            ag <= {ag[1:0], 1'b0};
            if (px_we) begin
                rsum <= rsum + {10'd0, px_g};
                if (!px_x[0]) pg <= px_g;
                else if (st == S_IDLE) begin
                    ag[0] <= 1'b1; aa0 <= {band, px_x[9:1]}; av0 <= {1'b0, pg} + {1'b0, px_g}; ac0 <= bfirst;
                end
            end
            if (ag[0]) begin if (csel) cb_r <= aa0; else ca_r <= aa0; aa1 <= aa0; av1 <= av0; ac1 <= ac0; end
            if (ag[1]) begin aa2 <= aa1; av2 <= av1; ac2 <= ac1; end   // the read data arrives
            if (ag[2]) begin
                cw_addr <= aa2; cw_d <= (ac2 ? 16'd0 : (csel ? cb_q : ca_q)) + {9'd0, av2};
                cw_a <= !csel; cw_b <= csel;
            end
            if (row_done) begin
                rw <= 1'b1; rw_addr <= row; rw_d <= rsum; rsum <= 16'd0;
                if (row == nrow - 9'd1 && st == S_IDLE) begin
                    st <= S_RUN; vert <= 1'b0; b <= 2'd0; s <= -5'sd12; i <= i0; flush <= 3'd0;
                    sad <= 28'd0; best <= {28{1'b1}}; tot <= 32'd0; fdone <= 1'b1;
                end
            end
            if (field_ev) begin
                if (!fdone) valid <= 1'b0;           // a field without all its lines: no estimate
                fdone <= 1'b0; rsum <= 16'd0;
            end
            // ---- search: per shift, the indices i0..i1 through a three-stage pipeline ----
            pv <= {pv[1:0], issue}; pf <= {pf[1:0], issue && i == i0};
            if (issue) begin
                if (vert) begin
                    case (rsel) 2'd0: ra_r <= i; 2'd1: rb_r <= i; default: rc_r <= i; endcase
                    case (rref) 2'd0: ra_r <= ip; 2'd1: rb_r <= ip; default: rc_r <= ip; endcase
                end else if (csel) begin cb_r <= {b, i}; ca_r <= {b, ip}; end
                else begin ca_r <= {b, i}; cb_r <= {b, ip}; end
                if (i == i1) flush <= 3'd1; else i <= i + 9'd1;
            end else if (st == S_RUN && flush != 3'd4) flush <= flush + 3'd1;
            if (pv[1]) begin                         // qc / qp hold the data of the index issued two clocks ago
                c1 <= qc; p1 <= qp;
                dc <= $signed({2'b0, qc}) - $signed({2'b0, c1});
                dp <= $signed({2'b0, qp}) - $signed({2'b0, p1});
            end
            if (pv[2] && !pf[2]) sad <= sad + {9'd0, adiff};
            if (st == S_RUN && flush == 3'd4) begin  // the shift's last slope is in
                tot <= tot + {4'd0, sad};
                if (sad < best) begin best <= sad; bs <= s; end
                sad <= 28'd0; flush <= 3'd0; i <= i0;
                if (s == 5'sd12) st <= S_END; else s <= s + 5'sd1;
            end
            if (st == S_END) begin                   // one band (or the vertical) done
                if (vert) begin vv <= res; st <= S_IDLE; valid <= 1'b1; csel <= ~csel; rsel <= rsel == 2'd2 ? 2'd0 : rsel + 2'd1; end
                else begin
                    case (b) 2'd0: vh0 <= res; 2'd1: vh1 <= res; 2'd2: vh2 <= res; default: vh3 <= res; endcase
                    if (b == 2'd3) vert <= 1'b1; else b <= b + 2'd1;
                    st <= S_RUN;
                end
                s <= -5'sd12; i <= i0; sad <= 28'd0; best <= {28{1'b1}}; tot <= 32'd0; flush <= 3'd0;
            end
        end
    end
endmodule
`default_nettype wire
