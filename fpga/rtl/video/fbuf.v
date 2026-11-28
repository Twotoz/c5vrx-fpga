// Triversity: field buffer in the GW2AR's SDRAM for the free-running 90 Hz
// HDMI output (TRI_HDMI90). The receiver writes every field, the display reads
// the newest complete one, so the two rates need not match (59.94 / 50 Hz in,
// ~90 Hz out); each output frame shows one field, never two halves (triple
// buffering: three field slots, the writer never takes the slot being read).
//
// Write side (clk, the IQ clock): vid_sync's line-buffer writes (720 RGB565
// pixels a line, in order) are packed two pixels a word into a two-line buffer
// (by orow[0] like the line buffer); at the line toggle the finished line
// becomes a write job of 360 words. A field toggle closes the slot (it becomes
// the newest) and the writer moves to the slot that is neither the newest nor
// the one the display reads.
// Read side: the display asks for a source line (fetch toggle + line, other
// clock domain) two output lines before it shows it; the engine reads it into
// a two-line buffer that the display reads in its own clock. At each output
// frame start the display's toggle latches the newest slot.
// SDRAM word address {0, slot[1:0], line[8:0], word[8:0]}: a line is two SDRAM
// rows, 23 bursts (22 x 16 + 8 words, never across a row). A read waits for at
// most one write burst: the engine looks at reads between write bursts.
`default_nettype none
module fbuf #(
    parameter WPL = 360,           // SDRAM words a line: 720 pixels (HDMI) 360, 800 (LCD) 400
    parameter RACE_N = 74,         // lines written before a frame may show the field still coming in
    parameter RACE_P = 122,
    parameter SMOOTH = 1           // Smooth (motion.v) for the 90 Hz HDMI output; the LCD has none
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        wr_en,
    input  wire [10:0] wr_addr,        // {bank, x}
    input  wire [15:0] wr_data,
    input  wire        line_tog,
    input  wire [8:0]  line_info,      // {show, orow[7:1], bank} of the line just written
    input  wire        line_skip,      // that line is corrupt (vid_sync): the row gets the line above (the other bank)
    input  wire        locked,         // vid_sync's lock (this clock): a field written without it is no concealment source
    input  wire        field_tog,
    input  wire        pal,
    input  wire [1:0]  mode_p,         // display domain (menu): 0 Free, 1 Camera, 2 Smooth
    output reg  signed [7:0] sh_h,     // Smooth: this frame's shift, pixels (+ right), at the middle row
    output reg  signed [7:0] sh_r,     //   its change per output row (1/256 pixel)
    output reg  signed [5:0] sh_v,     //   and its vertical shift, source lines (+ down)
    input  wire        frame_tog_p,    // display domain: a frame starts
    input  wire        fetch_tog_p,    // display domain: fetch source line fetch_line_p
    input  wire [8:0]  fetch_line_p,
    output reg         fetch_done,    // toggles after a complete visible SDRAM read
    input  wire        rclk,
    input  wire [10:0] raddr,          // {line[0], x}
    output wire [15:0] rdata,
    output wire        O_sdram_clk, O_sdram_cke, O_sdram_cs_n, O_sdram_ras_n, O_sdram_cas_n, O_sdram_wen_n,
    output wire [10:0] O_sdram_addr,
    output wire [1:0]  O_sdram_ba,
    output wire [3:0]  O_sdram_dqm,
    inout  wire [31:0] IO_sdram_dq
);
    // bursts a line: (WPL + 15) / 16, the last one LASTLEN words (360: 22 x 16 + 8; 400: 25 x 16)
    localparam [4:0] LASTB = (WPL + 15) / 16 - 1;
    localparam [4:0] LASTLEN = WPL - 16 * ((WPL + 15) / 16 - 1);
    // ---- write line buffer: two lines of WPL words ----
    reg [31:0] wlb [0:1023];
    reg [15:0] lo;
    reg [9:0]  wl_ra; reg [31:0] wl_q;
    always @(posedge clk) begin
        if (wr_en && !wr_addr[0]) lo <= wr_data;
        if (wr_en && wr_addr[0]) wlb[{wr_addr[10], wr_addr[9:1]}] <= {wr_data, lo};
        wl_q <= wlb[wl_ra];
    end
    // ---- read line buffer: two lines, written here, read in the display clock ----
    reg [31:0] rlb [0:1023];
    reg [9:0]  rl_wa; reg rl_we; reg [31:0] rl_wd;
    always @(posedge clk) if (rl_we) rlb[rl_wa] <= rl_wd;
    reg [31:0] rq; reg hsel;
    always @(posedge rclk) begin rq <= rlb[raddr[10:1]]; hsel <= raddr[0]; end
    assign rdata = hsel ? rq[31:16] : rq[15:0];
    // ---- slots ----
    function [1:0] third; input [1:0] a, b;
        third = (a != 2'd0 && b != 2'd0) ? 2'd0 : (a != 2'd1 && b != 2'd1) ? 2'd1 : 2'd2;
    endfunction
    reg [1:0] wslot, latest, rslot; reg lat_ok;
    reg [8:0] wrow;
    // ---- concealment sources (#12): a skipped line keeps the slot's older row only if
    // that older field is a valid one: complete (>= 240 rows), written while locked, of
    // this standard, without a corrupt line of its own, and at most 3 fields old.
    // Otherwise the line is written as it is.
    reg [7:0] fcnt;                    // fields closed
    reg [7:0] s_gen [0:2];             // fcnt when the slot's field was closed
    reg [2:0] s_clean, s_pal;
    reg       cur_bad;                 // this field: a corrupt line, or the lock lost
    wire [7:0] s_age = fcnt - s_gen[wslot];
    wire      src_ok = s_clean[wslot] && s_pal[wslot] == pal && s_age <= 8'd2;   // 2: closed at most two fields before the slot was taken again
    wire      skip = line_skip && src_ok;
    reg       lt_p, ft_p;
    // pending write jobs, one per line-buffer half
    reg [1:0] wp; reg [8:0] wp_line [0:1]; reg [1:0] wp_slot [0:1];
    // display requests
    reg [2:0] frs, fes; reg rp; reg [8:0] rq_line, rline; reg [1:0] rj_slot; reg rvalid, rj_valid;
    // ---- engine ----
    localparam E_IDLE = 3'd0, E_WLOAD = 3'd1, E_WREQ = 3'd2, E_WRUN = 3'd3, E_RREQ = 3'd4, E_RWAIT = 3'd5;
    reg [2:0]  est;
    reg        wb;                     // the write job's line-buffer half
    reg        wact;                   // a write job is under way (it may pause for a read)
    reg [4:0]  wc, rc;                 // burst of the line, 0..22
    reg [4:0]  ld, wn;                 // words loaded / written of the burst
    reg [31:0] sr [0:15];
    reg        ld_v;
    reg [8:0]  rcnt;                   // words of the read line received
    wire [4:0] wlen = wc == LASTB ? LASTLEN : 5'd16, rlen = rc == LASTB ? LASTLEN : 5'd16;
    wire       s_ack, s_next, s_rv; wire [31:0] s_rd;
    wire       s_req = est == E_WREQ || est == E_RREQ;
    wire       s_we = est == E_WREQ;
    wire [20:0] s_addr = s_we ? {1'b0, wp_slot[wb], wp_line[wb], wc[4:0], 4'd0} : {1'b0, rj_slot, rline, rc[4:0], 4'd0};
    wire [4:0] s_len = s_we ? wlen : rlen;
    wire [31:0] s_wd = s_next ? sr[1] : sr[0];
    integer i;
    wire fr_ev = frs[2] != frs[1];
    // ---- Camera / Smooth: show the field still coming in when enough of it is
    // in that the display cannot overtake it (racing the beam; the display reads
    // a source line two output lines before it shows it): lines written >= 74 of
    // 240 (NTSC) / 122 of 288 (PAL), 4 lines of margin ----
    reg  [1:0] md_m, md;
    always @(posedge clk) begin md_m <= mode_p; md <= md_m; end
    wire       race = md != 2'd0 && wrow >= (pal ? RACE_P[8:0] : RACE_N[8:0]);
    wire [1:0] nrs = race ? wslot : latest;          // the slot a frame starting now shows
    reg  [9:0] lcnt, pfl;                            // source lines since the field started, the last field's
    reg  [9:0] age;                                  // lines from the start of the shown field to the frame start
    always @(posedge clk) begin
        rl_we <= 1'b0;
        frs <= {frs[1:0], frame_tog_p}; fes <= {fes[1:0], fetch_tog_p};
        if (rst) begin
            fcnt <= 8'd0; s_clean <= 3'b000; s_pal <= 3'b000; cur_bad <= 1'b1;
            s_gen[0] <= 8'd0; s_gen[1] <= 8'd0; s_gen[2] <= 8'd0;
            wslot <= 2'd0; latest <= 2'd0; rslot <= 2'd0; lat_ok <= 1'b0; rvalid <= 1'b0; lcnt <= 10'd0; pfl <= 10'd262; age <= 10'd0; wrow <= 9'd0; wp <= 2'b00; rp <= 1'b0;
            lt_p <= line_tog; ft_p <= field_tog; est <= E_IDLE; wact <= 1'b0;
            fetch_done <= 1'b0;
        end else begin
            // ---- write side ----
            lt_p <= line_tog; ft_p <= field_tog;
            if (lt_p != line_tog && lcnt != 10'h3ff) lcnt <= lcnt + 10'd1;
            if (ft_p != field_tog) begin lcnt <= 10'd0; pfl <= lcnt; end
            if (lt_p != line_tog && line_info[8] && wrow < 9'd288) begin
                // a corrupt line: the row gets the last good line of this field, still in
                // the other half (vid_sync did not move its bank on); a corrupt first row
                // keeps the slot's older row (or is written as it is)
                if (line_skip && wrow != 9'd0 && !wp[!line_info[0]]) begin
                    wp[!line_info[0]] <= 1'b1; wp_line[!line_info[0]] <= wrow; wp_slot[!line_info[0]] <= wslot;
                end else if (!skip) begin wp[line_info[0]] <= 1'b1; wp_line[line_info[0]] <= wrow; wp_slot[line_info[0]] <= wslot; end
                wrow <= wrow + 9'd1;
            end
            if (lt_p != line_tog && line_skip) cur_bad <= 1'b1;
            if (!locked) cur_bad <= 1'b1;
            if (ft_p != field_tog) begin
                wrow <= 9'd0;
                // the closing field's quality, for its slot as a later concealment source
                if (wrow != 9'd0) begin
                    s_gen[wslot] <= fcnt + 8'd1; fcnt <= fcnt + 8'd1;
                    s_clean[wslot] <= !cur_bad && wrow >= 9'd240; s_pal[wslot] <= pal;
                end
                cur_bad <= !locked;
                // the slot the display reads from now on (a frame may start in this very clock)
                if (wrow != 9'd0) begin latest <= wslot; lat_ok <= 1'b1; wslot <= third(wslot, fr_ev && (lat_ok || race) ? nrs : rslot); end
            end
            // ---- display requests ----
            if (fr_ev && (lat_ok || race)) begin rslot <= nrs; rvalid <= 1'b1; age <= race ? lcnt : lcnt + pfl; end
            if (fes[2] != fes[1]) begin rp <= 1'b1; rq_line <= fetch_line_p; end
            // ---- engine ----
            case (est)
                E_IDLE:
                    if (rp) begin rp <= 1'b0; rc <= 5'd0; rcnt <= 9'd0; rline <= rq_line; rj_slot <= rslot; rj_valid <= rvalid; est <= E_RREQ; end
                    else if (wact) begin est <= E_WLOAD; ld <= 5'd0; ld_v <= 1'b0; wl_ra <= {wb, wc, 4'd0}; end
                    else if (wp != 2'b00) begin
                        wb <= wp[0] ? 1'b0 : 1'b1; wact <= 1'b1; wc <= 5'd0;
                        est <= E_WLOAD; ld <= 5'd0; ld_v <= 1'b0; wl_ra <= {wp[0] ? 1'b0 : 1'b1, 9'd0};
                    end
                E_WLOAD: begin                 // wlb -> sr, one word a clock (read latency 1)
                    wl_ra <= wl_ra + 10'd1; ld_v <= 1'b1;
                    if (ld_v) begin
                        sr[ld[3:0]] <= wl_q; ld <= ld + 5'd1;
                        if (ld + 5'd1 == wlen) begin est <= E_WREQ; wn <= 5'd0; end
                    end
                end
                E_WREQ: if (s_ack) est <= E_WRUN;
                E_WRUN: if (s_next) begin
                    for (i = 0; i < 15; i = i + 1) sr[i] <= sr[i + 1];
                    wn <= wn + 5'd1;
                    if (wn + 5'd1 == wlen) begin
                        est <= E_IDLE;
                        if (wc == LASTB) begin wact <= 1'b0; wp[wb] <= 1'b0; end
                        else wc <= wc + 5'd1;
                    end
                end
                E_RREQ: if (s_ack) begin
                    if (rc == LASTB) est <= E_RWAIT; else rc <= rc + 5'd1;
                end
                E_RWAIT: if (rcnt == WPL[8:0]) begin
                    est <= E_IDLE;
                    if (rj_valid) fetch_done <= ~fetch_done;
                end
                default: est <= E_IDLE;
            endcase
            if (s_rv) begin
                rl_we <= 1'b1; rl_wa <= {rline[0], rcnt}; rl_wd <= rj_valid ? s_rd : 32'd0; rcnt <= rcnt + 9'd1;
            end
        end
    end
    // ---- Smooth: whole-picture motion (motion.v) and this frame's shifts ----
    wire signed [5:0] vh0, vh1, vh2, vh3, vv; wire mv;
    generate if (SMOOTH) begin : gsm
    motion u_mo (.clk(clk), .rst(rst), .pal(pal), .px_we(wr_en), .px_x(wr_addr[9:0]), .px_g(wr_data[10:5]),
                 .row(wrow), .row_done(lt_p != line_tog && line_info[8] && wrow < 9'd288), .field_ev(ft_p != field_tog),
                 .vh0(vh0), .vh1(vh1), .vh2(vh2), .vh3(vh3), .vv(vv), .valid(mv));
    end else begin : gnosm
    assign vh0 = 6'sd0; assign vh1 = 6'sd0; assign vh2 = 6'sd0; assign vh3 = 6'sd0; assign vv = 6'sd0; assign mv = 1'b0;
    end endgenerate
    // Shift = motion a field x (age - reference age) / field: the picture is put
    // where the scene is at a fixed delay after capture, so every output frame
    // moves by the same step. With f = age - LREF (source lines):
    //   sh_h = sum(vh) x f x KH >> 16    (mean of the bands, 2 px a bin, / 2 field lines)
    //   sh_r = (-3 vh0 - vh1 + vh2 + 3 vh3) x f x KR >> 16   (slope over the bands, per output row, 1/256 px)
    //   sh_v = vv x f x KH >> 16          (half lines a field -> lines)
    // KH = 65536 / (2 x field lines), KR = 65536 x 2/10 x 256/band rows / field lines.
    localparam [7:0] KH_N = 8'd125, KH_P = 8'd105, KR_N = 8'd107, KR_P = 8'd75;
    wire [9:0]  lref = pal ? 10'd142 : 10'd92;     // the age of a frame that races the field
    reg  [2:0]  ms;                                 // step: 0 idle, 1..5 the products
    reg  signed [23:0] ma; reg [7:0] mb; reg mneg; reg [3:0] mk; reg signed [31:0] macc;
    reg  signed [23:0] fkh, fkr;
    reg         mrun;
    wire signed [7:0] sumv = vh0 + vh1 + vh2 + vh3;
    wire signed [7:0] numr = -(vh0 + vh0 + vh0) - vh1 + vh2 + vh3 + vh3 + vh3;
    wire signed [10:0] fa = $signed({1'b0, age}) - $signed({1'b0, lref});
    wire signed [31:0] pm = mneg ? -macc : macc;    // the product with b's sign
    wire signed [31:0] rnd = pm + 32'sd32768;
    wire signed [15:0] r16 = rnd[31:16];
    function signed [7:0] cl8; input signed [15:0] v; input [6:0] m;
        cl8 = v > $signed({9'd0, m}) ? $signed({1'b0, m}) : v < -$signed({9'd0, m}) ? -$signed({1'b0, m}) : v[7:0];
    endfunction
    task mstart; input signed [23:0] a; input signed [7:0] bb;
        begin ma <= a; mneg <= bb[7]; mb <= bb[7] ? -bb : bb; mk <= 4'd0; macc <= 32'sd0; mrun <= 1'b1; end
    endtask
    reg fr_ev_d; always @(posedge clk) fr_ev_d <= fr_ev;
    always @(posedge clk) begin
        if (rst) begin ms <= 3'd0; mrun <= 1'b0; sh_h <= 8'sd0; sh_r <= 8'sd0; sh_v <= 6'sd0; end
        else if (mrun) begin                          // a x |b|, b's bits one a clock
            if (mb[mk[2:0]]) macc <= macc + ($signed({{8{ma[23]}}, ma}) <<< mk);
            if (mk == 4'd7) mrun <= 1'b0; else mk <= mk + 4'd1;
        end else case (ms)
            3'd0: if (fr_ev_d) begin                 // a clock after the frame start: age is this frame's
                      if (SMOOTH && md == 2'd2 && mv) begin ms <= 3'd1; mstart({{13{fa[10]}}, fa}, $signed(pal ? KH_P : KH_N)); end
                      else begin sh_h <= 8'sd0; sh_r <= 8'sd0; sh_v <= 6'sd0; end
                  end
            3'd1: begin fkh <= pm[23:0]; ms <= 3'd2; mstart({{13{fa[10]}}, fa}, $signed(pal ? KR_P : KR_N)); end
            3'd2: begin fkr <= pm[23:0]; ms <= 3'd3; mstart(fkh, sumv); end
            3'd3: begin sh_h <= cl8(r16, 7'd96); ms <= 3'd4; mstart(fkr, numr); end
            3'd4: begin sh_r <= cl8(r16, 7'd127); ms <= 3'd5; mstart(fkh, {{2{vv[5]}}, vv}); end
            default: begin sh_v <= cl8(r16, 7'd24); ms <= 3'd0; end
        endcase
    end
    sdram u_ram (.clk(clk), .rst(rst), .ready(), .req(s_req), .req_we(s_we), .req_addr(s_addr), .req_len(s_len),
                 .req_ack(s_ack), .busy(), .wr_data(s_wd), .wr_next(s_next), .rd_valid(s_rv), .rd_data(s_rd),
                 .O_sdram_clk(O_sdram_clk), .O_sdram_cke(O_sdram_cke), .O_sdram_cs_n(O_sdram_cs_n), .O_sdram_ras_n(O_sdram_ras_n),
                 .O_sdram_cas_n(O_sdram_cas_n), .O_sdram_wen_n(O_sdram_wen_n), .O_sdram_addr(O_sdram_addr), .O_sdram_ba(O_sdram_ba),
                 .O_sdram_dqm(O_sdram_dqm), .IO_sdram_dq(IO_sdram_dq));
endmodule
`default_nettype wire
