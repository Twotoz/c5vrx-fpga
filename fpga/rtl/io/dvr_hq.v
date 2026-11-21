// Triversity HQ DVR: every field as a colour JPEG, 720 x 240 (NTSC) or
// 720 x 288 (PAL), into TRIDVR.BIN on the TF card. 40 MHz domain.
//  - vid_sync's DVR stream (720 pixels a line: Y, Cb, Cr) is packed into
//    32-bit words: Y four pixels a word, Cb / Cr at 4:2:0 four a word
//    (h = (c[2x] + c[2x+1] + 1) >> 1 on both lines of a pair, then
//    (h_even + h_odd + 1) >> 1; the even line waits in cev)
//  - the words go through a FIFO into the SDRAM (sdram.v): four field slots,
//    each field in 8 x 8 block order (a block = 16 consecutive words), so the
//    encoder reads a block as one burst; a slot holds Y at 0, Cb / Cr at
//    65536 (block rows of 1440 words)
//  - the encoder side takes the fields in order, strip by strip once the
//    strip is in the SDRAM, MCU by MCU (Y 0,0 0,8 8,0 8,8, Cb, Cr); it may
//    lag up to three fields behind the camera (the DVR need not keep up
//    field by field), a field that finds no free slot is dropped
//  - the records (prefix + JPEG) go through an 8 KB ring to the card (sd_ring.v)
//  - TARGET: ~1.47 MB/s (24 KB x 59.94, 29 KB x 50), what SPI mode at 20 MHz
//    sustains; the quality index follows the field sizes (down above
//    TARGET + 1/8, up below 3/4 TARGET), from 3 (quality 60)
// fpga/tools: tools/hqdvr_to_mp4.py turns the file into a video.
`default_nettype none
module dvr_hq #(parameter [17:0] TARGET_N = 18'd24576, TARGET_P = 18'd29696) (
    input  wire        clk,
    input  wire        rst,
    input  wire        rec,             // record (other domain)
    input  wire        d_valid,
    input  wire [9:0]  d_x,
    input  wire [8:0]  d_line,
    input  wire [7:0]  d_y, d_cb, d_cr,
    input  wire        d_fstart,
    input  wire        d_parity,
    input  wire        pal,
    output wire        sd_cs, sd_sck, sd_mosi,
    input  wire        sd_miso,
    output wire [1:0]  state,           // sd_ring: 0 no card, 1 ready, 2 recording, 3 error
    output reg  [2:0]  qi,              // current quality index
    output reg  [15:0] fields,          // fields recorded
    output reg  [15:0] dropped,
    // SDRAM
    output wire        O_sdram_clk, O_sdram_cke, O_sdram_cs_n, O_sdram_ras_n, O_sdram_cas_n, O_sdram_wen_n,
    output wire [10:0] O_sdram_addr,
    output wire [1:0]  O_sdram_ba,
    output wire [3:0]  O_sdram_dqm,
    inout  wire [31:0] IO_sdram_dq
);
    reg [1:0] rs; always @(posedge clk) rs <= {rs[0], rec};
    wire recording = rs[1] && state == 2'd2;
    // ================= slots =================
    reg  [1:0] shead, scnt;              // the oldest field being / to be encoded, fields queued (<= 3)
    reg  [3:0] comp;                     // slot complete in the SDRAM
    reg  [3:0] pal_s, par_s;
    wire [1:0] wslot = shead + scnt;     // the next free slot
    // ================= capture: words into the FIFO =================
    reg        cap;                      // capturing this field
    reg  [8:0] H;
    reg  [31:0] yw;                      // Y bytes of the word being packed
    reg  [7:0] cb0, cr0;                 // the even pixel
    reg        cw; reg [8:0] cwx; reg [7:0] cwb, cwr; reg codd;
    reg  [15:0] cev [0:511];             // the even line's pairs {Cb, Cr} by x / 2
    reg  [7:0] cbq, crq;
    wire [8:0] cbm = {1'b0, cbq} + {1'b0, cwb} + 9'd1, crm = {1'b0, crq} + {1'b0, cwr} + 9'd1;
    reg  [31:0] cbw, crw;                // Cb / Cr words being packed (odd lines)
    reg        push_cr;                  // the Cr word goes in the clock after the Cb word
    reg        f_we; reg [33:0] f_wd;    // FIFO push {tag, data}: 0 Y, 1 Cb, 2 Cr, 3 field start (data = slot)
    // a field begins: a free slot, or the field is dropped
    wire d_fstart_go = d_fstart && recording && scnt != 2'd3;
    reg  enc_done;                       // pulse: the encoder finished slot shead
    always @(posedge clk) begin
        f_we <= 1'b0; cw <= 1'b0; push_cr <= 1'b0;
        if (d_valid && cap && d_line < H) begin
            yw <= {d_y, yw[31:8]};
            if (d_x[1:0] == 2'd3) begin f_we <= 1'b1; f_wd <= {2'd0, d_y, yw[31:8]}; end
            if (!d_x[0]) begin cb0 <= d_cb; cr0 <= d_cr; end
            else begin
                cw <= 1'b1; cwx <= d_x[9:1]; codd <= d_line[0];
                cwb <= ({1'b0, cb0} + {1'b0, d_cb} + 9'd1) >> 1;
                cwr <= ({1'b0, cr0} + {1'b0, d_cr} + 9'd1) >> 1;
            end
        end
        {cbq, crq} <= cev[d_x[9:1]];
        if (cw && !codd) cev[cwx] <= {cwb, cwr};
        if (cw && codd) begin
            cbw <= {cbm[8:1], cbw[31:8]}; crw <= {crm[8:1], crw[31:8]};
            if (cwx[1:0] == 2'd3) begin f_we <= 1'b1; f_wd <= {2'd1, cbm[8:1], cbw[31:8]}; push_cr <= 1'b1; end
        end
        if (push_cr) begin f_we <= 1'b1; f_wd <= {2'd2, crw}; end
        if (d_fstart_go) begin f_we <= 1'b1; f_wd <= {2'd3, 30'd0, wslot}; end
    end
    always @(posedge clk) begin
        if (rst) begin cap <= 1'b0; scnt <= 2'd0; shead <= 2'd0; dropped <= 16'd0; end
        else begin
            if (d_fstart) begin
                cap <= 1'b0;
                if (d_fstart_go) begin cap <= 1'b1; H <= pal ? 9'd288 : 9'd240; pal_s[wslot] <= pal; par_s[wslot] <= d_parity; end
                else if (recording) dropped <= dropped + 16'd1;
            end
            if (cap && d_valid && d_x == 10'd719 && d_line == H - 9'd1) cap <= 1'b0;
            scnt <= scnt + {1'b0, d_fstart_go} - {1'b0, enc_done};
            if (enc_done) shead <= shead + 2'd1;
        end
    end
    // ================= FIFO (block RAM, read ahead) =================
    reg  [33:0] fifo [0:511];
    reg  [8:0]  fw, fr; reg [33:0] fq; reg fq_ok;
    wire        f_pop;
    wire [8:0]  fr_n = fr + {8'd0, f_pop};
    always @(posedge clk) begin
        if (f_we) fifo[fw] <= f_wd;
        fq <= fifo[fr_n]; fq_ok <= fw != fr_n && !f_pop;     // the word at fr is in fq one clock after fr moves
        if (rst) begin fw <= 9'd0; fr <= 9'd0; fq_ok <= 1'b0; end
        else begin if (f_we) fw <= fw + 9'd1; fr <= fr_n; end
    end
    // ================= drain: FIFO words to their SDRAM addresses =================
    reg  [1:0]  dslot;
    reg  [7:0]  yk; reg [8:0] yl; reg [15:0] ybase;   // Y word in the line, lines done, block row base
    reg  [7:0]  ck; reg [7:0] cl; reg [15:0] cbase;   // Cb / Cr word pair in the line, chroma lines done
    wire [2:0]  yr = yl[2:0], crr = cl[2:0];
    wire [15:0] yoff = ybase + {4'd0, yk[7:1], 4'd0} + {11'd0, yr, 1'b0} + {15'd0, yk[0]};
    wire [15:0] coff = cbase + {3'd0, ck[7:1], 5'd0} + {11'd0, fq[33], 4'd0} + {11'd0, crr, 1'b0} + {15'd0, ck[0]};
    wire [20:0] d_addr = fq[33:32] == 2'd0 ? {dslot, 3'd0, yoff} : {dslot, 3'd1, coff};
    wire        d_mark = fq_ok && fq[33:32] == 2'd3;
    reg         d_busy;                  // a write was taken and its word not yet pulled: no new request
    wire        d_want = fq_ok && !d_mark && !d_busy;
    // SDRAM requests: the drain first, the encoder's block reads otherwise
    wire        s_ack, s_wnext, s_rv; wire [31:0] s_rd;
    reg         r_want; reg [20:0] r_addr;
    wire        s_req = d_want || r_want;
    wire        s_we = d_want;
    wire [20:0] s_addr = d_want ? d_addr : r_addr;
    wire [4:0]  s_len = d_want ? 5'd1 : 5'd16;
    assign f_pop = s_wnext || d_mark;
    reg         req_was_we; always @(posedge clk) req_was_we <= s_we;   // the request the controller saw
    always @(posedge clk) if (rst || s_wnext) d_busy <= 1'b0; else if (s_ack && req_was_we) d_busy <= 1'b1;
    always @(posedge clk) begin
        if (rst) begin comp <= 4'd0; yl <= 9'd0; cl <= 8'd0; yk <= 8'd0; ck <= 8'd0; ybase <= 16'd0; cbase <= 16'd0; dslot <= 2'd0; end
        else begin
            if (d_mark) begin                                   // a new field: the slot before it is complete
                comp[dslot] <= 1'b1; comp[fq[1:0]] <= 1'b0; dslot <= fq[1:0];
                yl <= 9'd0; cl <= 8'd0; yk <= 8'd0; ck <= 8'd0; ybase <= 16'd0; cbase <= 16'd0;
            end else if (s_wnext) begin
                if (fq[33:32] == 2'd0) begin
                    if (yk == 8'd179) begin
                        yk <= 8'd0; yl <= yl + 9'd1;
                        if (yr == 3'd7) ybase <= ybase + 16'd1440;
                    end else yk <= yk + 8'd1;
                end else if (fq[33:32] == 2'd2) begin                // a Cr word ends a pair
                    if (ck == 8'd89) begin
                        ck <= 8'd0; cl <= cl + 8'd1;
                        if (crr == 3'd7) cbase <= cbase + 16'd1440;
                    end else ck <= ck + 8'd1;
                end
            end
            if (d_fstart_go) comp[wslot] <= 1'b0;             // not before the drain fills it
            if (!d_mark && yl == (pal_s[dslot] ? 9'd288 : 9'd240) && cl == (pal_s[dslot] ? 8'd144 : 8'd120)) comp[dslot] <= 1'b1;
        end
    end
    sdram u_ram (.clk(clk), .rst(rst), .ready(), .req(s_req), .req_we(s_we), .req_addr(s_addr), .req_len(s_len),
                 .req_ack(s_ack), .busy(), .wr_data(fq[31:0]), .wr_next(s_wnext), .rd_valid(s_rv), .rd_data(s_rd),
                 .O_sdram_clk(O_sdram_clk), .O_sdram_cke(O_sdram_cke), .O_sdram_cs_n(O_sdram_cs_n), .O_sdram_ras_n(O_sdram_ras_n),
                 .O_sdram_cas_n(O_sdram_cas_n), .O_sdram_wen_n(O_sdram_wen_n), .O_sdram_addr(O_sdram_addr), .O_sdram_ba(O_sdram_ba),
                 .O_sdram_dqm(O_sdram_dqm), .IO_sdram_dq(IO_sdram_dq));
    // ================= encoder side =================
    wire        e_busy, e_done, e_rdy, e_valid; wire [17:0] e_bytes; wire [7:0] e_data;
    reg         e_start, e_end, e_we, e_commit; reg [3:0] e_addr; reg [31:0] e_wd; reg [1:0] e_comp;
    reg  [15:0] seq;
    wire        ring_ready;
    wire        epal = pal_s[shead];
    jpeg_enc u_enc (.clk(clk), .rst(rst), .f_start(e_start), .qi(qi), .pal(epal), .parity(par_s[shead]), .seq(seq), .f_end(e_end),
                    .busy(e_busy), .f_done(e_done), .f_bytes(e_bytes), .in_rdy(e_rdy), .in_we(e_we), .in_addr(e_addr),
                    .in_data(e_wd), .in_comp(e_comp), .in_commit(e_commit), .o_valid(e_valid), .o_data(e_data), .o_ready(ring_ready));
    reg         in_field, ending;
    reg  [4:0]  my;                      // strip
    reg  [5:0]  mx; reg [2:0] blk;
    reg  [15:0] ys, cs;                  // strip bases: my * 2880 (Y), my * 1440 (Cb / Cr)
    reg  [2:0]  fph; reg [4:0] nw;
    wire [4:0]  nstrips = epal ? 5'd18 : 5'd15;
    wire        strip_in = comp[shead] || (dslot == shead && !comp[shead] &&
                           yl >= {my, 4'd0} + 9'd16 && {1'b0, cl} >= {1'b0, my, 3'd0} + 9'd8);
    wire [15:0] yblk = ys + (blk[1] ? 16'd1440 : 16'd0) + {5'd0, mx, 5'd0} + {11'd0, blk[0], 4'd0};
    wire [15:0] cblk = cs + {5'd0, mx, 5'd0} + {11'd0, blk == 3'd5, 4'd0};
    always @(posedge clk) begin
        e_start <= 1'b0; e_end <= 1'b0; e_we <= 1'b0; e_commit <= 1'b0; enc_done <= 1'b0;
        if (rst) begin
            in_field <= 1'b0; ending <= 1'b0; r_want <= 1'b0; fph <= 3'd0; seq <= 16'd0; qi <= 3'd3; fields <= 16'd0;
        end else begin
            if (!in_field && !ending) begin
                if (scnt != 2'd0 && !enc_done && !e_busy && !e_start) begin   // (scnt drops the clock after enc_done)
                    in_field <= 1'b1; e_start <= 1'b1; seq <= seq + 16'd1;
                    my <= 5'd0; mx <= 6'd0; blk <= 3'd0; ys <= 16'd0; cs <= 16'd0; fph <= 3'd0;
                end
            end else if (in_field) case (fph)
                3'd0: if (strip_in && e_rdy && !e_start) begin           // read the block: 16 words
                    r_want <= 1'b1; r_addr <= blk < 3'd4 ? {shead, 3'd0, yblk} : {shead, 3'd1, cblk}; fph <= 3'd1; nw <= 5'd0;
                end
                3'd1: begin
                    if (s_ack && !req_was_we) r_want <= 1'b0;
                    if (s_rv) begin
                        e_we <= 1'b1; e_addr <= nw[3:0]; e_wd <= s_rd; nw <= nw + 5'd1;
                        if (nw == 5'd15) fph <= 3'd2;
                    end
                end
                3'd2: begin e_commit <= 1'b1; e_comp <= blk < 3'd4 ? 2'd0 : blk == 3'd5 ? 2'd2 : 2'd1; fph <= 3'd3; end
                3'd3: fph <= 3'd4;                                       // in_rdy follows the commit
                default: begin
                    fph <= 3'd0;
                    if (blk != 3'd5) blk <= blk + 3'd1;
                    else begin
                        blk <= 3'd0;
                        if (mx != 6'd44) mx <= mx + 6'd1;
                        else begin
                            mx <= 6'd0; my <= my + 5'd1; ys <= ys + 16'd2880; cs <= cs + 16'd1440;
                            if (my + 5'd1 == nstrips) begin in_field <= 1'b0; ending <= 1'b1; e_end <= 1'b1; end
                        end
                    end
                end
            endcase
            if (ending && e_done) begin ending <= 1'b0; enc_done <= 1'b1; end
            // rate control on the finished field
            if (e_done) begin
                fields <= fields + 16'd1;
                if (e_bytes > (epal ? TARGET_P : TARGET_N) + ((epal ? TARGET_P : TARGET_N) >> 3)) begin if (qi != 3'd0) qi <= qi - 3'd1; end
                else if (e_bytes < (epal ? TARGET_P : TARGET_N) - ((epal ? TARGET_P : TARGET_N) >> 2)) begin if (qi != 3'd7) qi <= qi + 3'd1; end
            end
        end
    end
    // ================= ring and card =================
    reg  [7:0]  ring [0:8191];
    reg  [15:0] wp;
    wire [15:0] rp, used;
    reg  [7:0]  rb_rd;
    assign used = wp - rp;
    assign ring_ready = used < 16'd8192;
    wire idle = !e_busy && scnt == 2'd0 && !cap && !in_field && !ending && fw == fr;
    // after the last record: zeros up to a whole sector, so it reaches the card
    wire pad = !rs[1] && idle && wp[8:0] != 9'd0 && state == 2'd2;
    always @(posedge clk) begin
        if (rst) wp <= 16'd0;
        else if (e_valid && ring_ready) begin ring[wp[12:0]] <= e_data; wp <= wp + 16'd1; end
        else if (pad && ring_ready) begin ring[wp[12:0]] <= 8'd0; wp <= wp + 16'd1; end
        rb_rd <= ring[rp[12:0]];
    end
    sd_ring u_sd (.clk(clk), .rst(rst), .rec_on(rs[1]), .src_idle(idle && wp[8:0] == 9'd0),
                  .wp(wp), .used(used), .rb_rd(rb_rd), .rp(rp), .sd_cs(sd_cs), .sd_sck(sd_sck), .sd_mosi(sd_mosi),
                  .sd_miso(sd_miso), .state(state));
endmodule
`default_nettype wire
