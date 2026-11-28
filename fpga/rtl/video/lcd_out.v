// Triversity: 800x480 RGB LCD output, genlocked to the video (LCD domain).
// The LCD keeps an 800x480 active raster through lock changes and adjusts
// its blanking to follow the input when locked. Standard HDMI keeps a
// fixed 480p/576p raster and reads the newest complete source line.
// LCD DE-mode timing with
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
`ifdef TRI_HDMI90
`define TRI_FBUF
`endif
`ifdef TRI_LCDBUF
`define TRI_FBUF
`endif
module lcd_out (
    input  wire        clk,
    input  wire        rst,
    input  wire        line_tog_a,     // from vid_sync (other clock domain)
    input  wire [8:0]  line_info_a,    // {show, orow}
    input  wire        field_tog_a,
    input  wire        locked_a,
    input  wire        pal_a,
    input  wire [1:0]  hmode,          // 0 full width, 1 4:3, 2 Stretch (menu, this domain)
    input  wire        boot,           // menu: the start-up screen (the logo instead of the video)
    output reg  [10:0] lb_addr,        // line buffer read
    input  wire [15:0] lb_data,        // RGB565
    output reg  [10:0] osd_addr,       // cell RAM read
    input  wire [11:0] osd_cell,
    output wire        lcd_de,
    output wire        lcd_hs,
    output wire        lcd_vs,
    output reg  [4:0]  lcd_r,
    output reg  [5:0]  lcd_g,
    output reg  [4:0]  lcd_b,
    output reg  [7:0]  px_r, px_g, px_b   // the same pixel, 8 bits a channel (HDMI)
`ifdef TRI_FBUF
    ,
    input  wire [1:0]  hz90,           // menu: 0 Free (crystal), 1 Camera (locked to the fields), 2 Smooth
    input  wire signed [7:0] sh_h,     // fbuf.v, Smooth: shift at the middle row (pixels), its slope (1/256 px a row),
    input  wire signed [7:0] sh_r,     //   the vertical shift (source lines); set at each frame start (other domain,
    input  wire signed [5:0] sh_v,     //   read two lines later)
    output reg         frame_tog,      // to fbuf.v: a frame starts (latch the newest field)
    output reg         fetch_tog,      // to fbuf.v: fetch source line fetch_line
    output reg  [8:0]  fetch_line
`ifdef TRI_LCDBUF
    , input wire       fetch_done_a
`endif
`endif
);
    // ---- clock-domain crossing ------------------------------------------------
    reg [2:0] lt, ft; reg [1:0] lk, pl;
    always @(posedge clk) begin
        lt <= {lt[1:0], line_tog_a}; ft <= {ft[1:0], field_tog_a};
        lk <= {lk[0], locked_a}; pl <= {pl[0], pal_a};
    end
    wire line_ev = lt[2] ^ lt[1], field_ev = ft[2] ^ ft[1];
    wire locked = lk[1], pal = pl[1];
    // Change geometry only at the end of a complete display frame.
    reg pal_out;
`ifdef TRI_HDMI90
    // 90 Hz HDMI build: free-running from the crystal at 48.6 MHz, the field from
    // the SDRAM field buffer (fbuf.v), each source line twice. NTSC 720x480 in
    // 1030 x 525 (89.88 Hz), PAL 720x576 in 864 x 625 (90.00 Hz); syncs and back
    // porches as 480p / 576p, the wider NTSC line is front porch.
    wire [10:0] HBP = pal_out ? 11'd132 : 11'd122;
    localparam  HACT = 11'd720;
    wire [10:0] HHALF = pal_out ? 11'd864 : 11'd1030, HFREE = HHALF;
    wire [10:0] HSYNC = pal_out ? 11'd64 : 11'd62;
    wire [10:0] GSTART = HBP - 11'd37;
    wire [9:0]  VFRAME = pal_out ? 10'd625 : 10'd525;
    wire [9:0]  VSTART = pal_out ? 10'd44 : 10'd36;       // 6 sync lines, then the back porch
    wire [9:0]  NROW = pal_out ? 10'd576 : 10'd480;
    wire [9:0]  OSDV = pal_out ? 10'd48 : 10'd0;
`elsif TRI_LCDBUF
    // Buffered LCD: the 800x480 panel on fixed timing from the crystal (33.75 MHz,
    // every line HHALF, the frame VFRAME lines give or take the frame lock's trim),
    // each source line from the SDRAM (fbuf.v) shown twice; PAL's 288 lines into
    // 240 rows (every sixth dropped, as the genlocked LCD). The panel never sees
    // a line or frame shaped by the source.
    localparam  HBP = 11'd56, HACT = 11'd800;
    wire [10:0] HHALF = pal_out ? 11'd1080 : 11'd1072, HFREE = HHALF;
    wire [10:0] HSYNC = 11'd10;
    wire [10:0] GSTART = HBP + 11'd3;                  // X0 = 4: column 0 at x = 4
    wire [9:0]  VFRAME = pal_out ? 10'd625 : 10'd525;
    wire [9:0]  VSTART = 10'd23;
    wire [9:0]  NROW = 10'd480;
    wire [9:0]  OSDV = 10'd0;
`elsif TRI_HDMI
    // HDMI build: 720x480p59.94 / 720x576p50 at 27 MHz, half a line 858 / 864
    // clocks (twice the nominal analog line rate); sync 62 / 64,
    // video from 122 / 132; the OSD grid cropped to columns 3..62
    wire [10:0] HBP = pal_out ? 11'd132 : 11'd122;
    localparam  HACT = 11'd720;
    wire [10:0] HHALF = pal_out ? 11'd864 : 11'd858, HFREE = HHALF;
    wire [10:0] HSYNC = pal_out ? 11'd64 : 11'd62;
    wire [10:0] GSTART = HBP - 11'd37;                 // column 3, pixel 0 at x = 0
    wire [9:0]  VFRAME = pal_out ? 10'd625 : 10'd525;
    wire [9:0]  OSDV = pal_out ? 10'd48 : 10'd0;          // the 480-line OSD centred in 576
    wire [9:0]  VSTART = pal_out ? 10'd44 : 10'd36;
    wire [9:0]  NROW = pal_out ? 10'd576 : 10'd480;
`else
    reg pal_lcd;
    localparam  HBP = 11'd56, HACT = 11'd800;
    wire [10:0] HHALF = pal_lcd ? 11'd1080 : 11'd1072;
    wire [10:0] HSYNC = 11'd10;
    wire [10:0] GSTART = HBP + 11'd3;                  // X0 = 4: column 0 at x = 4
    wire [9:0]  VFRAME = pal_lcd ? 10'd625 : 10'd525;
    wire [9:0]  OSDV = 10'd0;
`endif
    // ---- timing -------------------------------------------------------------------
`ifdef TRI_FBUF
    reg  [10:0] hc;
    reg  [9:0]  lv;
    // Camera / Smooth: lock the frames to the fields, 3 frames to 2 fields (NTSC) or
    // 9 to 5 (PAL). Once a cycle, at a field start, the frame should be at line
    // PT, so the next frame starts when fbuf.v may already show this field (288 /
    // 523 output lines later); the frame length moves by up to 4 lines to get there.
    reg  signed [3:0] corr;
    reg  [2:0]  fcyc;
    wire [9:0]  VT = VFRAME + {{6{corr[3]}}, corr};
`ifdef TRI_LCDBUF
    // one frame a field: at the field start the frame should be at line PT, so the
    // frame starts when LAG_W source rows of the field are in (fbuf.v races it from
    // RACE rows on): rows come from vid_sync's line 18 / 20 on, two LCD lines a row.
    // Camera to panel: LAG_W + ~11 source lines, ~2.7 ms (NTSC); the frame lock
    // moves the frame by a line a field at most once in place (4 while far off).
    localparam [9:0] LAG_W = 10'd32;
    wire [9:0]  PT = VFRAME - 10'd2 * ((pal_out ? 10'd20 : 10'd18) + LAG_W);
`else
    wire [9:0]  PT = pal_out ? 10'd102 : 10'd237;
`endif
    wire signed [10:0] e0 = $signed({1'b0, lv}) - $signed({1'b0, PT});
    wire signed [10:0] eh = e0 > $signed({2'b0, VFRAME[9:1]}) ? e0 - $signed({1'b0, VFRAME}) :
                            e0 < -$signed({2'b0, VFRAME[9:1]}) ? e0 + $signed({1'b0, VFRAME}) : e0;
    always @(posedge clk) begin
        if (rst || hz90 == 2'd0 || !locked) begin corr <= 4'sd0; fcyc <= 3'd0; end
        else if (field_ev) begin
`ifdef TRI_LCDBUF
            fcyc <= 3'd0;                              // frames 1:1 with the fields
`else
            fcyc <= fcyc >= (pal_out ? 3'd4 : 3'd1) ? 3'd0 : fcyc + 3'd1;
`endif
            if (fcyc == 3'd0)
                corr <= eh > 11'sd32 ? 4'sd4 : eh > 11'sd2 ? 4'sd1 : eh < -11'sd32 ? -4'sd4 : eh < -11'sd2 ? -4'sd1 : 4'sd0;
        end
    end
    // Smooth: this frame's shifts (fbuf.v sets them at the frame start), the
    // horizontal one per row: h(row) = sh_h + sh_r / 256 x (row - rows / 2)
    reg  signed [7:0]  hh, hr; reg signed [5:0] hv;
    reg  signed [16:0] hacc;                      // 1/256 pixel
    reg  [8:0]  hn;
    reg  signed [7:0]  hrow;
    wire [9:0]  nr = lv + 10'd3 - VSTART;           // two output rows after the line starting next
`ifdef TRI_LCDBUF
    wire [17:0] nsr5 = {9'd0, nr[9:1]} * 18'd205;          // n x 205 / 1024 = n / 5 (n < 256)
    wire [8:0]  nsr = pal_out ? nr[9:1] + nsr5[18-1:10] : nr[9:1];   // PAL: n + n / 5
    wire signed [10:0] fl = $signed({2'b0, nsr});
`else
    wire signed [10:0] fl = $signed({2'b0, nr[9:1]}) - $signed({{5{hv[5]}}, hv});   // its source line
`endif
    wire [9:0]  nsrc = pal_out ? 10'd288 : 10'd240;
    always @(posedge clk) begin
        if (rst) begin hc <= 11'd0; lv <= 10'd0; pal_out <= 1'b0; frame_tog <= 1'b0; fetch_tog <= 1'b0; fetch_line <= 9'd0; hn <= 9'd0; end
        else begin
            if (hc == HHALF - 11'd1) begin
                hc <= 11'd0;
                lv <= lv >= VT - 10'd1 ? 10'd0 : lv + 10'd1;
                if (lv >= VT - 10'd1) begin frame_tog <= ~frame_tog; pal_out <= pal; end
                // line lv + 1 starts: fetch the source line of output row lv + 3 - VSTART (even rows)
                if (nr < NROW && !nr[0] && !fl[10] && fl < $signed({1'b0, nsrc})) begin fetch_line <= fl[8:0]; fetch_tog <= ~fetch_tog; end
                if (lv == 10'd1) begin hh <= sh_h; hr <= sh_r; hv <= sh_v; end
                if (lv == 10'd2) begin hacc <= {{1{hh[7]}}, hh, 8'd0}; hn <= NROW[9:1]; end
                // a row starts: its shift
                if (lv + 10'd1 - VSTART < NROW) begin hrow <= (hacc + 17'sd128) >>> 8; hacc <= hacc + {{9{hr[7]}}, hr}; end
            end else begin
                hc <= hc + 11'd1;
                if (hn != 9'd0) begin hacc <= hacc - {{9{hr[7]}}, hr}; hn <= hn - 9'd1; end   // to row 0: - rows / 2 x slope
            end
        end
    end
    wire [9:0]  row = lv - VSTART;
`ifdef TRI_LCDBUF
    wire [17:0] rsl5 = {9'd0, row[9:1]} * 18'd205;
    wire [8:0]  rsl = pal_out ? row[9:1] + rsl5[17:10] : row[9:1];   // the source line of this row
    // The panel clock keeps running even if the IQ clock or SDRAM reader
    // stops. Age the displayed field at frame boundaries in that clock.
    reg [2:0] fetched;
    reg saw_field, saw_fetch;
    reg [1:0] missed;
    reg [15:0] noise;
    wire fetch_ev = fetched[2] ^ fetched[1];
    wire video_stale = &missed;
    wire [4:0] snow = noise[4:0];
    wire [15:0] stale_pixel = {snow, snow, snow[4], snow};
    always @(posedge clk) begin
        if (rst) begin
            fetched <= 0; saw_field <= 0; saw_fetch <= 0; missed <= 3; noise <= 16'hace1;
        end else begin
            fetched <= {fetched[1:0], fetch_done_a};
            if (hc == HHALF - 1'b1 && lv >= VT - 1'b1) begin
                if ((saw_field || field_ev) && (saw_fetch || fetch_ev)) missed <= 0;
                else if (!video_stale) missed <= missed + 1'b1;
                saw_field <= 0; saw_fetch <= 0;
            end else begin
                if (field_ev) saw_field <= 1'b1;
                if (fetch_ev) saw_fetch <= 1'b1;
            end
            if (video_stale) noise <= {noise[14:0], ^{noise[15], noise[13], noise[12], noise[10]}};
        end
    end
`endif
`elsif TRI_HDMI
    // Fixed CEA raster. Take the newest completed source line at the
    // beginning of the active output row. Repeats/skips are local to video
    // content and never shorten an HDMI line or frame.
    reg [10:0] hc, line_age;
    reg [9:0] lv;
    reg latest_bank, row_bank, row_good;
    always @(posedge clk) begin
        if (rst) begin
            hc <= 0; lv <= 0; pal_out <= 0;
            line_age <= 11'h7ff; latest_bank <= 0; row_bank <= 0; row_good <= 0;
        end else begin
            if (hc == HHALF - 1'b1) begin
                hc <= 0;
                if (lv == VFRAME - 1'b1) begin lv <= 0; pal_out <= pal; end
                else lv <= lv + 1'b1;
            end else hc <= hc + 1'b1;
            if (line_ev && line_info_a[8]) begin latest_bank <= line_info_a[0]; line_age <= 0; end
            else if (!(&line_age)) line_age <= line_age + 1'b1;
            if (hc == HBP - 11'd4) begin
                row_bank <= latest_bank;
                row_good <= locked && !(&line_age);
            end
        end
    end
    wire [9:0] row = lv - VSTART;
`else
    reg [10:0] hc;
    reg [9:0] lv;
    reg half;
    reg latest_bank, line_bank, first_pending;
    reg signed [4:0] htrim, vtrim;
    reg [10:0] line_clocks;
    reg [9:0] frame_lines;
    localparam [9:0] FIRST_ROW = 10'd23;
    wire end_line = hc >= line_clocks - 11'd1;
    wire end_frame = lv >= frame_lines - 10'd1;
    wire new_line = line_ev && line_info_a[8];
    wire first_source_line = new_line && line_info_a[7:0] == 8'd0;
    // Line zero can rephase the horizontal pair before active video. The first
    // active LCD scanline stays at FIRST_ROW, independent of source timing.
    wire align_window = locked && pal == pal_lcd && lv >= FIRST_ROW - 10'd4 && lv < FIRST_ROW;
    wire align_start = align_window && (first_pending || first_source_line);
    wire [10:0] next_line_clocks = HHALF + {10'd0, !pal_lcd} + {{6{htrim[4]}}, htrim};
    wire [9:0] next_frame_lines = VFRAME + {{5{vtrim[4]}}, vtrim};

    // The panel reads a continuous rectangle. Adjust only the porch of future
    // lines, so a source edge or a lock change cannot truncate an active line.
    // One analog line should end just before the next pair of LCD lines starts.
    always @(posedge clk) begin
        if (rst) begin
            hc <= 11'd0; lv <= 10'd0; half <= 1'b0; pal_lcd <= 1'b0;
            line_clocks <= 11'd1072; frame_lines <= 10'd525;
            htrim <= 5'sd0; vtrim <= 5'sd0;
            latest_bank <= 1'b0; line_bank <= 1'b0;
            first_pending <= 1'b0;
        end else begin
            if (new_line) latest_bank <= line_info_a[0];
            if (!align_window) first_pending <= 1'b0;
            else if (first_source_line) first_pending <= 1'b1;
            if (!locked || pal != pal_lcd) htrim <= 5'sd0;
            else if (line_ev) begin
                if (!half) htrim <= hc < 11'd8 ? 5'sd2 : 5'sd8;
                else if (hc + 11'd12 < line_clocks) htrim <= -5'sd8;
                else if (hc + 11'd4 < line_clocks) htrim <= -5'sd2;
                else htrim <= 5'sd0;
            end

            // Keep the source's first completed row just ahead of the LCD
            // active window. The trim changes the total frame length, leaving
            // the VS-to-DE interval and the OSD coordinates fixed.
            if (!locked || pal != pal_lcd) vtrim <= 5'sd0;
            else if (first_source_line) begin
                if (lv > FIRST_ROW + (VFRAME >> 1) || lv + 10'd12 < FIRST_ROW)
                    vtrim <= -5'sd12;
                else if (lv + 10'd2 < FIRST_ROW) vtrim <= -5'sd2;
                else if (lv > FIRST_ROW + 10'd12) vtrim <= 5'sd12;
                else if (lv > FIRST_ROW + 10'd1) vtrim <= 5'sd2;
                else if (lv >= FIRST_ROW) vtrim <= 5'sd1;
                else vtrim <= 5'sd0;
            end

            if (end_line) begin
                hc <= 11'd0;
                line_bank <= align_start ? 1'b0 : (new_line ? line_info_a[0] : latest_bank);
                if (end_frame) begin
                    lv <= 10'd0;
                    pal_lcd <= pal;
                    frame_lines <= (!locked || pal != pal_lcd) ? (pal ? 10'd625 : 10'd525) : next_frame_lines;
                end else lv <= lv + 10'd1;
                if (align_start) first_pending <= 1'b0;
                half <= end_frame || align_start ? 1'b0 : ~half;
                line_clocks <= end_frame ? (pal ? 11'd1080 : 11'd1072) :
                               (half || align_start) ? HHALF : next_line_clocks;
            end else hc <= hc + 11'd1;
        end
    end
    wire [9:0] row = lv - FIRST_ROW;
`endif
    wire [9:0]  orow_v = row - OSDV;                  // the OSD's line
    wire        osd_line = orow_v < 10'd480;
`ifdef TRI_FBUF
    wire        row_on = row < NROW;
`elsif TRI_HDMI
    wire        row_on = row < NROW;
`else
    wire        row_on = row < 10'd480;
`endif
    wire        de0 = row_on && hc >= HBP && hc < HBP + HACT;
    wire [9:0]  x = hc[9:0] - HBP[9:0];
    // ---- cell row of this line: row / 24, row % 24, row / 24 * 66, by subtraction
    //      during the first clocks of the line (row is stable from hc = 0) ----
    reg [9:0]  rrem; reg [10:0] rbase; reg [4:0] ry;
    always @(posedge clk) begin
        if (hc == 11'd0) begin rrem <= orow_v; rbase <= 11'd0; end
        else if (rrem >= 10'd24) begin rrem <= rrem - 10'd24; rbase <= rbase + 11'd66; end
        ry <= rrem[4:0];
    end
    // ---- start-up screen: the Triversity logo (gen_osd.boot_runs: 300 x 79, run-length
    //      coded, shown twice as large at x 100, y 60 of the 800 x 480 grid); dark around it ----
`ifndef TRI_LIVEUI
    reg  [8:0]  logo [0:2047];
`include "boot_logo.vh"
    localparam [15:0] BC0 = 16'h0842, BC1 = 16'h0b50, BC2 = 16'h0aff, BC3 = 16'h7bf0, BC4 = 16'hef9e;
`ifdef TRI_HDMI
    localparam [9:0] LX = 10'd60;                   // the HDMI picture starts at x 40 of the grid
`else
    localparam [9:0] LX = 10'd100;
`endif
    wire [9:0]  lrow = orow_v - 10'd60;
    wire        lrow_in = lrow < 10'd158;
    reg  [10:0] lptr, lrs;                          // the run shown, the first run of this logo row
    reg  [8:0]  lq, lcur; reg [5:0] lrem; reg lph;
    wire [10:0] lnext = lptr + 11'd1;
    always @(posedge clk) lq <= logo[lnext];         // wraps to run zero
    wire        lin_x = de0 && x >= LX && x < LX + 10'd600;
    reg  [15:0] lg0;
    always @(*) begin
        lg0 = BC0;
        if (lin_x && lrow_in)
            case (lcur[8:6]) 3'd1: lg0 = BC1; 3'd2: lg0 = BC2; 3'd3: lg0 = BC3; 3'd4: lg0 = BC4; default: lg0 = BC0; endcase
    end
    always @(posedge clk) begin
        if (lrow_in && hc == 11'd2) begin               // a logo row: from its first run (twice each)
            if (lrow == 10'd0) begin lrs <= 11'd0; lptr <= 11'h7ff; end
            else if (lrow[0]) lptr <= lrs - 11'd1;
            else begin lrs <= lptr; lptr <= lptr - 11'd1; end
        end else if (lrow_in && hc == 11'd4) begin
            lcur <= lq; lrem <= lq[5:0]; lptr <= lptr + 11'd1; lph <= 1'b0;
        end else if (lrow_in && lin_x) begin           // two pixels a logo pixel
            lph <= ~lph;
            if (lph) begin
                if (lrem == 6'd0) begin lcur <= lq; lrem <= lq[5:0]; lptr <= lptr + 11'd1; end
                else lrem <= lrem - 6'd1;
            end
        end
    end
`else
    wire [15:0] lg0 = 16'd0;
`endif
    reg  [15:0] lg1, lg2;
    // ---- cell column: counters along the line ----
    reg [3:0] sx; reg [6:0] cx; reg ing;
    always @(posedge clk) begin
        if (hc == GSTART) begin sx <= 4'd0; cx <= 7'd0; ing <= osd_line; end
        else if (ing) begin
            if (sx == 4'd11) begin sx <= 4'd0; cx <= cx + 7'd1; if (cx == 7'd65) ing <= 1'b0; end
            else sx <= sx + 4'd1;
        end
    end
    // ing/cx/sx describe hc (they were set one clock before hc reached the
    // grid: at hc = HBP + X0 the counters read cell 0, pixel 0)
    // ---- pipeline: addresses end of n, RAM data in n+2, glyph row in n+3,
    //      blend sums end of n+3, pixel registers end of n+4 (shown in n+5) ----
`ifdef TRI_SEGFONT
    // Triversity DVR build: 7-segment glyphs from logic instead of the font ROM
    // (gen_osd.seg_glyphs() is the reference; coverage 0 / 1 / 3)
`include "osd_seg.vh"
`else
    reg [23:0] font [0:4095];
`include "osd_font.vh"
`endif
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
`ifdef TRI_HDMI
    wire [1:0] hm = 2'd0;                              // HDMI: the 720 samples as they are
`else
    wire [1:0] hm = hmode;
`endif
`ifdef TRI_HDMI90
    // the shifted source: column x - h(row), line row / 2 - v; outside: black
    wire signed [10:0] xs = $signed({1'b0, xn}) - $signed({{3{hrow[7]}}, hrow});
    wire signed [10:0] rs = $signed({2'b0, row[9:1]}) - $signed({{5{hv[5]}}, hv});
    wire        xs_ok = !xs[10] && xs < 11'sd720, rs_ok = !rs[10] && rs < $signed({1'b0, nsrc});
    wire [10:0] hcalc = {xs_ok && rs_ok, xs[9:0]};
`else
    // Full width and 4:3 have exact arithmetic mappings. Only Stretch
    // needs a table. Compact live UI builds offer 4:3 and full width.
    wire [9:0]  xb = xn - 10'd80;
    wire [11:0] xb5 = {xb, 2'b0} + {2'b0, xb};
    wire [10:0] linear = hm == 2'd1 ? ((xn >= 10'd80 && xn < 10'd720) ? {1'b1, xb5[11:2]} : 11'd0) :
                         xn < 10'd800 ? {1'b1, xn} : 11'd0;
`ifdef TRI_HMAPCALC
    wire [10:0] hcalc = linear;
`else
    reg [9:0] hmap [0:1023];
`include "hmap.vh"
    wire [10:0] hcalc = hm == 2'd2 ? {xn < 10'd800, hmap[xn]} : linear;
`endif
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
    // x 171 >> 9 as shift-adds on carry chains (the DSP blocks go to the receive path)
    always @(posedge clk) begin
        hq <= hcalc;
`ifdef TRI_HDMI90
        lb_addr  <= {rs[0], hq[9:0]};           // fbuf.v holds source line rs in half rs[0]
`elsif TRI_LCDBUF
        lb_addr  <= {rsl[0], hq[9:0]};          // fbuf.v holds source line rsl in half rsl[0]
`elsif TRI_HDMI
        lb_addr  <= {row_bank, hq[9:0]};
`else
        lb_addr  <= {line_bank, hq[9:0]};
`endif
        hv1 <= hq[10]; hv2 <= hv1;
        osd_addr <= rbase + {4'd0, cx};
        de_d <= {de_d[3:0], de0};
        hs_d <= {hs_d[3:0], hc < HSYNC};
`ifdef TRI_HDMI90
        vs_d <= {vs_d[3:0], lv < 10'd6};
`elsif TRI_HDMI
        vs_d <= {vs_d[3:0], lv < (pal_out ? 10'd5 : 10'd6)};
`else
        vs_d <= {vs_d[3:0], lv < 10'd3};              // three full lines of vertical sync
`endif
        sx1 <= sx; sx2 <= sx1; sx3 <= sx2;
        g1 <= ing; g2 <= g1; g3 <= g2;
        ry1 <= ry; ry2 <= ry1;
        // n+2: cell and video
        lg1 <= lg0; lg2 <= lg1;
        // unlocked: the line buffer as vid_sync's flywheel wrote it (snow, like an analog
        // receiver), not black
        cell3 <= osd_cell;
`ifdef TRI_HDMI
`ifndef TRI_HDMI90
        v3 <= boot ? lg2 : hv2 && row_good ? lb_data : 16'd0;
`else
        v3 <= boot ? lg2 : hv2 ? lb_data : 16'd0;
`endif
`elsif TRI_LCDBUF
        v3 <= boot ? lg2 : hv2 ? (video_stale ? stale_pixel : lb_data) : 16'd0;
`else
        v3 <= boot ? lg2 : hv2 ? lb_data : 16'd0;
`endif
`ifdef TRI_SEGFONT
        glyph <= seg_row(osd_cell[6:0], ry2);
`else
        glyph <= font[{osd_cell[6:0], ry2}];
`endif
        // n+3: blend sums
        begin : blend
            reg [1:0] a; reg [7:0] vr, vg, vb; reg [23:0] bgc, fgc, pnl, m0, m1;
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
            // bg * (3 - a) + fg * a as one add: (a[0] ? fg : bg) + 2 (a[1] ? fg : bg)
            m0 = a[0] ? fgc : bgc; m1 = a[1] ? fgc : bgc;
            sr <= {2'b0, m0[23:16]} + {1'b0, m1[23:16], 1'b0};
            sg <= {2'b0, m0[15:8]}  + {1'b0, m1[15:8], 1'b0};
            sb <= {2'b0, m0[7:0]}   + {1'b0, m1[7:0], 1'b0};
        end
        // n+4: / 3 (x 171 >> 9 on DSP blocks), out
        begin : px
            reg [9:0] r8, g8, b8;
            r8 = mul171s9(sr); g8 = mul171s9(sg); b8 = mul171s9(sb);
            if (!de_d[3]) begin lcd_r <= 5'd0; lcd_g <= 6'd0; lcd_b <= 5'd0; px_r <= 8'd0; px_g <= 8'd0; px_b <= 8'd0; end
            else begin lcd_r <= r8[7:3]; lcd_g <= g8[7:2]; lcd_b <= b8[7:3]; px_r <= r8[7:0]; px_g <= g8[7:0]; px_b <= b8[7:0]; end
        end
    end
    assign lcd_de = de_d[4];
    assign lcd_hs = ~hs_d[4];
    assign lcd_vs = ~vs_d[4];
endmodule
`default_nettype wire
