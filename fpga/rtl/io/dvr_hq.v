// Triversity HQ DVR (TRI_HQDVR build): every field as a colour JPEG, 720 x 240
// (NTSC) or 720 x 288 (PAL), into TRIDVR.BIN on the TF card. 40 MHz domain.
//  - vid_sync's DVR stream (720 pixels a line: Y, Cb, Cr) goes into a strip
//    buffer of 2 x 16 lines (Y) and 2 x 8 lines of Cb / Cr at 4:2:0
//    (h = (c[2x] + c[2x+1] + 1) >> 1 on both lines of a pair, then (h_even + h_odd + 1) >> 1)
//  - a finished strip is fed to jpeg_enc.v in MCU order (Y 0,0 0,8 8,0 8,8, Cb, Cr)
//  - the records (prefix + JPEG) go through an 8 KB ring to the card (sd_ring.v)
//  - TARGET: ~1.47 MB/s (24 KB x 59.94, 29 KB x 50), what SPI mode at 20 MHz
//    sustains with room for the card's busy times
//  - a field starts only with the encoder idle and the ring at most half
//    full, else it is dropped; the quality index follows the field sizes
//    (down above TARGET + 1/8, up below 3/4 TARGET), from 3 (quality 60)
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
    output reg  [15:0] dropped
);
    reg [1:0] rs; always @(posedge clk) rs <= {rs[0], rec};
    wire recording = rs[1] && state == 2'd2;
    // ---- strip buffers ----
    reg  [7:0] ybuf [0:23039];           // {strip, row 0..15} x 720
    reg  [15:0] cbcr [0:5759];           // {Cb, Cr} {strip, row 0..7} x 360
    wire       s_w = d_line[4];          // strip being written
    wire [4:0] yrow = {s_w, d_line[3:0]};
    wire [14:0] ya = {yrow, 9'd0} + {2'd0, yrow, 7'd0} + {3'd0, yrow, 6'd0} + {5'd0, yrow, 4'd0} + {5'd0, d_x};   // row * 720 + x
    wire [3:0] crow = {s_w, d_line[3:1]};
    wire [13:0] ca = {crow, 8'd0} + {2'd0, crow, 6'd0} + {3'd0, crow, 5'd0} + {5'd0, crow, 3'd0} + {5'd0, d_x[9:1]};  // row * 360 + x / 2
    reg  [7:0] cb0, cr0;                 // the even pixel
    reg        cw; reg [13:0] cwa; reg [8:0] cwx; reg [7:0] cwb, cwr; reg codd;
    // the even line's pairs wait in cev; the odd line averages with them and
    // writes cbcr (both memories one write and one read port: simple dual port)
    reg  [15:0] cev [0:511];
    reg  [7:0] cbq, crq;                 // the even line's pair at this x
    wire [8:0] cbm = {1'b0, cbq} + {1'b0, cwb} + 9'd1, crm = {1'b0, crq} + {1'b0, cwr} + 9'd1;
    reg        cap;                      // capturing this field
    reg  [8:0] H;                        // lines in the field
    always @(posedge clk) begin
        if (d_valid && cap && d_line < H) ybuf[ya] <= d_y;
        cw <= 1'b0;
        if (d_valid && cap && d_line < H) begin
            if (!d_x[0]) begin cb0 <= d_cb; cr0 <= d_cr; end
            else begin
                cw <= 1'b1; cwa <= ca; cwx <= d_x[9:1]; codd <= d_line[0];
                cwb <= ({1'b0, cb0} + {1'b0, d_cb} + 9'd1) >> 1;
                cwr <= ({1'b0, cr0} + {1'b0, d_cr} + 9'd1) >> 1;
            end
        end
        {cbq, crq} <= cev[d_x[9:1]];
        if (cw && !codd) cev[cwx] <= {cwb, cwr};
        if (cw && codd) cbcr[cwa] <= {cbm[8:1], crm[8:1]};
    end
    // ---- the encoder and the feeder ----
    wire        e_busy, e_done, e_rdy, e_valid; wire [17:0] e_bytes; wire [7:0] e_data;
    reg         e_start, e_end, e_we, e_commit; reg [5:0] e_addr; reg [7:0] e_wd; reg [1:0] e_comp;
    reg  [15:0] seq;
    wire        ring_ready;
    jpeg_enc u_enc (.clk(clk), .rst(rst), .f_start(e_start), .qi(qi), .pal(pal), .parity(d_parity), .seq(seq), .f_end(e_end),
                    .busy(e_busy), .f_done(e_done), .f_bytes(e_bytes), .in_rdy(e_rdy), .in_we(e_we), .in_addr(e_addr),
                    .in_data(e_wd), .in_comp(e_comp), .in_commit(e_commit), .o_valid(e_valid), .o_data(e_data), .o_ready(ring_ready));
    reg  [1:0] s_ready;                  // strips written, waiting for the feeder
    reg        s_rd;                     // strip being fed
    reg  [4:0] strips_fed, strips_all;
    reg        feeding;
    reg  [5:0] mx; reg [2:0] blk; reg [6:0] k; reg [2:0] fph;
    // read address of sample k (r = k[5:3], c = k[2:0]) of block blk in MCU mx
    wire [2:0] fr = k[5:3], fc = k[2:0];
    wire [4:0] yr = {s_rd, blk[1], fr};          // strip, by (0 / 8) + r
    wire [9:0] yx = {mx, 4'd0} + {6'd0, blk[0], fc};
    wire [14:0] fya = {yr, 9'd0} + {2'd0, yr, 7'd0} + {3'd0, yr, 6'd0} + {5'd0, yr, 4'd0} + {5'd0, yx};
    wire [3:0] cr_ = {s_rd, fr};
    wire [13:0] fca = {cr_, 8'd0} + {2'd0, cr_, 6'd0} + {3'd0, cr_, 5'd0} + {5'd0, cr_, 3'd0} + {5'd0, mx, fc};
    reg  [7:0] yq2, cbq2, crq2;
    always @(posedge clk) begin yq2 <= ybuf[fya]; {cbq2, crq2} <= cbcr[fca]; end
    wire [7:0] cq2 = blk == 3'd5 ? crq2 : cbq2;
    reg  [6:0] k_d; reg rd_v;
    // ---- field control ----
    reg        fend_pending, start_pend, in_field;
    reg        force_fill;                // the field ended short: feed its remaining strips as they are
    wire [15:0] used;
    wire       ring_half = used >= 16'd4096;
    always @(posedge clk) begin
        e_start <= 1'b0; e_end <= 1'b0; e_we <= 1'b0; e_commit <= 1'b0;
        if (rst) begin
            cap <= 1'b0; s_ready <= 2'b00; feeding <= 1'b0; qi <= 3'd3; seq <= 16'd0; fields <= 16'd0; dropped <= 16'd0;
            fend_pending <= 1'b0; rd_v <= 1'b0; start_pend <= 1'b0; in_field <= 1'b0; force_fill <= 1'b0;
        end else begin
            // a field begins
            // (the encoder may still finish the last field: the start waits for it, the
            //  strips of the new field arrive ~1.3 ms later, after the vertical blanking)
            if (d_fstart) begin
                if (cap) begin cap <= 1'b0; force_fill <= 1'b1; end    // short field (lost sync): finish it
                if (recording && !cap && !start_pend && !ring_half) begin
                    cap <= 1'b1; H <= pal ? 9'd288 : 9'd240; start_pend <= 1'b1;
                end else if (recording) dropped <= dropped + 16'd1;
            end
            if (start_pend && !e_busy && !in_field && !e_start) begin
                start_pend <= 1'b0; in_field <= 1'b1; e_start <= 1'b1; seq <= seq + 16'd1;
                strips_all <= pal ? 5'd18 : 5'd15; strips_fed <= 5'd0; s_rd <= 1'b0;
            end
            // a strip is complete: its last line's last pixel
            if (cap && d_valid && d_x == 10'd719 && d_line[3:0] == 4'd15 && d_line < H) begin
                s_ready[d_line[4]] <= 1'b1;
                if (d_line == H - 9'd1) cap <= 1'b0;
            end
            // the feeder
            rd_v <= 1'b0;
            if (!feeding) begin
                if (in_field && (s_ready[s_rd] || force_fill) && e_rdy && !e_start) begin feeding <= 1'b1; mx <= 6'd0; blk <= 3'd0; k <= 7'd0; fph <= 3'd0; end
            end else case (fph)
                3'd0: begin                                           // read 64 samples (one clock late)
                    rd_v <= 1'b1; k_d <= k; k <= k + 7'd1;
                    if (k == 7'd63) fph <= 3'd1;
                end
                3'd1: fph <= 3'd2;                                    // the last sample lands
                3'd2: begin e_commit <= 1'b1; e_comp <= blk < 3'd4 ? 2'd0 : blk == 3'd4 ? 2'd1 : 2'd2; fph <= 3'd3; end
                3'd3: fph <= 3'd4;                                    // in_rdy follows the commit
                default: if (e_rdy) begin
                    k <= 7'd0; fph <= 3'd0;
                    if (blk == 3'd5) begin
                        blk <= 3'd0;
                        if (mx == 6'd44) begin
                            feeding <= 1'b0; s_ready[s_rd] <= 1'b0; s_rd <= ~s_rd;
                            strips_fed <= strips_fed + 5'd1;
                            if (strips_fed + 5'd1 == strips_all) fend_pending <= 1'b1;
                        end else mx <= mx + 6'd1;
                    end else blk <= blk + 3'd1;
                end
            endcase
            if (rd_v) begin e_we <= 1'b1; e_addr <= k_d[5:0]; e_wd <= blk < 3'd4 ? yq2 : cq2; end
            if (fend_pending && !feeding) begin e_end <= 1'b1; fend_pending <= 1'b0; in_field <= 1'b0; force_fill <= 1'b0; end
            // rate control on the finished field
            if (e_done) begin
                fields <= fields + 16'd1;
                if (e_bytes > (pal ? TARGET_P : TARGET_N) + ((pal ? TARGET_P : TARGET_N) >> 3)) begin if (qi != 3'd0) qi <= qi - 3'd1; end
                else if (e_bytes < (pal ? TARGET_P : TARGET_N) - ((pal ? TARGET_P : TARGET_N) >> 2)) begin if (qi != 3'd7) qi <= qi + 3'd1; end
            end
        end
    end
    // ---- ring and card ----
    reg  [7:0]  ring [0:8191];
    reg  [15:0] wp;
    wire [15:0] rp;
    reg  [7:0]  rb_rd;
    assign used = wp - rp;
    assign ring_ready = used < 16'd8192;
    wire idle = !e_busy && !cap && !feeding && !fend_pending && !start_pend && !in_field;
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
