// Triversity: 800x480 RGB LCD output, genlocked to the video (LCD domain).
// Every video line is shown twice: a line toggle from vid_sync starts an LCD
// line pair (the second at half a video line). Without video the LCD free-runs
// its line and frame timing (dark picture, the OSD stays). DE-mode timing with
// HS/VS as well; 33.75 MHz pixel clock: half an NTSC line is 1072.5 clocks,
// half a PAL line 1080 (the Sipeed 800x480 example runs 1066 x 520).
// OSD: 50 x 30 characters of 16 x 16 pixels (an 8 x 16 font, doubled in x)
// from osd char RAM; code 0 = transparent, else a dimmed box with a white
// glyph (bit 7: yellow, the selection).
`default_nettype none
module lcd_out (
    input  wire        clk,
    input  wire        rst,
    input  wire        line_tog_a,     // from vid_sync (other clock domain)
    input  wire [8:0]  line_info_a,    // {show, orow}
    input  wire        field_tog_a,
    input  wire        locked_a,
    input  wire        pal_a,
    output reg  [10:0] lb_addr,        // line buffer read
    input  wire [7:0]  lb_data,
    output reg  [10:0] osd_addr,       // char RAM read
    input  wire [7:0]  osd_char,
    output wire        lcd_de,
    output wire        lcd_hs,
    output wire        lcd_vs,
    output reg  [4:0]  lcd_r,
    output reg  [5:0]  lcd_g,
    output reg  [4:0]  lcd_b
);
    localparam HBP = 11'd56, HACT = 11'd800, HFREE = 11'd1200;
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
    // displayed row and column
    wire        free_row = !locked && lv >= 10'd23 && lv < 10'd503;
    wire [8:0]  row = locked ? {info[7:0], half} : lv[8:0] - 9'd23;
    wire        row_on = locked ? info[8] : free_row;
    wire        de0 = row_on && hc >= HBP && hc < HBP + HACT;
    wire [9:0]  x = hc[9:0] - HBP[9:0];
    // ---- pipeline (hc of cycle n): RAM addresses at the end of n, RAM data in
    // n+2, glyph row in n+4, pixel registers out in n+5 ----
    reg [7:0] font [0:2047];
`include "font_init.vh"
    reg [4:0] de_d, hs_d, vs_d;
    reg [2:0] x1, x2, x3, x4;
    reg [3:0] y1, y2, y3;
    reg [7:0] ch3, ch4, gray3, gray4, glyph;
    always @(posedge clk) begin
        lb_addr  <= {row[1], x};          // vid_sync writes half orow[0]; row = {orow, half}
        osd_addr <= {2'b0, row[8:4]} * 11'd50 + {5'd0, x[9:4]};
        de_d <= {de_d[3:0], de0};
        hs_d <= {hs_d[3:0], hc < 11'd10};
        vs_d <= {vs_d[3:0], vs_r};
        x1 <= x[3:1]; x2 <= x1; x3 <= x2; x4 <= x3;
        y1 <= row[3:0]; y2 <= y1; y3 <= y2;
        ch3 <= osd_char; gray3 <= locked ? lb_data : 8'd0;           // end of n+2
        glyph <= font[{ch3[6:0], y3}]; ch4 <= ch3; gray4 <= gray3;  // end of n+3
        begin : px                                                   // end of n+4
            reg on; reg [7:0] g;
            on = glyph[3'd7 - x4];
            g = (ch4 == 8'd0) ? gray4 : (on ? 8'd255 : {2'b0, gray4[7:2]});
            if (!de_d[3]) begin lcd_r <= 5'd0; lcd_g <= 6'd0; lcd_b <= 5'd0; end
            else if (ch4 != 8'd0 && on && ch4[7]) begin lcd_r <= 5'd31; lcd_g <= 6'd63; lcd_b <= 5'd0; end
            else begin lcd_r <= g[7:3]; lcd_g <= g[7:2]; lcd_b <= g[7:3]; end
        end
    end
    assign lcd_de = de_d[4];
    assign lcd_hs = ~hs_d[4];
    assign lcd_vs = ~vs_d[4];
endmodule
`default_nettype wire
