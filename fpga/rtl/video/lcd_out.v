// Triversity: 800x480 RGB LCD output, genlocked to the video (LCD domain).
// Every video line is shown twice: a line toggle from vid_sync starts an LCD
// line pair (the second at half a video line). Without video the LCD free-runs
// its line and frame timing (black picture, the OSD stays). DE-mode timing with
// HS/VS as well; 33.75 MHz pixel clock: half an NTSC line is 1072.5 clocks,
// half a PAL line 1080 (the Sipeed 800x480 example runs 1066 x 520).
// OSD: 66 x 20 cells of 12 x 24 pixels from 4 px in (fpga/gen/gen_osd.py);
// each cell {bg, fg, glyph} from the cell RAM, glyphs with 2-bit coverage:
//   pixel = (bg * (3 - a) + fg * a) / 3     (a = coverage 0..3, x 171 >> 9)
// bg: video (RGB565 widened to 8 bits a channel), panel (video / 4 + a
// blue-grey), accent, dark; fg: the palette or
// the panel. gen_osd.render() is the reference, pixel for pixel.
// Aspect: hmode picks the column map (hmap.vh, gen_osd.hmaps()): full width,
// 4:3 in the middle 640 columns (black bars), or Stretch.
`default_nettype none
module lcd_out (
    input  wire        clk,
    input  wire        rst,
    input  wire        line_tog_a,     // from vid_sync (other clock domain)
    input  wire [8:0]  line_info_a,    // {show, orow}
    input  wire        field_tog_a,
    input  wire        locked_a,
    input  wire        pal_a,
    input  wire [1:0]  hmode,          // 0 full width, 1 4:3, 2 Stretch (menu, this domain)
    output reg  [10:0] lb_addr,        // line buffer read
    input  wire [15:0] lb_data,        // RGB565
    output reg  [10:0] osd_addr,       // cell RAM read
    input  wire [11:0] osd_cell,
    output wire        lcd_de,
    output wire        lcd_hs,
    output wire        lcd_vs,
    output reg  [4:0]  lcd_r,
    output reg  [5:0]  lcd_g,
    output reg  [4:0]  lcd_b
);
    localparam HBP = 11'd56, HACT = 11'd800, HFREE = 11'd1200;
    localparam X0 = 11'd4, GRIDW = 11'd792;
    // ---- clock-domain crossing ------------------------------------------------
    reg [2:0] lt, ft; reg [1:0] lk, pl;
    always @(posedge clk) begin
        lt <= {lt[1:0], line_tog_a}; ft <= {ft[1:0], field_tog_a};
        lk <= {lk[0], locked_a}; pl <= {pl[0], pal_a};
    end
    wire line_ev = lt[2] ^ lt[1], field_ev = ft[2] ^ ft[1];
    wire locked = lk[1], pal = pl[1];
    // ---- timing -------------------------------------------------------------------
    wire [10:0] HHALF = pal ? 11'd1080 : 11'd1072;
    reg  [10:0] hc;
    reg         half;
    reg  [8:0]  info;             // {show, orow} of the pair being shown
    reg  [9:0]  lv;               // free-running LCD line in the frame
    reg         vs_r;
    always @(posedge clk) begin
        if (rst) begin hc <= 11'd0; half <= 1'b0; info <= 9'd0; lv <= 10'd0; vs_r <= 1'b0; end
        else begin
            vs_r <= 1'b0;
            if (line_ev && locked) begin
                hc <= 11'd0; half <= 1'b0; info <= line_info_a;   // stable since the toggle
                lv <= lv + 10'd1;
            end else if (!half && hc == HHALF - 11'd1) begin
                hc <= 11'd0; half <= 1'b1; lv <= lv + 10'd1;
            end else if (half && hc == HFREE - 11'd1) begin   // no line toggle: free-run
                hc <= 11'd0; half <= 1'b0; info <= 9'd0; lv <= lv + 10'd1;
            end else hc <= hc + 11'd1;
            if ((field_ev && locked) || (!locked && lv >= 10'd525)) begin lv <= 10'd0; vs_r <= 1'b1; end
        end
    end
    wire        free_row = !locked && lv >= 10'd23 && lv < 10'd503;
    wire [8:0]  row = locked ? {info[7:0], half} : lv[8:0] - 9'd23;
    wire        row_on = locked ? info[8] : free_row;
    wire        de0 = row_on && hc >= HBP && hc < HBP + HACT;
    wire [9:0]  x = hc[9:0] - HBP[9:0];
    // ---- cell row of this line: row / 24, row % 24, row / 24 * 66, by subtraction
    //      during the first clocks of the line (row is stable from hc = 0) ----
    reg [8:0]  rrem; reg [10:0] rbase; reg [4:0] ry;
    always @(posedge clk) begin
        if (hc == 11'd0) begin rrem <= row; rbase <= 11'd0; end
        else if (rrem >= 9'd24) begin rrem <= rrem - 9'd24; rbase <= rbase + 11'd66; end
        ry <= rrem[4:0];
    end
    // ---- cell column: counters along the line ----
    reg [3:0] sx; reg [6:0] cx; reg ing;
    always @(posedge clk) begin
        if (hc == HBP + X0 - 11'd1) begin sx <= 4'd0; cx <= 7'd0; ing <= 1'b1; end
        else if (ing) begin
            if (sx == 4'd11) begin sx <= 4'd0; cx <= cx + 7'd1; if (cx == 7'd65) ing <= 1'b0; end
            else sx <= sx + 4'd1;
        end
    end
    // ing/cx/sx describe hc (they were set one clock before hc reached the
    // grid: at hc = HBP + X0 the counters read cell 0, pixel 0)
    // ---- pipeline: addresses end of n, RAM data in n+2, glyph row in n+3,
    //      blend sums end of n+3, pixel registers end of n+4 (shown in n+5) ----
    reg [23:0] font [0:4095];
`include "osd_font.vh"
    reg [4:0]  de_d, hs_d, vs_d;
    reg [3:0]  sx1, sx2, sx3;
    reg        g1, g2, g3;
    reg [4:0]  ry1, ry2;
    reg [15:0] v3;
    reg [11:0] cell3;
    reg [23:0] glyph;
    reg [9:0]  sr, sg, sb;
    // column map, read one pixel ahead: hq is the map of x
    wire [9:0] xn = x + 10'd1;
`ifdef TRI_HQDVR
    // HQ DVR build: full width or 4:3 only, computed (the map's BSRAM goes to the DVR)
    wire [9:0]  xb = xn - 10'd80;
    wire [11:0] xb5 = {xb, 2'b0} + {2'b0, xb};
    wire [10:0] hcalc = hmode == 2'd1 ? ((xn >= 10'd80 && xn < 10'd720) ? {1'b1, xb5[11:2]} : 11'd0) : {1'b1, xn};
`else
    reg [10:0] hmap [0:4095];
`include "hmap.vh"
    wire [10:0] hcalc = hmap[{hmode, xn}];
`endif
    reg [10:0] hq;
    reg        hv1, hv2;
    // palette
    function [23:0] pal8; input [2:0] i;
        case (i)
            3'd0: pal8 = {8'd240, 8'd242, 8'd245}; 3'd1: pal8 = {8'd142, 8'd149, 8'd160};
            3'd2: pal8 = {8'd0, 8'd88, 8'd242};    3'd3: pal8 = {8'd255, 8'd69, 8'd58};
            3'd4: pal8 = {8'd48, 8'd209, 8'd88};   3'd5: pal8 = {8'd255, 8'd176, 8'd32};
            default: pal8 = {8'd16, 8'd18, 8'd22};
        endcase
    endfunction
    function [9:0] mul171s9; input [9:0] s; reg [17:0] p; begin
        p = {s, 7'd0} + {2'd0, s, 5'd0} + {4'd0, s, 3'd0} + {6'd0, s, 1'b0} + {8'd0, s};   // s * 171
        mul171s9 = {1'b0, p[17:9]};
    end endfunction
    wire [35:0] m_r, m_g, m_b;
    mul18 #(.A_SIGNED(0), .B_SIGNED(0)) u_mr (.a({8'd0, sr}), .b(18'd171), .y(m_r));
    mul18 #(.A_SIGNED(0), .B_SIGNED(0)) u_mg (.a({8'd0, sg}), .b(18'd171), .y(m_g));
    mul18 #(.A_SIGNED(0), .B_SIGNED(0)) u_mb (.a({8'd0, sb}), .b(18'd171), .y(m_b));
    always @(posedge clk) begin
        hq <= hcalc;
        lb_addr  <= {row[1], hq[9:0]};           // vid_sync writes half orow[0]; row = {orow, half}
        hv1 <= hq[10]; hv2 <= hv1;
        osd_addr <= rbase + {4'd0, cx};
        de_d <= {de_d[3:0], de0};
        hs_d <= {hs_d[3:0], hc < 11'd10};
        vs_d <= {vs_d[3:0], vs_r};
        sx1 <= sx; sx2 <= sx1; sx3 <= sx2;
        g1 <= ing; g2 <= g1; g3 <= g2;
        ry1 <= ry; ry2 <= ry1;
        // n+2: cell and video
        cell3 <= osd_cell; v3 <= (locked && hv2) ? lb_data : 16'd0;
        glyph <= font[{osd_cell[6:0], ry2}];
        // n+3: blend sums
        begin : blend
            reg [1:0] a; reg [7:0] vr, vg, vb; reg [23:0] bgc, fgc, pnl;
            vr = {v3[15:11], v3[15:13]}; vg = {v3[10:5], v3[10:9]}; vb = {v3[4:0], v3[4:2]};
            a = g3 ? glyph[{sx3, 1'b0} +: 2] : 2'd0;
            pnl = {{2'b0, vr[7:2]} + 8'd14, {2'b0, vg[7:2]} + 8'd16, {2'b0, vb[7:2]} + 8'd22};
            case (g3 ? cell3[11:10] : 2'd0)
                2'd0: bgc = {vr, vg, vb};
                2'd1: bgc = pnl;
                2'd2: bgc = pal8(3'd2);
                default: bgc = pal8(3'd6);
            endcase
            fgc = cell3[9:7] == 3'd7 ? pnl : pal8(cell3[9:7]);
            sr <= bgc[23:16] * (2'd3 - a) + fgc[23:16] * a;
            sg <= bgc[15:8]  * (2'd3 - a) + fgc[15:8]  * a;
            sb <= bgc[7:0]   * (2'd3 - a) + fgc[7:0]   * a;
        end
        // n+4: / 3 (x 171 >> 9 on DSP blocks), out
        begin : px
            reg [9:0] r8, g8, b8;
            r8 = m_r[18:9]; g8 = m_g[18:9]; b8 = m_b[18:9];
            if (!de_d[3]) begin lcd_r <= 5'd0; lcd_g <= 6'd0; lcd_b <= 5'd0; end
            else begin lcd_r <= r8[7:3]; lcd_g <= g8[7:2]; lcd_b <= b8[7:3]; end
        end
    end
    assign lcd_de = de_d[4];
    assign lcd_hs = ~hs_d[4];
    assign lcd_vs = ~vs_d[4];
endmodule
`default_nettype wire
